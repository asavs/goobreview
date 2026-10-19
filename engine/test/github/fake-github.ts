// A fake fetch that serves recorded-shape GitHub responses so tests never hit
// the network. Routes match on method + pathname; handlers see the parsed URL
// and JSON body.

import { generateKeyPairSync } from "node:crypto";
import { createGitHubPort } from "../../src/github/index.js";
import type { GitHubPort, Logger } from "../../src/types.js";

export const BASE = "https://api.github.com";

export interface FakeRequest {
  method: string;
  url: URL;
  body: unknown;
  headers: Record<string, string>;
}

export interface FakeResponse {
  status?: number;
  body?: unknown;
  headers?: Record<string, string>;
}

type Handler = (req: FakeRequest) => FakeResponse | Promise<FakeResponse>;

export interface FakeGitHub {
  fetch: typeof fetch;
  calls: FakeRequest[];
  on(method: string, path: string | RegExp, handler: Handler | FakeResponse): FakeGitHub;
}

let cachedKey: string | undefined;
export function testPrivateKey(): string {
  cachedKey ??= generateKeyPairSync("rsa", {
    modulusLength: 2048,
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  }).privateKey;
  return cachedKey;
}

export function fakeGitHub(): FakeGitHub {
  const routes: { method: string; path: string | RegExp; handler: Handler }[] = [];
  const calls: FakeRequest[] = [];
  const fake: FakeGitHub = {
    calls,
    on(method, path, handler) {
      routes.unshift({ method, path, handler: typeof handler === "function" ? handler : () => handler });
      return fake;
    },
    fetch: (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
      const method = (init?.method ?? "GET").toUpperCase();
      const headers: Record<string, string> = {};
      for (const [k, v] of Object.entries((init?.headers ?? {}) as Record<string, string>)) headers[k.toLowerCase()] = v;
      const body = typeof init?.body === "string" && init.body ? JSON.parse(init.body) : undefined;
      const req = { method, url, body, headers };
      calls.push(req);
      const route = routes.find(
        (r) => r.method === method && (typeof r.path === "string" ? r.path === url.pathname : r.path.test(url.pathname)),
      );
      const res = route ? await route.handler(req) : { status: 404, body: { message: `no fake for ${method} ${url.pathname}` } };
      const status = res.status ?? 200;
      const response = new Response(status === 204 ? null : JSON.stringify(res.body ?? {}), {
        status,
        headers: { "content-type": "application/json; charset=utf-8", ...res.headers },
      });
      // A constructed Response has an empty url; real fetch sets it and the paginator reads it.
      Object.defineProperty(response, "url", { value: url.href });
      return response;
    }) as typeof fetch,
  };
  // App identity and token minting, shared by every test.
  fake
    .on("GET", "/app", { body: { id: 1, slug: "goob" } })
    .on("GET", /^\/repos\/[^/]+\/[^/]+\/installation$/, { body: { id: 77 } })
    .on("POST", /^\/app\/installations\/\d+\/access_tokens$/, {
      status: 201,
      body: {
        token: "ghs_faketoken000000000000000000000000",
        expires_at: new Date(Date.now() + 3600_000).toISOString(),
        permissions: { pull_requests: "write", checks: "write" },
        repository_selection: "all",
      },
    });
  return fake;
}

/** Serves `pages` with Link headers so Octokit's paginator walks them. */
export function paged(pages: unknown[], wrap?: (items: unknown, total: number) => unknown): Handler {
  const total = pages.reduce<number>((n, p) => n + (Array.isArray(p) ? p.length : 0), 0);
  return (req) => {
    const page = Number(req.url.searchParams.get("page") ?? "1");
    const items = pages[page - 1] ?? [];
    const headers: Record<string, string> = {};
    if (page < pages.length) {
      const next = new URL(req.url);
      next.searchParams.set("page", String(page + 1));
      headers.link = `<${next.href}>; rel="next"`;
    }
    return { body: wrap ? wrap(items, total) : items, headers };
  };
}

export interface CapturedLog extends Logger {
  lines: { level: string; msg: string; fields?: Record<string, unknown> }[];
}

export function captureLog(): CapturedLog {
  const lines: CapturedLog["lines"] = [];
  const at = (level: string) => (msg: string, fields?: Record<string, unknown>) => void lines.push({ level, msg, ...(fields ? { fields } : {}) });
  return { lines, info: at("info"), warn: at("warn"), error: at("error") };
}

export function portFor(fake: FakeGitHub, log?: Logger): GitHubPort {
  return createGitHubPort({
    appId: "1",
    privateKey: testPrivateKey(),
    fetch: fake.fetch,
    retry: { retries: 2, baseMs: 0, maxMs: 0 },
    ...(log ? { log } : {}),
  });
}
