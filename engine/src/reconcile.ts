// One PR end to end, and a sweep over every open PR. Collaborators are
// injected so this orchestration is testable against fakes; cli.ts wires the
// real modules. All GitHub writes go through `write()`, which is a no-op in
// dry run, so a dry run cannot touch GitHub even by accident.

import { chmod, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { evaluateCi } from "./ci.js";
import { armName, isAllowlisted, modelName, policyFor } from "./config.js";
import { decide, isSelf, nextState, type StateEvent } from "./decide.js";
import { classifyProviderError } from "./executor.js";
import {
  ExecutorError,
  repoName,
  type CheckRunUpdate,
  type ComposedPrompt,
  type Decision,
  type EngineConfig,
  type EngineState,
  type Executor,
  type ExecutorInput,
  type ExecutorResult,
  type GitHubPort,
  type Logger,
  type ModelRef,
  type PlannedReview,
  type PromptInput,
  type PullRequestFacts,
  type RepoRef,
  type ResearchArm,
  type ResearchOutcome,
  type ResearchRecord,
  type ResearchSink,
  type ReviewEvent,
  type ReviewForm,
  type ReviewPayload,
  type Snapshot,
} from "./types.js";

export type PrepareSnapshotFn = (
  gh: GitHubPort,
  repo: RepoRef,
  sha: string,
  workDir: string,
  log: Logger,
) => Promise<Snapshot>;
export type FindGuidanceFilesFn = (snapshot: Snapshot) => Promise<string[]>;
export type ComposePromptFn = (input: PromptInput) => ComposedPrompt;
export type PlanReviewFn = (
  form: ReviewForm,
  facts: PullRequestFacts,
  ctx: { config: EngineConfig; model: ModelRef; elapsedMs: number; engineVersion: string },
) => PlannedReview;
export type CiFailureReviewFn = (facts: PullRequestFacts, failing: string[]) => ReviewPayload;

export interface ReconcileDeps {
  gh: GitHubPort;
  executor: Executor;
  prepareSnapshot: PrepareSnapshotFn;
  /** Defaults to no guidance files. */
  findGuidanceFiles?: FindGuidanceFilesFn;
  composePrompt: ComposePromptFn;
  planReview: PlanReviewFn;
  ciFailureReview: CiFailureReviewFn;
  research?: ResearchSink;
  log: Logger;
  now?: () => Date;
  config: EngineConfig;
  engineVersion?: string;
}

export type ReconcileAction = "posted" | "dry-run" | "skipped" | "waiting" | "failed" | "superseded";

export interface ReconcileOutcome {
  repo: string;
  number: number;
  headSha: string;
  /** null when the PR could not be read at all. */
  decision: Decision | null;
  action: ReconcileAction;
  detail?: string;
  /** Posted (or, in dry run, planned) review event. */
  event?: ReviewEvent;
  reviewUrl?: string;
  /** Research arms recorded for this head, and how many of them failed. */
  research?: { recorded: number; failed: number };
}

const CONCLUSION: Record<ReviewEvent, "success" | "failure" | "neutral"> = {
  APPROVE: "success",
  REQUEST_CHANGES: "failure",
  COMMENT: "neutral",
};

const errMsg = (err: unknown): string => (err instanceof Error ? err.message : String(err));

/** Snapshots are made read-only, so restore write bits before removing. */
export async function removeTree(dir: string): Promise<void> {
  const unlock = async (p: string): Promise<void> => {
    await chmod(p, 0o700).catch(() => {});
    const entries = await readdir(p, { withFileTypes: true }).catch(() => []);
    for (const e of entries) if (e.isDirectory()) await unlock(join(p, e.name));
  };
  await unlock(dir);
  await rm(dir, { recursive: true, force: true, maxRetries: 3 });
}

class PrRun {
  readonly dry: boolean;
  readonly name: string;
  private readonly now: () => Date;
  state: EngineState;

  constructor(
    readonly deps: ReconcileDeps,
    readonly repo: RepoRef,
    readonly facts: PullRequestFacts,
    state: EngineState | null,
  ) {
    this.dry = deps.config.dryRun;
    this.name = `${repoName(repo)}#${facts.number}`;
    this.now = deps.now ?? (() => new Date());
    this.state = state ?? nextState(null, this.now(), { kind: "seen" });
  }

  get log(): Logger {
    return this.deps.log;
  }

  /** Best effort: GitHub side effects never block the review (v1 #permissions). */
  async write(what: string, fn: () => Promise<unknown>): Promise<boolean> {
    if (this.dry) return true;
    try {
      await fn();
      return true;
    } catch (err) {
      this.log.warn(`${this.name}: ${what} failed (continuing)`, { error: err });
      return false;
    }
  }

  async checkRun(update: Omit<CheckRunUpdate, "state">): Promise<boolean> {
    if (!this.deps.config.checkRunSignal) return true;
    return this.write(`check run ${update.status}`, async () => {
      // The adapter returns -1 instead of throwing when the App lacks checks:write.
      const id = await this.deps.gh.upsertEngineCheckRun(this.repo, this.facts.headSha, { ...update, state: this.state });
      if (id < 0) throw new Error("check run not persisted (the App needs checks:write)");
    });
  }

  bump(event: StateEvent): void {
    this.state = nextState(this.state, this.now(), event);
  }

  outcome(decision: Decision, action: ReconcileAction, detail?: string, extra?: Partial<ReconcileOutcome>): ReconcileOutcome {
    return {
      repo: repoName(this.repo),
      number: this.facts.number,
      headSha: this.facts.headSha,
      decision,
      action,
      ...(detail !== undefined ? { detail } : {}),
      ...extra,
    };
  }

  async fail(decision: Decision, reason: "review-failure" | "invalid-review", detail: string): Promise<ReconcileOutcome> {
    this.bump({ kind: "failure", reason });
    this.log.error(`${this.name}: ${detail}; retrying after backoff (attempt ${this.state.attempts})`);
    await this.checkRun({
      status: "completed",
      conclusion: "neutral",
      title: "Review attempt failed",
      summary: `${detail}. goobreview retries automatically once the backoff expires.\n\nattempt: ${this.state.attempts} (reason: ${reason})`,
    });
    return this.outcome(decision, "failed", detail);
  }

  /** Stale-head guard: re-read the head right before posting. */
  async superseded(decision: Decision): Promise<ReconcileOutcome | "ok" | "error"> {
    let current: string;
    try {
      current = await this.deps.gh.getHeadSha(this.repo, this.facts.number);
    } catch {
      return "error";
    }
    if (current === this.facts.headSha) return "ok";
    this.log.info(`${this.name}: head advanced to ${current} before posting; discarding review`);
    await this.checkRun({
      status: "completed",
      conclusion: "neutral",
      title: "Superseded",
      summary: "The PR head advanced while the review was being drafted. The new head gets a fresh review.",
    });
    return this.outcome(decision, "superseded", `head moved to ${current}`);
  }
}

export async function reconcilePull(deps: ReconcileDeps, repo: RepoRef, number: number): Promise<ReconcileOutcome> {
  const { gh, config, log } = deps;
  const now = deps.now ?? (() => new Date());
  let facts: PullRequestFacts;
  let botLogin: string;
  try {
    [facts, botLogin] = await Promise.all([gh.getPullFacts(repo, number), gh.botLogin()]);
  } catch (err) {
    log.error(`${repoName(repo)}#${number}: failed to read pull request`, { error: err });
    return { repo: repoName(repo), number, headSha: "", decision: null, action: "failed", detail: errMsg(err) };
  }

  let engineRun = null;
  try {
    engineRun = await gh.getEngineCheckRun(repo, facts.headSha);
  } catch (err) {
    // Fail open like v1: unreadable state means first sighting, never a freeze.
    log.warn(`${repoName(repo)}#${number}: failed to read engine check run; treating head as first seen`, { error: err });
  }
  const run = new PrRun(deps, repo, facts, engineRun?.state ?? null);
  const policy = policyFor(config, repo);
  const ci = evaluateCi(facts.checkRuns, policy.requiredChecks);
  const input = {
    facts,
    botLogin,
    state: engineRun?.state ?? null,
    policy,
    config,
    ci,
    now: now(),
    allowlisted: isAllowlisted(config, repo),
  };
  let decision = decide(input);
  log.info(`${run.name}@${facts.headSha}: decision ${decision.kind}`, { decision });

  if (decision.kind === "skip") return run.outcome(decision, "skipped", decision.reason);

  if (decision.kind === "wait") {
    const firstSighting = engineRun?.state == null;
    if (firstSighting || (decision.reason === "ci-pending" && engineRun?.status !== "queued")) {
      const title = decision.reason === "ci-pending" ? "Waiting for required checks" : "Waiting for the head to settle";
      const ok = await run.checkRun({ status: "queued", title, summary: decision.detail ?? title });
      if (!ok && decision.reason === "settling") {
        // Without a stored first sighting the window could never elapse; fail open (v1 did the same).
        decision = decide({ ...input, persistent: false });
        log.info(`${run.name}: state not persisted; re-decided ${decision.kind}`);
      }
    }
    if (decision.kind === "wait") {
      log.info(`${run.name}: waiting (${decision.reason})`, { until: decision.until, detail: decision.detail });
      return run.outcome(decision, "waiting", decision.detail);
    }
  }
  if (decision.kind === "skip") return run.outcome(decision, "skipped", decision.reason);

  // Committed to working this PR.
  if (!run.dry) {
    await run.write("eyes reaction", () => gh.addReaction(repo, number, "eyes"));
    await run.checkRun({ status: "in_progress", title: "Reviewing", summary: "goobreview is reviewing this head." });
  }

  if (decision.kind === "ci-failed") return postCiFailure(run, decision);
  return review(run, decision, policy, ci);
}

async function postCiFailure(run: PrRun, decision: Extract<Decision, { kind: "ci-failed" }>): Promise<ReconcileOutcome> {
  const payload = run.deps.ciFailureReview(run.facts, decision.failing);
  if (run.dry) {
    run.log.info(`${run.name}: dry run, would post ${payload.event} (CI failing)`, { payload });
    return run.outcome(decision, "dry-run", `CI failing: ${decision.failing.join(", ")}`, { event: payload.event });
  }
  const guard = await run.superseded(decision);
  if (guard === "error") return run.fail(decision, "review-failure", "failed to re-read PR head before posting");
  if (guard !== "ok") return guard;
  let posted: { id: number; htmlUrl: string };
  try {
    posted = await run.deps.gh.postReview(run.repo, run.facts.number, payload);
  } catch (err) {
    return run.fail(decision, "review-failure", `failed to post CI-failure review: ${errMsg(err)}`);
  }
  run.bump({ kind: "success" });
  await run.checkRun({
    status: "completed",
    conclusion: CONCLUSION[payload.event],
    title: `Review posted: ${payload.event}`,
    summary: "Required checks were failing, so changes were requested without invoking the model. A new head gets a fresh review.",
  });
  run.log.info(`${run.name}: posted ${payload.event} (CI failing)`, { url: posted.htmlUrl });
  return run.outcome(decision, "posted", `CI failing: ${decision.failing.join(", ")}`, {
    event: payload.event,
    reviewUrl: posted.htmlUrl,
  });
}

async function review(
  run: PrRun,
  decision: Extract<Decision, { kind: "review" }>,
  policy: ReturnType<typeof policyFor>,
  ci: ReturnType<typeof evaluateCi>,
): Promise<ReconcileOutcome> {
  const { deps, facts, repo } = run;
  const { config, gh } = deps;
  let snapshot: Snapshot | undefined;
  try {
    let prompt: ComposedPrompt;
    let promptInput: PromptInput;
    try {
      snapshot = await deps.prepareSnapshot(gh, repo, facts.headSha, config.workDir, run.log);
      const guidanceFiles = deps.findGuidanceFiles ? await deps.findGuidanceFiles(snapshot) : [];
      promptInput = { facts, snapshot, policy, budgets: config.budgets, ci, guidanceFiles };
      prompt = deps.composePrompt(promptInput);
    } catch (err) {
      return run.fail(decision, "review-failure", `failed to prepare review: ${errMsg(err)}`);
    }

    let result: ExecutorResult;
    try {
      result = await deps.executor.run({ prompt, snapshot, models: config.models, limits: config.limits });
    } catch (err) {
      if (err instanceof ExecutorError && err.kind === "quota") {
        // Quota is expected to clear; it must not push the head up the failure ladder.
        run.bump({ kind: "quota" });
        if (!run.dry) await run.write("confused reaction", () => gh.addReaction(repo, facts.number, "confused"));
        await run.checkRun({
          status: "completed",
          conclusion: "neutral",
          title: "Rate limited",
          summary: "The model quota is exhausted. The review retries automatically after a short backoff.",
        });
        run.log.warn(`${run.name}: model quota exhausted; short backoff, not counted as a failed attempt`);
        return run.outcome(decision, "failed", `quota: ${err.message}`);
      }
      const reason = err instanceof ExecutorError && (err.kind === "invalid-review" || err.kind === "no-review")
        ? "invalid-review"
        : "review-failure";
      const kind = err instanceof ExecutorError ? err.kind : "error";
      return run.fail(decision, reason, `executor failed (${kind}): ${errMsg(err)}`);
    }

    let planned: PlannedReview;
    try {
      planned = deps.planReview(result.form, facts, {
        config,
        model: result.model,
        elapsedMs: result.elapsedMs,
        engineVersion: deps.engineVersion ?? "dev",
      });
    } catch (err) {
      return run.fail(decision, "invalid-review", `failed to plan review: ${errMsg(err)}`);
    }
    const { payload } = planned;
    const execution = {
      model: `${result.model.provider}/${result.model.id}`,
      ...(result.credential ? { credential: result.credential } : {}),
      usage: result.usage,
      elapsedMs: result.elapsedMs,
    };

    if (run.dry) {
      run.log.info(`${run.name}: dry run, would post ${payload.event}`, {
        ...execution,
        comments: payload.comments.length,
        threadActions: planned.threadActions.map((a) => ({ handle: a.thread.handle, kind: a.kind })),
        notes: planned.notes,
        omissions: prompt.omissions,
        body: payload.body,
      });
      const research = await captureResearch(run, promptInput, { prompt, result, planned });
      return run.outcome(decision, "dry-run", undefined, { event: payload.event, ...(research ? { research } : {}) });
    }

    const guard = await run.superseded(decision);
    if (guard === "error") return run.fail(decision, "review-failure", "failed to re-read PR head before posting");
    if (guard !== "ok") return guard;

    let posted: { id: number; htmlUrl: string };
    try {
      posted = await gh.postReview(repo, facts.number, payload);
    } catch (err) {
      return run.fail(decision, "review-failure", `failed to post review: ${errMsg(err)}`);
    }
    run.bump({ kind: "success" });
    await run.checkRun({
      status: "completed",
      conclusion: CONCLUSION[payload.event],
      title: `Review posted: ${payload.event}`,
      summary: `goobreview posted a ${payload.event} review on this head.`,
    });

    for (const action of planned.threadActions) {
      await run.write(`reply to thread ${action.thread.handle}`, () =>
        gh.replyToThread(repo, facts.number, action.thread.firstCommentId, action.body),
      );
      if (action.kind === "resolve" && config.autoResolveBotThreads && action.thread.viewerCanResolve) {
        await run.write(`resolve thread ${action.thread.handle}`, () => gh.resolveThread(action.thread.id));
      }
    }

    run.log.info(`${run.name}: posted ${payload.event}`, { ...execution, url: posted.htmlUrl, notes: planned.notes });
    const research = await captureResearch(run, promptInput, { prompt, result, planned, reviewUrl: posted.htmlUrl });
    return run.outcome(decision, "posted", undefined, {
      event: payload.event,
      reviewUrl: posted.htmlUrl,
      ...(research ? { research } : {}),
    });
  } finally {
    // Only the current run's tree is kept (#166); prepareSnapshot evicts crash leftovers.
    if (snapshot) await removeTree(snapshot.root).catch((err) => run.log.warn(`${run.name}: snapshot cleanup failed`, { error: err }));
  }
}

const sameModel = (a: ModelRef, b: ModelRef): boolean => modelName(a) === modelName(b);

/**
 * One research arm run. Arms have a single model and no fallback, so a
 * transient availability error (503, overloaded) gets one retry rather than
 * costing the cell. The record keeps only the retry's transcript and usage.
 */
export async function runArm(executor: Executor, input: ExecutorInput): Promise<ExecutorResult> {
  try {
    return await executor.run(input);
  } catch (err) {
    if (!(err instanceof ExecutorError) || err.kind !== "provider" || !classifyProviderError(err.message).fallback) throw err;
    return executor.run(input);
  }
}

/**
 * Records the posted review as the arm it matches (or as an ad-hoc arm when
 * the policy is outside the grid, e.g. after a fallback), then runs every
 * other arm unposted on the same snapshot. Arms use a single model with no
 * fallback, so a quota or availability failure is a failed record, not a
 * substitution. Capture never affects the posted review.
 */
async function captureResearch(
  run: PrRun,
  promptInput: PromptInput,
  posted: { prompt: ComposedPrompt; result: ExecutorResult; planned: PlannedReview; reviewUrl?: string },
): Promise<{ recorded: number; failed: number } | undefined> {
  const { deps, facts, repo } = run;
  const { config } = deps;
  const sink = deps.research;
  if (!sink || !config.research.consent || (facts.repoPrivate && !config.research.allowPrivate)) return undefined;

  const engineVersion = deps.engineVersion ?? "dev";
  const personality = promptInput.policy.personality;
  const postedArm: ResearchArm = config.research.arms.find(
    (a) => a.personality === personality && sameModel(a.model, posted.result.model),
  ) ?? { name: armName(personality, posted.result.model), model: posted.result.model, personality };

  const planned = (p: PlannedReview, result: ExecutorResult): ResearchOutcome => ({
    status: "ok",
    result,
    event: p.payload.event,
    body: p.payload.body,
    comments: p.payload.comments,
    notes: p.notes,
  });
  const counts = { recorded: 0, failed: 0 };
  const save = async (arm: ResearchArm, prompt: ComposedPrompt | null, outcome: ResearchOutcome, isPosted: boolean): Promise<void> => {
    const rec: ResearchRecord = {
      schemaVersion: 2,
      itemId: `${repoName(repo)}#${facts.number}@${facts.headSha}`,
      repo: repoName(repo),
      pr: facts.number,
      headSha: facts.headSha,
      baseSha: facts.baseSha,
      engineVersion,
      live: !run.dry,
      arm,
      posted: isPosted,
      ...(isPosted && posted.reviewUrl ? { reviewUrl: posted.reviewUrl } : {}),
      prompt,
      outcome,
    };
    try {
      await sink.record(rec);
      counts.recorded++;
      if (outcome.status === "failed") counts.failed++;
    } catch (err) {
      run.log.warn(`${run.name}: research capture failed for ${arm.name} (continuing)`, { error: err });
    }
  };

  await save(postedArm, posted.prompt, planned(posted.planned, posted.result), true);

  for (const arm of config.research.arms) {
    if (arm.name === postedArm.name) continue;
    // Everything per arm is failure-isolated, prompt composition included: the
    // angry system prompt is longer, so an arm can exceed maxPromptBytes when
    // the posted review fit.
    let prompt: ComposedPrompt | null = null;
    let outcome: ResearchOutcome;
    try {
      prompt = deps.composePrompt({ ...promptInput, policy: { ...promptInput.policy, personality: arm.personality } });
      const result = await runArm(deps.executor, { prompt, snapshot: promptInput.snapshot, models: [arm.model], limits: config.limits });
      const p = deps.planReview(result.form, facts, { config, model: result.model, elapsedMs: result.elapsedMs, engineVersion });
      outcome = planned(p, result);
      run.log.info(`${run.name}: research arm ${arm.name} -> ${p.payload.event}`, { usage: result.usage, elapsedMs: result.elapsedMs });
    } catch (err) {
      outcome = {
        status: "failed",
        kind: err instanceof ExecutorError ? err.kind : "error",
        message: errMsg(err),
        transcript: err instanceof ExecutorError ? err.transcript : [],
      };
      run.log.warn(`${run.name}: research arm ${arm.name} failed`, { kind: outcome.kind, error: outcome.message });
    }
    await save(arm, prompt, outcome, false);
  }
  return counts;
}

/** Renders the prompt for one PR without calling a model or writing to GitHub. */
export async function renderPrompt(
  deps: Pick<ReconcileDeps, "gh" | "prepareSnapshot" | "findGuidanceFiles" | "composePrompt" | "config" | "log">,
  repo: RepoRef,
  number: number,
): Promise<ComposedPrompt> {
  const { gh, config } = deps;
  const facts = await gh.getPullFacts(repo, number);
  const policy = policyFor(config, repo);
  const ci = evaluateCi(facts.checkRuns, policy.requiredChecks);
  const snapshot = await deps.prepareSnapshot(gh, repo, facts.headSha, config.workDir, deps.log);
  try {
    const guidanceFiles = deps.findGuidanceFiles ? await deps.findGuidanceFiles(snapshot) : [];
    return deps.composePrompt({ facts, snapshot, policy, budgets: config.budgets, ci, guidanceFiles });
  } finally {
    await removeTree(snapshot.root).catch(() => {});
  }
}

const COUNTS_AGAINST_CAP: ReadonlySet<ReconcileAction> = new Set(["posted", "dry-run", "failed", "superseded"]);

/**
 * Reconciles every open PR in every allowed installed repo. `maxReviews`
 * caps PRs that reached a review attempt (posted, dry-run, failed or
 * superseded); skips and waits are free, as in v1's REVIEWER_MAX_ATTEMPTS.
 */
export async function sweep(
  deps: ReconcileDeps,
  opts: { onlyRepo?: RepoRef; maxReviews?: number } = {},
): Promise<ReconcileOutcome[]> {
  const { gh, config, log } = deps;
  const maxReviews = opts.maxReviews ?? 1;
  const same = (a: RepoRef, b: RepoRef): boolean => repoName(a).toLowerCase() === repoName(b).toLowerCase();

  const botLogin = await gh.botLogin();
  const repos = (await gh.listInstalledRepos()).filter(
    (r) => isAllowlisted(config, r) && (!opts.onlyRepo || same(r, opts.onlyRepo)),
  );
  const outcomes: ReconcileOutcome[] = [];
  let reviews = 0;
  for (const repo of repos) {
    let pulls;
    try {
      pulls = await gh.listOpenPulls(repo);
    } catch (err) {
      log.error(`${repoName(repo)}: failed to list open pulls`, { error: err });
      continue;
    }
    for (const pr of pulls) {
      // Cheap skips from the list response save a full facts fetch per PR.
      const reason = pr.draft ? "draft" : isSelf(pr.authorLogin, botLogin) ? "self-authored" : null;
      if (reason) {
        outcomes.push({
          repo: repoName(repo),
          number: pr.number,
          headSha: pr.headSha,
          decision: { kind: "skip", reason },
          action: "skipped",
          detail: reason,
        });
        continue;
      }
      if (reviews >= maxReviews) {
        log.info(`sweep: reached maxReviews=${maxReviews}, stopping`);
        return outcomes;
      }
      const outcome = await reconcilePull(deps, repo, pr.number);
      outcomes.push(outcome);
      if (COUNTS_AGAINST_CAP.has(outcome.action)) reviews++;
    }
  }
  return outcomes;
}
