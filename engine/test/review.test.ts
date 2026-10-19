import { describe, expect, it } from "vitest";
import { BODY_MAX_CHARS, ciFailureReview, planReview, type PlanContext } from "../src/review.js";
import type { EngineConfig, Finding, PullRequestFacts, ReviewForm, ReviewThread } from "../src/types.js";

// a.ts: hunk 0 covers RIGHT 1-4 (2 added), hunk 1 covers RIGHT 20-22 (21 added).
const PATCH = ["@@ -1,3 +1,4 @@", " l1", "+l2", " l3", " l4", "@@ -18,2 +20,3 @@", " l20", "+l21", " l22"].join("\n");

function facts(over: Partial<PullRequestFacts> = {}): PullRequestFacts {
  return {
    repo: { owner: "o", repo: "r" },
    number: 7,
    htmlUrl: "https://github.com/o/r/pull/7",
    title: "t",
    body: "",
    draft: false,
    state: "open",
    author: { login: "dev", type: "User" },
    headSha: "abc123",
    headRef: "feat",
    baseRef: "main",
    baseSha: "base",
    isFork: false,
    repoPrivate: false,
    commits: [],
    files: [{ path: "a.ts", status: "modified", additions: 2, deletions: 0, patch: PATCH }],
    botReviews: [],
    reviewRequested: false,
    botThreads: [],
    checkRuns: [],
    ...over,
  };
}

function ctx(over: Partial<EngineConfig> = {}): PlanContext {
  const config = {
    budgets: { suggestionMaxLines: 3 },
    autoResolveBotThreads: true,
    ...over,
  } as unknown as EngineConfig;
  return { config, model: { provider: "google", id: "gemini-x", thinking: "low" }, elapsedMs: 65_000, engineVersion: "2.0.0" };
}

const form = (findings: Finding[], over: Partial<ReviewForm> = {}): ReviewForm => ({
  verdict: "COMMENT",
  summary: "Summary.",
  findings,
  resolvedThreads: [],
  unresolvedThreads: [],
  notCovered: [],
  ...over,
});

const f = (over: Partial<Finding>): Finding => ({ title: "Bug", blocking: false, body: "Explain.", ...over });

describe("placement", () => {
  it("places a finding on a RIGHT line and keeps an off-diff one in the body", () => {
    const plan = planReview(form([f({ title: "On diff", path: "a.ts", line: 3 }), f({ title: "Off diff", path: "a.ts", line: 10 })]), facts(), ctx());
    expect(plan.payload.comments).toEqual([{ path: "a.ts", line: 3, side: "RIGHT", body: "### On diff\n\nExplain." }]);
    expect(plan.payload.body).toContain("### Off diff\n\nLocation: `a.ts:10`\n\nExplain.");
    expect(plan.payload.body).not.toContain("### On diff");
  });

  it("places a range inside one hunk and rejects one spanning hunks", () => {
    const plan = planReview(
      form([f({ title: "Range", path: "a.ts", startLine: 1, line: 4 }), f({ title: "Across", path: "a.ts", startLine: 3, line: 21 })]),
      facts(),
      ctx(),
    );
    expect(plan.payload.comments).toHaveLength(1);
    expect(plan.payload.comments[0]).toMatchObject({ line: 4, startLine: 1 });
    expect(plan.payload.body).toContain("Location: `a.ts:3-21`");
  });

  it("does not place findings on files without a patch", () => {
    const plan = planReview(
      form([f({ path: "b.ts", line: 1 })]),
      facts({ files: [{ path: "b.ts", previousPath: "c.ts", status: "renamed", additions: 0, deletions: 0 }] }),
      ctx(),
    );
    expect(plan.payload.comments).toEqual([]);
  });
});

describe("suggestions", () => {
  it("keeps short suggestions applicable and demotes long ones", () => {
    const plan = planReview(
      form([
        f({ title: "Short", path: "a.ts", line: 2, suggestion: "x\ny" }),
        f({ title: "Long", path: "a.ts", line: 21, suggestion: "1\n2\n3\n4" }),
      ]),
      facts(),
      ctx(),
    );
    const [short, long] = plan.payload.comments;
    expect(short!.body).toContain("```suggestion\nx\ny\n```");
    expect(long!.body).not.toContain("```suggestion");
    expect(long!.body).toContain("```\n1\n2\n3\n4\n```\n[goobreview: suggestion of 4 lines exceeds the 3-line cap");
    expect(plan.notes).toContain("demoted suggestion: Long");
  });

  it("never emits a suggestion block for an unplaced finding", () => {
    const plan = planReview(form([f({ path: "a.ts", line: 99, suggestion: "z" })]), facts(), ctx());
    expect(plan.payload.body).not.toContain("```suggestion");
    expect(plan.payload.body).toContain("Suggested replacement:\n\n```\nz\n```");
  });

  it("uses a longer fence when the suggestion contains backticks", () => {
    const plan = planReview(form([f({ path: "a.ts", line: 2, suggestion: "```js\nx\n```" })]), facts(), ctx());
    expect(plan.payload.comments[0]!.body).toContain("````suggestion\n```js\nx\n```\n````");
  });
});

describe("downgrade (#113)", () => {
  it("keeps REQUEST_CHANGES when a blocking finding sits on an added line", () => {
    const plan = planReview(form([f({ blocking: true, path: "a.ts", line: 2 })], { verdict: "REQUEST_CHANGES" }), facts(), ctx());
    expect(plan.payload.event).toBe("REQUEST_CHANGES");
  });

  it("downgrades when blocking findings only touch context lines or are unplaced", () => {
    const plan = planReview(
      form([f({ blocking: true, path: "a.ts", line: 3 }), f({ blocking: true, path: "z.ts", line: 1 })], { verdict: "REQUEST_CHANGES" }),
      facts(),
      ctx(),
    );
    expect(plan.payload.event).toBe("COMMENT");
    expect(plan.payload.body).toContain("[goobreview: posted as COMMENT");
    expect(plan.notes.some((n) => n.startsWith("downgraded"))).toBe(true);
  });

  it("counts a range that includes an added line", () => {
    const plan = planReview(form([f({ blocking: true, path: "a.ts", startLine: 1, line: 3 })], { verdict: "REQUEST_CHANGES" }), facts(), ctx());
    expect(plan.payload.event).toBe("REQUEST_CHANGES");
  });

  it("does not count a non-blocking finding on an added line", () => {
    const plan = planReview(form([f({ blocking: false, path: "a.ts", line: 2 })], { verdict: "REQUEST_CHANGES" }), facts(), ctx());
    expect(plan.payload.event).toBe("COMMENT");
  });
});

describe("thread actions", () => {
  const thread = (handle: string, over: Partial<ReviewThread> = {}): ReviewThread => ({
    id: `T_${handle}`,
    handle,
    path: "a.ts",
    line: 2,
    isResolved: false,
    firstCommentId: 1,
    firstCommentBody: `### ${handle}`,
    viewerCanResolve: true,
    ...over,
  });
  const threads = [thread("fixed"), thread("locked", { viewerCanResolve: false }), thread("open"), thread("done", { isResolved: true })];
  const tf = form([], {
    resolvedThreads: [
      { handle: "fixed", evidence: "guard added" },
      { handle: "locked", evidence: "e" },
      { handle: "ghost", evidence: "e" },
      { handle: "done", evidence: "e" },
    ],
    unresolvedThreads: [{ handle: "open", explanation: "still null" }],
  });

  it("resolves when allowed, replies otherwise, ignores unknown and already-resolved handles", () => {
    const plan = planReview(tf, facts({ botThreads: threads }), ctx());
    const byHandle = Object.fromEntries(plan.threadActions.map((a) => [a.thread.handle, a]));
    expect(Object.keys(byHandle).sort()).toEqual(["fixed", "locked", "open"]);
    expect(byHandle.fixed!.kind).toBe("resolve");
    expect(byHandle.fixed!.body).toContain("Confirmed fixed at abc123");
    expect(byHandle.locked!.kind).toBe("reply");
    expect(byHandle.open).toMatchObject({ kind: "reply", body: "Still open at abc123: still null" });
  });

  it("only replies when auto-resolve is off", () => {
    const plan = planReview(tf, facts({ botThreads: threads }), ctx({ autoResolveBotThreads: false }));
    expect(plan.threadActions.every((a) => a.kind === "reply")).toBe(true);
  });
});

describe("body", () => {
  it("renders summary, notCovered and the provenance footer", () => {
    const plan = planReview(form([], { notCovered: ["gen/x.ts"] }), facts(), ctx());
    expect(plan.payload.body.startsWith("Summary.")).toBe(true);
    expect(plan.payload.body).toContain("Not covered by this review: `gen/x.ts`.");
    expect(plan.payload.body.endsWith(
      "---\n*google/gemini-x took 1m05s via [goobreview 2.0.0](https://github.com/asavs/goobreview/releases/tag/v2.0.0).*",
    )).toBe(true);
    expect(plan.payload.commitId).toBe("abc123");
  });

  it("caps the body under GitHub's limit and keeps the footer", () => {
    const huge = Array.from({ length: 50 }, (_, i) => f({ title: `F${i}`, body: "```\n" + "x".repeat(3000) + "\n```" }));
    const plan = planReview(form(huge), facts(), { ...ctx(), engineVersion: "dev" });
    expect(plan.payload.body.length).toBeLessThanOrEqual(BODY_MAX_CHARS);
    expect(plan.payload.body).toContain("[goobreview: truncated");
    expect(plan.payload.body.endsWith("via goobreview dev.*")).toBe(true);
    const fences = plan.payload.body.match(/^```/gm)?.length ?? 0;
    expect(fences % 2).toBe(0);
  });
});

describe("ciFailureReview", () => {
  it("requests changes naming the failing checks without a model call", () => {
    const p = ciFailureReview(
      facts({ checkRuns: [{ name: "test", status: "completed", conclusion: "failure" }] }),
      ["test", "lint"],
    );
    expect(p.event).toBe("REQUEST_CHANGES");
    expect(p.comments).toEqual([]);
    expect(p.body).toContain("CI is failing on this commit. Fix the failing job(s) and push a new commit - I will re-review on the new head SHA.");
    expect(p.body).toContain("```\ntest: failure\nlint: failing\n```");
    expect(p.body).toContain("no model call was made");
  });
});
