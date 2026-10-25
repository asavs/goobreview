import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ConfigError, isAllowlisted, loadConfig, parseModelSpec, policyFor, resolveConfig } from "../src/config.js";

const dir = mkdtempSync(join(tmpdir(), "goob-config-"));
const file = (name: string, content: unknown): string => {
  const p = join(dir, name);
  writeFileSync(p, typeof content === "string" ? content : JSON.stringify(content));
  return p;
};
const problems = (fn: () => unknown): string[] => {
  try {
    fn();
  } catch (err) {
    expect(err).toBeInstanceOf(ConfigError);
    return (err as ConfigError).problems;
  }
  throw new Error("expected ConfigError");
};

describe("loadConfig", () => {
  it("applies defaults with no file", () => {
    const c = loadConfig({ env: {} });
    expect(c.models).toEqual([{ provider: "google", id: "gemini-3.8-flash", thinking: "medium" }]);
    expect(c.settleSeconds).toBe(300);
    expect(c.backoffSeconds).toEqual([900, 3600, 14400]);
    expect(c.budgets.maxPromptBytes).toBe(240_000);
    expect(c.budgets.diffFileMaxBytes).toBe(40_000);
    expect(c.limits).toEqual({ maxTurns: 40, maxToolCalls: 120, maxWallSeconds: 600, toolResultMaxBytes: 40_000 });
    expect(c.defaults).toEqual({
      requiredChecks: [],
      personality: "none:plain",
      include: { author: false, description: false, commitSubjects: true },
    });
    expect(c).toMatchObject({ checkRunSignal: true, autoResolveBotThreads: false, postTrace: false, dryRun: false });
    expect(c.workDir).toBe(join(tmpdir(), "goobreview"));
  });

  it("reads the file from GOOBREVIEW_CONFIG and merges partial sections", () => {
    const p = file("ok.json", {
      repos: ["o/r"],
      budgets: { diffMaxBytes: 1000 },
      defaults: { requiredChecks: ["test"], include: { author: true } },
      overrides: { "O/R": { personality: "angry", include: { commitSubjects: false } } },
    });
    const c = loadConfig({ env: { GOOBREVIEW_CONFIG: p } });
    expect(c.budgets.diffMaxBytes).toBe(1000);
    expect(c.budgets.maxPromptBytes).toBe(240_000);
    const policy = policyFor(c, { owner: "o", repo: "r" });
    expect(policy).toEqual({
      requiredChecks: ["test"],
      personality: "angry:v1",
      include: { author: true, description: false, commitSubjects: false },
    });
    expect(policyFor(c, { owner: "x", repo: "y" }).personality).toBe("none:plain");
    expect(isAllowlisted(c, { owner: "O", repo: "R" })).toBe(true);
    expect(isAllowlisted(c, { owner: "x", repo: "y" })).toBe(false);
  });

  it("applies env overrides", () => {
    const c = loadConfig({
      env: { GOOBREVIEW_DRY_RUN: "1", GOOBREVIEW_MODELS: "google/gemini-3.8-pro:high, openrouter/vendor/model:free" },
    });
    expect(c.dryRun).toBe(true);
    expect(c.models).toEqual([
      { provider: "google", id: "gemini-3.8-pro", thinking: "high" },
      { provider: "openrouter", id: "vendor/model:free", thinking: "medium" },
    ]);
  });

  it("rejects a bad GOOBREVIEW_DRY_RUN", () => {
    expect(problems(() => loadConfig({ env: { GOOBREVIEW_DRY_RUN: "maybe" } }))[0]).toMatch(/GOOBREVIEW_DRY_RUN/);
  });

  it("reports unreadable and malformed files", () => {
    expect(problems(() => loadConfig({ file: join(dir, "missing.json"), env: {} }))[0]).toMatch(/cannot read/);
    expect(problems(() => loadConfig({ file: file("bad.json", "{nope"), env: {} }))[0]).toMatch(/invalid JSON/);
    expect(problems(() => loadConfig({ file: file("arr.json", "[]"), env: {} }))[0]).toMatch(/JSON object/);
  });
});

describe("resolveConfig validation", () => {
  it("rejects model id auto", () => {
    expect(problems(() => resolveConfig({ models: [{ provider: "google", id: "auto" }] }))).toEqual([
      'models[0].id: "auto" is not a model; name an explicit model id',
    ]);
    expect(problems(() => resolveConfig({ models: ["google/auto"] }))[0]).toMatch(/"auto"/);
  });

  it("collects every problem with a path", () => {
    const p = problems(() =>
      resolveConfig({
        modles: [],
        models: [],
        repos: ["not-a-repo"],
        settleSeconds: -1,
        backoffSeconds: [],
        budgets: { diffMaxBytes: 0, bogus: 1 },
        limits: { maxTurns: 1.5 },
        defaults: { personality: "linus", requiredChecks: [""] },
        overrides: { nope: {} },
        checkRunSignal: "yes",
        research: { consent: 1 },
      }),
    );
    expect(p).toEqual(
      expect.arrayContaining([
        "config.modles: unknown key",
        "models: expected a non-empty array of models",
        'repos[0]: expected "owner/repo"',
        "settleSeconds: expected an integer >= 0",
        "backoffSeconds: expected a non-empty array of integers >= 0",
        "budgets.bogus: unknown key",
        "budgets.diffMaxBytes: expected an integer >= 1",
        "limits.maxTurns: expected an integer >= 1",
        expect.stringMatching(/^defaults.personality: persona "linus": cannot read persona.json/),
        "defaults.requiredChecks: expected an array of non-empty check-run names",
        'overrides.nope: key must be "owner/repo"',
        "checkRunSignal: expected true or false",
        "research.consent: expected true or false",
      ]),
    );
  });

  it("validates model fields", () => {
    const p = problems(() =>
      resolveConfig({ models: [{ provider: "", id: "x" }, { provider: "google", id: "m", thinking: "max" }, "noslash", 3] }),
    );
    expect(p).toEqual([
      'models[0].provider: expected a pi-ai provider id such as "google"',
      "models[1].thinking: expected one of off, minimal, low, medium, high",
      'models[2]: model "noslash" must look like provider/id[:thinking]',
      'models[3]: expected "provider/id[:thinking]" or {provider, id, thinking}',
    ]);
  });

  it("parses model specs", () => {
    expect(parseModelSpec("anthropic/claude-x:low")).toEqual({ provider: "anthropic", id: "claude-x", thinking: "low" });
    expect(parseModelSpec("google/")).toMatch(/provider\/id/);
  });
});
