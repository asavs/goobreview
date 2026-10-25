import type { Budgets, ComposedPersona, PromptInput, PullRequestFacts, RepoPolicy } from "../../src/types.js";

// A persona with no pieces, for fakes that never compose a real prompt.
export const noPersona = (spec = "none:plain"): ComposedPersona => ({ spec, pieces: [], role: "", history: [], before: "", after: "" });

export const budgets: Budgets = {
  maxPromptBytes: 240_000,
  diffMaxBytes: 120_000,
  diffFileMaxBytes: 40_000,
  descriptionMaxBytes: 12_000,
  previousReviewMaxBytes: 500,
  priorThreadLimit: 12,
  priorThreadBodyMaxBytes: 500,
  commitSubjectsMax: 10,
  suggestionMaxLines: 12,
  traceMaxBytes: 20_000,
};

export const policy: RepoPolicy = {
  requiredChecks: [],
  personality: "none:plain",
  include: { author: false, description: false, commitSubjects: true },
};

export function facts(over: Partial<PullRequestFacts> = {}): PullRequestFacts {
  return {
    repo: { owner: "o", repo: "r" },
    number: 7,
    htmlUrl: "https://github.com/o/r/pull/7",
    title: "Add widget",
    body: "",
    draft: false,
    state: "open",
    author: { login: "alice-author", type: "User" },
    headSha: "a".repeat(40),
    headRef: "feature/widget",
    baseRef: "main",
    baseSha: "b".repeat(40),
    isFork: false,
    repoPrivate: false,
    commits: [{ sha: "1".repeat(40), subject: "Add widget" }],
    files: [
      { path: "src/widget.ts", status: "added", additions: 2, deletions: 0, patch: "@@ -0,0 +1,2 @@\n+export const w = 1;\n+export const v = 2;" },
    ],
    botReviews: [],
    reviewRequested: false,
    botThreads: [],
    checkRuns: [],
    ...over,
  };
}

export function input(over: Partial<PromptInput> = {}): PromptInput {
  return {
    facts: facts(),
    snapshot: { root: "/snap", sha: "a".repeat(40), generatedPatterns: [], symlinkStubs: [] },
    policy,
    budgets,
    ci: { state: "none" },
    guidanceFiles: [],
    ...over,
  };
}
