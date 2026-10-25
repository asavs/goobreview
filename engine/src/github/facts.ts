// Pure mappers from GitHub response shapes to engine facts. Kept apart from
// the HTTP layer so the identity and re-request rules are testable directly.

import type { BotReview, ReviewThread } from "../types.js";
import { assignHandles, baseHandle } from "./handles.js";

export interface BotIdentity {
  slug: string;
  /** "<slug>[bot]", the REST login. */
  login: string;
  /** "app/<slug>", the form some endpoints and gh report (v1 #13). */
  author: string;
}

export const botIdentity = (slug: string): BotIdentity => ({ slug, login: `${slug}[bot]`, author: `app/${slug}` });

/** REST user login match: both forms count as the bot. */
export const isBotLogin = (bot: BotIdentity, login: string | null | undefined): boolean =>
  login === bot.login || login === bot.author;

/**
 * GraphQL reports a Bot actor's login as the bare slug, so that form is also
 * accepted, but only for Bot actors: a human may own a user named like the slug.
 */
export const isBotActor = (bot: BotIdentity, actor: { __typename?: string; login?: string } | null | undefined): boolean =>
  !!actor && (isBotLogin(bot, actor.login) || (actor.__typename === "Bot" && actor.login === bot.slug));

export interface RestReview {
  id: number;
  user?: { login?: string } | null;
  commit_id?: string | null;
  state?: string;
  body?: string | null;
  submitted_at?: string | null;
}

export function botReviews(bot: BotIdentity, reviews: RestReview[]): BotReview[] {
  return reviews
    .filter((r) => isBotLogin(bot, r.user?.login))
    .map((r) => ({
      id: r.id,
      commitId: r.commit_id ?? "",
      state: r.state ?? "",
      body: r.body ?? "",
      submittedAt: r.submitted_at ?? "",
    }));
}

export interface TimelineEvent {
  event?: string;
  created_at?: string;
  requested_reviewer?: { login?: string } | null;
}

/**
 * v1 treated the bot's presence in requested_reviewers as a re-request (GitHub
 * drops a reviewer from that list when they submit, so presence means asked
 * again). The timeline check also catches a request made after the bot's latest
 * review that a later state change removed from the list; an explicit
 * review_request_removed after it cancels it.
 */
export function reviewRequested(
  bot: BotIdentity,
  requestedReviewers: { login?: string }[],
  timeline: TimelineEvent[],
  reviews: BotReview[],
): boolean {
  if (requestedReviewers.some((u) => isBotLogin(bot, u.login))) return true;
  const latestReview = reviews.reduce((max, r) => Math.max(max, Date.parse(r.submittedAt) || 0), 0);
  let lastRequest = 0;
  let lastRemoval = 0;
  for (const e of timeline) {
    if (!isBotLogin(bot, e.requested_reviewer?.login)) continue;
    const t = Date.parse(e.created_at ?? "") || 0;
    if (e.event === "review_requested") lastRequest = Math.max(lastRequest, t);
    else if (e.event === "review_request_removed") lastRemoval = Math.max(lastRemoval, t);
  }
  return lastRequest > latestReview && lastRequest > lastRemoval;
}

export interface GqlThread {
  id: string;
  isResolved: boolean;
  viewerCanResolve?: boolean | null;
  path?: string | null;
  line?: number | null;
  originalLine?: number | null;
  comments: {
    nodes: ({ databaseId?: number | null; body?: string | null; path?: string | null; author?: { __typename?: string; login?: string } | null } | null)[];
  };
}

/**
 * Bot-opened threads with handles. Unresolved threads are handled exactly as
 * v1 did (it only ever addressed those). Resolved threads keep their base slug
 * and take an "-r<n>" suffix if it would shadow another handle.
 */
export function botThreads(bot: BotIdentity, threads: GqlThread[]): ReviewThread[] {
  const own = threads.filter((t) => isBotActor(bot, t.comments.nodes[0]?.author));
  const toThread = (t: GqlThread, handle: string): ReviewThread => {
    const first = t.comments.nodes[0];
    const line = t.line ?? t.originalLine ?? undefined;
    return {
      id: t.id,
      handle,
      path: t.path ?? first?.path ?? "",
      ...(line !== undefined ? { line } : {}),
      isResolved: t.isResolved,
      firstCommentId: first?.databaseId ?? 0,
      firstCommentBody: first?.body ?? "",
      viewerCanResolve: t.viewerCanResolve === true,
    };
  };
  const open = own.filter((t) => !t.isResolved);
  const openHandles = assignHandles(
    open.map((t) => ({ body: t.comments.nodes[0]?.body ?? "", line: t.line ?? t.originalLine ?? undefined })),
  );
  const taken = new Set(openHandles);
  const byId = new Map<string, ReviewThread>();
  open.forEach((t, i) => byId.set(t.id, toThread(t, openHandles[i]!)));
  for (const t of own.filter((t) => t.isResolved)) {
    const base = baseHandle(t.comments.nodes[0]?.body ?? "");
    let h = base;
    for (let n = 1; taken.has(h); n++) h = `${base}-r${n}`;
    taken.add(h);
    byId.set(t.id, toThread(t, h));
  }
  return own.map((t) => byId.get(t.id)!);
}
