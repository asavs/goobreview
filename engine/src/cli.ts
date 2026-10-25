#!/usr/bin/env node
// goobreview CLI: wires the real modules into reconcile/sweep/prompt.
// Exit codes: 0 ok, 1 failure, 2 usage.

import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { ConfigError, loadConfig } from "./config.js";
import { createExecutor } from "./executor.js";
import { createGitHubPort } from "./github/index.js";
import { createLogger } from "./log.js";
import { composePrompt } from "./prompt.js";
import { reconcilePull, renderPrompt, sweep, type ReconcileDeps, type ReconcileOutcome } from "./reconcile.js";
import { ciFailureReview, planReview } from "./review.js";
import { findGuidanceFiles, prepareSnapshot } from "./snapshot.js";
import type { RepoRef } from "./types.js";

const USAGE = `usage:
  goobreview reconcile --repo owner/repo --pr N [--dry-run] [--config file]
  goobreview sweep [--repo owner/repo] [--dry-run] [--max-reviews N] [--config file]
  goobreview prompt --repo owner/repo --pr N [--config file]

env: GOOBREVIEW_APP_ID, GOOBREVIEW_APP_PRIVATE_KEY or GOOBREVIEW_APP_PRIVATE_KEY_FILE,
     optional GOOBREVIEW_APP_INSTALLATION_ID, GOOBREVIEW_CONFIG, GOOBREVIEW_DRY_RUN,
     GOOBREVIEW_MODELS, GOOBREVIEW_CREDENTIALS_FILE (pi auth.json)`;

class UsageError extends Error {}

function parseRepo(s: string | undefined): RepoRef | undefined {
  if (s === undefined) return undefined;
  const m = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/.exec(s);
  if (!m) throw new UsageError(`--repo must be owner/repo, got "${s}"`);
  return { owner: m[1]!, repo: m[2]! };
}

function parsePositive(flag: string, s: string | undefined): number | undefined {
  if (s === undefined) return undefined;
  if (!/^[1-9][0-9]*$/.test(s)) throw new UsageError(`${flag} must be a positive integer, got "${s}"`);
  return Number(s);
}

function engineVersion(): string {
  try {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as { version?: string };
    return pkg.version ?? "dev";
  } catch {
    return "dev";
  }
}

function appCredentials(env: NodeJS.ProcessEnv): { appId: string; privateKey: string; installationId?: number } {
  const appId = env.GOOBREVIEW_APP_ID?.trim();
  if (!appId) throw new UsageError("GOOBREVIEW_APP_ID is not set");
  let privateKey = env.GOOBREVIEW_APP_PRIVATE_KEY;
  if (!privateKey && env.GOOBREVIEW_APP_PRIVATE_KEY_FILE) {
    try {
      privateKey = readFileSync(env.GOOBREVIEW_APP_PRIVATE_KEY_FILE, "utf8");
    } catch (err) {
      // Name the variable, never the key contents.
      throw new UsageError(`cannot read GOOBREVIEW_APP_PRIVATE_KEY_FILE (${(err as NodeJS.ErrnoException).code ?? "error"})`);
    }
  }
  if (!privateKey) throw new UsageError("set GOOBREVIEW_APP_PRIVATE_KEY or GOOBREVIEW_APP_PRIVATE_KEY_FILE");
  const inst = env.GOOBREVIEW_APP_INSTALLATION_ID?.trim();
  const installationId = inst ? parsePositive("GOOBREVIEW_APP_INSTALLATION_ID", inst) : undefined;
  return { appId, privateKey, ...(installationId !== undefined ? { installationId } : {}) };
}

export async function main(argv: string[], env: NodeJS.ProcessEnv = process.env): Promise<number> {
  const log = createLogger();
  let command: string | undefined;
  let values: Record<string, string | boolean | undefined>;
  try {
    const parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      strict: true,
      options: {
        repo: { type: "string" },
        pr: { type: "string" },
        "dry-run": { type: "boolean" },
        "max-reviews": { type: "string" },
        config: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
    });
    values = parsed.values;
    if (values.help) {
      process.stdout.write(USAGE + "\n");
      return 0;
    }
    if (parsed.positionals.length !== 1) throw new UsageError("expected exactly one command");
    command = parsed.positionals[0];
    if (!["reconcile", "sweep", "prompt"].includes(command!)) throw new UsageError(`unknown command "${command}"`);
  } catch (err) {
    process.stderr.write(`goobreview: ${(err as Error).message}\n${USAGE}\n`);
    return 2;
  }

  try {
    const repo = parseRepo(values.repo as string | undefined);
    const pr = parsePositive("--pr", values.pr as string | undefined);
    const maxReviews = parsePositive("--max-reviews", values["max-reviews"] as string | undefined);
    if (command !== "sweep" && (!repo || pr === undefined)) throw new UsageError(`${command} needs --repo and --pr`);
    if (command === "sweep" && pr !== undefined) throw new UsageError("sweep does not take --pr");
    if (command !== "sweep" && maxReviews !== undefined) throw new UsageError("--max-reviews is for sweep");
    if (command === "prompt" && values["dry-run"]) throw new UsageError("prompt never writes; --dry-run is implied");

    const config = loadConfig({ ...(values.config ? { file: values.config as string } : {}), env });
    // prompt renders only; forcing dry run keeps every path read-only.
    if (values["dry-run"] || command === "prompt") config.dryRun = true;

    const gh = createGitHubPort({ ...appCredentials(env), ...(repo ? { repo } : {}), log });

    if (command === "prompt") {
      const composed = await renderPrompt({ gh, config, log, prepareSnapshot, findGuidanceFiles, composePrompt }, repo!, pr!);
      process.stdout.write(`=== system ===\n${composed.system}\n\n=== user ===\n${composed.user}\n`);
      if (composed.omissions.length > 0) process.stdout.write(`\n=== omissions ===\n${composed.omissions.join("\n")}\n`);
      log.info("rendered prompt", { bytes: composed.bytes, omissions: composed.omissions.length });
      return 0;
    }

    const credentialsFile = env.GOOBREVIEW_CREDENTIALS_FILE;
    const deps: ReconcileDeps = {
      gh,
      config,
      log,
      executor: createExecutor({ log, ...(credentialsFile ? { credentialsFile } : {}) }),
      prepareSnapshot,
      findGuidanceFiles,
      composePrompt,
      planReview,
      ciFailureReview,
      engineVersion: engineVersion(),
    };
    const outcomes: ReconcileOutcome[] =
      command === "reconcile"
        ? [await reconcilePull(deps, repo!, pr!)]
        : await sweep(deps, { ...(repo ? { onlyRepo: repo } : {}), ...(maxReviews !== undefined ? { maxReviews } : {}) });
    for (const o of outcomes) process.stdout.write(JSON.stringify(o) + "\n");
    return outcomes.some((o) => o.action === "failed") ? 1 : 0;
  } catch (err) {
    if (err instanceof UsageError) {
      process.stderr.write(`goobreview: ${err.message}\n${USAGE}\n`);
      return 2;
    }
    if (err instanceof ConfigError) {
      process.stderr.write(`goobreview: ${err.message}\n`);
      return 2;
    }
    log.error(`${command} failed`, { error: err });
    return 1;
  }
}

// Run only when executed directly (npm bin shims are symlinks), so tests can import main().
function isEntry(): boolean {
  try {
    return !!process.argv[1] && pathToFileURL(realpathSync(process.argv[1])).href === import.meta.url;
  } catch {
    return false;
  }
}
if (isEntry()) main(process.argv.slice(2)).then((code) => process.exit(code));
