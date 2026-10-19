import { describe, expect, it } from "vitest";
import { evaluateCi } from "../src/ci.js";
import type { CheckRunFact } from "../src/types.js";

const run = (name: string, status: CheckRunFact["status"], conclusion: string | null = null): CheckRunFact => ({
  name,
  status,
  conclusion,
});

describe("evaluateCi", () => {
  it("is none when no checks are required", () => {
    expect(evaluateCi([run("test", "completed", "failure")], [])).toEqual({ state: "none" });
  });

  it("waits on missing required checks", () => {
    expect(evaluateCi([run("lint", "completed", "success")], ["test", "lint"])).toEqual({
      state: "pending",
      waitingOn: ["test"],
    });
  });

  it("waits on running checks", () => {
    for (const status of ["queued", "in_progress", "waiting", "requested", "pending"] as const) {
      expect(evaluateCi([run("test", status)], ["test"])).toEqual({ state: "pending", waitingOn: ["test"] });
    }
  });

  it("pending beats failing so the whole required set reports first", () => {
    expect(evaluateCi([run("a", "completed", "failure"), run("b", "in_progress")], ["a", "b"])).toEqual({
      state: "pending",
      waitingOn: ["b"],
    });
  });

  it("succeeds only when every required check concluded success", () => {
    expect(evaluateCi([run("a", "completed", "success"), run("b", "completed", "success")], ["a", "b"])).toEqual({
      state: "success",
      checks: ["a", "b"],
    });
  });

  it("treats every non-success conclusion as failing, including skipped and neutral (v1)", () => {
    for (const c of ["failure", "cancelled", "timed_out", "action_required", "skipped", "neutral", "stale", null]) {
      expect(evaluateCi([run("a", "completed", c)], ["a"])).toEqual({ state: "failing", failing: ["a"] });
    }
  });

  it("uses the last listed run for a name and ignores unrequired checks", () => {
    const runs = [run("a", "completed", "failure"), run("a", "completed", "success"), run("x", "completed", "failure")];
    expect(evaluateCi(runs, ["a"])).toEqual({ state: "success", checks: ["a"] });
  });
});
