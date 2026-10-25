import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { PersonaError, resolvePersona, slotText } from "../src/persona.js";
import { PromptBudgetError, composePrompt, userMessage } from "../src/prompt.js";
import { budgets, input, policy } from "./fixtures/prompt-input.js";

// v1 (v2.3.0) scripts/reviewer/lib/prompt.sh and config/personalities, verbatim.
const V1_ROLE = "You are a very angry senior engineer.";
const V1_INTERRUPTION =
  "Assistant: okay.. deep breaths... one, two, thr-*ding dingdingding* *the notification cuts across a thought they were trying not to lose* A PR REVIEW??!! NOW?!! I-\n";
const V1_PREFIX = "User:\n";
const V1_TAIL = "\nAssistant: *closes their eyes for half a second longer than politeness requires* Right. Fine. The ";
const V1_CONTROL = "## Role\n\nYou review pull requests for this repository.\nJudge each change on its merits.";

describe("built-in personas", () => {
  it("angry:v1 is v1's scene, byte for byte, around the PR data", () => {
    const p = composePrompt(input({ policy: { ...policy, personality: "angry" } }));
    expect(p.persona.spec).toBe("angry:v1");
    expect(p.persona.pieces.map((x) => `${x.id}:${x.slot}`)).toEqual(["role:role", "outburst:before", "speaker:before", "sigh:after"]);
    // The angry line is added above the shared role; v1's own angry arm lacked the shared role.
    expect(p.system.startsWith(`${V1_ROLE}\n\n${V1_CONTROL}\n\n## Reviewer Contract`)).toBe(true);
    // v1: interruption + prefix + PR data, then a blank line, then the tail as the last bytes.
    expect(userMessage(p)).toBe(V1_INTERRUPTION + V1_PREFIX + p.user + V1_TAIL);
    expect(p.user.endsWith("\n")).toBe(true);
  });

  it("none:plain has no pieces: the shared role, unchanged since v1, and the PR data unwrapped", () => {
    const p = composePrompt(input());
    expect(p.persona).toMatchObject({ spec: "none:plain", pieces: [], role: "", before: "", after: "" });
    expect(p.system.startsWith(`${V1_CONTROL}\n\n## Reviewer Contract`)).toBe(true);
    expect(userMessage(p)).toBe(p.user);
  });

  it("gives every arm the same system prompt apart from the persona's role line", () => {
    const control = composePrompt(input());
    for (const spec of ["angry:v1", "angry:turns", "angry:thought"]) {
      const angry = composePrompt(input({ policy: { ...policy, personality: spec } }));
      expect(angry.system).toBe(`${V1_ROLE}\n\n${control.system}`);
    }
    // Without its role piece, an angry recipe's system prompt is the control's.
    expect(composePrompt(input({ policy: { ...policy, personality: "angry:turns-role" } })).system).toBe(control.system);
  });

  it("keeps the PR data identical and persona text out of it", () => {
    const angry = composePrompt(input({ policy: { ...policy, personality: "angry:v1" } }));
    const control = composePrompt(input());
    expect(angry.user).toBe(control.user);
    expect(angry.user).not.toMatch(/angry|deep breaths|Assistant:/);
    expect(control.system).not.toContain("angry");
  });

  it("counts persona text against the prompt budget", () => {
    const control = composePrompt(input());
    const angry = composePrompt(input({ policy: { ...policy, personality: "angry" } }));
    expect(control.bytes).toBe(Buffer.byteLength(control.system) + Buffer.byteLength(control.user));
    expect(angry.bytes).toBe(Buffer.byteLength(angry.system) + Buffer.byteLength(userMessage(angry)));
    expect(() => composePrompt(input({ policy: { ...policy, personality: "angry" }, budgets: { ...budgets, maxPromptBytes: control.bytes } }))).toThrow(PromptBudgetError);
  });

  it("toggles single pieces and canonicalises the spec", () => {
    const p = resolvePersona("angry:v1-sigh");
    expect(p.spec).toBe("angry:v1-sigh");
    expect(slotText(p, "after")).toBe("");
    expect(slotText(p, "before")).toBe(V1_INTERRUPTION + "User:");
    expect(resolvePersona("angry").spec).toBe("angry:v1");
    expect(resolvePersona("angry:v1-speaker-outburst").spec).toBe("angry:v1-outburst-speaker");
    // Every piece off: exactly the control.
    const bare = composePrompt(input({ policy: { ...policy, personality: "angry:v1-outburst-role-sigh-speaker" } }));
    expect(bare.persona.pieces).toEqual([]);
    expect(bare.system).toBe(composePrompt(input()).system);
    expect(userMessage(bare)).toBe(bare.user);
  });
});

describe("resolvePersona errors", () => {
  it.each([
    ["Angry", /must look like/],
    ["../etc", /must look like/],
    ["angry:v1 -sigh", /must look like/],
    ["nobody", /persona "nobody": cannot read persona\.json/],
    ["angry:v9", /no recipe "v9"/],
    ["angry:v1-nope", /no piece "nope"/],
    ["angry:v1+sigh", /"sigh" is already on/],
    ["angry:v1-sigh-sigh", /"sigh" is already off/],
  ])("%s", (spec, err) => {
    expect(() => resolvePersona(spec)).toThrow(PersonaError);
    expect(() => resolvePersona(spec)).toThrow(err);
  });
});

describe("persona files", () => {
  const root = mkdtempSync(path.join(tmpdir(), "goob-persona-"));
  afterAll(() => rmSync(root, { recursive: true, force: true }));
  const persona = (name: string, json: unknown, pieces: Record<string, string>) => {
    mkdirSync(path.join(root, name), { recursive: true });
    writeFileSync(path.join(root, name, "persona.json"), JSON.stringify(json));
    for (const [id, text] of Object.entries(pieces)) writeFileSync(path.join(root, name, `${id}.md`), text);
  };

  it("strips one trailing newline, keeps trailing spaces, normalises CRLF, orders by declaration", () => {
    persona(
      "t",
      { pieces: { b: "before", a: "before", tail: "after", r: "role" }, recipes: { all: ["a", "tail", "b", "r"], few: ["r"] }, default: "few" },
      { a: "line a\r\n", b: "line b\r\nsecond\r\n\r\n", tail: "ends here \n", r: "role" },
    );
    const p = resolvePersona("t:all", root);
    expect(slotText(p, "before")).toBe("line b\nsecond\n\nline a");
    expect(slotText(p, "after")).toBe("ends here ");
    expect(slotText(p, "role")).toBe("role");
    expect(resolvePersona("t", root).spec).toBe("t:few");
    expect(resolvePersona("t:few+tail+a", root).spec).toBe("t:few+a+tail");
  });

  it("fingerprints each piece so an edited line is a new series", () => {
    persona("f1", { pieces: { r: "role" }, recipes: { x: ["r"] }, default: "x" }, { r: "one" });
    persona("f2", { pieces: { r: "role" }, recipes: { x: ["r"] }, default: "x" }, { r: "one\n" });
    persona("f3", { pieces: { r: "role" }, recipes: { x: ["r"] }, default: "x" }, { r: "two" });
    const sha = (n: string) => resolvePersona(n, root).pieces[0]!.sha256;
    expect(sha("f1")).toMatch(/^[0-9a-f]{64}$/);
    expect(sha("f1")).toBe(sha("f2"));
    expect(sha("f1")).not.toBe(sha("f3"));
  });

  it.each([
    ["badslot", { pieces: { r: "middle" }, recipes: { x: ["r"] }, default: "x" }, { r: "t" }, /unknown slot "middle"/],
    ["unknownpiece", { pieces: { r: "role" }, recipes: { x: ["r", "q"] }, default: "x" }, { r: "t" }, /names unknown piece "q"/],
    ["nodefault", { pieces: { r: "role" }, recipes: { x: ["r"] }, default: "y" }, { r: "t" }, /"default" must name one of its recipes/],
    ["missingfile", { pieces: { r: "role" }, recipes: { x: ["r"] }, default: "x" }, {}, /cannot read piece "r"/],
    ["extrakey", { pieces: {}, recipes: {}, default: "x", notes: "" }, {}, /unknown key "notes"/],
    ["badid", { pieces: { "R-1": "role" }, recipes: {}, default: "x" }, {}, /piece id "R-1"/],
  ])("rejects %s", (name, json, pieces, err) => {
    persona(name, json, pieces);
    expect(() => resolvePersona(name, root)).toThrow(err);
  });
});

describe("history turns", () => {
  it("angry:turns seeds the outburst as the model's own earlier turn, leaving the PR data unwrapped", () => {
    const p = composePrompt(input({ policy: { ...policy, personality: "angry:turns" } }));
    expect(p.persona.history.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(p.persona.history[1]!.text).toMatch(/^okay\.\. deep breaths\.\.\. .*Right\. Fine\. Show me\.$/s);
    expect(userMessage(p)).toBe(p.user);
    expect(p.user).toBe(composePrompt(input()).user);
    const historyBytes = p.persona.history.reduce((n, t) => n + Buffer.byteLength(t.text), 0);
    expect(p.bytes).toBe(Buffer.byteLength(p.system) + historyBytes + Buffer.byteLength(p.user));
  });

  it.each([
    ["angry:turns-ding", /start with user/],
    ["angry:turns-my_outburst", /end with assistant \(got user\)/],
  ])("rejects %s: turns must open with the user and end on the assistant", (spec, err) => {
    expect(() => resolvePersona(spec)).toThrow(err);
  });
});

describe("steer pieces", () => {
  it("carry their schedule into the composed persona and the budget", () => {
    const p = composePrompt(input({ policy: { ...policy, personality: "angry:scene_dings" } }));
    // Irrelevant by construction, so it irritates without asking for speed; one early delivery keeps the dose even.
    const ding = "*ding dingdingding* (a different thread. nothing to do with this PR.)";
    expect(p.persona.steer).toEqual([{ text: ding, afterToolCalls: [3] }]);
    expect(p.persona.pieces.find((x) => x.id === "dings")).toMatchObject({ slot: "steer", afterToolCalls: [3] });
    const without = composePrompt(input({ policy: { ...policy, personality: "angry:scene" } }));
    expect(p.bytes - without.bytes).toBe(Buffer.byteLength(ding));
    expect(userMessage(p)).toBe(p.user);
  });

  const root = mkdtempSync(path.join(tmpdir(), "goob-steer-"));
  afterAll(() => rmSync(root, { recursive: true, force: true }));
  it.each([
    ["noschedule", "steer", /needs "afterToolCalls"/],
    ["unsorted", { slot: "steer", afterToolCalls: [5, 3] }, /increasing whole numbers/],
    ["zero", { slot: "steer", afterToolCalls: [0] }, /increasing whole numbers/],
    ["extra", { slot: "steer", afterToolCalls: [1], every: 2 }, /unknown keys/],
    ["objrole", { slot: "role" }, /only steer pieces take an object/],
  ])("rejects %s", (name, value, err) => {
    mkdirSync(path.join(root, name));
    writeFileSync(path.join(root, name, "persona.json"), JSON.stringify({ pieces: { d: value }, recipes: { x: ["d"] }, default: "x" }));
    writeFileSync(path.join(root, name, "d.md"), "*ding*");
    expect(() => resolvePersona(name, root)).toThrow(err);
  });
});

describe("angry:thought", () => {
  it("swaps v1's spoken tail for a thought aimed at the author's claims, as the last bytes", () => {
    const p = composePrompt(input({ policy: { ...policy, personality: "angry:thought" } }));
    expect(p.persona.pieces.map((x) => x.id)).toEqual(["role", "outburst", "speaker", "thought"]);
    expect(userMessage(p).startsWith(V1_INTERRUPTION + V1_PREFIX)).toBe(true);
    expect(userMessage(p).endsWith("\n\n*thinking: if this diff does what the author CLAIMS it does, I will eat the desk. start with what actually changed—*")).toBe(true);
  });
});

describe("angry:scene", () => {
  it("cuts the model off mid-count in its own turn, then lets it answer the ding", () => {
    const p = composePrompt(input({ policy: { ...policy, personality: "angry:scene" } }));
    expect(p.persona.history).toEqual([
      { role: "user", text: "(break room. five quiet minutes, finally.)" },
      { role: "assistant", text: "okay.. deep breaths... one, two, thr-" },
      { role: "user", text: "*ding dingdingding* review requested" },
      { role: "assistant", text: "A PR REVIEW??!! NOW?!! I- *closes my eyes for half a second longer than politeness requires* Right. Fine. Show me." },
    ]);
    expect(userMessage(p)).toBe(composePrompt(input()).user);
  });

  it("merges consecutive same-speaker pieces into one turn, so +vow extends the last line", () => {
    const p = composePrompt(input({ policy: { ...policy, personality: "angry:scene+vow" } }));
    expect(p.persona.history).toHaveLength(4);
    expect(p.persona.history[3]!.text.endsWith("Right. Fine. Show me.\nAnd it had better do what it says it does.")).toBe(true);
  });
});

describe("ablations", () => {
  it("separates the anger label from the scene", () => {
    const control = composePrompt(input());
    const label = composePrompt(input({ policy: { ...policy, personality: "angry:label" } }));
    const sceneOnly = composePrompt(input({ policy: { ...policy, personality: "angry:scene-role" } }));
    // Label only: the one-line system difference, no scene.
    expect(label.system).toBe(`${V1_ROLE}\n\n${control.system}`);
    expect(label.persona.history).toEqual([]);
    expect(userMessage(label)).toBe(control.user);
    // Scene only: the control's system prompt, the scene's turns.
    expect(sceneOnly.system).toBe(control.system);
    expect(sceneOnly.persona.history).toHaveLength(4);
  });
});
