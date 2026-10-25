// File research sink: one JSON file per arm run plus an append-only index of
// summary rows. Records stay on the machine that ran the review; exporting
// and uploading are separate steps.
//
//   <dir>/index.jsonl
//   <dir>/runs/<owner>/<repo>/<pr>/<sha>/<arm>.<recordId>.json

import { randomUUID } from "node:crypto";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { PromptFingerprint, ResearchRecord, ResearchSink } from "./types.js";

export interface StoredResearchRecord extends ResearchRecord {
  recordId: string;
  recordedAt: string;
  /** Random per-install id from the credentials directory; identifies no person. */
  installationId: string;
}

/** Arm names contain "@", "/" and ":"; keep them readable but path-safe. */
const safe = (s: string): string => s.replace(/[^A-Za-z0-9._-]+/g, "_");

export function indexRow(rec: StoredResearchRecord, file: string): Record<string, unknown> {
  const o = rec.outcome;
  return {
    recordId: rec.recordId,
    recordedAt: rec.recordedAt,
    itemId: rec.itemId,
    arm: rec.arm.name,
    posted: rec.posted,
    live: rec.live,
    engineVersion: rec.engineVersion,
    fingerprint: rec.fingerprint,
    ...(rec.corpus ? { corpus: rec.corpus } : {}),
    status: o.status,
    ...(o.status === "ok"
      ? {
          event: o.event,
          findings: o.result.form.findings.length,
          blocking: o.result.form.findings.filter((f) => f.blocking).length,
          model: `${o.result.model.provider}/${o.result.model.id}`,
          credential: o.result.credential,
          usage: o.result.usage,
          elapsedMs: o.result.elapsedMs,
        }
      : { kind: o.kind }),
    file,
  };
}

/** The index fields resume reads. Rows written before fingerprints existed have none, so they match no current series. */
export interface IndexedRun {
  itemId: string;
  arm: string;
  status: string;
  kind?: string;
  fingerprint?: PromptFingerprint | null;
}

/** Index rows written so far; a torn last line (crash mid-append) is ignored. */
export async function readIndex(dir: string): Promise<IndexedRun[]> {
  const text = await readFile(join(dir, "index.jsonl"), "utf8").catch((err: NodeJS.ErrnoException) => {
    if (err.code === "ENOENT") return "";
    throw err;
  });
  const rows = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line));
    } catch {
      // skip
    }
  }
  return rows;
}

export function createFileResearchSink(opts: { dir: string; installationId: string; now?: () => Date }): ResearchSink {
  const now = opts.now ?? (() => new Date());
  return {
    async record(rec) {
      const stored: StoredResearchRecord = {
        ...rec,
        recordId: randomUUID(),
        recordedAt: now().toISOString(),
        installationId: opts.installationId,
      };
      const [owner = "", repo = ""] = rec.repo.split("/");
      const rel = join("runs", safe(owner), safe(repo), String(rec.pr), safe(rec.headSha), `${safe(rec.arm.name)}.${stored.recordId}.json`);
      const file = join(opts.dir, rel);
      await mkdir(join(file, ".."), { recursive: true, mode: 0o700 });
      // Write then rename, so a reader never sees a half-written record.
      const tmp = `${file}.tmp`;
      await writeFile(tmp, JSON.stringify(stored) + "\n", { mode: 0o600 });
      await rename(tmp, file);
      await appendFile(join(opts.dir, "index.jsonl"), JSON.stringify(indexRow(stored, rel.split("\\").join("/"))) + "\n", { mode: 0o600 });
    },
  };
}
