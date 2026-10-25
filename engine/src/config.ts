// Engine configuration: a JSON file plus a few environment overrides, merged
// over defaults and validated strictly. Unknown keys are errors, so a typo
// never silently falls back to a default.

import { readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import type {
  Budgets,
  EngineConfig,
  ExecutorLimits,
  ModelRef,
  Personality,
  ResearchArm,
  RepoPolicy,
  RepoRef,
  ThinkingLevel,
} from "./types.js";
import { repoName } from "./types.js";
import { resolvePersona } from "./persona.js";

export class ConfigError extends Error {
  constructor(readonly problems: string[]) {
    super(`invalid goobreview config:\n  - ${problems.join("\n  - ")}`);
    this.name = "ConfigError";
  }
}

const THINKING: readonly ThinkingLevel[] = ["off", "minimal", "low", "medium", "high"];
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const PROVIDER_RE = /^[a-z0-9][a-z0-9._-]*$/i;

// Byte budgets mirror v1's config/reviewer.env.example defaults.
export const DEFAULT_BUDGETS: Budgets = {
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

export const DEFAULT_LIMITS: ExecutorLimits = {
  maxTurns: 40,
  maxToolCalls: 120,
  maxWallSeconds: 600,
  toolResultMaxBytes: 40_000,
};

export function defaultConfig(): EngineConfig {
  return {
    models: [{ provider: "google", id: "gemini-3.8-flash", thinking: "medium" }],
    repos: [],
    defaults: {
      requiredChecks: [],
      personality: "none:plain",
      include: { author: false, description: false, commitSubjects: true },
    },
    overrides: {},
    budgets: { ...DEFAULT_BUDGETS },
    limits: { ...DEFAULT_LIMITS },
    settleSeconds: 300,
    backoffSeconds: [900, 3600, 14400],
    checkRunSignal: true,
    autoResolveBotThreads: false,
    postTrace: false,
    dryRun: false,
    research: { consent: false, allowPrivate: false, dir: join(homedir(), ".local", "share", "goobreview", "research"), arms: [] },
    workDir: join(tmpdir(), "goobreview"),
  };
}

type Json = Record<string, unknown>;
const isObject = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);

/** Parses "provider/id[:thinking]". The id may itself contain "/" (e.g. openrouter ids). */
export function parseModelSpec(spec: string): ModelRef | string {
  const s = spec.trim();
  const slash = s.indexOf("/");
  if (slash <= 0 || slash === s.length - 1) return `model "${spec}" must look like provider/id[:thinking]`;
  const provider = s.slice(0, slash);
  let id = s.slice(slash + 1);
  let thinking: string = "medium";
  // Only a known level counts as the suffix: openrouter ids carry their own ":free" etc.
  const colon = id.lastIndexOf(":");
  if (colon >= 0 && THINKING.includes(id.slice(colon + 1) as ThinkingLevel)) {
    thinking = id.slice(colon + 1);
    id = id.slice(0, colon);
  }
  return { provider, id, thinking: thinking as ThinkingLevel };
}

export const modelName = (m: ModelRef): string => `${m.provider}/${m.id}:${m.thinking}`;
export const armName = (personality: Personality, model: ModelRef): string => `${personality}@${modelName(model)}`;

class Checker {
  readonly problems: string[] = [];

  keys(where: string, obj: Json, allowed: readonly string[]): void {
    for (const k of Object.keys(obj)) {
      if (!allowed.includes(k)) this.problems.push(`${where}.${k}: unknown key`);
    }
  }

  bool(where: string, v: unknown, fallback: boolean): boolean {
    if (v === undefined) return fallback;
    if (typeof v !== "boolean") {
      this.problems.push(`${where}: expected true or false`);
      return fallback;
    }
    return v;
  }

  int(where: string, v: unknown, fallback: number, min: number): number {
    if (v === undefined) return fallback;
    if (typeof v !== "number" || !Number.isInteger(v) || v < min) {
      this.problems.push(`${where}: expected an integer >= ${min}`);
      return fallback;
    }
    return v;
  }

  model(where: string, v: unknown): ModelRef | null {
    let m: Json;
    if (typeof v === "string") {
      const parsed = parseModelSpec(v);
      if (typeof parsed === "string") {
        this.problems.push(`${where}: ${parsed}`);
        return null;
      }
      m = { ...parsed };
    } else if (isObject(v)) {
      this.keys(where, v, ["provider", "id", "thinking"]);
      m = v;
    } else {
      this.problems.push(`${where}: expected "provider/id[:thinking]" or {provider, id, thinking}`);
      return null;
    }
    const { provider, id } = m;
    const thinking = m.thinking ?? "medium";
    let ok = true;
    if (typeof provider !== "string" || !PROVIDER_RE.test(provider)) {
      this.problems.push(`${where}.provider: expected a pi-ai provider id such as "google"`);
      ok = false;
    }
    if (typeof id !== "string" || id.trim() === "") {
      this.problems.push(`${where}.id: expected a non-empty model id`);
      ok = false;
    } else if (id.trim().toLowerCase() === "auto") {
      // v1's agy "auto" routing hid which model actually reviewed; v2 names models explicitly.
      this.problems.push(`${where}.id: "auto" is not a model; name an explicit model id`);
      ok = false;
    }
    if (typeof thinking !== "string" || !THINKING.includes(thinking as ThinkingLevel)) {
      this.problems.push(`${where}.thinking: expected one of ${THINKING.join(", ")}`);
      ok = false;
    }
    return ok ? { provider: provider as string, id: (id as string).trim(), thinking: thinking as ThinkingLevel } : null;
  }

  models(where: string, v: unknown, fallback: ModelRef[]): ModelRef[] {
    if (v === undefined) return fallback;
    if (!Array.isArray(v) || v.length === 0) {
      this.problems.push(`${where}: expected a non-empty array of models`);
      return fallback;
    }
    return v.map((m, i) => this.model(`${where}[${i}]`, m)).filter((m): m is ModelRef => m !== null);
  }

  repoList(where: string, v: unknown): string[] {
    if (v === undefined) return [];
    if (!Array.isArray(v)) {
      this.problems.push(`${where}: expected an array of "owner/repo"`);
      return [];
    }
    return v.filter((r, i) => {
      if (typeof r === "string" && REPO_RE.test(r)) return true;
      this.problems.push(`${where}[${i}]: expected "owner/repo"`);
      return false;
    });
  }

  policy(where: string, v: unknown, base: RepoPolicy): Partial<RepoPolicy> {
    if (v === undefined) return {};
    if (!isObject(v)) {
      this.problems.push(`${where}: expected an object`);
      return {};
    }
    this.keys(where, v, ["requiredChecks", "personality", "include"]);
    const out: Partial<RepoPolicy> = {};
    if (v.requiredChecks !== undefined) {
      const rc = v.requiredChecks;
      if (!Array.isArray(rc) || !rc.every((n) => typeof n === "string" && n.length > 0)) {
        this.problems.push(`${where}.requiredChecks: expected an array of non-empty check-run names`);
      } else {
        out.requiredChecks = [...rc] as string[];
      }
    }
    if (v.personality !== undefined) {
      const p = this.persona(`${where}.personality`, v.personality);
      if (p !== undefined) out.personality = p;
    }
    if (v.include !== undefined) {
      if (!isObject(v.include)) {
        this.problems.push(`${where}.include: expected an object`);
      } else {
        const inc = v.include;
        this.keys(`${where}.include`, inc, ["author", "description", "commitSubjects"]);
        out.include = {
          author: this.bool(`${where}.include.author`, inc.author, base.include.author),
          description: this.bool(`${where}.include.description`, inc.description, base.include.description),
          commitSubjects: this.bool(`${where}.include.commitSubjects`, inc.commitSubjects, base.include.commitSubjects),
        };
      }
    }
    return out;
  }

  /** A persona spec, loaded and returned in canonical form, so "angry" and "angry:v1" name one arm. */
  persona(where: string, v: unknown): Personality | undefined {
    if (typeof v !== "string") {
      this.problems.push(`${where}: expected a persona spec string`);
      return undefined;
    }
    try {
      return resolvePersona(v).spec;
    } catch (err) {
      this.problems.push(`${where}: ${(err as Error).message}`);
      return undefined;
    }
  }

  /** {models, personalities} expands to their cross product, models outermost. */
  arms(where: string, v: unknown): ResearchArm[] {
    if (v === undefined) return [];
    if (!isObject(v)) {
      this.problems.push(`${where}: expected {models: [...], personalities: [...]}`);
      return [];
    }
    this.keys(where, v, ["models", "personalities"]);
    const models = this.models(`${where}.models`, v.models, []);
    if (v.models === undefined) this.problems.push(`${where}.models: required`);
    const ps = v.personalities;
    if (!Array.isArray(ps) || ps.length === 0) {
      this.problems.push(`${where}.personalities: expected a non-empty array of persona specs`);
      return [];
    }
    const specs = ps.map((p, i) => this.persona(`${where}.personalities[${i}]`, p));
    if (specs.some((s) => s === undefined)) return [];
    const out: ResearchArm[] = [];
    for (const model of models)
      for (const personality of specs as Personality[]) {
        const name = armName(personality, model);
        if (out.some((a) => a.name === name)) this.problems.push(`${where}: duplicate arm ${name}`);
        else out.push({ name, model, personality });
      }
    return out;
  }

  numbers<T extends object>(where: string, v: unknown, base: T, min: number): T {
    if (v === undefined) return { ...base };
    if (!isObject(v)) {
      this.problems.push(`${where}: expected an object`);
      return { ...base };
    }
    this.keys(where, v, Object.keys(base));
    const out = { ...base } as Record<string, number>;
    for (const k of Object.keys(base)) out[k] = this.int(`${where}.${k}`, v[k], out[k]!, min);
    return out as T;
  }
}

const TOP_KEYS = [
  "models",
  "repos",
  "defaults",
  "overrides",
  "budgets",
  "limits",
  "settleSeconds",
  "backoffSeconds",
  "checkRunSignal",
  "autoResolveBotThreads",
  "postTrace",
  "dryRun",
  "research",
  "workDir",
] as const;

/** Validates a parsed JSON config (already merged with env overrides) over the defaults. */
export function resolveConfig(raw: unknown): EngineConfig {
  const d = defaultConfig();
  const c = new Checker();
  if (!isObject(raw)) throw new ConfigError(["config: expected a JSON object"]);
  c.keys("config", raw, TOP_KEYS);

  const defaultsPartial = c.policy("defaults", raw.defaults, d.defaults);
  const defaults: RepoPolicy = { ...d.defaults, ...defaultsPartial };

  const overrides: Record<string, Partial<RepoPolicy>> = {};
  if (raw.overrides !== undefined) {
    if (!isObject(raw.overrides)) c.problems.push("overrides: expected an object keyed by owner/repo");
    else
      for (const [k, v] of Object.entries(raw.overrides)) {
        if (!REPO_RE.test(k)) c.problems.push(`overrides.${k}: key must be "owner/repo"`);
        else overrides[k] = c.policy(`overrides.${k}`, v, defaults);
      }
  }

  let backoffSeconds = d.backoffSeconds;
  if (raw.backoffSeconds !== undefined) {
    const b = raw.backoffSeconds;
    if (!Array.isArray(b) || b.length === 0 || !b.every((n) => Number.isInteger(n) && (n as number) >= 0)) {
      c.problems.push("backoffSeconds: expected a non-empty array of integers >= 0");
    } else backoffSeconds = [...b] as number[];
  }

  let research = d.research;
  if (raw.research !== undefined) {
    if (!isObject(raw.research)) c.problems.push("research: expected an object");
    else {
      const r = raw.research;
      c.keys("research", r, ["consent", "allowPrivate", "dir", "arms"]);
      let dir = d.research.dir;
      if (r.dir !== undefined) {
        if (typeof r.dir !== "string" || r.dir.trim() === "") c.problems.push("research.dir: expected a path");
        else dir = r.dir;
      }
      research = {
        consent: c.bool("research.consent", r.consent, false),
        allowPrivate: c.bool("research.allowPrivate", r.allowPrivate, false),
        dir,
        arms: c.arms("research.arms", r.arms),
      };
    }
  }

  let workDir = d.workDir;
  if (raw.workDir !== undefined) {
    if (typeof raw.workDir !== "string" || raw.workDir.trim() === "") c.problems.push("workDir: expected a path");
    else workDir = raw.workDir;
  }

  const config: EngineConfig = {
    models: c.models("models", raw.models, d.models),
    repos: c.repoList("repos", raw.repos),
    defaults,
    overrides,
    budgets: c.numbers("budgets", raw.budgets, d.budgets, 1),
    limits: c.numbers("limits", raw.limits, d.limits, 1),
    settleSeconds: c.int("settleSeconds", raw.settleSeconds, d.settleSeconds, 0),
    backoffSeconds,
    checkRunSignal: c.bool("checkRunSignal", raw.checkRunSignal, d.checkRunSignal),
    autoResolveBotThreads: c.bool("autoResolveBotThreads", raw.autoResolveBotThreads, d.autoResolveBotThreads),
    postTrace: c.bool("postTrace", raw.postTrace, d.postTrace),
    dryRun: c.bool("dryRun", raw.dryRun, d.dryRun),
    research,
    workDir,
  };
  if (c.problems.length > 0) throw new ConfigError(c.problems);
  return config;
}

function envBool(name: string, v: string): boolean {
  const s = v.trim().toLowerCase();
  if (["1", "true", "yes"].includes(s)) return true;
  if (["0", "false", "no", ""].includes(s)) return false;
  throw new ConfigError([`${name}: expected 1/0 or true/false, got "${v}"`]);
}

/**
 * Loads config from `file` (or $GOOBREVIEW_CONFIG), then applies env overrides:
 * GOOBREVIEW_DRY_RUN, GOOBREVIEW_MODELS ("provider/id[:thinking],..."),
 * GOOBREVIEW_WORK_DIR.
 */
export function loadConfig(opts: { file?: string; env?: NodeJS.ProcessEnv } = {}): EngineConfig {
  const env = opts.env ?? process.env;
  const file = opts.file ?? (env.GOOBREVIEW_CONFIG || undefined);
  let raw: Json = {};
  if (file) {
    let text: string;
    try {
      text = readFileSync(file, "utf8");
    } catch (err) {
      throw new ConfigError([`${file}: cannot read config file (${(err as NodeJS.ErrnoException).code ?? "error"})`]);
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      throw new ConfigError([`${file}: invalid JSON (${(err as Error).message})`]);
    }
    if (!isObject(parsed)) throw new ConfigError([`${file}: expected a JSON object`]);
    raw = parsed;
  }
  if (env.GOOBREVIEW_DRY_RUN !== undefined) raw.dryRun = envBool("GOOBREVIEW_DRY_RUN", env.GOOBREVIEW_DRY_RUN);
  if (env.GOOBREVIEW_MODELS !== undefined) {
    raw.models = env.GOOBREVIEW_MODELS.split(",").map((s) => s.trim()).filter((s) => s !== "");
  }
  if (env.GOOBREVIEW_WORK_DIR) raw.workDir = env.GOOBREVIEW_WORK_DIR;
  return resolveConfig(raw);
}

const lower = (s: string): string => s.toLowerCase();

/** GitHub owner/repo names are case-insensitive. */
export function isAllowlisted(config: EngineConfig, repo: RepoRef): boolean {
  if (config.repos.length === 0) return true;
  const name = lower(repoName(repo));
  return config.repos.some((r) => lower(r) === name);
}

export function policyFor(config: EngineConfig, repo: RepoRef): RepoPolicy {
  const name = lower(repoName(repo));
  const key = Object.keys(config.overrides).find((k) => lower(k) === name);
  const o = key ? config.overrides[key]! : {};
  return {
    requiredChecks: [...(o.requiredChecks ?? config.defaults.requiredChecks)],
    personality: o.personality ?? config.defaults.personality,
    include: { ...config.defaults.include, ...o.include },
  };
}
