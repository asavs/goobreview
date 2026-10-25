import { describe, expect, it } from "vitest";
import { buildDiffMap, parsePatch } from "../src/diffmap.js";

const sorted = (s: Set<number>) => [...s].sort((a, b) => a - b);

describe("parsePatch", () => {
  it("maps context and added lines across multiple hunks", () => {
    const patch = [
      "@@ -1,3 +1,4 @@",
      " a",
      "+b",
      " c",
      " d",
      "@@ -10,2 +11,3 @@ function x() {",
      " k",
      "+l",
      " m",
    ].join("\n");
    const f = parsePatch(patch);
    expect(sorted(f.right)).toEqual([1, 2, 3, 4, 11, 12, 13]);
    expect(sorted(f.added)).toEqual([2, 12]);
    expect(f.hunkOf.get(4)).toBe(0);
    expect(f.hunkOf.get(11)).toBe(1);
  });

  it("skips deleted lines without advancing the RIGHT counter", () => {
    const f = parsePatch(["@@ -5,4 +5,3 @@", " a", "-gone", "-gone2", "+new", " z"].join("\n"));
    expect(sorted(f.right)).toEqual([5, 6, 7]);
    expect(sorted(f.added)).toEqual([6]);
  });

  it("ignores no-newline markers and the trailing split artifact", () => {
    const f = parsePatch(["@@ -1 +1 @@", "-old", "\\ No newline at end of file", "+new", "\\ No newline at end of file", ""].join("\n"));
    expect(sorted(f.right)).toEqual([1]);
    expect(sorted(f.added)).toEqual([1]);
  });

  it("handles an added file and a context line with its space stripped", () => {
    expect(sorted(parsePatch("@@ -0,0 +1,2 @@\n+x\n+y\n").added)).toEqual([1, 2]);
    expect(sorted(parsePatch("@@ -1,3 +1,3 @@\n a\n\n c\n").right)).toEqual([1, 2, 3]);
  });
});

describe("buildDiffMap", () => {
  it("omits files without a patch (renames, binaries)", () => {
    const map = buildDiffMap([
      { path: "new.ts", previousPath: "old.ts", status: "renamed", additions: 0, deletions: 0 },
      { path: "img.png", status: "added", additions: 0, deletions: 0, patch: "" },
      { path: "a.ts", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n a\n+b" },
    ]);
    expect([...map.keys()]).toEqual(["a.ts"]);
    expect(sorted(map.get("a.ts")!.added)).toEqual([2]);
  });
});
