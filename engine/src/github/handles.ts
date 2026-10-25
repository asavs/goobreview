// Thread handles: a stable, meaningful address for each bot thread, derived
// from the heading of its first (bot-authored) comment. Ported exactly from
// v1's github_review_thread_handle_map_json so handles survive the rewrite.
// They are re-derived from live thread state on every run and only echoed back
// within the same prompt, so no name->id map is persisted.

// jq's [[:space:]] under Oniguruma is ASCII whitespace.
const SPACE = "[ \\t\\n\\r\\f\\v]";
const HEADING = new RegExp(`^${SPACE}*#{1,6}${SPACE}+`);
const TRAILING_SPACE = new RegExp(`${SPACE}+$`);
const NON_SPACE = /[^ \t\n\r\f\v]/;

export function slugify(s: string): string {
  // ascii_downcase: only A-Z fold; anything else is replaced below.
  return s
    .replace(/[A-Z]/g, (c) => c.toLowerCase())
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "")
    .slice(0, 48)
    .replace(/-+$/, "");
}

export function firstLine(body: string): string {
  return body.split("\n").find((l) => NON_SPACE.test(l)) ?? "";
}

export function heading(body: string): string {
  const line = body.split("\n").find((l) => HEADING.test(l)) ?? "";
  return line.replace(HEADING, "").replace(TRAILING_SPACE, "");
}

/** Base slug before collision handling: heading, else first non-blank line, else "thread". */
export function baseHandle(body: string): string {
  const head = heading(body);
  const base = head.length > 0 ? slugify(head) : slugify(firstLine(body));
  return base.length > 0 ? base : "thread";
}

export interface HandleInput {
  body: string;
  line?: number;
}

/**
 * Assign handles to a list of threads in order. A slug shared by two threads
 * gains a "-l<line>" suffix; any still-identical slug gains a "-<n>" running
 * suffix (every member of the group, starting at 1).
 */
export function assignHandles(items: HandleInput[]): string[] {
  const bases = items.map((it) => baseHandle(it.body));
  const baseCount = countBy(bases);
  const cands = bases.map((b, i) => (baseCount.get(b)! > 1 ? `${b}-l${items[i]!.line ?? 0}` : b));
  const candCount = countBy(cands);
  const seen = new Map<string, number>();
  return cands.map((c) => {
    const n = seen.get(c) ?? 0;
    seen.set(c, n + 1);
    return candCount.get(c)! > 1 ? `${c}-${n + 1}` : c;
  });
}

function countBy(xs: string[]): Map<string, number> {
  const m = new Map<string, number>();
  for (const x of xs) m.set(x, (m.get(x) ?? 0) + 1);
  return m;
}
