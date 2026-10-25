import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { encodeStateMarker } from "../../src/github/index.js";
import type { RepoRef } from "../../src/types.js";
import { captureLog, fakeGitHub, paged, portFor, type FakeGitHub } from "./fake-github.js";

const repo: RepoRef = { owner: "acme", repo: "widgets" };
const P = "/repos/acme/widgets";
const HEAD = "a".repeat(40);

const repoObj = (id: number, priv?: boolean) => ({ id, full_name: id === 1 ? "acme/widgets" : "fork/widgets", ...(priv === undefined ? {} : { private: priv }) });

function pullFixture(over: Record<string, unknown> = {}) {
  return {
    number: 5,
    html_url: "https://github.com/acme/widgets/pull/5",
    title: "Add thing",
    body: null,
    draft: false,
    state: "open",
    user: { login: "alice", type: "User" },
    head: { sha: HEAD, ref: "feat", repo: repoObj(1, false) },
    base: { sha: "b".repeat(40), ref: "main", repo: repoObj(1, false) },
    requested_reviewers: [],
    ...over,
  };
}

const run = (id: number, name: string, slug: string, extra: Record<string, unknown> = {}) => ({
  id,
  name,
  status: "completed",
  conclusion: "success",
  app: { slug },
  output: { title: null, summary: null, text: null },
  ...extra,
});

function withPull(fake: FakeGitHub, opts: { pull?: Record<string, unknown>; files?: unknown[][]; reviews?: unknown[]; timeline?: unknown[]; threads?: unknown[]; runs?: unknown[] } = {}) {
  return fake
    .on("GET", `${P}/pulls/5`, { body: pullFixture(opts.pull) })
    .on("GET", `${P}/pulls/5/commits`, paged([[{ sha: "c1", commit: { message: "First line\n\nbody" } }]]))
    .on("GET", `${P}/pulls/5/files`, paged(opts.files ?? [[]]))
    .on("GET", `${P}/pulls/5/reviews`, paged([opts.reviews ?? []]))
    .on("GET", `${P}/issues/5/timeline`, paged([opts.timeline ?? []]))
    .on("GET", `${P}/commits/${HEAD}/check-runs`, paged([opts.runs ?? []], (items, total) => ({ total_count: total, check_runs: items })))
    .on("POST", "/graphql", {
      body: { data: { repository: { pullRequest: { reviewThreads: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: opts.threads ?? [] } } } } },
    });
}

describe("GitHub port", () => {
  it("derives the bot login from GET /app and authenticates with App credentials only", async () => {
    const fake = fakeGitHub();
    const port = portFor(fake);
    expect(await port.botLogin()).toBe("goob[bot]");
    const appCall = fake.calls.find((c) => c.url.pathname === "/app")!;
    expect(appCall.headers.authorization).toMatch(/^bearer eyJ/i);
  });

  it("assembles pull facts across paginated files, keeping a missing patch undefined", async () => {
    const fake = withPull(fakeGitHub(), {
      pull: { head: { sha: HEAD, ref: "feat", repo: repoObj(2) }, base: { sha: "b".repeat(40), ref: "main", repo: { id: 1, full_name: "acme/widgets" } } },
      files: [
        Array.from({ length: 100 }, (_, i) => ({ filename: `f${i}.ts`, status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+x" })),
        [{ filename: "img.png", status: "renamed", previous_filename: "old.png", additions: 0, deletions: 0 }],
      ],
      reviews: [
        { id: 10, user: { login: "goob[bot]" }, commit_id: "old", state: "COMMENTED", body: "r1", submitted_at: "2026-05-01T00:00:00Z" },
        { id: 11, user: { login: "bob" }, commit_id: HEAD, state: "APPROVED", body: "", submitted_at: "2026-05-02T00:00:00Z" },
        { id: 12, user: { login: "app/goob" }, commit_id: "old2", state: "COMMENTED", body: "r2", submitted_at: "2026-05-03T00:00:00Z" },
      ],
      timeline: [{ event: "review_requested", created_at: "2026-05-04T00:00:00Z", requested_reviewer: { login: "goob[bot]" } }],
      threads: [
        {
          id: "PRRT_1",
          isResolved: false,
          viewerCanResolve: true,
          path: "src/x.ts",
          line: 7,
          originalLine: 7,
          comments: { nodes: [{ databaseId: 900, body: "### Off by one\nfix it", path: "src/x.ts", author: { __typename: "Bot", login: "goob" } }] },
        },
      ],
      runs: [run(1, "build", "github-actions"), run(2, "goobreview", "goob"), run(3, "goobreview", "impostor")],
    });
    const facts = await portFor(fake).getPullFacts(repo, 5);

    expect(facts.files).toHaveLength(101);
    expect(facts.files[100]).toEqual({ path: "img.png", previousPath: "old.png", status: "renamed", additions: 0, deletions: 0 });
    expect("patch" in facts.files[100]!).toBe(false);
    expect(facts.files[0]!.patch).toBe("@@ -1 +1 @@\n+x");
    expect(fake.calls.filter((c) => c.url.pathname.endsWith("/files")).map((c) => c.url.searchParams.get("page"))).toEqual([null, "2"]);

    expect(facts.botReviews.map((r) => r.id)).toEqual([10, 12]);
    expect(facts.reviewRequested).toBe(true);
    expect(facts.commits).toEqual([{ sha: "c1", subject: "First line" }]);
    expect(facts.body).toBe("");
    expect(facts.isFork).toBe(true);
    expect(facts.repoPrivate).toBe(true); // base repo visibility absent -> private
    expect(facts.checkRuns.map((r) => [r.name, r.appSlug])).toEqual([
      ["build", "github-actions"],
      ["goobreview", "impostor"],
    ]);
    expect(facts.botThreads).toEqual([
      { id: "PRRT_1", handle: "off-by-one", path: "src/x.ts", line: 7, isResolved: false, firstCommentId: 900, firstCommentBody: "### Off by one\nfix it", viewerCanResolve: true },
    ]);
    // Installation tokens, never the JWT, on repo endpoints.
    expect(fake.calls.find((c) => c.url.pathname === `${P}/pulls/5`)!.headers.authorization).toBe("token ghs_faketoken000000000000000000000000");
  });

  it("reports a same-repo public PR and no re-request when the bot already reviewed after the request", async () => {
    const fake = withPull(fakeGitHub(), {
      reviews: [{ id: 10, user: { login: "goob[bot]" }, commit_id: HEAD, state: "COMMENTED", body: "", submitted_at: "2026-05-05T00:00:00Z" }],
      timeline: [{ event: "review_requested", created_at: "2026-05-04T00:00:00Z", requested_reviewer: { login: "goob[bot]" } }],
    });
    const facts = await portFor(fake).getPullFacts(repo, 5);
    expect(facts.isFork).toBe(false);
    expect(facts.repoPrivate).toBe(false);
    expect(facts.reviewRequested).toBe(false);
  });

  it("retries an idempotent GET on 5xx but never a POST", async () => {
    let n = 0;
    const fake = fakeGitHub()
      .on("GET", `${P}/pulls/5`, () => (++n < 3 ? { status: 502, body: { message: "bad gateway" } } : { body: pullFixture() }))
      .on("POST", `${P}/issues/5/reactions`, { status: 500, body: { message: "boom" } });
    const port = portFor(fake);
    expect(await port.getHeadSha(repo, 5)).toBe(HEAD);
    expect(n).toBe(3);
    await expect(port.addReaction(repo, 5, "eyes")).rejects.toThrow(/500/);
    expect(fake.calls.filter((c) => c.url.pathname.endsWith("/reactions"))).toHaveLength(1);
  });

  it("keeps tokens out of error messages", async () => {
    const fake = fakeGitHub().on("GET", `${P}/pulls/5`, { status: 404, body: { message: "Not Found ghs_leakedtoken1234567890abcdef" } });
    const err = await portFor(fake).getHeadSha(repo, 5).catch((e: Error) => e);
    expect(String(err)).not.toMatch(/ghs_/);
    expect(JSON.stringify(err)).not.toMatch(/ghs_/);
  });

  it("ignores 403/422 on reactions", async () => {
    const log = captureLog();
    const fake = fakeGitHub().on("POST", `${P}/issues/5/reactions`, { status: 422, body: { message: "Validation Failed" } });
    await expect(portFor(fake, log).addReaction(repo, 5, "confused")).resolves.toBeUndefined();
    expect(fake.calls.at(-1)!.body).toEqual({ content: "confused" });
    expect(log.lines.some((l) => l.level === "warn")).toBe(true);
  });

  describe("engine check run", () => {
    const runsRoute = (fake: FakeGitHub, runs: unknown[]) =>
      fake.on("GET", `${P}/commits/${HEAD}/check-runs`, paged([runs], (items, total) => ({ total_count: total, check_runs: items })));

    it("reads our newest run's state and ignores other apps' runs", async () => {
      const state = { firstSeenAt: "2026-05-01T00:00:00.000Z", attempts: 1, lastFailureReason: "review-failure" as const };
      const fake = runsRoute(fakeGitHub(), [
        run(5, "goobreview", "goob", { output: { text: `x\n${encodeStateMarker({ ...state, attempts: 0 })}` } }),
        run(9, "goobreview", "goob", { status: "in_progress", conclusion: null, output: { text: encodeStateMarker(state) } }),
        run(12, "goobreview", "other-app", { output: { text: encodeStateMarker({ ...state, attempts: 7 }) } }),
      ]);
      const got = await portFor(fake).getEngineCheckRun(repo, HEAD);
      expect(got).toEqual({ id: 9, status: "in_progress", conclusion: null, state });
      expect(fake.calls.find((c) => c.url.pathname.endsWith("/check-runs"))!.url.searchParams.get("check_name")).toBe("goobreview");
    });

    it("returns null state for a garbage marker and null for no run", async () => {
      const fake = runsRoute(fakeGitHub(), [run(5, "goobreview", "goob", { output: { text: "<!-- goobreview-state:v2 {oops -->" } })]);
      expect((await portFor(fake).getEngineCheckRun(repo, HEAD))!.state).toBeNull();
      expect(await portFor(runsRoute(fakeGitHub(), [])).getEngineCheckRun(repo, HEAD)).toBeNull();
    });

    const update = {
      status: "completed" as const,
      conclusion: "success" as const,
      title: "Approved",
      summary: "done",
      state: { firstSeenAt: "2026-05-01T00:00:00.000Z", attempts: 0 },
    };

    it("creates a run with the state marker when none exists", async () => {
      const fake = runsRoute(fakeGitHub(), []).on("POST", `${P}/check-runs`, (req) => ({ status: 201, body: { id: 44, ...(req.body as object) } }));
      expect(await portFor(fake).upsertEngineCheckRun(repo, HEAD, update)).toBe(44);
      const body = fake.calls.find((c) => c.method === "POST" && c.url.pathname === `${P}/check-runs`)!.body as Record<string, any>;
      expect(body).toMatchObject({ name: "goobreview", head_sha: HEAD, status: "completed", conclusion: "success" });
      expect(body.output).toEqual({ title: "Approved", summary: "done", text: encodeStateMarker(update.state) });
    });

    it("patches our open run in place", async () => {
      const fake = runsRoute(fakeGitHub(), [run(9, "goobreview", "goob", { status: "in_progress", conclusion: null })]).on(
        "PATCH",
        `${P}/check-runs/9`,
        { body: { id: 9 } },
      );
      expect(await portFor(fake).upsertEngineCheckRun(repo, HEAD, update)).toBe(9);
      expect(fake.calls.at(-1)!.method).toBe("PATCH");
    });

    it("tolerates a missing checks:write permission", async () => {
      const log = captureLog();
      const fake = runsRoute(fakeGitHub(), []).on("POST", `${P}/check-runs`, { status: 403, body: { message: "Resource not accessible by integration" } });
      expect(await portFor(fake, log).upsertEngineCheckRun(repo, HEAD, update)).toBe(-1);
      expect(log.lines.find((l) => l.level === "warn")!.msg).toMatch(/checks:write/);
    });
  });

  it("posts a review with multi-line comments anchored RIGHT", async () => {
    const fake = fakeGitHub().on("POST", `${P}/pulls/5/reviews`, { body: { id: 321, html_url: "https://github.com/r/321" } });
    const out = await portFor(fake).postReview(repo, 5, {
      commitId: HEAD,
      event: "REQUEST_CHANGES",
      body: "summary",
      comments: [
        { path: "a.ts", line: 4, side: "RIGHT", body: "one" },
        { path: "a.ts", line: 9, startLine: 7, side: "RIGHT", body: "range" },
      ],
    });
    expect(out).toEqual({ id: 321, htmlUrl: "https://github.com/r/321" });
    expect(fake.calls.at(-1)!.body).toEqual({
      commit_id: HEAD,
      event: "REQUEST_CHANGES",
      body: "summary",
      comments: [
        { path: "a.ts", line: 4, side: "RIGHT", body: "one" },
        { path: "a.ts", line: 9, side: "RIGHT", start_line: 7, start_side: "RIGHT", body: "range" },
      ],
    });
  });

  it("replies to and resolves a thread seen in facts", async () => {
    const fake = withPull(fakeGitHub(), {
      threads: [{ id: "PRRT_9", isResolved: false, viewerCanResolve: true, path: "a", line: 1, comments: { nodes: [{ databaseId: 5, body: "# X", author: { login: "goob[bot]" } }] } }],
    }).on("POST", `${P}/pulls/5/comments/5/replies`, { status: 201, body: { id: 6 } });
    const port = portFor(fake);
    await port.getPullFacts(repo, 5);
    await port.replyToThread(repo, 5, 5, "confirmed");
    fake.on("POST", "/graphql", { body: { data: { resolveReviewThread: { thread: { id: "PRRT_9", isResolved: true } } } } });
    await port.resolveThread("PRRT_9");
    const last = fake.calls.at(-1)!;
    expect((last.body as { variables: unknown }).variables).toEqual({ threadId: "PRRT_9" });
  });

  it("lists repos across paginated installations, skipping suspended ones", async () => {
    const fake = fakeGitHub()
      .on("GET", "/app/installations", paged([[{ id: 77, suspended_at: null }, { id: 78, suspended_at: "2026-01-01T00:00:00Z" }]]))
      .on(
        "GET",
        "/installation/repositories",
        paged(
          [[{ name: "widgets", owner: { login: "acme" } }], [{ name: "gears", owner: { login: "acme" } }]],
          (items, total) => ({ total_count: total, repositories: items }),
        ),
      );
    expect(await portFor(fake).listInstalledRepos()).toEqual([
      { owner: "acme", repo: "widgets" },
      { owner: "acme", repo: "gears" },
    ]);
    expect(fake.calls.filter((c) => c.url.pathname.endsWith("/access_tokens")).map((c) => c.url.pathname)).toEqual(["/app/installations/77/access_tokens"]);
  });

  describe("tarball", () => {
    let dir: string | undefined;
    afterEach(async () => dir && rm(dir, { recursive: true, force: true }));

    it("streams the archive to a file", async () => {
      dir = await mkdtemp(join(tmpdir(), "gb-tar-"));
      const bytes = new Uint8Array([0x1f, 0x8b, 8, 0, 1, 2, 3]);
      const fake = fakeGitHub();
      const inner = fake.fetch;
      fake.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
        if (String(input).includes("/tarball/")) return new Response(bytes, { status: 200, headers: { "content-type": "application/x-gzip" } });
        return inner(input, init);
      }) as typeof fetch;
      const dest = join(dir, "head.tar.gz");
      await portFor(fake).downloadTarball(repo, HEAD, dest);
      expect(new Uint8Array(await readFile(dest))).toEqual(bytes);
    });
  });
});
