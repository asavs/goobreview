import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { prepareSnapshot, removeSnapshot } from "../src/snapshot.js";
import { createReadOnlyTools, resolveInside } from "../src/tools.js";
import type { ExecutorLimits, GitHubPort, Logger, Snapshot } from "../src/types.js";
import { makeTarball, type TarEntry } from "./fixtures/tarball.js";

const SHA = "d".repeat(40);
const TOP = "o-r-ddddddd";
const log: Logger = { info() {}, warn() {}, error() {} };
const limits: ExecutorLimits = { maxTurns: 10, maxToolCalls: 10, maxWallSeconds: 60, toolResultMaxBytes: 4000 };
const TOKEN = "ghp_" + "Z9y8X7w6V5".repeat(4);

const files: TarEntry[] = [
  { path: "src/", type: "dir" },
  { path: "src/a.ts", type: "file", body: "line one\nconst x = 1;\nline three\n" },
  { path: "src/b.ts", type: "file", body: `const token = "${TOKEN}";\nconst y = 2;\n` },
  { path: "src/big.txt", type: "file", body: Array.from({ length: 2000 }, (_, i) => `row ${i} needle`).join("\n") },
  { path: "docs/", type: "dir" },
  { path: "docs/readme.md", type: "file", body: "const in docs\n" },
  { path: "bin.dat", type: "file", body: "abc\0def const" },
  { path: "evil", type: "symlink", linkpath: "../../outside" },
];

let workDir: string;
let snap: Snapshot;
let tools: Record<string, AgentTool>;

const call = async (name: string, params: Record<string, unknown>): Promise<string> => {
  const tool = tools[name];
  if (!tool) throw new Error(`no tool ${name}`);
  const r = await tool.execute("id", params as never);
  return r.content.map((c) => (c.type === "text" ? c.text : "")).join("");
};

beforeAll(async () => {
  workDir = await mkdtemp(path.join(tmpdir(), "goob-tools-"));
  const tgz = makeTarball([{ path: `${TOP}/`, type: "dir" }, ...files.map((e) => ({ ...e, path: `${TOP}/${e.path}` }))]);
  const gh = { downloadTarball: async (_r: unknown, _s: string, dest: string) => writeFile(dest, tgz) } as unknown as GitHubPort;
  snap = await prepareSnapshot(gh, { owner: "o", repo: "r" }, SHA, workDir, log);
  tools = Object.fromEntries(createReadOnlyTools(snap, limits, { grepTimeoutMs: 1500 }).map((t) => [t.name, t]));
});

afterAll(async () => {
  await removeSnapshot(snap);
  await rm(workDir, { recursive: true, force: true });
});

describe("read_file", () => {
  it("returns numbered lines and honours ranges", async () => {
    const all = await call("read_file", { path: "src/a.ts" });
    expect(all).toContain("lines 1-3 of 3");
    expect(all).toContain("2\tconst x = 1;");
    const one = await call("read_file", { path: "src/a.ts", start_line: 3, end_line: 3 });
    expect(one).toContain("3\tline three");
    expect(one).not.toContain("const x");
  });

  it.each([["../outside"], ["src/../../x"], ["/etc/passwd"], ["C:\\Windows\\win.ini"], ["src\\..\\..\\x"]])(
    "rejects escape %s",
    async (p) => {
      await expect(call("read_file", { path: p })).rejects.toThrow(/absolute|"\.\."/);
    },
  );

  it("reads a symlink stub as a stub, never the target", async () => {
    const out = await call("read_file", { path: "evil" });
    expect(out).toContain("symlink stub");
    expect(out).toContain("target: ../../outside");
  });

  it("refuses directories, binaries and missing files", async () => {
    await expect(call("read_file", { path: "src" })).rejects.toThrow(/directory/);
    await expect(call("read_file", { path: "bin.dat" })).rejects.toThrow(/binary/);
    await expect(call("read_file", { path: "nope.ts" })).rejects.toThrow(/no such/);
  });

  it("redacts planted secrets", async () => {
    const out = await call("read_file", { path: "src/b.ts" });
    expect(out).not.toContain(TOKEN);
    expect(out).toContain("[REDACTED:github-token]");
  });

  it("truncates to toolResultMaxBytes with a marker", async () => {
    const out = await call("read_file", { path: "src/big.txt" });
    expect(Buffer.byteLength(out)).toBeLessThanOrEqual(limits.toolResultMaxBytes);
    expect(out).toMatch(/\[goobreview omitted: output truncated at 4000 bytes; narrow the range/);
  });
});

describe("grep", () => {
  it("finds matches with path:line and skips binaries", async () => {
    const out = await call("grep", { pattern: "^const" });
    expect(out).toContain("src/a.ts:2: const x = 1;");
    expect(out).toContain("docs/readme.md:1: const in docs");
    expect(out).not.toContain("bin.dat");
  });

  it("filters by path and glob", async () => {
    expect(await call("grep", { pattern: "const", path: "docs" })).not.toContain("src/");
    const g = await call("grep", { pattern: "const", glob: "*.md" });
    expect(g).toContain("docs/readme.md");
    expect(g).not.toContain("src/a.ts");
  });

  it("redacts secrets in matches", async () => {
    const out = await call("grep", { pattern: "token" });
    expect(out).not.toContain(TOKEN);
    expect(out).toContain("[REDACTED:github-token]");
  });

  it("caps results", async () => {
    const out = await call("grep", { pattern: "needle", max_results: 5 });
    expect(out).toContain("5 match(es)");
    expect(out).toContain("max_results (5) reached");
  });

  it("rejects bad and oversized patterns and escapes", async () => {
    await expect(call("grep", { pattern: "(" })).rejects.toThrow(/invalid regular expression/);
    await expect(call("grep", { pattern: "a".repeat(501) })).rejects.toThrow(/over 500/);
    await expect(call("grep", { pattern: "x", path: "../" })).rejects.toThrow(/"\.\."/);
  });

  it("times out a catastrophic pattern instead of hanging", async () => {
    // (a+)+$ backtracks exponentially on a long run of a's followed by a non-match.
    const dir = await mkdtemp(path.join(tmpdir(), "goob-redos-"));
    await writeFile(path.join(dir, "f.txt"), "a".repeat(40) + "!\n");
    const t = Object.fromEntries(
      createReadOnlyTools({ root: dir, sha: SHA, generatedPatterns: [], symlinkStubs: [] }, limits, { grepTimeoutMs: 500 }).map((x) => [x.name, x]),
    );
    const started = Date.now();
    await expect(t.grep!.execute("id", { pattern: "^(a+)+$" } as never)).rejects.toThrow(/timed out/);
    expect(Date.now() - started).toBeLessThan(5000);
    await rm(dir, { recursive: true, force: true });
  });
});

describe("list_dir", () => {
  it("lists entries with directory slashes and stub notes", async () => {
    const out = await call("list_dir", {});
    expect(out).toContain("src/");
    expect(out).toContain("evil (symlink stub)");
    expect(await call("list_dir", { path: "src" })).toContain("a.ts");
    await expect(call("list_dir", { path: "/" })).rejects.toThrow(/absolute/);
  });
});

describe("resolveInside", () => {
  it("refuses a real link or junction even if a snapshot somehow contained one", async () => {
    const root = await mkdtemp(path.join(tmpdir(), "goob-root-"));
    const outside = await mkdtemp(path.join(tmpdir(), "goob-out-"));
    await writeFile(path.join(outside, "secret"), "s");
    await mkdir(path.join(root, "d"));
    let linked = true;
    try {
      await symlink(outside, path.join(root, "d", "j"), "junction");
    } catch {
      linked = false; // no link privilege on this host
    }
    if (linked) await expect(resolveInside(root, "d/j/secret")).rejects.toThrow(/symlink/);
    await expect(resolveInside(root, "d")).resolves.toMatchObject({ rel: "d" });
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  });
});
