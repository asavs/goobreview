// Model credentials: a pi-format auth.json ({ "<providerId>": Credential })
// behind pi-ai's CredentialStore, plus the Models collection the executor
// uses. OAuth refresh runs inside `modify`, so writes must be durable and
// atomic or a rotated refresh token is lost and the next run cannot log in.

import { randomBytes } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import type { Credential, CredentialInfo, CredentialStore, Models } from "@earendil-works/pi-ai";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";

type AuthFile = Record<string, Credential>;

const LOCK_STALE_MS = 30_000;
const LOCK_WAIT_MS = 10_000;

export function createFileCredentialStore(file: string): CredentialStore {
  const lockFile = `${file}.lock`;
  // In-process serialization; the lock file covers other processes.
  let chain: Promise<unknown> = Promise.resolve();

  const serialized = <T>(task: () => Promise<T>, signal?: AbortSignal): Promise<T> => {
    const run = chain.catch(() => {}).then(async () => {
      signal?.throwIfAborted();
      return withLock(lockFile, task, signal);
    });
    chain = run.catch(() => {});
    return run;
  };

  return {
    async read(providerId, options) {
      options?.signal?.throwIfAborted();
      return (await load(file))[providerId];
    },
    async list(options): Promise<readonly CredentialInfo[]> {
      options?.signal?.throwIfAborted();
      return Object.entries(await load(file)).map(([providerId, c]) => ({ providerId, type: c.type }));
    },
    modify(providerId, fn, options) {
      return serialized(async () => {
        const all = await load(file);
        const current = all[providerId];
        const next = await fn(current);
        options?.signal?.throwIfAborted();
        if (next === undefined) return current;
        all[providerId] = next;
        await save(file, all);
        return next;
      }, options?.signal);
    },
    delete(providerId, options) {
      return serialized(async () => {
        const all = await load(file);
        if (!(providerId in all)) return;
        delete all[providerId];
        await save(file, all);
      }, options?.signal);
    },
  };
}

/**
 * Every built-in pi-ai provider. The catalogs are small static tables and
 * each provider SDK is imported lazily on its first request, so registering
 * all of them costs little and lets config name any built-in provider.
 * Nothing here touches the network: dynamic catalogs (e.g. radius) only fetch
 * on an explicit `refresh()`, which the engine never calls.
 */
export function createModelsCollection(opts: { credentialsFile?: string }): Models {
  return builtinModels(opts.credentialsFile ? { credentials: createFileCredentialStore(opts.credentialsFile) } : {});
}

// ---------------------------------------------------------------------------

async function load(file: string): Promise<AuthFile> {
  let text: string;
  try {
    text = await fs.readFile(file, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw err;
  }
  if (text.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    // Never echo the contents: they are secrets.
    throw new Error(`credentials file ${file} is not valid JSON`);
  }
  if (!isRecord(parsed)) throw new Error(`credentials file ${file} must hold a JSON object`);
  const out: AuthFile = {};
  for (const [id, value] of Object.entries(parsed)) {
    if (isRecord(value) && (value.type === "api_key" || value.type === "oauth")) out[id] = value as unknown as Credential;
  }
  return out;
}

/** Write a temp file beside the target (same filesystem), then rename over it. */
async function save(file: string, data: AuthFile): Promise<void> {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  const handle = await fs.open(tmp, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(data, null, 2)}\n`, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await fs.chmod(tmp, 0o600); // umask can widen the create mode on some systems
    await fs.rename(tmp, file);
  } catch (err) {
    await fs.rm(tmp, { force: true });
    throw err;
  }
}

async function withLock<T>(lockFile: string, task: () => Promise<T>, signal?: AbortSignal): Promise<T> {
  const deadline = Date.now() + LOCK_WAIT_MS;
  await fs.mkdir(path.dirname(lockFile), { recursive: true, mode: 0o700 });
  for (;;) {
    signal?.throwIfAborted();
    try {
      const h = await fs.open(lockFile, "wx", 0o600);
      await h.close();
      break;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      const stat = await fs.stat(lockFile).catch(() => undefined);
      // A crashed holder leaves its lock behind; take it over once stale.
      if (stat && Date.now() - stat.mtimeMs > LOCK_STALE_MS) {
        await fs.rm(lockFile, { force: true });
        continue;
      }
      if (Date.now() > deadline) throw new Error(`timed out waiting for credentials lock ${lockFile}`);
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  try {
    return await task();
  } finally {
    await fs.rm(lockFile, { force: true });
  }
}

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
