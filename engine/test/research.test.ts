import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { noPersona } from "./fixtures/prompt-input.js";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { resolveConfig } from "../src/config.js";
import { createFileResearchSink } from "../src/research.js";
import type { ResearchRecord } from "../src/types.js";

let dir: string;
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const model = { provider: "openai", id: "gpt-x", thinking: "medium" as const };
const rec = (over: Partial<ResearchRecord> = {}): ResearchRecord => ({
  schemaVersion: 2,
  itemId: "o/r#7@abc",
  repo: "o/r",
  pr: 7,
  headSha: "abc",
  baseSha: "def",
  fingerprint: null,
  engineVersion: "test",
  live: true,
  arm: { name: "angry:v1@openai/gpt-x:medium", model, personality: "angry:v1" },
  posted: true,
  prompt: { system: "sys", user: "user", persona: noPersona(), omissions: [], bytes: 7 },
  outcome: {
    status: "ok",
    result: {
      form: { verdict: "REQUEST_CHANGES", summary: "s", findings: [{ title: "t", blocking: true, body: "b" }], resolvedThreads: [], unresolvedThreads: [], notCovered: [] },
      model,
      credential: { type: "oauth", subscription: true, rewritesRequests: false },
      transcript: [],
      usage: { requests: 2, inputTokens: 100, outputTokens: 10, toolCalls: 3 },
      elapsedMs: 50,
    },
    event: "REQUEST_CHANGES",
    body: "b",
    comments: [],
    notes: [],
  },
  ...over,
});

describe("file research sink", () => {
  it("writes one record file per arm run and an index row", async () => {
    dir = mkdtempSync(path.join(tmpdir(), "goob-research-"));
    const sink = createFileResearchSink({ dir, installationId: "inst-1", now: () => new Date("2026-10-24T00:00:00Z") });
    await sink.record(rec());
    await sink.record(rec({ arm: { name: "none:plain@openai/gpt-x:medium", model, personality: "none:plain" }, posted: false, outcome: { status: "failed", kind: "quota", message: "429", transcript: [] } }));

    const rows = readFileSync(path.join(dir, "index.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatchObject({
      itemId: "o/r#7@abc",
      arm: "angry:v1@openai/gpt-x:medium",
      posted: true,
      status: "ok",
      event: "REQUEST_CHANGES",
      findings: 1,
      blocking: 1,
      model: "openai/gpt-x",
      usage: { inputTokens: 100 },
    });
    expect(rows[1]).toMatchObject({ status: "failed", kind: "quota", posted: false });
    expect(rows[0].file).toMatch(/^runs\/o\/r\/7\/abc\/angry_v1_openai_gpt-x_medium\.[0-9a-f-]{36}\.json$/);

    const stored = JSON.parse(readFileSync(path.join(dir, rows[0].file), "utf8"));
    expect(stored).toMatchObject({ installationId: "inst-1", recordedAt: "2026-10-24T00:00:00.000Z", prompt: { user: "user" } });
    expect(stored.recordId).toBe(rows[0].recordId);
    if (process.platform !== "win32") expect(statSync(path.join(dir, rows[0].file)).mode & 0o777).toBe(0o600);
  });
});

describe("research config", () => {
  it("expands arms to models x personalities", () => {
    const c = resolveConfig({
      research: { consent: true, dir: "/r", arms: { models: ["openai/gpt-x:medium", "anthropic/c:low"], personalities: ["none", "angry"] } },
    });
    expect(c.research.dir).toBe("/r");
    expect(c.research.arms.map((a) => a.name)).toEqual([
      "none:plain@openai/gpt-x:medium",
      "angry:v1@openai/gpt-x:medium",
      "none:plain@anthropic/c:low",
      "angry:v1@anthropic/c:low",
    ]);
  });

  it("rejects malformed arms", () => {
    expect(() => resolveConfig({ research: { arms: { models: ["openai/x"], personalities: ["linus"] } } })).toThrow(/research\.arms\.personalities/);
    expect(() => resolveConfig({ research: { arms: { personalities: ["none"] } } })).toThrow(/research\.arms\.models: required/);
    expect(() => resolveConfig({ research: { arms: { models: ["openai/x", "openai/x"], personalities: ["none"] } } })).toThrow(/duplicate arm none:plain@openai\/x:medium/);
  });
});
