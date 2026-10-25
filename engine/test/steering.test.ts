import { describe, expect, it } from "vitest";
import { createSteering } from "../src/steering.js";

describe("createSteering", () => {
  it("returns each message once, at its scheduled counts, in persona order", () => {
    const s = createSteering([
      { text: "*ding*", afterToolCalls: [2, 4] },
      { text: "ETA?", afterToolCalls: [4] },
    ]);
    const due = Array.from({ length: 6 }, () => s.toolCompleted());
    expect(due).toEqual([[], ["*ding*"], [], ["*ding*", "ETA?"], [], []]);
    expect(s.completed).toBe(6);
  });

  it("is inert without steer pieces", () => {
    const s = createSteering([]);
    expect([s.toolCompleted(), s.toolCompleted()]).toEqual([[], []]);
  });
});
