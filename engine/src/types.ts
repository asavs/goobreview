// Shared contracts for the goobreview engine. Modules depend on these types,
// not on each other's internals, so each layer can be tested against fakes.

export type ReviewEvent = "APPROVE" | "REQUEST_CHANGES" | "COMMENT";
export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high";
/** A persona spec (personas/README.md): "<name>[:<recipe>][+piece|-piece]...", canonical once config is loaded. */
export type Personality = string;
/** Where a persona piece lands in the conversation. */
export type PieceSlot = "role" | "history.user" | "history.assistant" | "before" | "after" | "steer";

/** One seeded conversation turn, placed before the PR data. */
export interface PersonaTurn {
  role: "user" | "assistant";
  text: string;
}

/** A user message delivered mid-run, once after each listed count of completed tool calls. */
export interface PersonaSteer {
  /** The piece id and its SHA-256: what transcripts log, so they never carry persona text. */
  id: string;
  sha256: string;
  text: string;
  afterToolCalls: number[];
}

export interface PersonaPiece {
  id: string;
  slot: PieceSlot;
  /** SHA-256 of the piece text, so an edited line starts a new series. */
  sha256: string;
  /** Steer pieces only: the schedule. */
  afterToolCalls?: number[];
}

export interface RepoRef {
  owner: string;
  repo: string;
}

export const repoName = (r: RepoRef): string => `${r.owner}/${r.repo}`;

// ---------------------------------------------------------------------------
// Configuration (fully resolved; see config.ts for defaults and validation)

export interface ModelRef {
  /** pi-ai provider id, e.g. "google", "google-vertex", "anthropic", "openrouter". */
  provider: string;
  /** Provider model id, e.g. "gemini-3.8-flash". Never "auto". */
  id: string;
  thinking: ThinkingLevel;
}

export interface Budgets {
  maxPromptBytes: number;
  diffMaxBytes: number;
  diffFileMaxBytes: number;
  descriptionMaxBytes: number;
  previousReviewMaxBytes: number;
  priorThreadLimit: number;
  priorThreadBodyMaxBytes: number;
  commitSubjectsMax: number;
  suggestionMaxLines: number;
  traceMaxBytes: number;
}

export interface ExecutorLimits {
  maxTurns: number;
  maxToolCalls: number;
  maxWallSeconds: number;
  /** Per tool result, bytes returned to the model before truncation. */
  toolResultMaxBytes: number;
}

export interface RepoPolicy {
  /** Exact check-run names that must succeed before review; [] = no gate. */
  requiredChecks: string[];
  personality: Personality;
  include: { author: boolean; description: boolean; commitSubjects: boolean };
}

export interface EngineConfig {
  /** Models tried in order; later entries are used only on quota/availability errors. */
  models: ModelRef[];
  /** Optional allowlist of "owner/repo"; empty = every repo the App is installed on. */
  repos: string[];
  defaults: RepoPolicy;
  /** Per-repo overrides keyed by "owner/repo". */
  overrides: Record<string, Partial<RepoPolicy>>;
  budgets: Budgets;
  limits: ExecutorLimits;
  /** A PR the bot already reviewed waits until its head is unchanged this long. */
  settleSeconds: number;
  /** Failure backoff ladder; attempt N waits ladder[min(N-1, len-1)] seconds. */
  backoffSeconds: number[];
  checkRunSignal: boolean;
  autoResolveBotThreads: boolean;
  postTrace: boolean;
  dryRun: boolean;
  research: ResearchConfig;
  /** Directory for snapshots and transcripts; ephemeral is fine. */
  workDir: string;
}

// ---------------------------------------------------------------------------
// GitHub facts

export interface PullSummary {
  number: number;
  headSha: string;
  draft: boolean;
  authorLogin: string;
}

export type FileStatus = "added" | "removed" | "modified" | "renamed" | "copied" | "changed" | "unchanged";

export interface ChangedFile {
  path: string;
  previousPath?: string;
  status: FileStatus;
  additions: number;
  deletions: number;
  /** Unified diff hunk text as GitHub returns it; undefined when GitHub omits it (binary/too large). */
  patch?: string;
}

export interface BotReview {
  id: number;
  commitId: string;
  state: string;
  body: string;
  submittedAt: string;
}

export interface ReviewThread {
  /** GraphQL node id, used to resolve. */
  id: string;
  /** Stable slug derived from the thread's first heading. */
  handle: string;
  path: string;
  line?: number;
  isResolved: boolean;
  /** REST id of the first comment, used to reply. */
  firstCommentId: number;
  firstCommentBody: string;
  viewerCanResolve: boolean;
}

export type CheckStatus = "queued" | "in_progress" | "completed" | "waiting" | "requested" | "pending";

export interface CheckRunFact {
  name: string;
  status: CheckStatus;
  conclusion: string | null;
  appSlug?: string;
}

export interface PullRequestFacts {
  repo: RepoRef;
  number: number;
  htmlUrl: string;
  title: string;
  body: string;
  draft: boolean;
  state: "open" | "closed";
  author: { login: string; type: string };
  headSha: string;
  headRef: string;
  baseRef: string;
  baseSha: string;
  isFork: boolean;
  repoPrivate: boolean;
  commits: { sha: string; subject: string }[];
  files: ChangedFile[];
  /** Reviews authored by this App's bot, oldest first. */
  botReviews: BotReview[];
  /** True when a review from the bot was (re-)requested after its latest review. */
  reviewRequested: boolean;
  /** Inline threads opened by the bot. */
  botThreads: ReviewThread[];
  /** Check runs on headSha, excluding this engine's own check run. */
  checkRuns: CheckRunFact[];
}

// ---------------------------------------------------------------------------
// Engine state, persisted in the engine's own check run on each head SHA, so
// any stateless worker can pick up where another left off.

export interface EngineState {
  /** When the engine first observed this head SHA (ISO). */
  firstSeenAt: string;
  /** Consecutive failed review attempts on this head. */
  attempts: number;
  lastFailureReason?: "review-failure" | "invalid-review" | "quota";
  lastAttemptAt?: string;
}

export interface EngineCheckRun {
  id: number;
  status: CheckStatus;
  conclusion: string | null;
  state: EngineState | null;
}

export interface CheckRunUpdate {
  status: "queued" | "in_progress" | "completed";
  conclusion?: "success" | "failure" | "neutral" | "skipped";
  title: string;
  summary: string;
  state: EngineState;
}

// ---------------------------------------------------------------------------
// Decisions (pure; see decide.ts)

export type SkipReason =
  | "draft"
  | "self-authored"
  | "already-reviewed"
  | "closed"
  | "not-allowlisted";

export type Decision =
  | { kind: "skip"; reason: SkipReason }
  | { kind: "wait"; reason: "settling" | "backoff" | "ci-pending"; until?: string; detail?: string }
  | { kind: "ci-failed"; failing: string[] }
  | { kind: "review"; rereview: boolean };

export type CiState =
  | { state: "none" }
  | { state: "success"; checks: string[] }
  | { state: "pending"; waitingOn: string[] }
  | { state: "failing"; failing: string[] };

// ---------------------------------------------------------------------------
// Snapshot and prompt

export interface Snapshot {
  /** Absolute path of the extracted, read-only PR-head tree. */
  root: string;
  sha: string;
  /** linguist-generated patterns from the snapshot's .gitattributes (non-symlink only). */
  generatedPatterns: string[];
  /** Paths replaced by stubs because they were symlinks. */
  symlinkStubs: string[];
}

export interface PromptInput {
  facts: PullRequestFacts;
  snapshot: Snapshot;
  policy: RepoPolicy;
  budgets: Budgets;
  ci: CiState;
  /** Guidance files present in the snapshot (AGENTS.md, CONTRIBUTING.md, ...), relative paths. */
  guidanceFiles: string[];
}

/** The persona as composed into one prompt; blinding strips these texts. */
export interface ComposedPersona {
  spec: string;
  pieces: PersonaPiece[];
  /** Text of each slot exactly as placed ("" when empty). `system` starts with `role`. */
  role: string;
  /** Turns the model sees as earlier conversation, ending on an assistant turn. */
  history: PersonaTurn[];
  before: string;
  after: string;
  /** Mid-run messages; the executor delivers each as a user message after its tool-call counts. */
  steer: PersonaSteer[];
}

/** Short SHA-256s of what an arm sends apart from the PR data (`promptFingerprint`). */
export interface PromptFingerprint {
  /** The shared system prompt: role section, contract, tools, output rules, trust boundary. */
  contract: string;
  /** The persona's texts by slot and its steer schedule. */
  persona: string;
}

export interface ComposedPrompt {
  /** Trusted: persona role, contract, output rules. Never contains PR-authored text. */
  system: string;
  /** Untrusted PR data, clearly fenced, identical across personas. The model receives it wrapped by the persona (`userMessage`). */
  user: string;
  persona: ComposedPersona;
  /** Human-readable notes of what was omitted for budget or generated-file reasons. */
  omissions: string[];
  bytes: number;
}

// ---------------------------------------------------------------------------
// Review form: the model's only output channel is a submit_review tool call
// whose arguments match this shape. Nothing is parsed out of free text.

export interface Finding {
  /** Short distinctive title; becomes the heading and the thread handle. */
  title: string;
  blocking: boolean;
  path?: string;
  /** Line in the PR head (RIGHT side). */
  line?: number;
  /** First line of a multi-line range ending at `line`. */
  startLine?: number;
  body: string;
  /** Exact replacement for [startLine..line], verified against the snapshot. */
  suggestion?: string;
}

export interface ReviewForm {
  verdict: ReviewEvent;
  summary: string;
  findings: Finding[];
  resolvedThreads: { handle: string; evidence: string }[];
  unresolvedThreads: { handle: string; explanation: string }[];
  /** Changed paths the verdict does not cover (not inspected). */
  notCovered: string[];
}

// ---------------------------------------------------------------------------
// Executor

export interface TranscriptEntry {
  t: string;
  type: string;
  [key: string]: unknown;
}

export interface ExecutorInput {
  prompt: ComposedPrompt;
  snapshot: Snapshot;
  models: ModelRef[];
  limits: ExecutorLimits;
  signal?: AbortSignal;
}

/** How the reviewing model was authenticated; recorded with research data. */
export interface ModelCredential {
  type: "api_key" | "oauth";
  /** pi-ai's label, e.g. "OPENAI_API_KEY" or "stored credential". Never a value. */
  source?: string;
  /** A consumer subscription login rather than API billing. */
  subscription: boolean;
  /** The provider's login path alters the system prompt or tools the model sees. */
  rewritesRequests: boolean;
}

/** The thinking level asked for and what actually ran, which can differ by model. */
export interface ThinkingUsed {
  requested: ThinkingLevel;
  /** The level pi sent after fitting the request to the model (it rounds to the nearest supported level). */
  sent: string;
  /** The provider-native level the provider reported using, when it reports one. */
  provider?: string;
}

export interface ExecutorResult {
  form: ReviewForm;
  model: ModelRef;
  thinking?: ThinkingUsed;
  credential?: ModelCredential;
  transcript: TranscriptEntry[];
  usage: { requests: number; inputTokens: number; outputTokens: number; toolCalls: number };
  elapsedMs: number;
}

export type ExecutorErrorKind = "quota" | "auth" | "no-review" | "invalid-review" | "timeout" | "provider";

export class ExecutorError extends Error {
  constructor(
    readonly kind: ExecutorErrorKind,
    message: string,
    readonly transcript: TranscriptEntry[] = [],
  ) {
    super(message);
    this.name = "ExecutorError";
  }
}

export interface Executor {
  run(input: ExecutorInput): Promise<ExecutorResult>;
}

// ---------------------------------------------------------------------------
// Posting

export interface InlineComment {
  path: string;
  line: number;
  startLine?: number;
  side: "RIGHT";
  body: string;
}

export interface ReviewPayload {
  commitId: string;
  event: ReviewEvent;
  body: string;
  comments: InlineComment[];
}

export interface ThreadAction {
  thread: ReviewThread;
  kind: "resolve" | "reply";
  body: string;
}

export interface PlannedReview {
  payload: ReviewPayload;
  threadActions: ThreadAction[];
  /** Notes about transformations applied (downgrade, demoted suggestions, unplaced findings). */
  notes: string[];
}

// ---------------------------------------------------------------------------
// GitHub port. The Octokit implementation lives in github/; tests use a fake.

export interface GitHubPort {
  /** "<slug>[bot]" for the authenticated App. */
  botLogin(): Promise<string>;
  listInstalledRepos(): Promise<RepoRef[]>;
  listOpenPulls(repo: RepoRef): Promise<PullSummary[]>;
  getPullFacts(repo: RepoRef, number: number): Promise<PullRequestFacts>;
  getHeadSha(repo: RepoRef, number: number): Promise<string>;
  /** Writes the gzipped tarball of `sha` to `destFile`. */
  downloadTarball(repo: RepoRef, sha: string, destFile: string): Promise<void>;
  getEngineCheckRun(repo: RepoRef, sha: string): Promise<EngineCheckRun | null>;
  /** Creates or updates the engine's check run on `sha`; returns its id. */
  upsertEngineCheckRun(repo: RepoRef, sha: string, update: CheckRunUpdate): Promise<number>;
  addReaction(repo: RepoRef, number: number, content: "eyes" | "confused"): Promise<void>;
  postReview(repo: RepoRef, number: number, payload: ReviewPayload): Promise<{ id: number; htmlUrl: string }>;
  replyToThread(repo: RepoRef, number: number, commentId: number, body: string): Promise<void>;
  resolveThread(threadId: string): Promise<void>;
}

// ---------------------------------------------------------------------------
// Research capture. With consent, every reviewed head yields one record per
// arm: the posted review fills the arm it matches, and every other arm runs
// unposted on the same snapshot. Failures are records too, never gaps.

/** One cell of the research grid: a single model (no fallback) and a personality. */
export interface ResearchArm {
  /** "<personality>@<provider>/<id>:<thinking>", stable across runs. */
  name: string;
  model: ModelRef;
  personality: Personality;
}

export interface ResearchConfig {
  consent: boolean;
  allowPrivate: boolean;
  /** Where the file sink writes records. */
  dir: string;
  /** The grid run on every consenting head; [] records only the posted review. */
  arms: ResearchArm[];
}

export type ResearchOutcome =
  | {
      status: "ok";
      result: ExecutorResult;
      /** After the engine's own planning (downgrade rule, inline placement). */
      event: ReviewEvent;
      body: string;
      comments: InlineComment[];
      notes: string[];
    }
  | { status: "failed"; kind: ExecutorErrorKind | "error"; message: string; transcript: TranscriptEntry[] };

export interface ResearchRecord {
  schemaVersion: 2;
  /** Groups the arms run on one PR head: "owner/repo#N@sha". */
  itemId: string;
  repo: string;
  pr: number;
  headSha: string;
  baseSha: string;
  engineVersion: string;
  /** False for dry runs, which post nothing. */
  live: boolean;
  arm: ResearchArm;
  /** This arm's review is the one posted (or, in dry run, the one that would be). */
  posted: boolean;
  reviewUrl?: string;
  /** Set for offline eval runs; scoring joins this to the corpus label. */
  /** `claims`: short SHA-256 of the variant's pr.json, null without one; scoring keeps the two conditions apart. */
  corpus?: { name: string; item: string; variant: string; claims: string | null };
  /** Which series this run belongs to; null only if the arm's persona could not be resolved. */
  fingerprint: PromptFingerprint | null;
  /** Persona text is in `prompt.persona` (and starts `system`); consumers that blind must strip it. Null when composing it failed. */
  prompt: ComposedPrompt | null;
  outcome: ResearchOutcome;
}

export interface ResearchSink {
  record(rec: ResearchRecord): Promise<void>;
}

// ---------------------------------------------------------------------------

export interface Logger {
  info(msg: string, fields?: Record<string, unknown>): void;
  warn(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
}
