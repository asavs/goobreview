// GitHubPort over Octokit with GitHub App auth.

import { createWriteStream } from "node:fs";
import { rm } from "node:fs/promises";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as WebReadableStream } from "node:stream/web";
import type {
  ChangedFile,
  CheckRunFact,
  CheckStatus,
  EngineCheckRun,
  FileStatus,
  GitHubPort,
  Logger,
  PullRequestFacts,
  RepoRef,
} from "../types.js";
import { type AppOctokitClient, GitHubApiError, type RetryOptions, createAppClient, scrubTokens } from "./client.js";
import { type BotIdentity, type GqlThread, botIdentity, botReviews, botThreads, reviewRequested } from "./facts.js";
import { encodeStateMarker, parseStateMarker } from "./state.js";

export { GitHubApiError, createAppClient, scrubTokens } from "./client.js";
export type { AppOctokitClient, ClientOptions, RetryOptions } from "./client.js";
export { assignHandles, baseHandle, slugify } from "./handles.js";
export { encodeStateMarker, parseStateMarker } from "./state.js";

export const ENGINE_CHECK_NAME = "goobreview";

export interface GitHubPortOptions {
  appId: string;
  privateKey: string;
  /** Pins every repo to this installation instead of discovering it per repo. */
  installationId?: number;
  /** Single-target mode: listInstalledRepos returns only this repo. */
  repo?: RepoRef;
  fetch?: typeof fetch;
  log?: Logger;
  retry?: RetryOptions;
  baseUrl?: string;
}

const NOOP_LOG: Logger = { info() {}, warn() {}, error() {} };

const THREADS_QUERY = `
  query($owner: String!, $name: String!, $number: Int!, $after: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            viewerCanResolve
            path
            line
            originalLine
            comments(first: 1) {
              nodes { databaseId body path author { __typename login } }
            }
          }
        }
      }
    }
  }`;

const RESOLVE_MUTATION = `
  mutation($threadId: ID!) {
    resolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } }
  }`;

const statusOf = (err: unknown): number => (err instanceof GitHubApiError ? err.status : Number((err as { status?: unknown })?.status) || 0);

export function createGitHubPort(opts: GitHubPortOptions): GitHubPort {
  const log = opts.log ?? NOOP_LOG;
  const clientOpts = {
    appId: opts.appId,
    privateKey: opts.privateKey,
    ...(opts.fetch ? { fetch: opts.fetch } : {}),
    ...(opts.retry ? { retry: opts.retry } : {}),
    ...(opts.baseUrl ? { baseUrl: opts.baseUrl } : {}),
    log,
  };
  const app = createAppClient(clientOpts);
  const clients = new Map<number, AppOctokitClient>();
  const installationByRepo = new Map<string, Promise<number>>();
  // resolveThread gets only a node id, so remember which installation saw each thread.
  const installationByThread = new Map<string, number>();
  let identity: Promise<BotIdentity> | undefined;

  const key = (r: RepoRef) => `${r.owner}/${r.repo}`.toLowerCase();

  const clientFor = (installationId: number): AppOctokitClient => {
    let c = clients.get(installationId);
    if (!c) {
      c = createAppClient({ ...clientOpts, installationId });
      clients.set(installationId, c);
    }
    return c;
  };

  const installationFor = (repo: RepoRef): Promise<number> => {
    if (opts.installationId !== undefined) return Promise.resolve(opts.installationId);
    let p = installationByRepo.get(key(repo));
    if (!p) {
      p = app.rest.apps.getRepoInstallation({ owner: repo.owner, repo: repo.repo }).then((r) => r.data.id);
      // Do not cache a failure: a later install should be picked up.
      p.catch(() => installationByRepo.delete(key(repo)));
      installationByRepo.set(key(repo), p);
    }
    return p;
  };

  const gh = async (repo: RepoRef) => clientFor(await installationFor(repo));

  const bot = (): Promise<BotIdentity> => {
    identity ??= app.request("GET /app").then((r) => {
      const slug = r.data?.slug;
      if (!slug) throw new Error("GET /app returned no slug");
      return botIdentity(slug);
    });
    identity.catch(() => (identity = undefined));
    return identity;
  };

  async function graphql<T>(client: AppOctokitClient, query: string, vars: Record<string, unknown>): Promise<T> {
    try {
      return await client.graphql<T>(query, vars);
    } catch (err) {
      if (err instanceof GitHubApiError) throw err;
      throw new GitHubApiError(statusOf(err), "POST", "/graphql", `GitHub GraphQL failed: ${scrubTokens(String((err as Error)?.message ?? err)).slice(0, 500)}`);
    }
  }

  async function listThreads(client: AppOctokitClient, repo: RepoRef, number: number): Promise<GqlThread[]> {
    type Page = {
      repository: { pullRequest: { reviewThreads: { pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: (GqlThread | null)[] } } | null } | null;
    };
    const out: GqlThread[] = [];
    let after: string | null = null;
    for (;;) {
      const page: Page = await graphql<Page>(client, THREADS_QUERY, { owner: repo.owner, name: repo.repo, number, after });
      const conn = page.repository?.pullRequest?.reviewThreads;
      if (!conn) break;
      for (const n of conn.nodes) if (n) out.push(n);
      if (!conn.pageInfo.hasNextPage || !conn.pageInfo.endCursor) break;
      after = conn.pageInfo.endCursor;
    }
    return out;
  }

  type RawCheckRun = {
    id: number;
    name: string;
    status: string;
    conclusion: string | null;
    app?: { slug?: string } | null;
    output?: { text?: string | null } | null;
  };

  async function listCheckRuns(client: AppOctokitClient, repo: RepoRef, sha: string, checkName?: string): Promise<RawCheckRun[]> {
    return (await client.paginate(client.rest.checks.listForRef, {
      owner: repo.owner,
      repo: repo.repo,
      ref: sha,
      filter: "latest",
      per_page: 100,
      ...(checkName ? { check_name: checkName } : {}),
    })) as RawCheckRun[];
  }

  const isOurs = (run: RawCheckRun, slug: string) => run.name === ENGINE_CHECK_NAME && run.app?.slug === slug;

  async function findEngineRun(client: AppOctokitClient, repo: RepoRef, sha: string): Promise<RawCheckRun | null> {
    const { slug } = await bot();
    const ours = (await listCheckRuns(client, repo, sha, ENGINE_CHECK_NAME)).filter((r) => isOurs(r, slug));
    // Newest wins: a fresh run supersedes a completed one on the same SHA.
    return ours.reduce<RawCheckRun | null>((best, r) => (!best || r.id > best.id ? r : best), null);
  }

  return {
    async botLogin() {
      return (await bot()).login;
    },

    async listInstalledRepos() {
      if (opts.repo) {
        await installationFor(opts.repo);
        return [{ owner: opts.repo.owner, repo: opts.repo.repo }];
      }
      const ids =
        opts.installationId !== undefined
          ? [opts.installationId]
          : (await app.paginate(app.rest.apps.listInstallations, { per_page: 100 }))
              // A suspended installation cannot mint tokens.
              .filter((i) => !i.suspended_at)
              .map((i) => i.id);
      const out: RepoRef[] = [];
      for (const id of ids) {
        const client = clientFor(id);
        const repos = await client.paginate(client.rest.apps.listReposAccessibleToInstallation, { per_page: 100 });
        for (const r of repos) {
          const ref = { owner: r.owner.login, repo: r.name };
          installationByRepo.set(key(ref), Promise.resolve(id));
          out.push(ref);
        }
      }
      return out;
    },

    async listOpenPulls(repo) {
      const client = await gh(repo);
      const pulls = await client.paginate(client.rest.pulls.list, { owner: repo.owner, repo: repo.repo, state: "open", per_page: 100 });
      return pulls.map((p) => ({ number: p.number, headSha: p.head.sha, draft: p.draft === true, authorLogin: p.user?.login ?? "" }));
    },

    async getHeadSha(repo, number) {
      const client = await gh(repo);
      return (await client.rest.pulls.get({ owner: repo.owner, repo: repo.repo, pull_number: number })).data.head.sha;
    },

    async getPullFacts(repo, number) {
      const installationId = await installationFor(repo);
      const client = clientFor(installationId);
      const base = { owner: repo.owner, repo: repo.repo };
      const pr = { ...base, pull_number: number, per_page: 100 };
      const [id, pull, commits, files, reviews, timeline, threads] = await Promise.all([
        bot(),
        client.rest.pulls.get({ ...base, pull_number: number }).then((r) => r.data),
        client.paginate(client.rest.pulls.listCommits, pr),
        client.paginate(client.rest.pulls.listFiles, pr),
        client.paginate(client.rest.pulls.listReviews, pr),
        client.paginate(client.rest.issues.listEventsForTimeline, { ...base, issue_number: number, per_page: 100 }),
        listThreads(client, repo, number),
      ]);
      const runs = await listCheckRuns(client, repo, pull.head.sha);
      for (const t of threads) installationByThread.set(t.id, installationId);
      const ownReviews = botReviews(id, reviews.map((r) => ({ ...r, id: Number(r.id) })));

      const changed: ChangedFile[] = files.map((f) => {
        const c: ChangedFile = {
          path: f.filename,
          status: f.status as FileStatus,
          additions: f.additions,
          deletions: f.deletions,
        };
        if (f.previous_filename) c.previousPath = f.previous_filename;
        if (typeof f.patch === "string") c.patch = f.patch;
        return c;
      });

      const checkRuns: CheckRunFact[] = runs
        .filter((r) => !isOurs(r, id.slug))
        .map((r) => {
          const c: CheckRunFact = { name: r.name, status: r.status as CheckStatus, conclusion: r.conclusion ?? null };
          if (r.app?.slug) c.appSlug = r.app.slug;
          return c;
        });

      const basePrivate = (pull.base.repo as { private?: unknown } | null)?.private;
      const facts: PullRequestFacts = {
        repo,
        number,
        htmlUrl: pull.html_url,
        title: pull.title,
        body: pull.body ?? "",
        draft: pull.draft === true,
        state: pull.state === "closed" ? "closed" : "open",
        author: { login: pull.user?.login ?? "", type: pull.user?.type ?? "" },
        headSha: pull.head.sha,
        headRef: pull.head.ref,
        baseRef: pull.base.ref,
        baseSha: pull.base.sha,
        // A deleted fork leaves head.repo null; that is still a fork.
        isFork: !pull.head.repo || pull.head.repo.id !== pull.base.repo.id,
        // Unknown visibility is treated as private (fails closed for research capture).
        repoPrivate: typeof basePrivate === "boolean" ? basePrivate : true,
        commits: commits.map((c) => ({ sha: c.sha, subject: (c.commit.message ?? "").split("\n")[0] ?? "" })),
        files: changed,
        botReviews: ownReviews,
        reviewRequested: reviewRequested(
          id,
          (pull.requested_reviewers ?? []).map((u) => ({ login: u?.login })),
          timeline as never,
          ownReviews,
        ),
        botThreads: botThreads(id, threads),
        checkRuns,
      };
      return facts;
    },

    async downloadTarball(repo, sha, destFile) {
      const client = await gh(repo);
      const res = await client.request("GET /repos/{owner}/{repo}/tarball/{ref}", {
        owner: repo.owner,
        repo: repo.repo,
        ref: sha,
        // Stream instead of buffering the archive; the redirect to codeload is followed by fetch.
        request: { parseSuccessResponseBody: false },
      });
      const body = res.data as unknown as WebReadableStream<Uint8Array> | null;
      if (!body) throw new Error(`tarball for ${sha} had no body`);
      try {
        await pipeline(Readable.fromWeb(body), createWriteStream(destFile));
      } catch (err) {
        await rm(destFile, { force: true });
        throw err;
      }
    },

    async getEngineCheckRun(repo, sha): Promise<EngineCheckRun | null> {
      const run = await findEngineRun(await gh(repo), repo, sha);
      if (!run) return null;
      return {
        id: run.id,
        status: run.status as CheckStatus,
        conclusion: run.conclusion ?? null,
        state: parseStateMarker(run.output?.text),
      };
    },

    async upsertEngineCheckRun(repo, sha, update) {
      const client = await gh(repo);
      const now = new Date().toISOString();
      const output = { title: update.title, summary: update.summary, text: encodeStateMarker(update.state) };
      const completion =
        update.status === "completed" ? { conclusion: update.conclusion ?? "neutral", completed_at: now } : {};
      try {
        const existing = await findEngineRun(client, repo, sha);
        // A completed run is not reopened; a new run supersedes it as latest for the name.
        if (existing && (existing.status !== "completed" || update.status === "completed")) {
          await client.request("PATCH /repos/{owner}/{repo}/check-runs/{check_run_id}", {
            owner: repo.owner,
            repo: repo.repo,
            check_run_id: existing.id,
            status: update.status,
            output,
            ...completion,
          });
          return existing.id;
        }
        const res = await client.request("POST /repos/{owner}/{repo}/check-runs", {
          owner: repo.owner,
          repo: repo.repo,
          name: ENGINE_CHECK_NAME,
          head_sha: sha,
          status: update.status,
          ...(update.status === "queued" ? {} : { started_at: now }),
          output,
          ...completion,
        });
        return Number(res.data.id);
      } catch (err) {
        if (statusOf(err) === 403) {
          log.warn("check run not written; the App needs checks:write", { repo: `${repo.owner}/${repo.repo}`, sha });
          return -1;
        }
        throw err;
      }
    },

    async addReaction(repo, number, content) {
      const client = await gh(repo);
      try {
        await client.rest.reactions.createForIssue({ owner: repo.owner, repo: repo.repo, issue_number: number, content });
      } catch (err) {
        const s = statusOf(err);
        if (s !== 403 && s !== 422) throw err;
        log.warn("reaction not added", { repo: `${repo.owner}/${repo.repo}`, number, content, status: s });
      }
    },

    async postReview(repo, number, payload) {
      const client = await gh(repo);
      const comments = payload.comments.map((c) => ({
        path: c.path,
        line: c.line,
        side: c.side,
        ...(c.startLine !== undefined ? { start_line: c.startLine, start_side: "RIGHT" as const } : {}),
        body: c.body,
      }));
      const res = await client.rest.pulls.createReview({
        owner: repo.owner,
        repo: repo.repo,
        pull_number: number,
        commit_id: payload.commitId,
        event: payload.event,
        body: payload.body,
        ...(comments.length > 0 ? { comments } : {}),
      });
      return { id: Number(res.data.id), htmlUrl: res.data.html_url };
    },

    async replyToThread(repo, number, commentId, body) {
      const client = await gh(repo);
      await client.rest.pulls.createReplyForReviewComment({
        owner: repo.owner,
        repo: repo.repo,
        pull_number: number,
        comment_id: commentId,
        body,
      });
    },

    async resolveThread(threadId) {
      const inst =
        installationByThread.get(threadId) ??
        opts.installationId ??
        (clients.size === 1 ? [...clients.keys()][0] : undefined);
      if (inst === undefined) throw new Error("resolveThread: unknown thread; read it with getPullFacts first");
      const client = clientFor(inst);
      type R = { resolveReviewThread: { thread: { id: string; isResolved: boolean } | null } | null };
      const r = await graphql<R>(client, RESOLVE_MUTATION, { threadId });
      if (!r.resolveReviewThread?.thread?.isResolved) throw new Error(`thread ${threadId} was not resolved`);
    },
  };
}
