// Octokit with GitHub App auth only: an App (JWT) client for /app endpoints and
// per-installation clients whose tokens are minted from the App key. No user
// tokens and no ambient GH_TOKEN/GITHUB_TOKEN are ever read (v1 #14).

import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "@octokit/core";
import { paginateRest } from "@octokit/plugin-paginate-rest";
import { restEndpointMethods } from "@octokit/plugin-rest-endpoint-methods";
import type { Logger } from "../types.js";

export const AppOctokit = Octokit.plugin(paginateRest, restEndpointMethods);
export type AppOctokitClient = InstanceType<typeof AppOctokit>;

export interface RetryOptions {
  /** Extra attempts for an idempotent GET. */
  retries: number;
  baseMs: number;
  maxMs: number;
}

export const DEFAULT_RETRY: RetryOptions = { retries: 2, baseMs: 1000, maxMs: 10_000 };

export interface ClientOptions {
  appId: string;
  privateKey: string;
  /** Omit for the App (JWT) client. */
  installationId?: number;
  fetch?: typeof fetch;
  log?: Logger;
  retry?: RetryOptions;
  baseUrl?: string;
}

export class GitHubApiError extends Error {
  constructor(
    readonly status: number,
    readonly method: string,
    readonly route: string,
    message: string,
  ) {
    super(message);
    this.name = "GitHubApiError";
  }
}

// Token shapes that must never reach a message: installation/user tokens and JWTs.
const TOKENISH = /\b(?:gh[opsur]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{20,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+)/g;
export const scrubTokens = (s: string): string => s.replace(TOKENISH, "[REDACTED]");

const statusOf = (err: unknown): number => {
  const s = (err as { status?: unknown })?.status;
  return typeof s === "number" ? s : 0;
};

function headerOf(err: unknown, name: string): string | undefined {
  const h = (err as { response?: { headers?: Record<string, unknown> } })?.response?.headers?.[name];
  return typeof h === "string" || typeof h === "number" ? String(h) : undefined;
}

function isSecondaryRateLimit(err: unknown): boolean {
  const status = statusOf(err);
  if (status !== 403 && status !== 429) return false;
  if (status === 429 || headerOf(err, "retry-after") !== undefined) return true;
  return /secondary rate limit|abuse detection/i.test(String((err as Error)?.message ?? ""));
}

/** Octokit reports fetch/network failures as status 500, so those retry too. */
const retryable = (err: unknown): boolean => statusOf(err) >= 500 || isSecondaryRateLimit(err);

function retryDelay(err: unknown, attempt: number, opts: RetryOptions): number {
  const after = Number(headerOf(err, "retry-after"));
  const ms = Number.isFinite(after) && after > 0 ? after * 1000 : opts.baseMs * 2 ** attempt;
  return Math.min(ms, opts.maxMs);
}

function toApiError(err: unknown, method: string, route: string): GitHubApiError {
  if (err instanceof GitHubApiError) return err;
  const status = statusOf(err);
  const detail = scrubTokens(String((err as Error)?.message ?? err)).slice(0, 500);
  const e = new GitHubApiError(status, method, route, `GitHub ${method} ${route} failed (${status || "network"}): ${detail}`);
  // Keep the response headers the auth layer and callers inspect, never the request.
  const headers = (err as { response?: { headers?: unknown } })?.response?.headers;
  if (headers) Object.defineProperty(e, "response", { value: { headers }, enumerable: false });
  return e;
}

/**
 * One Octokit client. GETs retry with bounded backoff on 5xx/secondary rate
 * limits; non-GET requests are never retried blindly. Errors are rethrown as
 * GitHubApiError carrying the route template (no ids, no tokens).
 */
export function createAppClient(opts: ClientOptions): AppOctokitClient {
  const retry = opts.retry ?? DEFAULT_RETRY;
  const auth: Record<string, unknown> = { appId: opts.appId, privateKey: opts.privateKey };
  if (opts.installationId !== undefined) auth.installationId = opts.installationId;
  const octokit = new AppOctokit({
    authStrategy: createAppAuth,
    auth,
    userAgent: "goobreview-engine",
    ...(opts.baseUrl ? { baseUrl: opts.baseUrl } : {}),
    request: opts.fetch ? { fetch: opts.fetch } : {},
    // Octokit's default logger writes to the console; route warnings to ours.
    log: {
      debug: () => {},
      info: () => {},
      warn: (msg: string) => opts.log?.warn(scrubTokens(msg)),
      error: (msg: string) => opts.log?.error(scrubTokens(msg)),
    },
  });
  // Registered after the auth hook, so it wraps it: retries re-run auth too.
  octokit.hook.wrap("request", async (request, options) => {
    const method = String(options.method ?? "GET").toUpperCase();
    const route = String(options.url ?? "");
    for (let attempt = 0; ; attempt++) {
      try {
        return await request(options);
      } catch (err) {
        if (method === "GET" && attempt < retry.retries && retryable(err)) {
          const ms = retryDelay(err, attempt, retry);
          opts.log?.warn("github request retry", { method, route, status: statusOf(err), attempt: attempt + 1, delayMs: ms });
          if (ms > 0) await new Promise((r) => setTimeout(r, ms));
          continue;
        }
        throw toApiError(err, method, route);
      }
    }
  });
  return octokit;
}
