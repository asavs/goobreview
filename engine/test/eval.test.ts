import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { noPersona } from "./fixtures/prompt-input.js";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { defaultConfig } from "../src/config.js";
import { listCorpus, parseUnifiedDiff, runEval, type EvalDeps } from "../src/eval.js";
import { ExecutorError, type EngineConfig, type ExecutorInput, type ExecutorResult, type ResearchRecord } from "../src/types.js";

const DIFF = `--- a/pkg/calc.py
+++ b/pkg/calc.py
@@ -1,4 +1,4 @@
 def clamp(x, hi):
-    if x < hi:
+    if x <= hi:
         return x
     return hi
`;

describe("parseUnifiedDiff", () => {
  it("turns diff -u output into GitHub-style files", () => {
    expect(parseUnifiedDiff(DIFF)).toEqual([
      {
        path: "pkg/calc.py",
        status: "modified",
        additions: 1,
        deletions: 1,
        patch: "@@ -1,4 +1,4 @@\n def clamp(x, hi):\n-    if x < hi:\n+    if x <= hi:\n         return x\n     return hi",
      },
    ]);
  });

  it("handles added files, renames and CRLF", () => {
    const files = parseUnifiedDiff("--- /dev/null\r\n+++ b/new.py\r\n@@ -0,0 +1 @@\r\n+x = 1\r\n--- a/old.py\t2026\n+++ b/moved.py\t2026\n@@ -1 +1 @@\n-a\n+b\n");
    expect(files.map((f) => [f.path, f.status, f.previousPath, f.additions, f.deletions])).toEqual([
      ["new.py", "added", undefined, 1, 0],
      ["moved.py", "renamed", "old.py", 1, 1],
    ]);
  });
});

let root: string;
let config: EngineConfig;
let records: ResearchRecord[];
let run: ReturnType<typeof vi.fn<(i: ExecutorInput) => Promise<ExecutorResult>>>;

const model = (provider: string) => ({ provider, id: "m", thinking: "medium" as const });
const arms = ["a", "b"].flatMap((p) =>
  (["none:plain", "angry:v1"] as const).map((personality) => ({ name: `${personality}@${p}/m:medium`, model: model(p), personality })),
);

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), "goob-eval-"));
  const tree = path.join(root, "tree");
  mkdirSync(path.join(tree, "pkg"), { recursive: true });
  mkdirSync(path.join(tree, ".git"));
  writeFileSync(path.join(tree, ".git", "HEAD"), "ref");
  writeFileSync(path.join(tree, "pkg", "calc.py"), "def clamp(x, hi):\n    if x < hi:\n        return x\n    return hi\n");
  writeFileSync(path.join(tree, "README.md"), "seed");
  for (const [item, variant, line] of [
    ["calc-L2-boundary", "mutant", "    if x <= hi:"],
    ["calc-L2-boundary", "clean", "    if hi > x:"],
    ["calc-L2-inverted", "mutant", "    if x >= hi:"],
  ] as const) {
    const dir = path.join(root, "corpus", item, variant);
    mkdirSync(path.join(dir, "snapshot", "pkg"), { recursive: true });
    writeFileSync(path.join(dir, "snapshot", "pkg", "calc.py"), `def clamp(x, hi):\n${line}\n        return x\n    return hi\n`);
    writeFileSync(path.join(dir, "diff.patch"), DIFF.replace("+    if x <= hi:", `+${line}`));
    writeFileSync(path.join(dir, "label.json"), JSON.stringify({ variant, secret: "ground truth" }));
  }
  config = { ...defaultConfig(), workDir: path.join(root, "work") };
  config.research = { ...config.research, arms };
  records = [];
  run = vi.fn(async (i: ExecutorInput) => ({
    form: { verdict: "APPROVE" as const, summary: readFileSync(path.join(i.snapshot.root, "pkg", "calc.py"), "utf8"), findings: [], resolvedThreads: [], unresolvedThreads: [], notCovered: [] },
    model: i.models[0]!,
    transcript: [],
    usage: { requests: 1, inputTokens: 1, outputTokens: 1, toolCalls: 0 },
    elapsedMs: 1,
  }));
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

const deps = (): EvalDeps => ({
  config,
  executor: { run },
  log: { info: () => {}, warn: () => {}, error: () => {} },
  composePrompt: (i) => ({ system: `sys:${i.policy.personality}`, user: `${i.facts.title}\n${i.facts.files[0]?.patch}`, persona: noPersona(), omissions: [], bytes: 1 }),
  planReview: (form, facts) => ({ payload: { commitId: facts.headSha, event: form.verdict, body: form.summary, comments: [] }, threadActions: [], notes: [] }),
  research: { record: async (r) => void records.push(r) },
  engineVersion: "test",
});
const opts = () => ({ corpus: path.join(root, "corpus"), tree: path.join(root, "tree"), repeats: 2 });

describe("runEval", () => {
  it("runs every arm on every variant, on the seed tree with the variant overlaid", async () => {
    expect((await listCorpus(opts().corpus)).map((v) => `${v.item}/${v.variant}`)).toEqual([
      "calc-L2-boundary/clean",
      "calc-L2-boundary/mutant",
      "calc-L2-inverted/mutant",
    ]);
    const s = await runEval(deps(), opts());
    expect(s).toMatchObject({ variants: 3, runs: 24, ok: 24, failed: 0, resumed: 0, skippedQuota: 0, unprepared: 0, incomplete: 0 });
    const boundary = records.filter((r) => r.itemId === "eval:corpus/calc-L2-boundary/mutant");
    expect(boundary).toHaveLength(8);
    // The reviewer sees the mutant file, not the seed's.
    expect(boundary.every((r) => r.outcome.status === "ok" && r.outcome.body.includes("if x <= hi:"))).toBe(true);
    expect(boundary[0]).toMatchObject({ repo: "eval/corpus", live: false, posted: false, corpus: { name: "corpus", item: "calc-L2-boundary", variant: "mutant" } });
    // Arms share one payload; only the system prompt differs. The title names the file only.
    expect(new Set(boundary.map((r) => r.prompt?.user)).size).toBe(1);
    expect(boundary[0]!.prompt?.user.startsWith("Update pkg/calc.py\n@@")).toBe(true);
    expect(new Set(boundary.map((r) => r.prompt?.system))).toEqual(new Set(["sys:none:plain", "sys:angry:v1"]));
    // Single model per arm; snapshots and staging copies are cleaned up.
    expect(run.mock.calls.every(([i]) => i.models.length === 1)).toBe(true);
    expect(readdirSync(config.workDir)).toEqual(["snapshots"]);
    expect(readdirSync(path.join(config.workDir, "snapshots"))).toEqual([]);
  });

  it("keeps labels and .git out of the snapshot", async () => {
    run.mockImplementation(async (i) => {
      expect(existsSync(path.join(i.snapshot.root, "label.json"))).toBe(false);
      expect(existsSync(path.join(i.snapshot.root, ".git"))).toBe(false);
      expect(existsSync(path.join(i.snapshot.root, "README.md"))).toBe(true);
      return { form: { verdict: "APPROVE", summary: "s", findings: [], resolvedThreads: [], unresolvedThreads: [], notCovered: [] }, model: i.models[0]!, transcript: [], usage: { requests: 1, inputTokens: 1, outputTokens: 1, toolCalls: 0 }, elapsedMs: 1 };
    });
    await runEval(deps(), { ...opts(), limit: 1, repeats: 1 });
    expect(run).toHaveBeenCalledTimes(8);
  });

  it("resumes from the index, retrying only quota failures", async () => {
    const done = [
      ...Array.from({ length: 2 }, () => ({ itemId: "eval:corpus/calc-L2-boundary/clean", arm: arms[0]!.name, status: "ok" })),
      { itemId: "eval:corpus/calc-L2-boundary/clean", arm: arms[1]!.name, status: "failed", kind: "provider" },
      { itemId: "eval:corpus/calc-L2-boundary/clean", arm: arms[2]!.name, status: "failed", kind: "quota" },
    ];
    const s = await runEval(deps(), { ...opts(), limit: 1, done });
    expect(s).toMatchObject({ resumed: 3, runs: 13 });
    const clean = records.filter((r) => r.itemId.endsWith("/clean")).map((r) => r.arm.name);
    expect(clean.filter((a) => a === arms[0]!.name)).toHaveLength(0);
    expect(clean.filter((a) => a === arms[1]!.name)).toHaveLength(1);
    expect(clean.filter((a) => a === arms[2]!.name)).toHaveLength(2);
  });

  it("stops using a model once it runs out of quota", async () => {
    run.mockImplementation(async (i) => {
      if (i.models[0]!.provider === "b") throw new ExecutorError("quota", "usage limit");
      return { form: { verdict: "APPROVE", summary: "s", findings: [], resolvedThreads: [], unresolvedThreads: [], notCovered: [] }, model: i.models[0]!, transcript: [], usage: { requests: 1, inputTokens: 1, outputTokens: 1, toolCalls: 0 }, elapsedMs: 1 };
    });
    const s = await runEval(deps(), opts());
    // Model a: 3 variants x 2 arms x 2 repeats. Model b: one failed attempt, the rest skipped.
    expect(s).toMatchObject({ ok: 12, failed: 1, skippedQuota: 11, exhaustedModels: ["b/m:medium"], incomplete: 12 });
    expect(records.filter((r) => r.outcome.status === "failed")).toHaveLength(1);
  });

  it("counts a quota failure on the last pending run as incomplete", async () => {
    const s = await runEval(deps(), { ...opts(), limit: 1, repeats: 1 });
    expect(s.incomplete).toBe(0);
    run.mockRejectedValueOnce(new ExecutorError("quota", "usage limit"));
    const done = records.map((r) => ({ itemId: r.itemId, arm: r.arm.name, status: r.outcome.status })).slice(0, -1);
    records = [];
    const again = await runEval(deps(), { ...opts(), limit: 1, repeats: 1, done });
    expect(again).toMatchObject({ runs: 1, failed: 1, skippedQuota: 0, incomplete: 1 });
  });

  it("counts unprepared variants and refuses a missing tree", async () => {
    writeFileSync(path.join(root, "corpus", "calc-L2-inverted", "mutant", "diff.patch"), "");
    const s = await runEval(deps(), { ...opts(), repeats: 1 });
    expect(s).toMatchObject({ unprepared: 1, incomplete: 4, runs: 8 });
    await expect(runEval(deps(), { ...opts(), tree: path.join(root, "nope") })).rejects.toThrow(/--tree .* is not a directory/);
  });

  it("records a run whose prompt cannot be composed as failed", async () => {
    const base = deps();
    const s = await runEval(
      {
        ...base,
        composePrompt: (i) => {
          if (i.policy.personality === "angry:v1") throw new Error("over maxPromptBytes");
          return base.composePrompt(i);
        },
      },
      { ...opts(), limit: 1, repeats: 1 },
    );
    expect(s).toMatchObject({ runs: 8, ok: 4, failed: 4, incomplete: 0 });
    expect(records.filter((r) => r.prompt === null)).toHaveLength(4);
  });

  it("uses a variant's pr.json as the author's claims, and refuses a malformed one", async () => {
    const claim = { title: "Tidy clamp", body: "Pure refactor: no behaviour change.", commits: ["Tidy clamp", "Rename local"] };
    writeFileSync(path.join(root, "corpus", "calc-L2-inverted", "mutant", "pr.json"), JSON.stringify(claim));
    const seen: { title: string; body: string; commits: string[] }[] = [];
    const base = deps();
    const composePrompt: EvalDeps["composePrompt"] = (i) => {
      seen.push({ title: i.facts.title, body: i.facts.body, commits: i.facts.commits.map((c) => c.subject) });
      return base.composePrompt(i);
    };
    await runEval({ ...base, composePrompt }, { ...opts(), repeats: 1 });
    const inverted = seen.filter((f) => f.title === "Tidy clamp");
    expect(inverted).toHaveLength(4);
    expect(inverted[0]).toEqual(claim);
    // Variants without pr.json keep the plain synthetic PR.
    expect(seen.filter((f) => f.title === "Update pkg/calc.py" && f.body === "" && f.commits[0] === f.title)).toHaveLength(8);

    writeFileSync(path.join(root, "corpus", "calc-L2-inverted", "mutant", "pr.json"), JSON.stringify({ title: 1 }));
    records = [];
    const s = await runEval(deps(), { ...opts(), repeats: 1 });
    expect(s).toMatchObject({ unprepared: 1, incomplete: 4 });
  });

  it("refuses to run without arms", async () => {
    config.research.arms = [];
    await expect(runEval(deps(), opts())).rejects.toThrow(/research\.arms/);
  });
});
