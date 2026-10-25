#!/usr/bin/env node
// goobreview CLI: wires the real modules into reconcile/sweep/prompt/auth.
// Exit codes: 0 ok, 1 failure, 2 usage.

import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { AuthCommandError, authLogin, authLogout, authProviders, authStatus, terminalIO, type AuthIO } from "./auth.js";
import { ConfigError, loadConfig } from "./config.js";
import { createModelsCollection, credentialsPath, installationId } from "./credentials.js";
import { createExecutor } from "./executor.js";
import { createGitHubPort } from "./github/index.js";
import { createLogger } from "./log.js";
import { PersonaError, resolvePersona } from "./persona.js";
import { composePrompt, userMessage } from "./prompt.js";
import { reconcilePull, renderPrompt, sweep, type ReconcileDeps, type ReconcileOutcome } from "./reconcile.js";
import { runEval } from "./eval.js";
import { createFileResearchSink, readIndex } from "./research.js";
import { ciFailureReview, planReview } from "./review.js";
import { findGuidanceFiles, prepareSnapshot } from "./snapshot.js";
import type { RepoRef } from "./types.js";

const USAGE = `usage:
  goobreview reconcile --repo owner/repo --pr N [--dry-run] [--config file]
  goobreview sweep [--repo owner/repo] [--dry-run] [--max-reviews N] [--config file]
  goobreview prompt --repo owner/repo --pr N [--persona spec] [--config file]
                                              print the exact conversation, e.g. --persona angry:v1-sigh
  goobreview eval --corpus dir --tree dir [--repeats N] [--limit N] [--name s] [--config file]
                                              run research.arms over a known-answer corpus; resumes
  goobreview auth status [--config file]      which models in the chain can sign in
  goobreview auth login <provider> [--api-key | --oauth]
  goobreview auth logout <provider>
  goobreview auth providers

env: GOOBREVIEW_APP_ID, GOOBREVIEW_APP_PRIVATE_KEY or GOOBREVIEW_APP_PRIVATE_KEY_FILE,
     optional GOOBREVIEW_APP_INSTALLATION_ID, GOOBREVIEW_CONFIG, GOOBREVIEW_DRY_RUN,
     GOOBREVIEW_MODELS, GOOBREVIEW_CREDENTIALS_FILE (pi auth.json; default
     ~/.config/goobreview/auth.json)`;

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

async function runEvalCommand(
  values: Record<string, string | boolean | undefined>,
  env: NodeJS.ProcessEnv,
  log: ReturnType<typeof createLogger>,
): Promise<number> {
  try {
    const corpus = values.corpus as string | undefined;
    const tree = values.tree as string | undefined;
    if (!corpus || !tree) throw new UsageError("eval needs --corpus and --tree");
    const repeats = parsePositive("--repeats", values.repeats as string | undefined) ?? 1;
    const limit = parsePositive("--limit", values.limit as string | undefined);
    const config = loadConfig({ ...(values.config ? { file: values.config as string } : {}), env });
    if (config.research.arms.length === 0) throw new UsageError("eval needs research.arms in the config");
    const summary = await runEval(
      {
        config,
        log,
        executor: createExecutor({ log, credentialsFile: credentialsPath(env) }),
        composePrompt,
        planReview,
        findGuidanceFiles,
        engineVersion: engineVersion(),
        research: createFileResearchSink({ dir: config.research.dir, installationId: await installationId(credentialsPath(env)) }),
      },
      {
        corpus,
        tree,
        repeats,
        ...(limit !== undefined ? { limit } : {}),
        ...(values.name ? { name: values.name as string } : {}),
        done: await readIndex(config.research.dir),
      },
    );
    process.stdout.write(JSON.stringify(summary) + "\n");
    // Runs still owed (quota, unprepared variants): exit 1; a rerun resumes.
    return summary.incomplete > 0 ? 1 : 0;
  } catch (err) {
    if (err instanceof UsageError || err instanceof ConfigError) {
      process.stderr.write(`goobreview: ${err.message}\n`);
      return 2;
    }
    log.error("eval failed", { error: err });
    return 1;
  }
}

export async function main(argv: string[], env: NodeJS.ProcessEnv = process.env, io: AuthIO = terminalIO()): Promise<number> {
  const log = createLogger();
  let command: string | undefined;
  let positionals: string[];
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
        "api-key": { type: "boolean" },
        oauth: { type: "boolean" },
        corpus: { type: "string" },
        tree: { type: "string" },
        name: { type: "string" },
        repeats: { type: "string" },
        limit: { type: "string" },
        persona: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
    });
    values = parsed.values;
    if (values.help) {
      process.stdout.write(USAGE + "\n");
      return 0;
    }
    positionals = parsed.positionals;
    command = positionals[0];
    if (!command) throw new UsageError("expected a command");
    if (!["reconcile", "sweep", "prompt", "auth", "eval"].includes(command)) throw new UsageError(`unknown command "${command}"`);
    if (command !== "auth" && positionals.length !== 1) throw new UsageError(`unexpected argument "${positionals[1]}"`);
    if (command !== "auth" && (values["api-key"] || values.oauth)) throw new UsageError("--api-key and --oauth are for auth login");
    const evalFlags = ["corpus", "tree", "name", "repeats", "limit"].filter((f) => values[f] !== undefined);
    if (command !== "eval" && evalFlags.length > 0) throw new UsageError(`--${evalFlags[0]} is for eval`);
    if (command !== "prompt" && values.persona !== undefined) throw new UsageError("--persona is for prompt; arms come from config");
    if (command === "eval" && (values.repo || values.pr || values["dry-run"] || values["max-reviews"])) {
      throw new UsageError("eval takes no --repo, --pr, --dry-run or --max-reviews; it never touches GitHub");
    }
  } catch (err) {
    process.stderr.write(`goobreview: ${(err as Error).message}\n${USAGE}\n`);
    return 2;
  }

  if (command === "auth") return runAuth(positionals.slice(1), values, env, io);
  if (command === "eval") return runEvalCommand(values, env, log);

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
      let persona: string | undefined;
      try {
        persona = values.persona === undefined ? undefined : resolvePersona(values.persona as string).spec;
      } catch (err) {
        if (err instanceof PersonaError) throw new UsageError(err.message);
        throw err;
      }
      const composed = await renderPrompt({ gh, config, log, prepareSnapshot, findGuidanceFiles, composePrompt }, repo!, pr!, persona);
      const pieces = composed.persona.pieces.map((p) => `${p.id} (${p.slot})`).join(", ") || "(no pieces)";
      process.stdout.write(`=== persona ===\n${composed.persona.spec}: ${pieces}\n\n=== system ===\n${composed.system}\n\n=== user ===\n${userMessage(composed)}\n`);
      if (composed.omissions.length > 0) process.stdout.write(`\n=== omissions ===\n${composed.omissions.join("\n")}\n`);
      log.info("rendered prompt", { bytes: composed.bytes, omissions: composed.omissions.length });
      return 0;
    }

    const deps: ReconcileDeps = {
      gh,
      config,
      log,
      executor: createExecutor({ log, credentialsFile: credentialsPath(env) }),
      prepareSnapshot,
      findGuidanceFiles,
      composePrompt,
      planReview,
      ciFailureReview,
      engineVersion: engineVersion(),
      ...(config.research.consent
        ? { research: createFileResearchSink({ dir: config.research.dir, installationId: await installationId(credentialsPath(env)) }) }
        : {}),
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

async function runAuth(args: string[], values: Record<string, string | boolean | undefined>, env: NodeJS.ProcessEnv, io: AuthIO): Promise<number> {
  const [sub, provider, extra] = args;
  try {
    if (extra !== undefined) throw new UsageError(`unexpected argument "${extra}"`);
    if (values.repo || values.pr || values["dry-run"] || values["max-reviews"]) throw new UsageError("auth takes no --repo, --pr, --dry-run or --max-reviews");
    if (sub !== "login" && (values["api-key"] || values.oauth)) throw new UsageError("--api-key and --oauth are for auth login");
    if (values["api-key"] && values.oauth) throw new UsageError("choose one of --api-key and --oauth");
    const needsProvider = sub === "login" || sub === "logout";
    if (needsProvider && !provider) throw new UsageError(`auth ${sub} needs a provider, e.g. openai`);
    if (!needsProvider && provider) throw new UsageError(`unexpected argument "${provider}"`);

    const credentialsFile = credentialsPath(env);
    const models = createModelsCollection({ credentialsFile });
    switch (sub) {
      case "status": {
        const config = loadConfig({ ...(values.config ? { file: values.config as string } : {}), env });
        await authStatus(models, config.models, credentialsFile, io);
        return 0;
      }
      case "login": {
        const type = values["api-key"] ? "api_key" : values.oauth ? "oauth" : undefined;
        await authLogin(models, provider!, type, io, { agentName: "goobreview", getDeviceId: constant(await installationId(credentialsFile)) });
        return 0;
      }
      case "logout":
        await authLogout(models, provider!, io);
        return 0;
      case "providers":
        authProviders(models, io);
        return 0;
      default:
        throw new UsageError(sub ? `unknown auth command "${sub}"` : "auth needs a command: status, login, logout or providers");
    }
  } catch (err) {
    if (err instanceof UsageError) {
      process.stderr.write(`goobreview: ${err.message}
${USAGE}
`);
      return 2;
    }
    if (err instanceof AuthCommandError || err instanceof ConfigError) {
      process.stderr.write(`goobreview: ${err.message}
`);
      return err instanceof ConfigError ? 2 : 1;
    }
    // Provider errors can quote request details; log the message through the redacting logger.
    createLogger().error(`auth ${sub} failed`, { error: err });
    return 1;
  }
}

const constant = (v: string) => () => v;

// Run only when executed directly (npm bin shims are symlinks), so tests can import main().
function isEntry(): boolean {
  try {
    return !!process.argv[1] && pathToFileURL(realpathSync(process.argv[1])).href === import.meta.url;
  } catch {
    return false;
  }
}
if (isEntry()) main(process.argv.slice(2)).then((code) => process.exit(code));
