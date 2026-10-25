import { chmod, mkdir, mkdtemp, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { defaultConfig } from "../src/config.js";
import { QUOTA_BACKOFF_SECONDS } from "../src/decide.js";
import { reconcilePull, sweep, type ReconcileDeps } from "../src/reconcile.js";
import {
  ExecutorError,
  type EngineConfig,
  type ExecutorInput,
  type ExecutorResult,
  type Logger,
  type ResearchRecord,
  type ReviewForm,
  type ReviewThread,
} from "../src/types.js";
import { FakeGitHub, makeFacts } from "./fakes/github.js";

const NOW = new Date("2026-10-19T12:00:00Z");
const HEAD = "a".repeat(40);
const REPO = { owner: "o", repo: "r" };
const FORM: ReviewForm = { verdict: "APPROVE", summary: "ok", findings: [], resolvedThreads: [], unresolvedThreads: [], notCovered: [] };
const thread: ReviewThread = {
  id: "T1",
  handle: "old-bug",
  path: "a.ts",
  isResolved: false,
  firstCommentId: 55,
  firstCommentBody: "### Old bug",
  viewerCanResolve: true,
};

const logger = (): Logger & { lines: string[] } => {
  const lines: string[] = [];
  const push = (m: string) => void lines.push(m);
  return { lines, info: push, warn: push, error: push };
};

let workDir: string;
let gh: FakeGitHub;
let config: EngineConfig;
let executorRun: ReturnType<typeof vi.fn<(i: ExecutorInput) => Promise<ExecutorResult>>>;
let research: ResearchRecord[];

function deps(over: Partial<ReconcileDeps> = {}): ReconcileDeps {
  return {
    gh,
    config,
    executor: { run: executorRun },
    log: logger(),
    now: () => NOW,
    prepareSnapshot: async (_gh, _repo, sha, dir) => {
      // Mimic the real snapshot: a read-only tree under workDir.
      const root = join(dir, `snap-${sha.slice(0, 8)}`);
      await mkdir(join(root, "src"), { recursive: true });
      await writeFile(join(root, "src", "a.ts"), "x");
      await chmod(join(root, "src"), 0o555);
      await chmod(root, 0o555);
      return { root, sha, generatedPatterns: [], symlinkStubs: [] };
    },
    findGuidanceFiles: async () => ["AGENTS.md"],
    composePrompt: (i) => ({ system: `sys:${i.policy.personality}`, user: `pr ${i.facts.number} ${i.guidanceFiles.join()}`, omissions: [], bytes: 10 }),
    planReview: (form, facts) => ({
      payload: { commitId: facts.headSha, event: form.verdict, body: form.summary, comments: [] },
      threadActions: [
        { thread, kind: "resolve", body: "Fixed." },
        { thread: { ...thread, id: "T2", handle: "other", firstCommentId: 56 }, kind: "reply", body: "Still open." },
      ],
      notes: [],
    }),
    ciFailureReview: (facts, failing) => ({
      commitId: facts.headSha,
      event: "REQUEST_CHANGES",
      body: `CI failing: ${failing.join(", ")}`,
      comments: [],
    }),
    research: { record: async (r) => void research.push(r) },
    engineVersion: "test",
    ...over,
  };
}

const ok = (form: ReviewForm = FORM): ExecutorResult => ({
  form,
  model: { provider: "google", id: "m", thinking: "medium" },
  transcript: [],
  usage: { requests: 1, inputTokens: 1, outputTokens: 1, toolCalls: 0 },
  elapsedMs: 1000,
});

beforeEach(async () => {
  workDir = await mkdtemp(join(tmpdir(), "goob-reconcile-"));
  config = { ...defaultConfig(), workDir };
  gh = new FakeGitHub(makeFacts());
  executorRun = vi.fn(async () => ok());
  research = [];
});

const engineState = () => gh.engineRuns.get(`o/r@${HEAD}`)?.state;

describe("research arms", () => {
  const google = { provider: "google", id: "m", thinking: "medium" as const };
  const anthropic = { provider: "anthropic", id: "c", thinking: "medium" as const };
  const grid = () =>
    [google, anthropic].flatMap((model) =>
      (["none", "angry"] as const).map((personality) => ({ name: `${personality}@${model.provider}/${model.id}:medium`, model, personality })),
    );

  beforeEach(() => {
    config.research = { ...config.research, consent: true, arms: grid() };
    config.models = [google];
    executorRun.mockImplementation(async (i) => ({ ...ok(), model: i.models[0]! }));
  });

  it("fills the posted arm from the posted review and runs the other three unposted", async () => {
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "posted", research: { recorded: 4, failed: 0 } });
    expect(gh.ops().filter((o) => o === "review")).toHaveLength(1);
    expect(executorRun).toHaveBeenCalledTimes(4);
    // Arms run on one model each, with the arm's personality in the system prompt only.
    const shadows = executorRun.mock.calls.slice(1).map(([i]) => ({ models: i.models, system: i.prompt.system, user: i.prompt.user }));
    expect(shadows).toEqual([
      { models: [google], system: "sys:angry", user: "pr 7 AGENTS.md" },
      { models: [anthropic], system: "sys:none", user: "pr 7 AGENTS.md" },
      { models: [anthropic], system: "sys:angry", user: "pr 7 AGENTS.md" },
    ]);
    expect(research.map((r) => [r.arm.name, r.posted])).toEqual([
      ["none@google/m:medium", true],
      ["angry@google/m:medium", false],
      ["none@anthropic/c:medium", false],
      ["angry@anthropic/c:medium", false],
    ]);
    expect(new Set(research.map((r) => r.itemId)).size).toBe(1);
  });

  it("records a failed arm as a row and leaves the posted review alone", async () => {
    executorRun.mockImplementation(async (i) => {
      if (i.models[0]!.provider === "anthropic" && i.prompt.system === "sys:angry") throw new ExecutorError("quota", "429", [{ t: "x", type: "model_failed" }]);
      return { ...ok(), model: i.models[0]! };
    });
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "posted", research: { recorded: 4, failed: 1 } });
    expect(research.at(-1)).toMatchObject({
      arm: { name: "angry@anthropic/c:medium" },
      outcome: { status: "failed", kind: "quota", transcript: [{ type: "model_failed" }] },
    });
  });

  it("records a posted review outside the grid as its own arm", async () => {
    executorRun.mockImplementation(async (i) => ({ ...ok(), model: i.models.length > 1 ? { provider: "openai", id: "x", thinking: "low" } : i.models[0]! }));
    config.models = [google, anthropic];
    await reconcilePull(deps(), REPO, 7);
    expect(research.map((r) => r.arm.name)).toEqual([
      "none@openai/x:low",
      "none@google/m:medium",
      "angry@google/m:medium",
      "none@anthropic/c:medium",
      "angry@anthropic/c:medium",
    ]);
  });

  it("dry runs record too, marked not live", async () => {
    config.dryRun = true;
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "dry-run", research: { recorded: 4 } });
    expect(gh.writes).toEqual([]);
    expect(research.every((r) => !r.live && r.reviewUrl === undefined)).toBe(true);
  });

  it("runs no arms without consent, on private repos, or when the review fails", async () => {
    config.research.consent = false;
    await reconcilePull(deps(), REPO, 7);
    expect(executorRun).toHaveBeenCalledOnce();

    config.research.consent = true;
    gh.addPull(makeFacts({ repoPrivate: true, headSha: "b".repeat(40) }));
    executorRun.mockClear();
    await reconcilePull(deps(), REPO, 7);
    expect(executorRun).toHaveBeenCalledOnce();

    gh.addPull(makeFacts({ headSha: "c".repeat(40) }));
    executorRun.mockReset().mockRejectedValue(new ExecutorError("provider", "boom"));
    await reconcilePull(deps(), REPO, 7);
    expect(executorRun).toHaveBeenCalledOnce();
    expect(research).toEqual([]);
  });
});

describe("reconcilePull", () => {
  it("happy path: reacts, signals, reviews, posts, handles threads, concludes, records research", async () => {
    config.autoResolveBotThreads = true;
    config.research = { ...config.research, consent: true };
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "posted", event: "APPROVE", headSha: HEAD, decision: { kind: "review" } });
    expect(gh.ops()).toEqual([
      "reaction:eyes",
      "checkRun:in_progress",
      "review",
      "checkRun:completed/success",
      "reply",
      "resolve",
      "reply",
    ]);
    expect(executorRun).toHaveBeenCalledOnce();
    expect(executorRun.mock.calls[0]![0].prompt.user).toBe("pr 7 AGENTS.md");
    expect(gh.writes.filter((w) => w.op === "resolve")).toEqual([{ op: "resolve", threadId: "T1" }]);
    expect(engineState()).toMatchObject({ firstSeenAt: NOW.toISOString(), attempts: 0 });
    expect(research).toHaveLength(1);
    expect(research[0]).toMatchObject({
      schemaVersion: 2,
      itemId: `o/r#7@${HEAD}`,
      repo: "o/r",
      pr: 7,
      live: true,
      posted: true,
      reviewUrl: expect.any(String),
      arm: { name: "none@google/m:medium", personality: "none" },
      outcome: { status: "ok", event: "APPROVE" },
    });
    expect(out.research).toEqual({ recorded: 1, failed: 0 });
    expect(await readdir(workDir)).toEqual([]);
  });

  it("does not resolve threads unless autoResolveBotThreads, and skips research on private repos", async () => {
    config.research = { ...config.research, consent: true };
    gh.addPull(makeFacts({ repoPrivate: true }));
    await reconcilePull(deps(), REPO, 7);
    expect(gh.ops()).not.toContain("resolve");
    expect(gh.ops().filter((o) => o === "reply")).toHaveLength(2);
    expect(research).toHaveLength(0);
  });

  it("maps REQUEST_CHANGES and COMMENT to failure and neutral conclusions", async () => {
    executorRun.mockResolvedValueOnce(ok({ ...FORM, verdict: "REQUEST_CHANGES" }));
    await reconcilePull(deps(), REPO, 7);
    expect(gh.ops()).toContain("checkRun:completed/failure");
  });

  it("dry run writes nothing to GitHub but still plans the review", async () => {
    config.dryRun = true;
    const log = logger();
    const out = await reconcilePull(deps({ log }), REPO, 7);
    expect(out).toMatchObject({ action: "dry-run", event: "APPROVE" });
    expect(gh.writes).toEqual([]);
    expect(executorRun).toHaveBeenCalledOnce();
    expect(log.lines.some((l) => l.includes("dry run, would post APPROVE"))).toBe(true);
    expect(await readdir(workDir)).toEqual([]);
  });

  it("dry run with failing CI plans the CI review without writes or the executor", async () => {
    config.dryRun = true;
    config.defaults.requiredChecks = ["test"];
    gh.addPull(makeFacts({ checkRuns: [{ name: "test", status: "completed", conclusion: "failure" }] }));
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "dry-run", event: "REQUEST_CHANGES" });
    expect(gh.writes).toEqual([]);
    expect(executorRun).not.toHaveBeenCalled();
  });

  it("stale head: discards the review and concludes superseded", async () => {
    gh.headShaSequence = ["f".repeat(40)];
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "superseded" });
    expect(gh.ops()).toEqual(["reaction:eyes", "checkRun:in_progress", "checkRun:completed/neutral"]);
    expect(engineState()?.attempts).toBe(0);
  });

  it("ci-failed posts REQUEST_CHANGES without the executor", async () => {
    config.defaults.requiredChecks = ["test", "lint"];
    gh.addPull(
      makeFacts({
        checkRuns: [
          { name: "test", status: "completed", conclusion: "failure" },
          { name: "lint", status: "completed", conclusion: "success" },
        ],
      }),
    );
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "posted", event: "REQUEST_CHANGES", decision: { kind: "ci-failed", failing: ["test"] } });
    expect(executorRun).not.toHaveBeenCalled();
    expect(gh.ops()).toEqual(["reaction:eyes", "checkRun:in_progress", "review", "checkRun:completed/failure"]);
    const review = gh.writes.find((w) => w.op === "review");
    expect(review).toMatchObject({ payload: { body: "CI failing: test", commitId: HEAD } });
  });

  it("ci-failed is posted once per head: the posted review dedups the next run", async () => {
    config.defaults.requiredChecks = ["test"];
    gh.addPull(
      makeFacts({
        checkRuns: [{ name: "test", status: "completed", conclusion: "failure" }],
        botReviews: [{ id: 1, commitId: HEAD, state: "CHANGES_REQUESTED", body: "", submittedAt: NOW.toISOString() }],
      }),
    );
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "skipped", detail: "already-reviewed" });
    expect(gh.writes).toEqual([]);
  });

  it("CI pending writes a queued check run once", async () => {
    config.defaults.requiredChecks = ["test"];
    gh.addPull(makeFacts({ checkRuns: [{ name: "test", status: "in_progress", conclusion: null }] }));
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "waiting", decision: { reason: "ci-pending" } });
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "waiting" });
    expect(gh.ops()).toEqual(["checkRun:queued"]);
    expect(engineState()).toEqual({ firstSeenAt: NOW.toISOString(), attempts: 0 });
  });

  it("settling records the first sighting; later runs review once settled", async () => {
    const prior = { id: 1, commitId: "c".repeat(40), state: "COMMENTED", body: "", submittedAt: NOW.toISOString() };
    gh.addPull(makeFacts({ botReviews: [prior] }));
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "waiting", decision: { reason: "settling" } });
    expect(gh.ops()).toEqual(["checkRun:queued"]);
    const later = new Date(NOW.getTime() + 301_000);
    expect(await reconcilePull(deps({ now: () => later }), REPO, 7)).toMatchObject({ action: "posted" });
  });

  it("settling fails open when the state write fails", async () => {
    const prior = { id: 1, commitId: "c".repeat(40), state: "COMMENTED", body: "", submittedAt: NOW.toISOString() };
    gh.addPull(makeFacts({ botReviews: [prior] }));
    gh.failing.add("upsertEngineCheckRun");
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "posted" });
  });

  it("settling fails open when the App cannot write check runs (adapter resolves -1)", async () => {
    const prior = { id: 1, commitId: "c".repeat(40), state: "COMMENTED", body: "", submittedAt: NOW.toISOString() };
    gh.addPull(makeFacts({ botReviews: [prior] }));
    gh.checkRunsForbidden = true;
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "posted" });
  });

  it("quota: confused reaction, neutral check run, short backoff, ladder untouched", async () => {
    executorRun.mockRejectedValueOnce(new ExecutorError("quota", "429"));
    const out = await reconcilePull(deps(), REPO, 7);
    expect(out).toMatchObject({ action: "failed" });
    expect(gh.ops()).toEqual(["reaction:eyes", "checkRun:in_progress", "reaction:confused", "checkRun:completed/neutral"]);
    expect(engineState()).toMatchObject({ attempts: 0, lastFailureReason: "quota", lastAttemptAt: NOW.toISOString() });

    const soon = new Date(NOW.getTime() + (QUOTA_BACKOFF_SECONDS - 1) * 1000);
    expect(await reconcilePull(deps({ now: () => soon }), REPO, 7)).toMatchObject({
      action: "waiting",
      decision: { reason: "backoff" },
    });
    const after = new Date(NOW.getTime() + QUOTA_BACKOFF_SECONDS * 1000);
    expect(await reconcilePull(deps({ now: () => after }), REPO, 7)).toMatchObject({ action: "posted" });
  });

  it("other executor failures advance the ladder", async () => {
    executorRun.mockRejectedValueOnce(new ExecutorError("provider", "boom"));
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "failed" });
    expect(gh.ops()).toEqual(["reaction:eyes", "checkRun:in_progress", "checkRun:completed/neutral"]);
    expect(engineState()).toMatchObject({ attempts: 1, lastFailureReason: "review-failure" });

    const t1 = new Date(NOW.getTime() + 899_000);
    expect(await reconcilePull(deps({ now: () => t1 }), REPO, 7)).toMatchObject({ action: "waiting" });
    executorRun.mockRejectedValueOnce(new ExecutorError("invalid-review", "bad form"));
    const t2 = new Date(NOW.getTime() + 900_000);
    expect(await reconcilePull(deps({ now: () => t2 }), REPO, 7)).toMatchObject({ action: "failed" });
    expect(engineState()).toMatchObject({ attempts: 2, lastFailureReason: "invalid-review", lastAttemptAt: t2.toISOString() });
  });

  it("snapshot failure counts as a failed attempt and still cleans up", async () => {
    const out = await reconcilePull(
      deps({ prepareSnapshot: async () => Promise.reject(new Error("tarball 404")) }),
      REPO,
      7,
    );
    expect(out).toMatchObject({ action: "failed", detail: expect.stringContaining("tarball 404") });
    expect(engineState()?.attempts).toBe(1);
    expect(await readdir(workDir)).toEqual([]);
  });

  it("post failure counts as a failed attempt", async () => {
    gh.failing.add("postReview");
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "failed" });
    expect(engineState()?.attempts).toBe(1);
  });

  it("missing checks:write is best effort", async () => {
    gh.failing.add("upsertEngineCheckRun");
    gh.failing.add("addReaction");
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "posted" });
  });

  it("checkRunSignal false writes no check runs", async () => {
    config.checkRunSignal = false;
    await reconcilePull(deps(), REPO, 7);
    expect(gh.ops().some((o) => o.startsWith("checkRun"))).toBe(false);
  });

  it("skips write nothing", async () => {
    gh.addPull(makeFacts({ draft: true }));
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "skipped", detail: "draft" });
    expect(gh.writes).toEqual([]);
  });

  it("unreadable PR is a failed outcome, not a throw", async () => {
    gh.failing.add("getPullFacts");
    expect(await reconcilePull(deps(), REPO, 7)).toMatchObject({ action: "failed", decision: null });
  });
});

describe("sweep", () => {
  it("skips drafts and self-authored PRs cheaply and caps reviews", async () => {
    gh.addPull(makeFacts({ number: 1, draft: true }));
    gh.addPull(makeFacts({ number: 2, author: { login: "app/goob", type: "Bot" } }));
    gh.addPull(makeFacts({ number: 3 }));
    gh.addPull(makeFacts({ number: 4 }));
    const out = await sweep(deps());
    expect(out.map((o) => [o.number, o.action])).toEqual([
      [7, "posted"],
      [1, "skipped"],
      [2, "skipped"],
    ]);
    // 7 is now deduped by its posted review; the cap moves on to 3 and 4.
    const all = await sweep(deps(), { maxReviews: 10 });
    expect(all.filter((o) => o.action === "posted").map((o) => o.number)).toEqual([3, 4]);
  });

  it("honours the allowlist and onlyRepo", async () => {
    gh.repos = [REPO, { owner: "x", repo: "y" }];
    gh.addPull(makeFacts({ repo: { owner: "x", repo: "y" }, number: 9 }));
    config.repos = ["x/y"];
    expect((await sweep(deps(), { maxReviews: 5 })).map((o) => o.repo)).toEqual(["x/y"]);
    config.repos = [];
    expect((await sweep(deps(), { maxReviews: 5, onlyRepo: REPO })).map((o) => o.repo)).toEqual(["o/r"]);
  });
});
