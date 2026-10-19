// EngineState lives in the engine's own check run as a marker in output.text,
// so any stateless worker can resume a head where another left off.

import type { EngineState } from "../types.js";

const MARKER = /<!-- goobreview-state:v2 (\{.*?\}) -->/s;
const REASONS = new Set(["review-failure", "invalid-review", "quota"]);

export function encodeStateMarker(state: EngineState): string {
  // Escaping ">" keeps a "-->" inside any string value from closing the comment.
  const json = JSON.stringify(state).replace(/>/g, "\\u003e");
  return `<!-- goobreview-state:v2 ${json} -->`;
}

/** Parses the marker from check-run text; null when missing or malformed. */
export function parseStateMarker(text: string | null | undefined): EngineState | null {
  const m = text ? MARKER.exec(text) : null;
  if (!m) return null;
  let raw: unknown;
  try {
    raw = JSON.parse(m[1]!);
  } catch {
    return null;
  }
  if (typeof raw !== "object" || raw === null) return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.firstSeenAt !== "string" || Number.isNaN(Date.parse(o.firstSeenAt))) return null;
  if (typeof o.attempts !== "number" || !Number.isInteger(o.attempts) || o.attempts < 0) return null;
  const state: EngineState = { firstSeenAt: o.firstSeenAt, attempts: o.attempts };
  if (o.lastFailureReason !== undefined) {
    if (typeof o.lastFailureReason !== "string" || !REASONS.has(o.lastFailureReason)) return null;
    state.lastFailureReason = o.lastFailureReason as EngineState["lastFailureReason"];
  }
  if (o.lastAttemptAt !== undefined) {
    if (typeof o.lastAttemptAt !== "string") return null;
    state.lastAttemptAt = o.lastAttemptAt;
  }
  return state;
}
