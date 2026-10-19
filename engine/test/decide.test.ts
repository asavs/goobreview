import { describe, expect, it } from "vitest";
import { defaultConfig } from "../src/config.js";
import { backoffFor, decide, nextState, QUOTA_BACKOFF_SECONDS, type DecideInput } from "../src/decide.js";
import type { BotReview, EngineState } from "../src/types.js";
import { makeFacts } from "./fakes/github.js";

const NOW = new Date("2026-10-19T12:00:00Z");
const ago = (s: number): string => new Date(NOW.getTime() - s * 1000).toISOString();
const HEAD = "a".repeat(40);
const review = (commitId: string): BotReview => ({ id: 1, commitId, state: "COMMENTED", body: "", submittedAt: ago(9999) });

function input(over: Partial<DecideInput> = {}, facts = {}): DecideInput {
  const config = defaultConfig();
  return {
    facts: makeFacts(facts),
    botLogin: "goob[bot]",
    state: null,
    policy: config.defaults,
    config,
    ci: { state: "none" },
    now: NOW,
    allowlisted: true,
    ...over,
  };
}
const state = (s: Partial<EngineState>): EngineState => ({ firstSeenAt: ago(10_000), attempts: 0, ...s });

describe("decide: skips", () => {
  it("closed", () => expect(decide(input({}, { state: "closed" }))).toEqual({ kind: "skip", reason: "closed" }));
  it("draft", () => expect(decide(input({}, { draft: true }))).toEqual({ kind: "skip", reason: "draft" }));
  it("self via <slug>[bot]", () =>
    expect(decide(input({}, { author: { login: "goob[bot]", type: "Bot" } }))).toEqual({ kind: "skip", reason: "self-authored" }));
  it("self via app/<slug>", () =>
    expect(decide(input({}, { author: { login: "app/goob", type: "Bot" } }))).toEqual({ kind: "skip", reason: "self-authored" }));
  it("not allowlisted", () =>
    expect(decide(input({ allowlisted: false }))).toEqual({ kind: "skip", reason: "not-allowlisted" }));
  it("already reviewed this head", () =>
    expect(decide(input({}, { botReviews: [review(HEAD)] }))).toEqual({ kind: "skip", reason: "already-reviewed" }));
  it("re-requested review bypasses dedup and settle", () =>
    expect(decide(input({ state: null }, { botReviews: [review(HEAD)], reviewRequested: true }))).toEqual({
      kind: "review",
      rereview: true,
    }));
});

describe("decide: settle window", () => {
  const followUp = { botReviews: [review("c".repeat(40))] };

  it("first review is never delayed, even on first sighting", () =>
    expect(decide(input({ state: null }))).toEqual({ kind: "review", rereview: false }));

  it("follow-up on a first-seen head waits the full window", () => {
    const d = decide(input({ state: null }, followUp));
    expect(d).toMatchObject({ kind: "wait", reason: "settling", until: "2026-10-19T12:05:00.000Z" });
  });

  it("follow-up still settling", () =>
    expect(decide(input({ state: state({ firstSeenAt: ago(120) }) }, followUp))).toMatchObject({
      kind: "wait",
      reason: "settling",
      until: "2026-10-19T12:03:00.000Z",
    }));

  it("follow-up settled after the window", () =>
    expect(decide(input({ state: state({ firstSeenAt: ago(300) }) }, followUp))).toEqual({ kind: "review", rereview: false }));

  it("a new head restarts the window (state is per head, so it starts null)", () => {
    const old = decide(input({ state: state({ firstSeenAt: ago(3600) }) }, followUp));
    expect(old.kind).toBe("review");
    const pushed = decide(input({ state: null }, { ...followUp, headSha: "d".repeat(40) }));
    expect(pushed).toMatchObject({ kind: "wait", reason: "settling" });
  });

  it("a future first sighting (clock skew) costs at most one window", () =>
    expect(decide(input({ state: state({ firstSeenAt: ago(-86_400) }) }, followUp))).toMatchObject({
      until: "2026-10-19T12:05:00.000Z",
    }));

  it("re-request bypasses settle", () =>
    expect(decide(input({ state: state({ firstSeenAt: ago(1) }) }, { ...followUp, reviewRequested: true }))).toEqual({
      kind: "review",
      rereview: false,
    }));

  it("settleSeconds 0 disables it", () => {
    const i = input({ state: null }, followUp);
    i.config.settleSeconds = 0;
    expect(decide(i).kind).toBe("review");
  });

  it("fails open when state is not persisted (dry run)", () => {
    const i = input({ state: null }, followUp);
    i.config.dryRun = true;
    expect(decide(i).kind).toBe("review");
    expect(decide({ ...input({ state: null }, followUp), persistent: false }).kind).toBe("review");
  });
});

describe("decide: backoff", () => {
  it("ladder steps and cap", () => {
    const ladder = [900, 3600, 14400];
    expect([0, 1, 2, 3, 9].map((n) => backoffFor(n, ladder))).toEqual([0, 900, 3600, 14400, 14400]);
  });

  it.each([
    [1, 899, true],
    [1, 900, false],
    [2, 3599, true],
    [2, 3600, false],
    [3, 14399, true],
    [7, 14399, true],
    [7, 14400, false],
  ])("attempts=%i, %is since last attempt → waiting=%s", (attempts, since, waiting) => {
    const d = decide(input({ state: state({ attempts, lastAttemptAt: ago(since), lastFailureReason: "review-failure" }) }));
    if (waiting) expect(d).toMatchObject({ kind: "wait", reason: "backoff" });
    else expect(d.kind).toBe("review");
  });

  it("quota backs off briefly and ignores the ladder", () => {
    const s = state({ attempts: 3, lastAttemptAt: ago(QUOTA_BACKOFF_SECONDS - 1), lastFailureReason: "quota" });
    expect(decide(input({ state: s }))).toMatchObject({ kind: "wait", reason: "backoff", detail: "model quota exhausted" });
    // At attempts=3 the ladder would say 4h; quota clears after the short wait.
    const later = { ...s, lastAttemptAt: ago(QUOTA_BACKOFF_SECONDS) };
    expect(decide(input({ state: later })).kind).toBe("review");
  });

  it("does not apply when unpersisted", () => {
    const d = decide({ ...input({ state: state({ attempts: 1, lastAttemptAt: ago(1) }) }), persistent: false });
    expect(d.kind).toBe("review");
  });
});

describe("decide: CI gate", () => {
  it("none → review", () => expect(decide(input({ ci: { state: "none" } })).kind).toBe("review"));
  it("success → review", () => expect(decide(input({ ci: { state: "success", checks: ["t"] } })).kind).toBe("review"));
  it("pending → wait", () =>
    expect(decide(input({ ci: { state: "pending", waitingOn: ["t"] } }))).toEqual({
      kind: "wait",
      reason: "ci-pending",
      detail: "waiting on t",
    }));
  it("failing → ci-failed", () =>
    expect(decide(input({ ci: { state: "failing", failing: ["t", "u"] } }))).toEqual({ kind: "ci-failed", failing: ["t", "u"] }));
  it("backoff gates before CI", () =>
    expect(
      decide(input({ ci: { state: "failing", failing: ["t"] }, state: state({ attempts: 1, lastAttemptAt: ago(1) }) })).kind,
    ).toBe("wait"));
});

describe("nextState", () => {
  it("records first sighting once", () => {
    const s = nextState(null, NOW, { kind: "seen" });
    expect(s).toEqual({ firstSeenAt: NOW.toISOString(), attempts: 0 });
    const later = new Date(NOW.getTime() + 60_000);
    expect(nextState(s, later, { kind: "seen" }).firstSeenAt).toBe(NOW.toISOString());
  });

  it("counts failures, not quota, and resets on success", () => {
    let s = nextState(null, NOW, { kind: "failure", reason: "review-failure" });
    expect(s).toMatchObject({ attempts: 1, lastFailureReason: "review-failure", lastAttemptAt: NOW.toISOString() });
    s = nextState(s, NOW, { kind: "quota" });
    expect(s).toMatchObject({ attempts: 1, lastFailureReason: "quota" });
    s = nextState(s, NOW, { kind: "failure", reason: "invalid-review" });
    expect(s.attempts).toBe(2);
    s = nextState(s, NOW, { kind: "success" });
    expect(s).toEqual({ firstSeenAt: NOW.toISOString(), attempts: 0, lastAttemptAt: NOW.toISOString() });
  });
});
