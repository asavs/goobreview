// RIGHT-side line maps parsed from GitHub's per-file `patch` text. GitHub
// accepts an inline comment only on a line its own diff exposes, so this is
// the ground truth for placement; a stale or invented citation just stays in
// the review body instead of failing the whole review.

import type { ChangedFile } from "./types.js";

export interface FileLines {
  /** RIGHT-side lines (context or added) present in the diff. */
  right: Set<number>;
  /** Subset of `right` that the PR added. */
  added: Set<number>;
  /** RIGHT line -> index of the hunk it belongs to; a range must stay inside one hunk. */
  hunkOf: Map<number, number>;
}

export type DiffMap = Map<string, FileLines>;

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

export function parsePatch(patch: string): FileLines {
  const lines: FileLines = { right: new Set(), added: new Set(), hunkOf: new Map() };
  let hunk = -1;
  let next = 0;
  let oldLeft = 0;
  let newLeft = 0;
  for (const raw of patch.split("\n")) {
    const header = HUNK.exec(raw);
    if (header) {
      hunk += 1;
      next = Number(header[3]);
      oldLeft = header[2] === undefined ? 1 : Number(header[2]);
      newLeft = header[4] === undefined ? 1 : Number(header[4]);
      continue;
    }
    if (hunk < 0) continue;
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    const tag = line[0];
    if (tag === "\\") continue; // "\ No newline at end of file"
    if (tag === "+") {
      if (newLeft <= 0) continue;
      lines.right.add(next);
      lines.added.add(next);
      lines.hunkOf.set(next, hunk);
      next += 1;
      newLeft -= 1;
    } else if (tag === "-") {
      oldLeft -= 1;
    } else if (tag === " " || (line === "" && oldLeft > 0 && newLeft > 0)) {
      // An empty element is a context line whose leading space was stripped,
      // but only while the header says lines remain; otherwise it is the
      // trailing split artifact.
      lines.right.add(next);
      lines.hunkOf.set(next, hunk);
      next += 1;
      oldLeft -= 1;
      newLeft -= 1;
    }
  }
  return lines;
}

/** Files without a patch (binary, too large, pure renames) are absent: nothing on them is placeable. */
export function buildDiffMap(files: ChangedFile[]): DiffMap {
  const map: DiffMap = new Map();
  for (const file of files) {
    if (file.patch === undefined || file.patch === "") continue;
    map.set(file.path, parsePatch(file.patch));
  }
  return map;
}
