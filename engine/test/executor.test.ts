import { createModels, fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall, Type } from "@earendil-works/pi-ai";
import { noPersona } from "./fixtures/prompt-input.js";
import { describe, expect, it, vi } from "vitest";
import { classifyProviderError, createExecutor, validateReviewForm } from "../src/executor.js";
import { ExecutorError, type ExecutorInput, type ExecutorLimits, type ModelRef } from "../src/types.js";

// tools.ts is another module's concern; a single fake read_file is enough here.
vi.mock("../src/tools.js", () => ({
  createReadOnlyTools: () => [
    {
      name: "read_file",
      label: "Read file",
      description: "read",
      parameters: Type.Object({ path: Type.String() }),
      execute: async (_id: string, p: { path: string }) => ({ content: [{ type: "text", text: `contents of ${p.path}` }], details: {} }),
    },
  ],
}));

const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
const LIMITS: ExecutorLimits = { maxTurns: 10, maxToolCalls: 10, maxWallSeconds: 30, toolResultMaxBytes: 1000 };
const GOOD = { verdict: "APPROVE", summary: "Looks fine.", findings: [] };

function setup(...providers: string[]) {
  const models = createModels();
  const fauxes = providers.map((provider) => {
    const faux = fauxProvider({ provider, models: [{ id: "m" }] });
    models.setProvider(faux.provider);
    return faux;
  });
  const executor = createExecutor({ log, models });
  const refs: ModelRef[] = providers.map((provider) => ({ provider, id: "m", thinking: "off" }));
  const input = (over: Partial<ExecutorInput> = {}): ExecutorInput => ({
    prompt: { system: "sys", user: "review this", persona: noPersona(), omissions: [], bytes: 0 },
    snapshot: { root: "/nonexistent", sha: "abc", generatedPatterns: [], symlinkStubs: [] },
    models: refs,
    limits: LIMITS,
    ...over,
  });
  return { fauxes, executor, input };
}

const submit = (args: unknown) => fauxAssistantMessage(fauxToolCall("submit_review", args as Parameters<typeof fauxToolCall>[1]), { stopReason: "toolUse" });

async function failure(p: Promise<unknown>): Promise<ExecutorError> {
  try {
    await p;
  } catch (e) {
    if (e instanceof ExecutorError) return e;
    throw e;
  }
  throw new Error("expected ExecutorError");
}

describe("executor", () => {
  it("reads a file then submits; captures transcript and usage", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    fauxes[0]!.setResponses([
      fauxAssistantMessage([fauxThinking("look first"), fauxToolCall("read_file", { path: "a.ts" })], { stopReason: "toolUse" }),
      submit({ ...GOOD, findings: [{ title: "Nit", blocking: false, path: "a.ts", line: 2, body: "b" }] }),
    ]);
    const res = await executor.run(input());
    expect(res.form.verdict).toBe("APPROVE");
    expect(res.form.findings[0]).toMatchObject({ title: "Nit", line: 2 });
    expect(res.form.resolvedThreads).toEqual([]);
    expect(res.model.provider).toBe("faux-a");
    expect(res.usage.requests).toBe(2);
    expect(res.usage.toolCalls).toBe(2);
    expect(res.usage.inputTokens).toBeGreaterThan(0);
    const types = res.transcript.map((e) => e.type);
    expect(types).toEqual(expect.arrayContaining(["model", "turn_start", "assistant", "tool_call", "tool_result"]));
    expect(res.transcript.find((e) => e.type === "tool_call")).toMatchObject({ name: "read_file", args: { path: "a.ts" } });
    expect(res.transcript.find((e) => e.type === "tool_result")).toMatchObject({ text: "contents of a.ts", isError: false });
    expect(res.transcript.find((e) => e.type === "assistant")).toMatchObject({ thinking: "look first" });
    // submit_review terminates the loop: no further model request.
    expect(fauxes[0]!.state.callCount).toBe(2);
  });

  it("nudges once when the model stops without submitting, then fails no-review", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    fauxes[0]!.setResponses([fauxAssistantMessage(fauxText("LGTM")), fauxAssistantMessage(fauxText("still LGTM"))]);
    const err = await failure(executor.run(input()));
    expect(err.kind).toBe("no-review");
    expect(err.transcript.some((e) => e.type === "nudge")).toBe(true);
    expect(fauxes[0]!.state.callCount).toBe(2);
  });

  it("accepts a submission made after the nudge", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    fauxes[0]!.setResponses([fauxAssistantMessage(fauxText("done")), submit(GOOD)]);
    expect((await executor.run(input())).form.summary).toBe("Looks fine.");
  });

  it("fails invalid-review when submissions never validate", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    const bad = { ...GOOD, findings: [{ title: "x", blocking: true, path: "a.ts", line: 3, startLine: 5, body: "b" }] };
    fauxes[0]!.setResponses([submit(bad), fauxAssistantMessage(fauxText("oops")), submit(bad), fauxAssistantMessage(fauxText("?"))]);
    const err = await failure(executor.run(input()));
    expect(err.kind).toBe("invalid-review");
    expect(err.message).toContain("startLine must be <= line");
  });

  it("falls back to the next model on a quota error", async () => {
    const { fauxes, executor, input } = setup("faux-a", "faux-b");
    fauxes[0]!.setResponses([
      fauxAssistantMessage([], { stopReason: "error", errorMessage: "429 RESOURCE_EXHAUSTED: Quota exceeded for metric" }),
    ]);
    fauxes[1]!.setResponses([submit(GOOD)]);
    const res = await executor.run(input());
    expect(res.model.provider).toBe("faux-b");
    expect(res.transcript.find((e) => e.type === "model_failed")).toMatchObject({ provider: "faux-a", kind: "quota" });
  });

  it("does not fall back on auth errors", async () => {
    const { fauxes, executor, input } = setup("faux-a", "faux-b");
    fauxes[0]!.setResponses([fauxAssistantMessage([], { stopReason: "error", errorMessage: "401 Unauthorized: invalid api key" })]);
    fauxes[1]!.setResponses([submit(GOOD)]);
    expect((await failure(executor.run(input()))).kind).toBe("auth");
    expect(fauxes[1]!.state.callCount).toBe(0);
  });

  it("reports quota when every model is out of quota", async () => {
    const { fauxes, executor, input } = setup("faux-a", "faux-b");
    for (const f of fauxes) f.setResponses([fauxAssistantMessage([], { stopReason: "error", errorMessage: "Too Many Requests" })]);
    expect((await failure(executor.run(input()))).kind).toBe("quota");
  });

  it("blocks tool calls past the cap and tells the model to submit", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    const read = (p: string) => fauxAssistantMessage(fauxToolCall("read_file", { path: p }), { stopReason: "toolUse" });
    fauxes[0]!.setResponses([read("1"), read("2"), read("3"), submit(GOOD)]);
    const res = await executor.run(input({ limits: { ...LIMITS, maxToolCalls: 2 } }));
    const results = res.transcript.filter((e) => e.type === "tool_result" && e.name === "read_file");
    expect(results.map((r) => r.isError)).toEqual([false, false, true]);
    expect(String(results[2]!.text)).toContain("Call submit_review now");
  });

  it("ends the main loop at maxTurns, then nudges", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    const read = fauxAssistantMessage(fauxToolCall("read_file", { path: "x" }), { stopReason: "toolUse" });
    fauxes[0]!.setResponses([read, read, submit(GOOD)]);
    const res = await executor.run(input({ limits: { ...LIMITS, maxTurns: 2 } }));
    expect(res.transcript.some((e) => e.type === "nudge")).toBe(true);
    expect(res.form.verdict).toBe("APPROVE");
  });

  it("times out on the wall-clock budget", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    fauxes[0]!.setResponses([async () => new Promise((r) => setTimeout(() => r(fauxAssistantMessage("late")), 5_000))]);
    const err = await failure(executor.run(input({ limits: { ...LIMITS, maxWallSeconds: 0.2 } })));
    expect(err.kind).toBe("timeout");
  });

  it("treats an unknown model as unavailable and moves on", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    fauxes[0]!.setResponses([submit(GOOD)]);
    const res = await executor.run(input({ models: [{ provider: "faux-a", id: "nope", thinking: "off" }, { provider: "faux-a", id: "m", thinking: "off" }] }));
    expect(res.model.id).toBe("m");
  });
});

describe("classifyProviderError", () => {
  it.each([
    ["429 Too Many Requests", "quota", true],
    ["RESOURCE_EXHAUSTED: Quota exceeded", "quota", true],
    ["RESOURCE_EXHAUSTED: request payload too large", "provider", false],
    ["OpenAI API error: subscription_sharing_usage_limit_exceeded\nCheck your ChatGPT usage: https://chatgpt.com/settings/usage", "quota", true],
    ["Provider is not configured: anthropic", "auth", false],
    ["403 PERMISSION_DENIED", "auth", false],
    ["503 Service Unavailable", "provider", true],
    ["400 invalid tool schema", "provider", false],
  ])("%s -> %s", (msg, kind, fallback) => {
    expect(classifyProviderError(msg)).toEqual({ kind, fallback });
  });
});

describe("validateReviewForm", () => {
  it("rejects bad verdicts, empty summaries and bad lines", () => {
    const r = validateReviewForm({ verdict: "LGTM", summary: " ", findings: [{ title: "t", blocking: false, body: "", path: "a", line: 0 }] });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.errors.join("\n")).toMatch(/verdict[\s\S]*summary[\s\S]*line must be an integer/);
  });

  it("normalizes optional arrays", () => {
    const r = validateReviewForm(GOOD);
    expect(r.ok && r.form).toMatchObject({ resolvedThreads: [], unresolvedThreads: [], notCovered: [] });
  });
});

describe("executor: persona turns", () => {
  it("seeds the persona's turns before the wrapped PR data, and never counts them as model output", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    let seen: { role: string; text: string }[] = [];
    fauxes[0]!.setResponses([
      (ctx) => {
        seen = (ctx.messages as { role: string; content: string | { type: string; text?: string }[] }[])
          .filter((m) => m.role === "user" || m.role === "assistant")
          .map((m) => ({ role: m.role, text: typeof m.content === "string" ? m.content : m.content.map((c) => c.text ?? "").join("") }));
        return submit(GOOD);
      },
    ]);
    const persona = { ...noPersona("angry:turns"), history: [{ role: "user" as const, text: "*ding*" }, { role: "assistant" as const, text: "Right. Fine. Show me." }], after: "Go." };
    const res = await executor.run(input({ prompt: { system: "sys", user: "review this\n", persona, omissions: [], bytes: 0 } }));
    expect(seen).toEqual([
      { role: "user", text: "*ding*" },
      { role: "assistant", text: "Right. Fine. Show me." },
      { role: "user", text: "review this\n\nGo." },
    ]);
    expect(res.usage.requests).toBe(1);
    expect(res.transcript.filter((e) => e.type === "assistant")).toHaveLength(1);
  });
});

describe("executor: persona steering", () => {
  it("delivers a steer message after the scheduled tool call, before the next request", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    const userTexts: string[][] = [];
    const read = (path: string) => (ctx: { messages: unknown[] }) => {
      userTexts.push((ctx.messages as { role: string; content: unknown }[]).filter((m) => m.role === "user").map((m) => String(m.content)));
      return fauxAssistantMessage(fauxToolCall("read_file", { path }), { stopReason: "toolUse" });
    };
    fauxes[0]!.setResponses([read("a"), read("b"), read("c"), (ctx) => (read("x")(ctx), submit(GOOD))]);
    const persona = { ...noPersona("angry:x"), steer: [{ text: "*ding*", afterToolCalls: [2] }] };
    const res = await executor.run(input({ prompt: { system: "sys", user: "review this", persona, omissions: [], bytes: 0 } }));
    expect(res.form.verdict).toBe("APPROVE");
    // Requests 1-2 see only the PR message; the ding lands after the second tool result, once.
    expect(userTexts.map((u) => u.filter((t) => t === "*ding*").length)).toEqual([0, 0, 1, 1]);
    expect(res.transcript.filter((e) => e.type === "steer")).toEqual([expect.objectContaining({ afterToolCalls: 2, text: "*ding*" })]);
  });
});

describe("executor: steering counts calls that ran", () => {
  it("ignores blocked and unknown tool calls", async () => {
    const { fauxes, executor, input } = setup("faux-a");
    const seen: number[] = [];
    const call = (name: string) => (ctx: { messages: unknown[] }) => {
      seen.push((ctx.messages as { role: string; content: unknown }[]).filter((m) => m.role === "user" && m.content === "*ding*").length);
      return fauxAssistantMessage(fauxToolCall(name, { path: "a" }), { stopReason: "toolUse" });
    };
    // Call 1 runs; the unknown tool and call 2 (past maxToolCalls: 1) never run, so a ding due at 2 never fires.
    fauxes[0]!.setResponses([call("read_file"), call("no_such_tool"), call("read_file"), (ctx) => (call("x")(ctx), submit(GOOD))]);
    const persona = { ...noPersona("angry:x"), steer: [{ text: "*ding*", afterToolCalls: [2] }] };
    const res = await executor.run(input({ prompt: { system: "sys", user: "review this", persona, omissions: [], bytes: 0 }, limits: { ...LIMITS, maxToolCalls: 1 } }));
    expect(res.form.verdict).toBe("APPROVE");
    expect(seen).toEqual([0, 0, 0, 0]);
    expect(res.transcript.filter((e) => e.type === "steer")).toEqual([]);
  });
});
