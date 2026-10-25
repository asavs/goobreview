import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  SnapshotError,
  findGuidanceFiles,
  matchesGitPattern,
  prepareSnapshot,
  readGeneratedPatterns,
  removeSnapshot,
} from "../src/snapshot.js";
import type { GitHubPort, Logger, Snapshot } from "../src/types.js";
import { makeTarball, type TarEntry } from "./fixtures/tarball.js";

const SHA = "c0ffee".padEnd(40, "0");
const TOP = `o-r-${SHA.slice(0, 7)}`;
const repo = { owner: "o", repo: "r" };
const log: Logger = { info() {}, warn() {}, error() {} };

const port = (tgz: Buffer): GitHubPort =>
  ({
    downloadTarball: async (_r: unknown, _s: string, dest: string) => writeFile(dest, tgz),
  }) as unknown as GitHubPort;

const under = (entries: TarEntry[]): TarEntry[] => [{ path: `${TOP}/`, type: "dir" }, ...entries.map((e) => ({ ...e, path: `${TOP}/${e.path}` }))];

let workDir: string;
let snap: Snapshot | undefined;
beforeEach(async () => {
  workDir = await mkdtemp(path.join(tmpdir(), "goob-snap-"));
  snap = undefined;
});
afterEach(async () => {
  if (snap) await removeSnapshot(snap);
  await rm(workDir, { recursive: true, force: true });
});

describe("prepareSnapshot", () => {
  it("extracts, strips the top dir, stubs symlinks and goes read-only", async () => {
    const tgz = makeTarball(
      under([
        { path: "src/", type: "dir" },
        { path: "src/a.ts", type: "file", body: "export const a = 1;\n" },
        { path: "AGENTS.md", type: "file", body: "be nice\n" },
        { path: ".github/CONTRIBUTING.md", type: "file", body: "x\n" },
        { path: "link", type: "symlink", linkpath: "/etc/passwd" },
        { path: ".gitattributes", type: "file", body: "dist/** linguist-generated\n*.pb.go linguist-generated=true\n" },
      ]),
    );
    snap = await prepareSnapshot(port(tgz), repo, SHA, workDir, log);

    expect(await readFile(path.join(snap.root, "src/a.ts"), "utf8")).toBe("export const a = 1;\n");
    expect(snap.symlinkStubs).toEqual(["link"]);
    const stub = await readFile(path.join(snap.root, "link"), "utf8");
    expect(stub).toContain("target: /etc/passwd");
    expect(stub).toContain("target content was not read");
    expect(snap.generatedPatterns).toEqual(["dist/**", "*.pb.go"]);
    expect(snap.sha).toBe(SHA);

    const st = await stat(path.join(snap.root, "src/a.ts"));
    expect(st.mode & 0o222).toBe(0);
    await expect(writeFile(path.join(snap.root, "src/a.ts"), "pwned")).rejects.toThrow();

    expect(await findGuidanceFiles(snap)).toEqual(["AGENTS.md", ".github/CONTRIBUTING.md"]);
    // The downloaded archive does not linger.
    expect((await readdir(path.join(workDir, "snapshots"))).filter((n) => n.endsWith(".tar.gz"))).toEqual([]);
  });

  it("ignores a symlinked .gitattributes", async () => {
    const tgz = makeTarball(
      under([
        { path: "attrs", type: "file", body: "*.ts linguist-generated\n" },
        { path: ".gitattributes", type: "symlink", linkpath: "attrs" },
      ]),
    );
    snap = await prepareSnapshot(port(tgz), repo, SHA, workDir, log);
    expect(snap.symlinkStubs).toEqual([".gitattributes"]);
    expect(snap.generatedPatterns).toEqual([]);
  });

  it.each<[string, TarEntry]>([
    ["a .. entry", { path: `${TOP}/../escape.txt`, type: "file", body: "x" }],
    ["an absolute path", { path: "/tmp/goob-abs.txt", type: "file", body: "x" }],
    ["a hardlink", { path: `${TOP}/hl`, type: "hardlink", linkpath: `${TOP}/a` }],
    ["a device file", { path: `${TOP}/dev`, type: "chardev" }],
  ])("rejects %s and leaves nothing behind", async (_label, bad) => {
    const tgz = makeTarball([{ path: `${TOP}/`, type: "dir" }, { path: `${TOP}/a`, type: "file", body: "a" }, bad]);
    await expect(prepareSnapshot(port(tgz), repo, SHA, workDir, log)).rejects.toBeInstanceOf(SnapshotError);
    expect(await readdir(path.join(workDir, "snapshots"))).toEqual([]);
    await expect(stat(path.join(workDir, "escape.txt"))).rejects.toThrow();
  });

  it("removeSnapshot deletes the read-only tree", async () => {
    snap = await prepareSnapshot(port(makeTarball(under([{ path: "f", type: "file", body: "x" }]))), repo, SHA, workDir, log);
    await removeSnapshot(snap);
    await expect(stat(snap.root)).rejects.toThrow();
    snap = undefined;
  });

  it("refuses a non-hex sha", async () => {
    await expect(prepareSnapshot(port(Buffer.alloc(0)), repo, "../x", workDir, log)).rejects.toBeInstanceOf(SnapshotError);
  });
});

describe("readGeneratedPatterns", () => {
  it("parses linguist-generated with negation and comments", async () => {
    const f = path.join(workDir, "ga");
    await writeFile(
      f,
      [
        "# comment linguist-generated",
        "/gen/*.js linguist-generated",
        "a.txt linguist-generated -linguist-generated",
        "b.txt linguist-generated=true",
        "c.txt linguist-generated=false",
        "d.txt -linguist-generated linguist-generated",
        "e.txt text eol=lf",
        "",
      ].join("\r\n"),
    );
    expect(await readGeneratedPatterns(f)).toEqual(["/gen/*.js", "b.txt", "d.txt"]);
  });
});

describe("matchesGitPattern", () => {
  it.each<[string, string, boolean]>([
    ["package-lock.json", "web/package-lock.json", true],
    ["*.min.js", "a/b/c.min.js", true],
    ["*.min.js", "a/b/c.js", false],
    ["dist/**", "dist/x/y.js", true],
    ["dist/**", "src/dist/y.js", false],
    ["/gen/*.js", "gen/a.js", true],
    ["/gen/*.js", "gen/sub/a.js", false],
    ["/gen/*.js", "x/gen/a.js", false],
    ["**/fixtures/*.json", "a/b/fixtures/x.json", true],
    ["**/fixtures/*.json", "fixtures/x.json", true],
    ["vendor/", "a/vendor/x.go", true],
    ["file?.txt", "file1.txt", true],
    ["[ab].txt", "b.txt", true],
    ["[!ab].txt", "b.txt", false],
  ])("%s vs %s -> %s", (pattern, file, want) => {
    expect(matchesGitPattern(file, pattern)).toBe(want);
  });
});
