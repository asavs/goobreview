// PR-head snapshot: the GitHub tarball of one SHA, extracted into a fresh
// directory, hardened, then made read-only. The reviewer reads this tree
// through tools.ts; nothing ever executes from it.

import { randomBytes } from "node:crypto";
import { chmod, lstat, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import * as tar from "tar";
import type { GitHubPort, Logger, RepoRef, Snapshot } from "./types.js";

/** Hard caps against tarball bombs. GitHub repos near these are unreviewable anyway. */
export const SNAPSHOT_MAX_ENTRIES = 200_000;
export const SNAPSHOT_MAX_BYTES = 2 * 1024 ** 3;
/** Leftover snapshot dirs (crashed runs) older than this are evicted on the next prepare (#166). */
export const SNAPSHOT_STALE_MS = 6 * 60 * 60 * 1000;

// v1 named AGENTS.md, CONTRIBUTING.md and GUIDELINES.md at any depth (the one
// nearest a changed file governs it); CLAUDE.md is the same kind of file.
const GUIDANCE_NAMES = new Set(["AGENTS.md", "CONTRIBUTING.md", "GUIDELINES.md", "CLAUDE.md"]);
const GUIDANCE_MAX = 50;

const ALLOWED_TYPES = new Set(["File", "OldFile", "ContiguousFile", "Directory"]);
const REFUSED_TYPES = new Set(["Link", "CharacterDevice", "BlockDevice", "FIFO"]);

export class SnapshotError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SnapshotError";
  }
}

const snapshotsDir = (workDir: string): string => path.join(path.resolve(workDir), "snapshots");

/** Repo-relative path after dropping GitHub's single top-level `<owner>-<repo>-<sha>/` dir. */
function stripTop(entryPath: string): string {
  const parts = entryPath.replace(/\\/g, "/").split("/").filter((p) => p !== "" && p !== ".");
  return parts.slice(1).join("/");
}

function isUnsafePath(entryPath: string): boolean {
  const p = entryPath.replace(/\\/g, "/");
  return p.startsWith("/") || /^[A-Za-z]:/.test(p) || p.split("/").includes("..") || p.includes("\0");
}

export async function prepareSnapshot(
  gh: GitHubPort,
  repo: RepoRef,
  sha: string,
  workDir: string,
  log: Logger,
): Promise<Snapshot> {
  return snapshotFromArchive((dest) => gh.downloadTarball(repo, sha, dest), sha, workDir, log);
}

/**
 * Builds a snapshot from any gzipped tarball with one top-level directory,
 * so trees that never came from GitHub (eval corpora) get the same hardening.
 */
export async function snapshotFromArchive(
  writeArchive: (destFile: string) => Promise<void>,
  sha: string,
  workDir: string,
  log: Logger,
): Promise<Snapshot> {
  if (!/^[0-9a-f]{7,64}$/i.test(sha)) throw new SnapshotError(`refusing unexpected head SHA: ${sha}`);
  const parent = snapshotsDir(workDir);
  await mkdir(parent, { recursive: true });
  await evictStale(parent, log);

  const id = `${sha}-${randomBytes(4).toString("hex")}`;
  const archive = path.join(parent, `${id}.tar.gz`);
  const root = path.join(parent, id);
  await mkdir(root);

  const links: { rel: string; target: string }[] = [];
  let violation: string | undefined;
  let entries = 0;
  let bytes = 0;

  try {
    await writeArchive(archive);
    await tar.x({
      file: archive,
      cwd: root,
      strip: 1,
      // Entry-level policy. Filter must not throw (it runs inside the parser
      // stream), so the first violation is recorded and every later entry is
      // skipped; the snapshot is rejected after extraction.
      filter: (entryPath, entry) => {
        if (violation) return false;
        const type = "type" in entry ? String(entry.type) : "File";
        if (isUnsafePath(entryPath)) {
          violation = `unsafe path in tarball: ${JSON.stringify(entryPath)}`;
          return false;
        }
        if (REFUSED_TYPES.has(type)) {
          violation = `refusing ${type} entry: ${JSON.stringify(entryPath)}`;
          return false;
        }
        if (++entries > SNAPSHOT_MAX_ENTRIES) {
          violation = `tarball has more than ${SNAPSHOT_MAX_ENTRIES} entries`;
          return false;
        }
        bytes += "size" in entry && typeof entry.size === "number" ? entry.size : 0;
        if (bytes > SNAPSHOT_MAX_BYTES) {
          violation = `tarball expands past ${SNAPSHOT_MAX_BYTES} bytes`;
          return false;
        }
        const rel = stripTop(entryPath);
        if (type === "SymbolicLink") {
          // Never materialise links (#47): record them and write stubs below.
          if (rel) links.push({ rel, target: "linkpath" in entry ? String(entry.linkpath ?? "") : "" });
          return false;
        }
        return ALLOWED_TYPES.has(type);
      },
    });
    if (violation) throw new SnapshotError(violation);

    const symlinkStubs: string[] = [];
    for (const { rel, target } of links) {
      const dest = path.join(root, rel);
      const existing = await lstat(dest).catch(() => undefined);
      if (existing?.isDirectory()) {
        log.warn("snapshot: symlink path collides with a directory; stub skipped", { path: rel });
        continue;
      }
      await mkdir(path.dirname(dest), { recursive: true });
      await writeFile(
        dest,
        `goobreview: symlink metadata only; target content was not read.\npath: ${rel}\ntarget: ${target}\n`,
      );
      symlinkStubs.push(rel);
      log.info("snapshot: neutralized symlink", { path: rel, target });
    }

    const generatedPatterns = symlinkStubs.includes(".gitattributes")
      ? []
      : await readGeneratedPatterns(path.join(root, ".gitattributes"));

    await makeReadOnly(root);
    return { root, sha, generatedPatterns, symlinkStubs };
  } catch (err) {
    await removeTree(root).catch(() => undefined);
    throw err instanceof SnapshotError ? err : new SnapshotError(`snapshot of ${sha} failed: ${(err as Error).message}`);
  } finally {
    await rm(archive, { force: true }).catch(() => undefined);
  }
}

export async function removeSnapshot(s: Snapshot): Promise<void> {
  await removeTree(s.root);
}

/** Guidance files in the snapshot as repo-relative paths, shallowest first. */
export async function findGuidanceFiles(s: Snapshot): Promise<string[]> {
  const stubs = new Set(s.symlinkStubs);
  const found: string[] = [];
  const queue = [""];
  while (queue.length > 0 && found.length < GUIDANCE_MAX) {
    const rel = queue.shift() as string;
    const dirents = await readdir(path.join(s.root, rel), { withFileTypes: true }).catch(() => []);
    dirents.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const d of dirents) {
      const child = rel ? `${rel}/${d.name}` : d.name;
      if (d.isDirectory()) {
        if (d.name !== "node_modules" && d.name !== ".git") queue.push(child);
      } else if (d.isFile() && !stubs.has(child) && GUIDANCE_NAMES.has(d.name)) {
        // .github/CONTRIBUTING.md is covered by the name match.
        found.push(child);
      }
    }
  }
  return found.slice(0, GUIDANCE_MAX);
}

/**
 * linguist-generated patterns from a root .gitattributes, as written (a leading
 * `/` still anchors; see matchesGitPattern). The last generated/negated
 * attribute on a line wins, matching v1.
 */
export async function readGeneratedPatterns(file: string): Promise<string[]> {
  const st = await lstat(file).catch(() => undefined);
  if (!st?.isFile() || st.size > 1024 * 1024) return [];
  const text = await readFile(file, "utf8");
  const out: string[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const [pattern, ...attrs] = line.split(/\s+/);
    if (!pattern || pattern === "/" || attrs.length === 0) continue;
    let generated = false;
    for (const a of attrs) {
      if (a === "linguist-generated" || a === "linguist-generated=true") generated = true;
      if (a === "-linguist-generated" || a === "!linguist-generated" || a === "linguist-generated=false") generated = false;
    }
    if (generated) out.push(pattern);
  }
  return out;
}

// ---------------------------------------------------------------------------
// gitattributes-style glob matching, shared by prompt.ts (generated files) and
// tools.ts (grep's glob). A pattern without `/` matches the basename at any
// depth; one with `/` is anchored at the repo root. `*` and `?` stay within a
// path segment; `**` crosses segments.

export function gitPatternToRegExp(pattern: string): RegExp {
  let p = pattern.replace(/\\/g, "/");
  // Only a leading or middle slash anchors; a trailing one just means "directory".
  const anchored = p.replace(/\/+$/, "").includes("/");
  if (p.startsWith("/")) p = p.slice(1);
  // A trailing slash names a directory: match everything under it.
  if (p.endsWith("/")) p += "**";
  let re = "";
  for (let i = 0; i < p.length; i++) {
    const c = p[i] as string;
    if (c === "*") {
      if (p[i + 1] === "*") {
        const atStart = i === 0 || p[i - 1] === "/";
        const atEnd = i + 2 === p.length || p[i + 2] === "/";
        if (atStart && atEnd) {
          // `**/` = zero or more directories; trailing `/**` = everything inside.
          if (p[i + 2] === "/") {
            re += "(?:.*/)?";
            i += 2;
          } else {
            re += ".*";
            i += 1;
          }
          continue;
        }
        re += "[^/]*";
        i += 1;
        continue;
      }
      re += "[^/]*";
    } else if (c === "?") {
      re += "[^/]";
    } else if (c === "[") {
      const close = p.indexOf("]", i + 2);
      if (close === -1) {
        re += "\\[";
      } else {
        let body = p.slice(i + 1, close).replace(/\\/g, "\\\\");
        if (body.startsWith("!")) body = "^" + body.slice(1);
        re += `[${body}]`;
        i = close;
      }
    } else {
      re += c.replace(/[.+^${}()|\\]/g, "\\$&");
    }
  }
  return new RegExp(anchored ? `^${re}$` : `(?:^|/)${re}$`);
}

export function matchesGitPattern(filePath: string, pattern: string): boolean {
  return gitPatternToRegExp(pattern).test(filePath.replace(/\\/g, "/"));
}

// ---------------------------------------------------------------------------

async function makeReadOnly(dir: string): Promise<void> {
  for (const d of await readdir(dir, { withFileTypes: true })) {
    const p = path.join(dir, d.name);
    if (d.isDirectory()) await makeReadOnly(p);
    else if (d.isFile()) await chmod(p, 0o444);
  }
  await chmod(dir, 0o555);
}

async function makeWritable(dir: string): Promise<void> {
  await chmod(dir, 0o755).catch(() => undefined);
  for (const d of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
    const p = path.join(dir, d.name);
    if (d.isDirectory()) await makeWritable(p);
    else await chmod(p, 0o644).catch(() => undefined);
  }
}

async function removeTree(dir: string): Promise<void> {
  if (!(await stat(dir).catch(() => undefined))) return;
  await makeWritable(dir);
  await rm(dir, { recursive: true, force: true });
}

async function evictStale(parent: string, log: Logger): Promise<void> {
  const now = Date.now();
  for (const d of await readdir(parent, { withFileTypes: true }).catch(() => [])) {
    const p = path.join(parent, d.name);
    const st = await lstat(p).catch(() => undefined);
    if (!st || now - st.mtimeMs < SNAPSHOT_STALE_MS) continue;
    try {
      if (d.isDirectory()) await removeTree(p);
      else await rm(p, { force: true });
      log.info("snapshot: evicted stale snapshot", { name: d.name });
    } catch (err) {
      log.warn("snapshot: eviction failed", { name: d.name, error: (err as Error).message });
    }
  }
}
