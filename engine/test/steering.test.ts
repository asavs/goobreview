import { describe, expect, it } from "vitest";
import { createSteering } from "../src/steering.js";

describe("createSteering", () => {
  it("returns each message once, at its scheduled counts, in persona order", () => {
    const s = createSteering([
      { id: "*ding*", sha256: "h", text: "*ding*", afterToolCalls: [2, 4] },
      { id: "ETA?", sha256: "h", text: "ETA?", afterToolCalls: [4] },
    ]);
    const due = Array.from({ length: 6 }, () => s.toolCompleted().map((p) => p.text));
    expect(due).toEqual([[], ["*ding*"], [], ["*ding*", "ETA?"], [], []]);
    expect(s.completed).toBe(6);
  });

  it("is inert without steer pieces", () => {
    const s = createSteering([]);
    expect([s.toolCompleted(), s.toolCompleted()]).toEqual([[], []]);
  });
});
