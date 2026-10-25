// Runs the reviewer agent in-process. The model gets the read-only snapshot
// tools plus submit_review, and nothing else: no shell, ever. Its only output
// channel is a submit_review call validated here; free text is never parsed.
//
// Telemetry: pi-ai accepts an optional `telemetryContext` and does nothing
// without one; pi-telemetry ships contracts only, no exporter. We never pass
// one, so the only network peer is the configured model provider.

import { Agent, type AgentEvent, type AgentMessage, type AgentTool } from "@earendil-works/pi-agent-core";
import { Type, type AssistantMessage, type Model, type Models, type Api } from "@earendil-works/pi-ai";
import { createModelsCollection, describeCredential } from "./credentials.js";
import { userMessage } from "./prompt.js";
import { createSteering } from "./steering.js";
import { createReadOnlyTools } from "./tools.js";
import {
  ExecutorError,
  type ComposedPrompt,
  type Executor,
  type ExecutorErrorKind,
  type ExecutorInput,
  type ExecutorResult,
  type Finding,
  type Logger,
  type ModelCredential,
  type ModelRef,
  type ReviewForm,
  type TranscriptEntry,
} from "./types.js";

export const SUBMIT_TOOL = "submit_review";

const NUDGE =
  "You stopped without calling submit_review. The review is only recorded through that tool. " +
  "Call submit_review now with your verdict, summary and findings; do not call any other tool.";

/** Per transcript text field; the transcript is a debugging artifact, not an archive. */
const TRANSCRIPT_TEXT_MAX = 16_384;
const TRANSCRIPT_RESULT_MAX = 2_048;
/** Turns allowed after the nudge (one to submit, one to fix a rejected submission). */
const NUDGE_TURNS = 2;
/** Fail fast on long provider-requested retry waits so the next model gets a turn. */
const MAX_RETRY_DELAY_MS = 15_000;

const FindingSchema = Type.Object({
  title: Type.String({ minLength: 1, description: "Short distinctive title; becomes the comment heading." }),
  blocking: Type.Boolean({ description: "True only if this must be fixed before merge." }),
  path: Type.Optional(Type.String({ description: "Repository-relative path in the PR head." })),
  line: Type.Optional(Type.Integer({ minimum: 1, description: "Line in the PR head (RIGHT side)." })),
  startLine: Type.Optional(Type.Integer({ minimum: 1, description: "First line of a range ending at `line`." })),
  body: Type.String({ description: "Markdown explanation." }),
  suggestion: Type.Optional(
    Type.String({ description: "Exact replacement text for lines startLine..line (or just line), verified against the snapshot." }),
  ),
});

const ReviewFormSchema = Type.Object({
  verdict: Type.Union([Type.Literal("APPROVE"), Type.Literal("REQUEST_CHANGES"), Type.Literal("COMMENT")]),
  summary: Type.String({ minLength: 1, description: "Review summary in Markdown." }),
  findings: Type.Array(FindingSchema),
  resolvedThreads: Type.Optional(Type.Array(Type.Object({ handle: Type.String(), evidence: Type.String() }))),
  unresolvedThreads: Type.Optional(Type.Array(Type.Object({ handle: Type.String(), explanation: Type.String() }))),
  notCovered: Type.Optional(Type.Array(Type.String(), { description: "Changed paths this verdict does not cover." })),
});

export interface ExecutorOptions {
  log: Logger;
  credentialsFile?: string;
  /** Injectable for tests. */
  models?: Models;
}

export function createExecutor(opts: ExecutorOptions): Executor {
  const models = opts.models ?? createModelsCollection(opts.credentialsFile ? { credentialsFile: opts.credentialsFile } : {});
  return { run: (input) => runWithFallback(models, opts.log, input) };
}

async function runWithFallback(models: Models, log: Logger, input: ExecutorInput): Promise<ExecutorResult> {
  const started = Date.now();
  const deadline = started + input.limits.maxWallSeconds * 1000;
  const transcript: TranscriptEntry[] = [];
  const usage = { requests: 0, inputTokens: 0, outputTokens: 0, toolCalls: 0 };
  if (input.models.length === 0) throw new ExecutorError("provider", "no models configured", transcript);
  let last: ExecutorError | undefined;
  let allQuota = true;
  for (const ref of input.models) {
    try {
      const credential = await describeCredential(models, ref.provider);
      const form = await runOne(models, ref, credential, input, deadline, transcript, usage);
      return { form, model: ref, ...(credential ? { credential } : {}), transcript, usage, elapsedMs: Date.now() - started };
    } catch (err) {
      const e = err instanceof ExecutorError ? err : new ExecutorError("provider", errorText(err), transcript);
      const fallback = (e as FallbackError).fallback === true;
      log.warn("model attempt failed", { provider: ref.provider, model: ref.id, kind: e.kind, fallback });
      transcript.push(entry("model_failed", { provider: ref.provider, model: ref.id, kind: e.kind, message: e.message }));
      last = e;
      if (e.kind !== "quota") allQuota = false;
      if (!fallback) break;
    }
  }
  // Reconcile backs off briefly on quota without advancing the failure ladder,
  // so report quota only when every model we tried was out of quota.
  const kind: ExecutorErrorKind = allQuota ? "quota" : last!.kind;
  throw new ExecutorError(kind, last!.message, transcript);
}

/** An ExecutorError that may be retried on the next configured model. */
class FallbackError extends ExecutorError {
  constructor(
    kind: ExecutorErrorKind,
    message: string,
    transcript: TranscriptEntry[],
    readonly fallback: boolean,
  ) {
    super(kind, message, transcript);
  }
}

async function runOne(
  models: Models,
  ref: ModelRef,
  credential: ModelCredential | undefined,
  input: ExecutorInput,
  deadline: number,
  transcript: TranscriptEntry[],
  usage: ExecutorResult["usage"],
): Promise<ReviewForm> {
  const model = models.getModel(ref.provider, ref.id) as Model<Api> | undefined;
  transcript.push(entry("model", { provider: ref.provider, model: ref.id, thinking: ref.thinking, ...(credential ? { credential } : {}) }));
  if (!model) throw new FallbackError("provider", `unknown model ${ref.provider}/${ref.id}`, transcript, true);

  const remaining = deadline - Date.now();
  if (remaining <= 0 || input.signal?.aborted) throw new ExecutorError("timeout", "wall-clock budget exhausted", transcript);

  let form: ReviewForm | undefined;
  let rejected: string | undefined;
  let phase: "main" | "nudge" = "main";
  let turns = 0;
  let nudgeTurns = 0;
  let budgetedCalls = 0;
  /** Snapshot tool calls admitted to run; unknown, invalid and blocked calls never are. */
  const admitted = new Set<string>();
  const { maxTurns, maxToolCalls } = input.limits;

  const submit: AgentTool<typeof ReviewFormSchema> = {
    name: SUBMIT_TOOL,
    label: "Submit review",
    description:
      "Record your review. This is the only way to deliver it; call it exactly once when done. " +
      "Use line/startLine from the PR head. Findings on lines outside the diff stay in the review body.",
    parameters: ReviewFormSchema,
    executionMode: "sequential",
    execute: async (_id, params) => {
      const checked = validateReviewForm(params);
      if (!checked.ok) {
        rejected = checked.errors.join("; ");
        return {
          content: [{ type: "text", text: `submit_review rejected: ${rejected}. Fix these and call submit_review again.` }],
          details: { rejected },
          isError: true,
        };
      }
      form ??= checked.form;
      return { content: [{ type: "text", text: "Review recorded." }], details: { recorded: true }, terminate: true };
    },
  };

  const agent = new Agent({
    initialState: {
      systemPrompt: input.prompt.system,
      model,
      thinkingLevel: ref.thinking,
      tools: [...createReadOnlyTools(input.snapshot, input.limits), submit],
    },
    streamFn: models.streamSimple.bind(models),
    maxRetryDelayMs: MAX_RETRY_DELAY_MS,
    // Steer messages due at the same count arrive together, before the same
    // request; one-at-a-time would stagger them and can force extra requests.
    steeringMode: "all",
    beforeToolCall: async ({ toolCall }) => {
      if (toolCall.name === SUBMIT_TOOL) return undefined;
      if (phase === "nudge") return { block: true, reason: "Only submit_review is available now. Call it with your review." };
      if (budgetedCalls >= maxToolCalls) {
        return { block: true, reason: `Tool-call budget (${maxToolCalls}) exhausted. Call submit_review now with what you have.` };
      }
      budgetedCalls += 1;
      admitted.add(toolCall.id);
      return undefined;
    },
    finishTurn: async () => {
      if (form) return { action: "end" };
      if (phase === "main") {
        turns += 1;
        if (turns >= maxTurns) return { action: "end" };
      } else {
        nudgeTurns += 1;
        if (nudgeTurns >= NUDGE_TURNS) return { action: "end" };
      }
      return undefined;
    },
  });

  const steering = createSteering(input.prompt.persona.steer);
  /** Queued steer messages and the tool-call count each fell due at; logged only once delivered. */
  const queued = new Map<AgentMessage, number>();
  agent.subscribe((event) => {
    record(event, transcript, usage);
    // pi emits message_end for a queued message when it adds it to the
    // context, right before the request it reaches. A message dropped (the
    // review ended, or the nudge cleared it) is never logged.
    if (event.type === "message_end" && queued.has(event.message)) {
      const m = event.message as { content: string };
      transcript.push(entry("steer", { afterToolCalls: queued.get(event.message), text: clip(m.content, TRANSCRIPT_TEXT_MAX) }));
      queued.delete(event.message);
      return;
    }
    // Persona steering counts snapshot tool calls that actually ran, in the
    // main review only.
    if (event.type !== "tool_execution_end" || !admitted.has(event.toolCallId) || phase !== "main" || form) return;
    for (const text of steering.toolCompleted()) {
      const message: AgentMessage = { role: "user", content: text, timestamp: Date.now() };
      queued.set(message, steering.completed);
      agent.steer(message);
    }
  });

  // Abort the agent on the deadline or the caller's signal, and stop waiting
  // for it too: a provider that ignores its abort signal must not hang the run.
  let timedOut = false;
  let stop!: (err: ExecutorError) => void;
  const stopped = new Promise<never>((_, reject) => (stop = reject));
  stopped.catch(() => {});
  const timer = setTimeout(() => {
    timedOut = true;
    agent.abort();
    stop(new ExecutorError("timeout", "wall-clock budget exhausted", transcript));
  }, remaining);
  const onAbort = () => {
    agent.abort();
    stop(new ExecutorError("timeout", "review aborted", transcript));
  };
  input.signal?.addEventListener("abort", onAbort, { once: true });

  try {
    await Promise.race([prompt(agent, openingMessages(input.prompt), transcript), stopped]);
    if (!form) {
      check(agent, transcript, timedOut, input.signal);
      phase = "nudge";
      // A steer message still queued from the main review must not land
      // after the nudge's instruction; the nudge is persona-free in every arm.
      agent.clearSteeringQueue();
      transcript.push(entry("nudge", { text: NUDGE }));
      await Promise.race([prompt(agent, NUDGE, transcript), stopped]);
    }
    if (!form) check(agent, transcript, timedOut, input.signal);
  } finally {
    clearTimeout(timer);
    input.signal?.removeEventListener("abort", onAbort);
  }

  if (form) return form;
  if (rejected) throw new ExecutorError("invalid-review", `submitted review failed validation: ${rejected}`, transcript);
  throw new ExecutorError("no-review", "model stopped without calling submit_review", transcript);
}

/** Marks persona turns seeded as earlier conversation: never a model response, never counted as one. */
export const SEEDED = "goobreview-persona";

/** The persona's seeded turns, then the PR data wrapped in the persona: one batch, ending on the user. */
export function openingMessages(p: ComposedPrompt, now = Date.now()): AgentMessage[] {
  const turns: AgentMessage[] = p.persona.history.map((t) =>
    t.role === "user"
      ? { role: "user", content: t.text, timestamp: now }
      : {
          role: "assistant",
          content: [{ type: "text", text: t.text }],
          api: SEEDED,
          provider: SEEDED,
          model: SEEDED,
          usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
          stopReason: "stop",
          timestamp: now,
        },
  );
  return [...turns, { role: "user", content: userMessage(p), timestamp: now }];
}

const seeded = (m: AssistantMessage): boolean => m.provider === SEEDED;

async function prompt(agent: Agent, input: string | AgentMessage[], transcript: TranscriptEntry[]): Promise<void> {
  try {
    await (typeof input === "string" ? agent.prompt(input) : agent.prompt(input));
  } catch (err) {
    // Agent normally reports failures on the last assistant message; a throw
    // here is a setup failure, classified the same way.
    throw classified(errorText(err), transcript);
  }
}

/** Throw if the last run ended in a provider error or an abort. */
function check(agent: Agent, transcript: TranscriptEntry[], timedOut: boolean, signal?: AbortSignal): void {
  const last = lastAssistant(agent);
  if (timedOut) throw new ExecutorError("timeout", "wall-clock budget exhausted", transcript);
  if (last?.stopReason === "aborted" || signal?.aborted) throw new ExecutorError("timeout", "review aborted", transcript);
  if (last?.stopReason === "error") throw classified(last.errorMessage ?? agent.state.errorMessage ?? "provider error", transcript);
}

function lastAssistant(agent: Agent): AssistantMessage | undefined {
  const msgs = agent.state.messages;
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i] as { role?: string };
    if (m.role === "assistant" && !seeded(m as AssistantMessage)) return m as AssistantMessage;
  }
  return undefined;
}

function classified(message: string, transcript: TranscriptEntry[]): FallbackError {
  const { kind, fallback } = classifyProviderError(message);
  return new FallbackError(kind, message, transcript, fallback);
}

/**
 * Map a provider error message to an executor error kind. RESOURCE_EXHAUSTED
 * alone is a generic gRPC status (also used for oversized requests), so it
 * counts as quota only alongside quota-shaped wording (v1 lib/agy.sh).
 * `fallback` says whether the next configured model is worth trying.
 */
export function classifyProviderError(message: string): { kind: "quota" | "auth" | "provider"; fallback: boolean } {
  const m = message;
  if (
    /\b429\b|rate.?limit|too many requests|QUOTA_EXHAUSTED|insufficient_quota|exceeded your current quota|quota exceeded|Individual quota reached|exhausted your capacity|No capacity available|usage.?limit/i.test(m) ||
    (/RESOURCE_EXHAUSTED/i.test(m) && /quota|rate limit/i.test(m))
  ) {
    return { kind: "quota", fallback: true };
  }
  if (
    /\b(401|403)\b|unauthori[sz]ed|unauthenticated|authentication|permission[ _]denied|invalid[ _-]?(api[ _-]?)?key|api key not valid|not configured|credential|oauth|token refresh|x-api-key/i.test(m)
  ) {
    return { kind: "auth", fallback: false };
  }
  // Availability problems are worth another model; anything else is a bug or
  // a request problem that the next model would hit too.
  const unavailable = /\b(500|502|503|504|529)\b|overloaded|\bUNAVAILABLE\b|temporarily unavailable|model[^.]*not found|not_found_error|does not exist/i.test(m);
  return { kind: "provider", fallback: unavailable };
}

export type FormCheck = { ok: true; form: ReviewForm } | { ok: false; errors: string[] };

/** Semantic validation beyond the tool schema; normalizes optional arrays. */
export function validateReviewForm(raw: unknown): FormCheck {
  const errors: string[] = [];
  if (!isRecord(raw)) return { ok: false, errors: ["arguments must be an object"] };
  const verdict = raw.verdict;
  if (verdict !== "APPROVE" && verdict !== "REQUEST_CHANGES" && verdict !== "COMMENT") {
    errors.push("verdict must be APPROVE, REQUEST_CHANGES or COMMENT");
  }
  if (typeof raw.summary !== "string" || raw.summary.trim() === "") errors.push("summary must be non-empty");
  const findings: Finding[] = [];
  if (!Array.isArray(raw.findings)) errors.push("findings must be an array");
  else {
    raw.findings.forEach((f, i) => {
      const at = `findings[${i}]`;
      if (!isRecord(f)) return void errors.push(`${at} must be an object`);
      if (typeof f.title !== "string" || f.title.trim() === "") errors.push(`${at}.title must be non-empty`);
      if (typeof f.blocking !== "boolean") errors.push(`${at}.blocking must be a boolean`);
      if (typeof f.body !== "string") errors.push(`${at}.body must be a string`);
      if (f.path !== undefined && (typeof f.path !== "string" || f.path.trim() === "")) errors.push(`${at}.path must be a non-empty string`);
      const line = f.line;
      const start = f.startLine;
      if (line !== undefined && !(Number.isInteger(line) && (line as number) >= 1)) errors.push(`${at}.line must be an integer >= 1`);
      if (line !== undefined && f.path === undefined) errors.push(`${at}.line needs a path`);
      if (start !== undefined) {
        if (!(Number.isInteger(start) && (start as number) >= 1)) errors.push(`${at}.startLine must be an integer >= 1`);
        else if (line === undefined) errors.push(`${at}.startLine needs line`);
        else if (Number.isInteger(line) && (start as number) > (line as number)) errors.push(`${at}.startLine must be <= line`);
      }
      if (f.suggestion !== undefined) {
        if (typeof f.suggestion !== "string") errors.push(`${at}.suggestion must be a string`);
        else if (line === undefined) errors.push(`${at}.suggestion needs line`);
      }
      const finding: Finding = { title: String(f.title ?? ""), blocking: f.blocking === true, body: String(f.body ?? "") };
      if (typeof f.path === "string") finding.path = f.path;
      if (typeof line === "number") finding.line = line;
      if (typeof start === "number") finding.startLine = start;
      if (typeof f.suggestion === "string") finding.suggestion = f.suggestion;
      findings.push(finding);
    });
  }
  const pairs = <K extends string>(value: unknown, name: string, key: K): ({ handle: string } & Record<K, string>)[] => {
    if (value === undefined) return [];
    if (!Array.isArray(value)) return void errors.push(`${name} must be an array`), [];
    const out: ({ handle: string } & Record<K, string>)[] = [];
    value.forEach((v, i) => {
      if (!isRecord(v) || typeof v.handle !== "string" || typeof v[key] !== "string") {
        errors.push(`${name}[${i}] must have string handle and ${key}`);
      } else {
        out.push({ handle: v.handle, [key]: v[key] } as { handle: string } & Record<K, string>);
      }
    });
    return out;
  };
  const resolvedThreads = pairs(raw.resolvedThreads, "resolvedThreads", "evidence");
  const unresolvedThreads = pairs(raw.unresolvedThreads, "unresolvedThreads", "explanation");
  let notCovered: string[] = [];
  if (raw.notCovered !== undefined) {
    if (!Array.isArray(raw.notCovered) || raw.notCovered.some((p) => typeof p !== "string")) errors.push("notCovered must be an array of strings");
    else notCovered = raw.notCovered as string[];
  }
  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    form: { verdict: verdict as ReviewForm["verdict"], summary: raw.summary as string, findings, resolvedThreads, unresolvedThreads, notCovered },
  };
}

// ---------------------------------------------------------------------------
// Transcript

function record(
  event: AgentEvent,
  transcript: TranscriptEntry[],
  usage: ExecutorResult["usage"],
): void {
  switch (event.type) {
    case "turn_start":
      transcript.push(entry("turn_start", {}));
      break;
    case "message_end": {
      const msg = event.message as { role?: string };
      if (msg.role !== "assistant") break;
      const m = msg as AssistantMessage;
      if (seeded(m)) break;
      const u = m.usage;
      usage.requests += 1;
      usage.inputTokens += (u?.input ?? 0) + (u?.cacheRead ?? 0) + (u?.cacheWrite ?? 0);
      usage.outputTokens += u?.output ?? 0;
      const text = m.content.flatMap((c) => (c.type === "text" ? [c.text] : [])).join("\n");
      const thinking = m.content.flatMap((c) => (c.type === "thinking" ? [c.thinking] : [])).join("\n");
      const fields: Record<string, unknown> = {
        stopReason: m.stopReason,
        usage: { input: u?.input ?? 0, output: u?.output ?? 0, cacheRead: u?.cacheRead ?? 0, cacheWrite: u?.cacheWrite ?? 0 },
      };
      if (text) fields.text = clip(text, TRANSCRIPT_TEXT_MAX);
      if (thinking) fields.thinking = clip(thinking, TRANSCRIPT_TEXT_MAX);
      if (m.errorMessage) fields.error = clip(m.errorMessage, TRANSCRIPT_RESULT_MAX);
      transcript.push(entry("assistant", fields));
      break;
    }
    case "tool_execution_start":
      usage.toolCalls += 1;
      transcript.push(entry("tool_call", { id: event.toolCallId, name: event.toolName, args: event.args }));
      break;
    case "tool_execution_end": {
      const result = event.result as { content?: { type: string; text?: string }[] } | undefined;
      const text = (result?.content ?? []).flatMap((c) => (c.type === "text" && c.text ? [c.text] : [])).join("\n");
      transcript.push(
        entry("tool_result", { id: event.toolCallId, name: event.toolName, isError: event.isError, text: clip(text, TRANSCRIPT_RESULT_MAX) }),
      );
      break;
    }
    default:
      break;
  }
}

const entry = (type: string, fields: Record<string, unknown>): TranscriptEntry => ({ t: new Date().toISOString(), type, ...fields });

const clip = (s: string, max: number): string => (s.length <= max ? s : `${s.slice(0, max)}… [${s.length - max} chars truncated]`);

const errorText = (err: unknown): string => (err instanceof Error ? err.message : String(err));

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
