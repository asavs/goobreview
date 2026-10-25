// Read-only tools confined to the PR-head snapshot. No shell, no link
// following, every result size-capped and secret-redacted before the model
// sees it. Failures throw; pi reports thrown errors to the model.

import { lstat, open, readdir, realpath } from "node:fs/promises";
import path from "node:path";
import { Worker } from "node:worker_threads";
import type { AgentTool, AgentToolResult } from "@earendil-works/pi-agent-core";
import { Type } from "@earendil-works/pi-ai";
import { redact, truncateUtf8 } from "./redact.js";
import { gitPatternToRegExp } from "./snapshot.js";
import type { ExecutorLimits, Snapshot } from "./types.js";

export const READ_FILE_MAX_BYTES = 8 * 1024 * 1024;
export const GREP_PATTERN_MAX_CHARS = 500;
export const GREP_DEFAULT_RESULTS = 100;
export const GREP_MAX_RESULTS = 500;
export const GREP_TIMEOUT_MS = 10_000;
export const GREP_LINE_SCAN_CHARS = 4_000;
export const GREP_FILE_MAX_BYTES = 2 * 1024 * 1024;
export const GREP_TOTAL_MAX_BYTES = 64 * 1024 * 1024;
export const LIST_DIR_MAX_ENTRIES = 1_000;
const BINARY_SNIFF_BYTES = 8_000;

export class ToolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ToolError";
  }
}

interface Resolved {
  abs: string;
  /** Repo-relative, `/`-separated; "" for the root. */
  rel: string;
}

/** Resolve a model-supplied path inside the snapshot, refusing every escape. */
export async function resolveInside(root: string, input: string | undefined): Promise<Resolved> {
  const raw = (input ?? "").trim();
  if (raw.includes("\0")) throw new ToolError("path contains a NUL byte");
  const p = raw.replace(/\\/g, "/");
  if (p.startsWith("/") || /^[A-Za-z]:/.test(p) || path.isAbsolute(raw)) {
    throw new ToolError(`absolute paths are not allowed; use a repository-relative path (got ${JSON.stringify(raw)})`);
  }
  const segs = p.split("/").filter((s) => s !== "" && s !== ".");
  if (segs.includes("..")) throw new ToolError(`".." is not allowed in paths (got ${JSON.stringify(raw)})`);

  const realRoot = await realpath(root);
  let cur = realRoot;
  for (const s of segs) {
    cur = path.join(cur, s);
    const st = await lstat(cur).catch(() => undefined);
    if (!st) throw new ToolError(`no such file or directory: ${segs.join("/")}`);
    if (st.isSymbolicLink()) throw new ToolError(`refusing to follow a symlink: ${segs.join("/")}`);
  }
  const real = await realpath(cur);
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) {
    throw new ToolError(`path escapes the snapshot: ${segs.join("/")}`);
  }
  return { abs: real, rel: segs.join("/") };
}

function isBinary(buf: Buffer): boolean {
  return buf.subarray(0, BINARY_SNIFF_BYTES).includes(0);
}

/** Redact first (a cap must never split a secret into an unrecognised prefix), then cap. */
export function finishResult(text: string, maxBytes: number, hint: string): string {
  const clean = redact(text);
  if (Buffer.byteLength(clean, "utf8") <= maxBytes) return clean;
  const marker = `\n[goobreview omitted: output truncated at ${maxBytes} bytes; ${hint}]`;
  let body = truncateUtf8(clean, Math.max(0, maxBytes - Buffer.byteLength(marker, "utf8")));
  const nl = body.lastIndexOf("\n");
  if (nl > 0) body = body.slice(0, nl);
  return body + marker;
}

const textResult = (text: string, details: Record<string, unknown>): AgentToolResult<Record<string, unknown>> => ({
  content: [{ type: "text", text }],
  details,
});

// ---------------------------------------------------------------------------

const readFileParams = Type.Object({
  path: Type.String({ description: "Repository-relative file path, e.g. src/index.ts" }),
  start_line: Type.Optional(Type.Integer({ minimum: 1, description: "First line to return (1-based, inclusive)" })),
  end_line: Type.Optional(Type.Integer({ minimum: 1, description: "Last line to return (1-based, inclusive)" })),
});

const grepParams = Type.Object({
  pattern: Type.String({ description: "JavaScript regular expression, matched per line" }),
  path: Type.Optional(Type.String({ description: "Repository-relative file or directory to search; default: whole repo" })),
  glob: Type.Optional(Type.String({ description: "gitattributes-style glob on file paths, e.g. *.ts or src/**/*.test.ts" })),
  max_results: Type.Optional(Type.Integer({ minimum: 1, maximum: GREP_MAX_RESULTS, description: `Default ${GREP_DEFAULT_RESULTS}` })),
});

const listDirParams = Type.Object({
  path: Type.Optional(Type.String({ description: "Repository-relative directory; default: repository root" })),
});

export function createReadOnlyTools(
  snapshot: Snapshot,
  limits: ExecutorLimits,
  opts: { grepTimeoutMs?: number } = {},
): AgentTool[] {
  const root = snapshot.root;
  const grepTimeoutMs = opts.grepTimeoutMs ?? GREP_TIMEOUT_MS;
  const cap = limits.toolResultMaxBytes;
  const stubs = new Set(snapshot.symlinkStubs);

  const readFileTool: AgentTool<typeof readFileParams> = {
    name: "read_file",
    label: "Read file",
    description:
      "Read a file from the PR-head snapshot. Output lines are prefixed with their 1-based line number and a tab; " +
      "those numbers are the PR-head (RIGHT side) line numbers. Use start_line/end_line for large files.",
    parameters: readFileParams,
    executionMode: "parallel",
    execute: async (_id, params) => {
      const { abs, rel } = await resolveInside(root, params.path);
      const st = await lstat(abs);
      if (st.isDirectory()) throw new ToolError(`${rel || "."} is a directory; use list_dir`);
      if (!st.isFile()) throw new ToolError(`${rel} is not a regular file`);
      if (st.size > READ_FILE_MAX_BYTES) throw new ToolError(`${rel} is ${st.size} bytes; too large to read, use grep`);
      const buf = await readCapped(abs, READ_FILE_MAX_BYTES);
      if (isBinary(buf)) throw new ToolError(`${rel} looks binary; not shown`);

      const lines = buf.toString("utf8").split(/\r?\n/);
      if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
      const total = lines.length;
      const start = params.start_line ?? 1;
      const end = Math.min(params.end_line ?? total, total);
      if (start > Math.max(total, 1)) throw new ToolError(`start_line ${start} is past the end of ${rel} (${total} lines)`);
      if (end < start) throw new ToolError(`end_line ${end} is before start_line ${start}`);

      const width = String(end).length;
      const body = lines
        .slice(start - 1, end)
        .map((l, i) => `${String(start + i).padStart(width, " ")}\t${l}`)
        .join("\n");
      const note = stubs.has(rel) ? " (symlink stub written by goobreview; not the link target)" : "";
      const text = `${rel}: lines ${start}-${end} of ${total}${note}\n${body}`;
      return textResult(finishResult(text, cap, "narrow the range with start_line/end_line"), { path: rel, start, end, total });
    },
  };

  const grepTool: AgentTool<typeof grepParams> = {
    name: "grep",
    label: "Search files",
    description:
      "Search files in the PR-head snapshot for a JavaScript regular expression, line by line. " +
      "Returns path:line: text. Binary and very large files are skipped; very long lines are only scanned in part.",
    parameters: grepParams,
    executionMode: "parallel",
    execute: async (_id, params, signal) => {
      if (params.pattern.length === 0) throw new ToolError("pattern is empty");
      if (params.pattern.length > GREP_PATTERN_MAX_CHARS) {
        throw new ToolError(`pattern is over ${GREP_PATTERN_MAX_CHARS} characters`);
      }
      try {
        new RegExp(params.pattern);
      } catch (err) {
        throw new ToolError(`invalid regular expression: ${(err as Error).message}`);
      }
      const glob = params.glob ? gitPatternToRegExp(params.glob).source : undefined;
      const start = await resolveInside(root, params.path);
      const maxResults = Math.min(params.max_results ?? GREP_DEFAULT_RESULTS, GREP_MAX_RESULTS);
      const r = await runGrepWorker({
        root: await realpath(root),
        startRel: start.rel,
        pattern: params.pattern,
        glob,
        maxResults,
        lineScanChars: GREP_LINE_SCAN_CHARS,
        fileMaxBytes: GREP_FILE_MAX_BYTES,
        totalMaxBytes: GREP_TOTAL_MAX_BYTES,
        sniffBytes: BINARY_SNIFF_BYTES,
        stubs: [...stubs],
      }, grepTimeoutMs, signal);
      const head =
        r.matches.length === 0
          ? `no matches (${r.filesScanned} files scanned)`
          : `${r.matches.length} match(es) in ${r.filesScanned} files scanned`;
      const stop = r.stopped ? `\n[goobreview omitted: search stopped early: ${r.stopped}]` : "";
      const text = `${head}${stop}\n${r.matches.join("\n")}`;
      return textResult(finishResult(text, cap, "narrow the search with path, glob or a more specific pattern"), {
        matches: r.matches.length,
        filesScanned: r.filesScanned,
        stopped: r.stopped ?? null,
      });
    },
  };

  const listDirTool: AgentTool<typeof listDirParams> = {
    name: "list_dir",
    label: "List directory",
    description: "List a directory in the PR-head snapshot. Directories end with '/'.",
    parameters: listDirParams,
    executionMode: "parallel",
    execute: async (_id, params) => {
      const { abs, rel } = await resolveInside(root, params.path);
      const st = await lstat(abs);
      if (!st.isDirectory()) throw new ToolError(`${rel} is not a directory; use read_file`);
      const dirents = await readdir(abs, { withFileTypes: true });
      dirents.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
      const lines: string[] = [];
      for (const d of dirents.slice(0, LIST_DIR_MAX_ENTRIES)) {
        const child = rel ? `${rel}/${d.name}` : d.name;
        if (d.isDirectory()) lines.push(`${d.name}/`);
        else if (d.isSymbolicLink()) lines.push(`${d.name} (symlink, not followed)`);
        else if (stubs.has(child)) lines.push(`${d.name} (symlink stub)`);
        else lines.push(d.name);
      }
      if (dirents.length > LIST_DIR_MAX_ENTRIES) {
        lines.push(`[goobreview omitted: ${dirents.length - LIST_DIR_MAX_ENTRIES} more entries]`);
      }
      const text = `${rel || "."}/ (${dirents.length} entries)\n${lines.join("\n")}`;
      return textResult(finishResult(text, cap, "list a subdirectory instead"), { path: rel, entries: dirents.length });
    },
  };

  return [readFileTool, grepTool, listDirTool] as unknown as AgentTool[];
}

async function readCapped(file: string, max: number): Promise<Buffer> {
  const fh = await open(file, "r");
  try {
    const buf = Buffer.alloc(max);
    const { bytesRead } = await fh.read(buf, 0, max, 0);
    return buf.subarray(0, bytesRead);
  } finally {
    await fh.close();
  }
}

// ---------------------------------------------------------------------------
// grep runs in a worker so a catastrophic pattern (JS regexes cannot be
// interrupted) is bounded by terminating the thread, not by hoping.

interface GrepJob {
  root: string;
  startRel: string;
  pattern: string;
  glob: string | undefined;
  maxResults: number;
  lineScanChars: number;
  fileMaxBytes: number;
  totalMaxBytes: number;
  sniffBytes: number;
  stubs: string[];
}

interface GrepOutcome {
  matches: string[];
  filesScanned: number;
  stopped?: string;
}

// Plain CommonJS so it runs from `eval` both under tsx/vitest and from dist.
const GREP_WORKER = `
const { parentPort, workerData: job } = require("node:worker_threads");
const fs = require("node:fs");
const path = require("node:path");
const re = new RegExp(job.pattern);
const glob = job.glob ? new RegExp(job.glob) : null;
const stubs = new Set(job.stubs);
const matches = [];
let filesScanned = 0, bytes = 0, stopped;
function scanFile(abs, rel) {
  if (glob && !glob.test(rel)) return;
  if (stubs.has(rel)) return;
  const st = fs.lstatSync(abs);
  if (!st.isFile() || st.size > job.fileMaxBytes) return;
  if (bytes + st.size > job.totalMaxBytes) { stopped = "scanned-bytes limit (" + job.totalMaxBytes + ") reached"; return; }
  const buf = fs.readFileSync(abs);
  bytes += buf.length;
  filesScanned++;
  if (buf.subarray(0, job.sniffBytes).includes(0)) return;
  const lines = buf.toString("utf8").split(/\\r?\\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].length > job.lineScanChars ? lines[i].slice(0, job.lineScanChars) : lines[i];
    if (re.test(line)) {
      const shown = line.length > 300 ? line.slice(0, 300) + " [...]" : line;
      matches.push(rel + ":" + (i + 1) + ": " + shown);
      if (matches.length >= job.maxResults) { stopped = "max_results (" + job.maxResults + ") reached"; return; }
    }
  }
}
function walk(abs, rel) {
  if (stopped) return;
  const st = fs.lstatSync(abs);
  if (st.isSymbolicLink()) return;
  if (st.isFile()) return scanFile(abs, rel);
  if (!st.isDirectory()) return;
  const names = fs.readdirSync(abs).sort();
  for (const n of names) {
    if (stopped) return;
    if (n === ".git") continue;
    walk(path.join(abs, n), rel ? rel + "/" + n : n);
  }
}
walk(job.startRel ? path.join(job.root, ...job.startRel.split("/")) : job.root, job.startRel);
parentPort.postMessage({ matches, filesScanned, stopped });
`;

function runGrepWorker(job: GrepJob, timeoutMs: number, signal?: AbortSignal): Promise<GrepOutcome> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(GREP_WORKER, { eval: true, workerData: job, resourceLimits: { maxOldGenerationSizeMb: 256 } });
    let settled = false;
    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      void worker.terminate();
      fn();
    };
    const timer = setTimeout(
      () => finish(() => reject(new ToolError(`grep timed out after ${timeoutMs} ms; use a simpler pattern or narrower path`))),
      timeoutMs,
    );
    const onAbort = () => finish(() => reject(new ToolError("grep aborted")));
    signal?.addEventListener("abort", onAbort, { once: true });
    worker.once("message", (m: GrepOutcome) => finish(() => resolve(m)));
    worker.once("error", (err) => finish(() => reject(new ToolError(`grep failed: ${err.message}`))));
    worker.once("exit", (code) => finish(() => reject(new ToolError(`grep worker exited (${code})`))));
  });
}
