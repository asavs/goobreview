// Pure decision function. Pipeline order follows v1 review_one_pr: skips,
// dedup, settle, backoff, then the CI gate. Settle and backoff come before
// any side effect so a waiting PR never costs a review slot.

import type { CiState, Decision, EngineConfig, EngineState, PullRequestFacts, RepoPolicy } from "./types.js";

/** Quota errors back off this long without advancing the failure ladder (v1 padded quota resets similarly). */
export const QUOTA_BACKOFF_SECONDS = 600;

export interface DecideInput {
  facts: PullRequestFacts;
  /** "<slug>[bot]". */
  botLogin: string;
  /** State from the engine check run on facts.headSha; null on first sighting. */
  state: EngineState | null;
  policy: RepoPolicy;
  config: EngineConfig;
  ci: CiState;
  now: Date;
  allowlisted: boolean;
  /**
   * Whether engine state is being persisted. Settle and backoff are measured
   * from persisted state; without it (dry run, check runs disabled, or a
   * failed state write) they fail open rather than waiting forever, as v1 did
   * when it could not record a first sighting.
   */
  persistent?: boolean;
}

/** Both login forms GitHub uses for an App's bot: REST "<slug>[bot]", GraphQL/gh "app/<slug>". */
export function isSelf(login: string, botLogin: string): boolean {
  const slug = botLogin.replace(/\[bot\]$/, "");
  const l = login.toLowerCase();
  return l === botLogin.toLowerCase() || l === `app/${slug}`.toLowerCase() || l === `${slug}[bot]`.toLowerCase();
}

const iso = (ms: number): string => new Date(ms).toISOString();

/** Seconds to wait after the Nth consecutive failure; the last rung repeats. */
export function backoffFor(attempts: number, ladder: number[]): number {
  if (attempts <= 0 || ladder.length === 0) return 0;
  return ladder[Math.min(attempts - 1, ladder.length - 1)]!;
}

export function decide(input: DecideInput): Decision {
  const { facts, botLogin, state, config, ci, now, allowlisted } = input;
  const persistent = input.persistent ?? (!config.dryRun && config.checkRunSignal);
  const nowMs = now.getTime();

  if (facts.state === "closed") return { kind: "skip", reason: "closed" };
  if (facts.draft) return { kind: "skip", reason: "draft" };
  if (isSelf(facts.author.login, botLogin)) return { kind: "skip", reason: "self-authored" };
  if (!allowlisted) return { kind: "skip", reason: "not-allowlisted" };

  const reviewedThisHead = facts.botReviews.some((r) => r.commitId === facts.headSha);
  if (reviewedThisHead && !facts.reviewRequested) return { kind: "skip", reason: "already-reviewed" };

  // First reviews are never delayed; re-requests are a human asking for feedback now.
  if (persistent && facts.botReviews.length > 0 && !facts.reviewRequested && config.settleSeconds > 0) {
    const seen = state ? Date.parse(state.firstSeenAt) : nowMs;
    // A first sighting in the future (clock skew) costs at most one window.
    const from = Number.isNaN(seen) || seen > nowMs ? nowMs : seen;
    const until = from + config.settleSeconds * 1000;
    if (nowMs < until) {
      return {
        kind: "wait",
        reason: "settling",
        until: iso(until),
        detail: `head unchanged ${Math.floor((nowMs - from) / 1000)}s of ${config.settleSeconds}s`,
      };
    }
  }

  if (persistent && state?.lastAttemptAt) {
    const last = Date.parse(state.lastAttemptAt);
    if (!Number.isNaN(last)) {
      // The last attempt only happened once any earlier ladder wait had
      // expired, so after a quota failure only the short quota wait applies.
      const wait =
        state.lastFailureReason === "quota" ? QUOTA_BACKOFF_SECONDS : backoffFor(state.attempts, config.backoffSeconds);
      const until = last + wait * 1000;
      if (wait > 0 && nowMs < until) {
        return {
          kind: "wait",
          reason: "backoff",
          until: iso(until),
          detail:
            state.lastFailureReason === "quota"
              ? "model quota exhausted"
              : `attempt ${state.attempts} failed (${state.lastFailureReason ?? "review-failure"})`,
        };
      }
    }
  }

  switch (ci.state) {
    case "pending":
      return { kind: "wait", reason: "ci-pending", detail: `waiting on ${ci.waitingOn.join(", ")}` };
    case "failing":
      return { kind: "ci-failed", failing: ci.failing };
    default:
      return { kind: "review", rereview: reviewedThisHead };
  }
}

export type StateEvent =
  | { kind: "seen" }
  | { kind: "success" }
  | { kind: "failure"; reason: "review-failure" | "invalid-review" }
  | { kind: "quota" };

/**
 * State bookkeeping for one head. The engine check run is per head SHA, so a
 * new push starts from null: settle and the ladder restart by construction.
 */
export function nextState(prev: EngineState | null, now: Date, event: StateEvent): EngineState {
  const base: EngineState = prev ? { ...prev } : { firstSeenAt: now.toISOString(), attempts: 0 };
  switch (event.kind) {
    case "seen":
      return base;
    case "success":
      return { firstSeenAt: base.firstSeenAt, attempts: 0, lastAttemptAt: now.toISOString() };
    case "failure":
      return { ...base, attempts: base.attempts + 1, lastFailureReason: event.reason, lastAttemptAt: now.toISOString() };
    case "quota":
      return { ...base, lastFailureReason: "quota", lastAttemptAt: now.toISOString() };
  }
}
