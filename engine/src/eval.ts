// Offline eval: run the research arms over a known-answer corpus with no
// GitHub. Each corpus variant becomes a synthetic PR on a copy of the seed
// tree with the variant overlaid, hardened exactly like a PR-head snapshot.
// Labels are never read here; scoring joins records to labels by corpus path.
//
// Corpus layout (angry-llm-research scripts/generate-mutants.sh):
//   <corpus>/<item>/<variant>/diff.patch
//   <corpus>/<item>/<variant>/snapshot/<relpath>   files that replace the seed's
//   <corpus>/<item>/<variant>/pr.json              optional PR text: {title?, body?, commits?}
//   <corpus>/<item>/<variant>/label.json           ground truth (not read)

import { createHash, randomBytes } from "node:crypto";
import { cp, mkdir, readdir, readFile, rm, stat } from "node:fs/promises";
import path from "node:path";
import * as tar from "tar";
import { modelName } from "./config.js";
import type { ComposePromptFn, FindGuidanceFilesFn, PlanReviewFn } from "./reconcile.js";
import { removeTree, runArm } from "./reconcile.js";
import { fingerprintOrNull, seriesKey } from "./prompt.js";
import type { IndexedRun } from "./research.js";
import { snapshotFromArchive } from "./snapshot.js";
import {
  ExecutorError,
  type ChangedFile,
  type ComposedPrompt,
  type EngineConfig,
  type Executor,
  type Logger,
  type PullRequestFacts,
  type ResearchOutcome,
  type ResearchSink,
  type Snapshot,
} from "./types.js";

export interface EvalVariant {
  item: string;
  variant: string;
  dir: string;
}

export interface EvalDeps {
  config: EngineConfig;
  executor: Executor;
  composePrompt: ComposePromptFn;
  planReview: PlanReviewFn;
  findGuidanceFiles?: FindGuidanceFilesFn;
  research: ResearchSink;
  log: Logger;
  engineVersion?: string;
}

export interface EvalOptions {
  corpus: string;
  /** The seed tree the corpus was generated from. */
  tree: string;
  /** Corpus name in item ids; defaults to the corpus directory's basename. */
  name?: string;
  /** Runs per (variant, arm); design v2 asks for k >= 3. */
  repeats: number;
  /** Only the first N items (each with all its variants), in sorted order. */
  limit?: number;
  /** Prior index rows, so an interrupted eval resumes instead of repeating runs. */
  done?: IndexedRun[];
}

export interface EvalSummary {
  variants: number;
  runs: number;
  ok: number;
  failed: number;
  /** Runs already in the index from an earlier invocation. */
  resumed: number;
  /** Runs not attempted because their model ran out of quota this invocation. */
  skippedQuota: number;
  exhaustedModels: string[];
  /** Variants whose snapshot could not be prepared or whose diff was empty. */
  unprepared: number;
  /**
   * Runs still owed after this invocation: quota failures, quota skips, and
   * every pending run of an unprepared variant. Zero means the corpus is done.
   */
  incomplete: number;
}

export async function listCorpus(corpus: string): Promise<EvalVariant[]> {
  const out: EvalVariant[] = [];
  const dirs = async (p: string) =>
    (await readdir(p, { withFileTypes: true })).filter((d) => d.isDirectory()).map((d) => d.name).sort();
  for (const item of await dirs(corpus)) {
    for (const variant of await dirs(path.join(corpus, item))) {
      const dir = path.join(corpus, item, variant);
      const has = await readFile(path.join(dir, "diff.patch"), "utf8").then(() => true, () => false);
      if (has) out.push({ item, variant, dir });
    }
  }
  return out;
}

/** Unified diff (one or more files) to GitHub-style ChangedFiles: `patch` starts at the first hunk. */
export function parseUnifiedDiff(text: string): ChangedFile[] {
  const files: ChangedFile[] = [];
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  let cur: { file: ChangedFile; hunks: string[] } | undefined;
  const flush = () => {
    if (!cur) return;
    while (cur.hunks.length > 0 && cur.hunks[cur.hunks.length - 1] === "") cur.hunks.pop();
    if (cur.hunks.length > 0) cur.file.patch = cur.hunks.join("\n");
    files.push(cur.file);
    cur = undefined;
  };
  const strip = (p: string) => p.replace(/\t.*$/, "").replace(/^[ab]\//, "");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (line.startsWith("--- ") && lines[i + 1]?.startsWith("+++ ")) {
      flush();
      const from = strip(line.slice(4));
      const to = strip(lines[i + 1]!.slice(4));
      const status = from === "/dev/null" ? "added" : to === "/dev/null" ? "removed" : "modified";
      const file: ChangedFile = { path: status === "removed" ? from : to, status, additions: 0, deletions: 0 };
      if (status === "modified" && from !== to) {
        file.status = "renamed";
        file.previousPath = from;
      }
      cur = { file, hunks: [] };
      i++;
      continue;
    }
    if (!cur || (cur.hunks.length === 0 && !line.startsWith("@@"))) continue;
    cur.hunks.push(line);
    if (line.startsWith("+")) cur.file.additions++;
    else if (line.startsWith("-")) cur.file.deletions++;
  }
  flush();
  return files;
}

async function filesUnder(root: string, rel = ""): Promise<string[]> {
  const out: string[] = [];
  for (const d of await readdir(path.join(root, rel), { withFileTypes: true }).catch(() => [])) {
    const r = rel ? `${rel}/${d.name}` : d.name;
    if (d.isDirectory()) out.push(...(await filesUnder(root, r)));
    else if (d.isFile()) out.push(r);
  }
  return out.sort();
}

/** Content-addressed id for a variant, shaped like a SHA so it flows through the snapshot code. */
async function variantSha(v: EvalVariant, diff: string, overlay: string[]): Promise<string> {
  const h = createHash("sha256").update(`${v.item}\0${v.variant}\0${diff}`);
  for (const rel of overlay) h.update(`\0${rel}\0`).update(await readFile(path.join(v.dir, "snapshot", rel)));
  return h.digest("hex").slice(0, 40);
}

/** Copy of the seed tree (minus .git) with the variant's files overlaid, as a gzipped tarball. */
async function writeVariantArchive(tree: string, v: EvalVariant, overlay: string[], workDir: string, dest: string): Promise<void> {
  const stage = path.join(workDir, `eval-stage-${randomBytes(4).toString("hex")}`);
  const top = path.join(stage, "tree");
  try {
    await cp(tree, top, {
      recursive: true,
      // Links stay links, so the snapshot stubs them like any PR's.
      verbatimSymlinks: true,
      filter: (src) => path.basename(src) !== ".git",
    });
    for (const rel of overlay) {
      await mkdir(path.dirname(path.join(top, rel)), { recursive: true });
      await cp(path.join(v.dir, "snapshot", rel), path.join(top, rel));
    }
    await tar.c({ gzip: true, file: dest, cwd: stage, portable: true }, ["tree"]);
  } finally {
    await rm(stage, { recursive: true, force: true });
  }
}

/** Optional author text for a variant: the claims a reviewer checks the code against. */
export interface VariantPrText {
  title?: string;
  body?: string;
  commits?: string[];
}

/**
 * Reads `pr.json` beside the diff, with a short SHA-256 of its bytes that
 * becomes part of the run's identity. Undefined only when the file does not
 * exist; any other read error, or a malformed file, throws.
 */
export async function readPrText(dir: string): Promise<{ pr: VariantPrText; sha: string } | undefined> {
  let raw: string;
  try {
    raw = await readFile(path.join(dir, "pr.json"), "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw err;
  }
  const v = JSON.parse(raw) as Record<string, unknown>;
  const ok =
    typeof v === "object" && v !== null && !Array.isArray(v) &&
    Object.keys(v).every((k) => ["title", "body", "commits"].includes(k)) &&
    (v.title === undefined || (typeof v.title === "string" && v.title.length > 0)) &&
    (v.body === undefined || typeof v.body === "string") &&
    (v.commits === undefined || (Array.isArray(v.commits) && v.commits.length > 0 && v.commits.every((c) => typeof c === "string" && c.length > 0)));
  if (!ok) throw new Error("pr.json must be {title?: string, body?: string, commits?: non-empty string[]}");
  return { pr: v as VariantPrText, sha: createHash("sha256").update(raw).digest("hex").slice(0, 16) };
}

/**
 * A synthetic PR with one commit and no CI. Without `pr`, there is no
 * description and the title names the file and nothing else; `pr` supplies
 * the author's claims instead.
 */
export function syntheticFacts(name: string, files: ChangedFile[], sha: string, pr: VariantPrText = {}): PullRequestFacts {
  const subject = files.length === 1 ? `Update ${files[0]!.path}` : `Update ${files.length} files`;
  return {
    repo: { owner: "eval", repo: name },
    number: 1,
    htmlUrl: "",
    title: pr.title ?? subject,
    body: pr.body ?? "",
    draft: false,
    state: "open",
    author: { login: "contributor", type: "User" },
    headSha: sha,
    headRef: "change",
    baseRef: "main",
    baseSha: "",
    isFork: false,
    repoPrivate: true,
    commits: (pr.commits ?? [pr.title ?? subject]).map((s) => ({ sha, subject: s })),
    files,
    botReviews: [],
    reviewRequested: false,
    botThreads: [],
    checkRuns: [],
  };
}

export async function runEval(deps: EvalDeps, opts: EvalOptions): Promise<EvalSummary> {
  const { config, log } = deps;
  const arms = config.research.arms;
  if (arms.length === 0) throw new Error("eval needs research.arms in the config");
  const name = opts.name ?? path.basename(path.resolve(opts.corpus));
  const engineVersion = deps.engineVersion ?? "dev";
  for (const [flag, dir] of [["--corpus", opts.corpus], ["--tree", opts.tree]] as const) {
    if (!(await stat(dir).then((s) => s.isDirectory(), () => false))) throw new Error(`${flag} ${dir} is not a directory`);
  }

  let variants = await listCorpus(opts.corpus);
  if (opts.limit !== undefined) {
    const keep = new Set([...new Set(variants.map((v) => v.item))].slice(0, opts.limit));
    variants = variants.filter((v) => keep.has(v.item));
  }

  // Quota failures do not count as attempts, so a resumed eval retries them.
  // A run counts only toward its own series: an edited persona or contract
  // has a new fingerprint, so its cells run again instead of being skipped.
  const fingerprints = new Map(arms.map((a) => [a.name, fingerprintOrNull({ ...config.defaults, personality: a.personality }, config.budgets)]));
  const prior = new Map<string, number>();
  for (const r of opts.done ?? []) {
    if (r.status === "failed" && r.kind === "quota") continue;
    const k = seriesKey(r.itemId, r.arm, r.fingerprint, r.corpus?.claims);
    prior.set(k, (prior.get(k) ?? 0) + 1);
  }

  const summary: EvalSummary = {
    variants: variants.length,
    runs: 0,
    ok: 0,
    failed: 0,
    resumed: 0,
    skippedQuota: 0,
    exhaustedModels: [],
    unprepared: 0,
    incomplete: 0,
  };
  const exhausted = new Set<string>();

  for (const v of variants) {
    const itemId = `eval:${name}/${v.item}/${v.variant}`;
    // The claims are part of the run's identity: adding or editing pr.json is a new series.
    let claims: { pr: VariantPrText; sha: string } | undefined;
    let claimsError: unknown;
    try {
      claims = await readPrText(v.dir);
    } catch (err) {
      claimsError = err;
    }
    const claimsSha = claims?.sha ?? null;
    const todo = arms.map((arm) => {
      const have = Math.min(prior.get(seriesKey(itemId, arm.name, fingerprints.get(arm.name), claimsSha)) ?? 0, opts.repeats);
      summary.resumed += have;
      return { arm, left: opts.repeats - have };
    });
    if (todo.every((t) => t.left === 0)) continue;
    const owed = todo.reduce((n, t) => n + t.left, 0);
    const unprepared = (why: string, error?: unknown) => {
      summary.unprepared++;
      summary.incomplete += owed;
      log.error(`eval: ${itemId} ${why}; its ${owed} runs are still owed`, error === undefined ? {} : { error });
    };

    const diff = await readFile(path.join(v.dir, "diff.patch"), "utf8");
    const files = parseUnifiedDiff(diff);
    if (files.length === 0) {
      unprepared("has an empty diff");
      continue;
    }
    const overlay = await filesUnder(path.join(v.dir, "snapshot"));
    const sha = await variantSha(v, diff, overlay);
    if (claimsError !== undefined) {
      unprepared("has an unreadable or invalid pr.json", claimsError);
      continue;
    }
    const facts = syntheticFacts(name, files, sha, claims?.pr);
    let snapshot: Snapshot;
    try {
      snapshot = await snapshotFromArchive((dest) => writeVariantArchive(opts.tree, v, overlay, config.workDir, dest), sha, config.workDir, log);
    } catch (err) {
      unprepared("could not be prepared", err);
      continue;
    }
    // A sink failure (e.g. a full disk) ends the eval: runs nobody records are wasted spend.
    try {
      const guidanceFiles = deps.findGuidanceFiles ? await deps.findGuidanceFiles(snapshot) : [];
      const input = { facts, snapshot, budgets: config.budgets, ci: { state: "none" } as const, guidanceFiles };

      // Arms interleave within a repeat, so a model running dry part-way leaves balanced cells.
      for (let rep = 0; rep < opts.repeats; rep++) {
        for (const t of todo) {
          if (rep >= t.left) continue;
          const { arm } = t;
          if (exhausted.has(modelName(arm.model))) {
            summary.skippedQuota++;
            summary.incomplete++;
            continue;
          }
          let prompt: ComposedPrompt | null = null;
          let outcome: ResearchOutcome;
          try {
            prompt = deps.composePrompt({ ...input, policy: { ...config.defaults, personality: arm.personality } });
            const result = await runArm(deps.executor, { prompt, snapshot, models: [arm.model], limits: config.limits });
            const p = deps.planReview(result.form, facts, { config, model: result.model, ...(result.thinking ? { thinking: result.thinking } : {}), elapsedMs: result.elapsedMs, engineVersion });
            outcome = { status: "ok", result, event: p.payload.event, body: p.payload.body, comments: p.payload.comments, notes: p.notes };
            summary.ok++;
            log.info(`eval: ${itemId} ${arm.name} -> ${p.payload.event}`, { usage: result.usage, elapsedMs: result.elapsedMs });
          } catch (err) {
            const kind = err instanceof ExecutorError ? err.kind : "error";
            outcome = { status: "failed", kind, message: (err as Error).message, transcript: err instanceof ExecutorError ? err.transcript : [] };
            summary.failed++;
            log.warn(`eval: ${itemId} ${arm.name} failed`, { kind, error: outcome.message });
            if (kind === "quota") {
              // A quota failure does not count as an attempt; the next invocation retries it.
              summary.incomplete++;
              exhausted.add(modelName(arm.model));
              log.warn(`eval: ${modelName(arm.model)} is out of quota; its remaining runs are skipped until the next invocation`);
            }
          }
          summary.runs++;
          await deps.research.record({
            schemaVersion: 2,
            itemId,
            repo: `eval/${name}`,
            pr: 0,
            headSha: sha,
            baseSha: "",
            engineVersion,
            live: false,
            arm,
            posted: false,
            corpus: { name, item: v.item, variant: v.variant, claims: claimsSha },
            fingerprint: fingerprints.get(arm.name) ?? null,
            prompt,
            outcome,
          });
        }
      }
    } finally {
      await removeTree(snapshot.root).catch(() => {});
    }
  }
  summary.exhaustedModels = [...exhausted];
  return summary;
}
