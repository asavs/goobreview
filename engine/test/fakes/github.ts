// In-memory GitHubPort. Reads come from seeded data; every write is recorded
// in `writes` (in order) so tests can assert exactly what reached GitHub.

import { writeFile } from "node:fs/promises";
import type {
  CheckRunUpdate,
  EngineCheckRun,
  GitHubPort,
  PullRequestFacts,
  PullSummary,
  RepoRef,
  ReviewPayload,
} from "../../src/types.js";
import { repoName } from "../../src/types.js";

export type Write =
  | { op: "checkRun"; repo: string; sha: string; update: CheckRunUpdate }
  | { op: "reaction"; repo: string; number: number; content: "eyes" | "confused" }
  | { op: "review"; repo: string; number: number; payload: ReviewPayload }
  | { op: "reply"; repo: string; number: number; commentId: number; body: string }
  | { op: "resolve"; threadId: string };

export function makeFacts(over: Partial<PullRequestFacts> = {}): PullRequestFacts {
  return {
    repo: { owner: "o", repo: "r" },
    number: 7,
    htmlUrl: "https://github.com/o/r/pull/7",
    title: "Add thing",
    body: "",
    draft: false,
    state: "open",
    author: { login: "alice", type: "User" },
    headSha: "a".repeat(40),
    headRef: "feature",
    baseRef: "main",
    baseSha: "b".repeat(40),
    isFork: false,
    repoPrivate: false,
    commits: [{ sha: "a".repeat(40), subject: "Add thing" }],
    files: [],
    botReviews: [],
    reviewRequested: false,
    botThreads: [],
    checkRuns: [],
    ...over,
  };
}

export class FakeGitHub implements GitHubPort {
  bot = "goob[bot]";
  repos: RepoRef[] = [{ owner: "o", repo: "r" }];
  facts = new Map<string, PullRequestFacts>();
  /** Head SHAs returned by successive getHeadSha calls; falls back to facts.headSha. */
  headShaSequence: string[] = [];
  engineRuns = new Map<string, EngineCheckRun>();
  writes: Write[] = [];
  /** Method names that should throw. */
  failing = new Set<keyof GitHubPort>();
  private nextId = 100;

  constructor(...prs: PullRequestFacts[]) {
    for (const f of prs) this.addPull(f);
  }

  addPull(f: PullRequestFacts): void {
    this.facts.set(`${repoName(f.repo)}#${f.number}`, f);
  }

  private guard(m: keyof GitHubPort): void {
    if (this.failing.has(m)) throw new Error(`fake ${m} failure`);
  }

  private pull(repo: RepoRef, number: number): PullRequestFacts {
    const f = this.facts.get(`${repoName(repo)}#${number}`);
    if (!f) throw new Error(`no such pull ${repoName(repo)}#${number}`);
    return f;
  }

  async botLogin(): Promise<string> {
    return this.bot;
  }
  async listInstalledRepos(): Promise<RepoRef[]> {
    this.guard("listInstalledRepos");
    return this.repos;
  }
  async listOpenPulls(repo: RepoRef): Promise<PullSummary[]> {
    this.guard("listOpenPulls");
    return [...this.facts.values()]
      .filter((f) => repoName(f.repo) === repoName(repo) && f.state === "open")
      .map((f) => ({ number: f.number, headSha: f.headSha, draft: f.draft, authorLogin: f.author.login }));
  }
  async getPullFacts(repo: RepoRef, number: number): Promise<PullRequestFacts> {
    this.guard("getPullFacts");
    return structuredClone(this.pull(repo, number));
  }
  async getHeadSha(repo: RepoRef, number: number): Promise<string> {
    this.guard("getHeadSha");
    return this.headShaSequence.shift() ?? this.pull(repo, number).headSha;
  }
  async downloadTarball(_repo: RepoRef, _sha: string, destFile: string): Promise<void> {
    this.guard("downloadTarball");
    await writeFile(destFile, "");
  }
  async getEngineCheckRun(repo: RepoRef, sha: string): Promise<EngineCheckRun | null> {
    this.guard("getEngineCheckRun");
    return this.engineRuns.get(`${repoName(repo)}@${sha}`) ?? null;
  }
  async upsertEngineCheckRun(repo: RepoRef, sha: string, update: CheckRunUpdate): Promise<number> {
    this.guard("upsertEngineCheckRun");
    this.writes.push({ op: "checkRun", repo: repoName(repo), sha, update: structuredClone(update) });
    const key = `${repoName(repo)}@${sha}`;
    const id = this.engineRuns.get(key)?.id ?? this.nextId++;
    this.engineRuns.set(key, {
      id,
      status: update.status,
      conclusion: update.conclusion ?? null,
      state: structuredClone(update.state),
    });
    return id;
  }
  async addReaction(repo: RepoRef, number: number, content: "eyes" | "confused"): Promise<void> {
    this.guard("addReaction");
    this.writes.push({ op: "reaction", repo: repoName(repo), number, content });
  }
  async postReview(repo: RepoRef, number: number, payload: ReviewPayload): Promise<{ id: number; htmlUrl: string }> {
    this.guard("postReview");
    this.writes.push({ op: "review", repo: repoName(repo), number, payload: structuredClone(payload) });
    const id = this.nextId++;
    // Like GitHub, the posted review shows up in later facts and dedups the head.
    this.pull(repo, number).botReviews.push({
      id,
      commitId: payload.commitId,
      state: payload.event,
      body: payload.body,
      submittedAt: new Date(0).toISOString(),
    });
    return { id, htmlUrl: `https://github.com/${repoName(repo)}/pull/${number}#pullrequestreview-${id}` };
  }
  async replyToThread(repo: RepoRef, number: number, commentId: number, body: string): Promise<void> {
    this.guard("replyToThread");
    this.writes.push({ op: "reply", repo: repoName(repo), number, commentId, body });
  }
  async resolveThread(threadId: string): Promise<void> {
    this.guard("resolveThread");
    this.writes.push({ op: "resolve", threadId });
  }

  ops(): string[] {
    return this.writes.map((w) =>
      w.op === "checkRun" ? `checkRun:${w.update.status}${w.update.conclusion ? `/${w.update.conclusion}` : ""}` : w.op === "reaction" ? `reaction:${w.content}` : w.op,
    );
  }
}
