// Offline eval: run the research arms over a known-answer corpus with no
// GitHub. Each corpus variant becomes a synthetic PR on a copy of the seed
// tree with the variant overlaid, hardened exactly like a PR-head snapshot.
// Labels are never read here; scoring joins records to labels by corpus path.
//
// Corpus layout (angry-llm-research scripts/generate-mutants.sh):
//   <corpus>/<item>/<variant>/diff.patch
//   <corpus>/<item>/<variant>/snapshot/<relpath>   files that replace the seed's
//   <corpus>/<item>/<variant>/label.json           ground truth (not read)

import { createHash, randomBytes } from "node:crypto";
import { cp, mkdir, readdir, readFile, rm } from "node:fs/promises";
import path from "node:path";
import * as tar from "tar";
import { modelName } from "./config.js";
import type { ComposePromptFn, FindGuidanceFilesFn, PlanReviewFn } from "./reconcile.js";
import { removeTree } from "./reconcile.js";
import { snapshotFromArchive } from "./snapshot.js";
import {
  ExecutorError,
  type ChangedFile,
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
  done?: { itemId: string; arm: string; status: string; kind?: string }[];
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

/** A plain PR: no description, one commit, no CI. The title names the file and nothing else. */
export function syntheticFacts(name: string, files: ChangedFile[], sha: string): PullRequestFacts {
  const subject = files.length === 1 ? `Update ${files[0]!.path}` : `Update ${files.length} files`;
  return {
    repo: { owner: "eval", repo: name },
    number: 1,
    htmlUrl: "",
    title: subject,
    body: "",
    draft: false,
    state: "open",
    author: { login: "contributor", type: "User" },
    headSha: sha,
    headRef: "change",
    baseRef: "main",
    baseSha: "",
    isFork: false,
    repoPrivate: true,
    commits: [{ sha, subject }],
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

  let variants = await listCorpus(opts.corpus);
  if (opts.limit !== undefined) {
    const keep = new Set([...new Set(variants.map((v) => v.item))].slice(0, opts.limit));
    variants = variants.filter((v) => keep.has(v.item));
  }

  // Quota failures do not count as attempts, so a resumed eval retries them.
  const prior = new Map<string, number>();
  for (const r of opts.done ?? []) {
    if (r.status === "failed" && r.kind === "quota") continue;
    const k = `${r.itemId}\0${r.arm}`;
    prior.set(k, (prior.get(k) ?? 0) + 1);
  }

  const summary: EvalSummary = { variants: variants.length, runs: 0, ok: 0, failed: 0, resumed: 0, skippedQuota: 0, exhaustedModels: [] };
  const exhausted = new Set<string>();

  for (const v of variants) {
    const itemId = `eval:${name}/${v.item}/${v.variant}`;
    const todo = arms.map((arm) => {
      const have = Math.min(prior.get(`${itemId}\0${arm.name}`) ?? 0, opts.repeats);
      summary.resumed += have;
      return { arm, left: opts.repeats - have };
    });
    if (todo.every((t) => t.left === 0)) continue;

    const diff = await readFile(path.join(v.dir, "diff.patch"), "utf8");
    const files = parseUnifiedDiff(diff);
    if (files.length === 0) {
      log.warn(`eval: ${itemId} has an empty diff; skipped`);
      continue;
    }
    const overlay = await filesUnder(path.join(v.dir, "snapshot"));
    const sha = await variantSha(v, diff, overlay);
    const facts = syntheticFacts(name, files, sha);
    let snapshot: Snapshot;
    try {
      snapshot = await snapshotFromArchive((dest) => writeVariantArchive(opts.tree, v, overlay, config.workDir, dest), sha, config.workDir, log);
    } catch (err) {
      log.error(`eval: ${itemId} could not be prepared; skipped`, { error: err });
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
            continue;
          }
          const prompt = deps.composePrompt({ ...input, policy: { ...config.defaults, personality: arm.personality } });
          let outcome: ResearchOutcome;
          try {
            const result = await deps.executor.run({ prompt, snapshot, models: [arm.model], limits: config.limits });
            const p = deps.planReview(result.form, facts, { config, model: result.model, elapsedMs: result.elapsedMs, engineVersion });
            outcome = { status: "ok", result, event: p.payload.event, body: p.payload.body, comments: p.payload.comments, notes: p.notes };
            summary.ok++;
            log.info(`eval: ${itemId} ${arm.name} -> ${p.payload.event}`, { usage: result.usage, elapsedMs: result.elapsedMs });
          } catch (err) {
            const kind = err instanceof ExecutorError ? err.kind : "error";
            outcome = { status: "failed", kind, message: (err as Error).message, transcript: err instanceof ExecutorError ? err.transcript : [] };
            summary.failed++;
            log.warn(`eval: ${itemId} ${arm.name} failed`, { kind, error: outcome.message });
            if (kind === "quota") {
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
            corpus: { name, item: v.item, variant: v.variant },
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
