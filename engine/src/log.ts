// JSON-lines logger on stderr. Every message and every string inside fields
// passes through redact(), so a token in an error message never reaches a log.

import { redact } from "./redact.js";
import type { Logger } from "./types.js";

type Level = "info" | "warn" | "error";

function scrub(v: unknown, depth = 0): unknown {
  if (typeof v === "string") return redact(v);
  if (v === null || typeof v !== "object") return v;
  if (depth > 6) return "[depth]";
  if (v instanceof Error) {
    const e: Record<string, unknown> = { name: v.name, message: redact(v.message) };
    const kind = (v as { kind?: unknown }).kind;
    if (typeof kind === "string") e.kind = kind;
    return e;
  }
  if (Array.isArray(v)) return v.map((x) => scrub(x, depth + 1));
  const out: Record<string, unknown> = {};
  for (const [k, x] of Object.entries(v)) out[k] = scrub(x, depth + 1);
  return out;
}

export function createLogger(
  opts: { write?: (line: string) => void; fields?: Record<string, unknown>; now?: () => Date } = {},
): Logger {
  const write = opts.write ?? ((line: string) => process.stderr.write(line + "\n"));
  const now = opts.now ?? (() => new Date());
  const base = opts.fields ?? {};
  const emit = (level: Level, msg: string, fields?: Record<string, unknown>): void => {
    const rec = { t: now().toISOString(), level, msg: redact(msg), ...(scrub({ ...base, ...fields }) as object) };
    write(JSON.stringify(rec));
  };
  return {
    info: (m, f) => emit("info", m, f),
    warn: (m, f) => emit("warn", m, f),
    error: (m, f) => emit("error", m, f),
  };
}

export const silentLogger: Logger = { info() {}, warn() {}, error() {} };
