import { describe, expect, it } from "vitest";
import { botIdentity, botReviews, botThreads, isBotActor, reviewRequested, type GqlThread } from "../../src/github/facts.js";
import { assignHandles, baseHandle, slugify } from "../../src/github/handles.js";
import { encodeStateMarker, parseStateMarker } from "../../src/github/state.js";

const bot = botIdentity("goob");

describe("handles (v1 slug derivation)", () => {
  it("slugs the first heading of the comment", () => {
    expect(baseHandle("### Null deref footgun\n`src/app.py:42` dereferences a possibly-null ref.")).toBe("null-deref-footgun");
  });

  it("skips prose before the heading and strips heading whitespace", () => {
    expect(baseHandle("intro text\n  ## Stale   Render!!  \t\nmore")).toBe("stale-render");
  });

  it("falls back to the first non-blank line, then to 'thread'", () => {
    expect(baseHandle("\n   \nNo heading here: just text.")).toBe("no-heading-here-just-text");
    expect(baseHandle("")).toBe("thread");
    expect(baseHandle("#   \n")).toBe("thread");
    expect(baseHandle("!!!")).toBe("thread");
  });

  it("does not treat seven hashes or a missing space as a heading", () => {
    expect(baseHandle("####### Seven\n# Real one")).toBe("real-one");
    expect(baseHandle("#nospace\nbody")).toBe("nospace");
  });

  it("folds only ASCII case, caps at 48 chars and trims a trailing dash", () => {
    expect(slugify("Ünïcode İs Dropped")).toBe("n-code-s-dropped");
    const long = "a".repeat(47) + " bcd";
    expect(slugify(long)).toBe("a".repeat(47));
    expect(slugify("x".repeat(60))).toHaveLength(48);
  });

  it("disambiguates collisions with -l<line>, then a running -<n>", () => {
    expect(
      assignHandles([
        { body: "# Leak", line: 10 },
        { body: "# Leak", line: 20 },
        { body: "# Race", line: 5 },
        { body: "# Race", line: 5 },
        { body: "# Race" },
        { body: "# Unique" },
      ]),
    ).toEqual(["leak-l10", "leak-l20", "race-l5-1", "race-l5-2", "race-l0", "unique"]);
  });
});

describe("bot identity", () => {
  it("matches both REST login forms (v1 #13) and the bare slug only for Bot actors", () => {
    const reviews = botReviews(bot, [
      { id: 1, user: { login: "goob[bot]" }, commit_id: "a", state: "COMMENTED", body: "x", submitted_at: "2026-01-01T00:00:00Z" },
      { id: 2, user: { login: "app/goob" }, commit_id: "b", state: "APPROVED", body: null, submitted_at: "2026-01-02T00:00:00Z" },
      { id: 3, user: { login: "goob" }, commit_id: "c" },
      { id: 4, user: null },
    ]);
    expect(reviews.map((r) => r.id)).toEqual([1, 2]);
    expect(reviews[1]).toEqual({ id: 2, commitId: "b", state: "APPROVED", body: "", submittedAt: "2026-01-02T00:00:00Z" });
    expect(isBotActor(bot, { __typename: "Bot", login: "goob" })).toBe(true);
    expect(isBotActor(bot, { __typename: "User", login: "goob" })).toBe(false);
    expect(isBotActor(bot, { __typename: "User", login: "goob[bot]" })).toBe(true);
  });
});

describe("reviewRequested", () => {
  const reviewed = [{ id: 1, commitId: "a", state: "COMMENTED", body: "", submittedAt: "2026-05-01T12:00:00Z" }];
  const ev = (event: string, at: string, login = "goob[bot]") => ({ event, created_at: at, requested_reviewer: { login } });

  it("is true when the bot is a requested reviewer, in either form", () => {
    expect(reviewRequested(bot, [{ login: "app/goob" }], [], reviewed)).toBe(true);
    expect(reviewRequested(bot, [{ login: "someone" }], [], reviewed)).toBe(false);
  });

  it("is true for a review_requested event newer than the latest bot review", () => {
    expect(reviewRequested(bot, [], [ev("review_requested", "2026-05-01T13:00:00Z")], reviewed)).toBe(true);
  });

  it("ignores requests older than the latest review, for other users, or since removed", () => {
    expect(reviewRequested(bot, [], [ev("review_requested", "2026-05-01T11:00:00Z")], reviewed)).toBe(false);
    expect(reviewRequested(bot, [], [ev("review_requested", "2026-05-01T13:00:00Z", "human")], reviewed)).toBe(false);
    expect(
      reviewRequested(bot, [], [ev("review_requested", "2026-05-01T13:00:00Z"), ev("review_request_removed", "2026-05-01T14:00:00Z")], reviewed),
    ).toBe(false);
  });

  it("counts any request when the bot has never reviewed", () => {
    expect(reviewRequested(bot, [], [ev("review_requested", "2026-05-01T11:00:00Z")], [])).toBe(true);
    expect(reviewRequested(bot, [], [], [])).toBe(false);
  });
});

describe("botThreads", () => {
  const t = (id: string, body: string, opts: Partial<GqlThread> & { login?: string; typename?: string } = {}): GqlThread => ({
    id,
    isResolved: opts.isResolved ?? false,
    viewerCanResolve: opts.viewerCanResolve ?? true,
    path: "src/a.ts",
    line: opts.line ?? null,
    originalLine: opts.originalLine ?? null,
    comments: { nodes: [{ databaseId: Number(id.replace(/\D/g, "")) || 1, body, path: "src/a.ts", author: { __typename: opts.typename ?? "Bot", login: opts.login ?? "goob" } }] },
  });

  it("keeps only bot-opened threads and assigns v1 handles to unresolved ones", () => {
    const out = botThreads(bot, [
      t("T1", "### Leak", { line: 3 }),
      t("T2", "### Leak", { originalLine: 9 }),
      t("T3", "### Human note", { login: "alice", typename: "User" }),
      t("T4", "### Leak", { isResolved: true, line: 1 }),
    ]);
    expect(out.map((x) => [x.id, x.handle, x.line, x.isResolved])).toEqual([
      ["T1", "leak-l3", 3, false],
      ["T2", "leak-l9", 9, false],
      ["T4", "leak", 1, true],
    ]);
    expect(out[0]).toMatchObject({ firstCommentId: 1, firstCommentBody: "### Leak", viewerCanResolve: true, path: "src/a.ts" });
  });

  it("suffixes a resolved handle that would shadow an open one", () => {
    const out = botThreads(bot, [t("T1", "# Leak"), t("T2", "# Leak", { isResolved: true })]);
    expect(out.map((x) => x.handle)).toEqual(["leak", "leak-r1"]);
  });
});

describe("state marker", () => {
  it("round-trips", () => {
    const s = { firstSeenAt: "2026-05-01T12:00:00.000Z", attempts: 2, lastFailureReason: "quota" as const, lastAttemptAt: "2026-05-01T13:00:00.000Z" };
    const text = `Some prose\n\n${encodeStateMarker(s)}\n`;
    expect(parseStateMarker(text)).toEqual(s);
  });

  it("cannot be closed early by a string value", () => {
    const s = { firstSeenAt: "2026-05-01T12:00:00.000Z", attempts: 0, lastAttemptAt: "x --> y" };
    const marker = encodeStateMarker(s);
    expect(marker.indexOf("-->")).toBe(marker.length - 3);
    expect(parseStateMarker(marker)).toEqual(s);
  });

  it("returns null for missing, garbage or ill-typed markers", () => {
    expect(parseStateMarker(undefined)).toBeNull();
    expect(parseStateMarker("no marker")).toBeNull();
    expect(parseStateMarker("<!-- goobreview-state:v2 {not json} -->")).toBeNull();
    expect(parseStateMarker('<!-- goobreview-state:v1 {"firstSeenAt":"2026-01-01T00:00:00Z","attempts":0} -->')).toBeNull();
    expect(parseStateMarker('<!-- goobreview-state:v2 {"firstSeenAt":"later","attempts":0} -->')).toBeNull();
    expect(parseStateMarker('<!-- goobreview-state:v2 {"firstSeenAt":"2026-01-01T00:00:00Z","attempts":-1} -->')).toBeNull();
    expect(parseStateMarker('<!-- goobreview-state:v2 {"firstSeenAt":"2026-01-01T00:00:00Z","attempts":1,"lastFailureReason":"oops"} -->')).toBeNull();
  });
});
