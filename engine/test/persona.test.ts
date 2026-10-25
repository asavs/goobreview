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
    expect(p.system.startsWith(`${V1_ROLE}\n\n## Reviewer Contract`)).toBe(true);
    // v1: interruption + prefix + PR data, then a blank line, then the tail as the last bytes.
    expect(userMessage(p)).toBe(V1_INTERRUPTION + V1_PREFIX + p.user + V1_TAIL);
    expect(p.user.endsWith("\n")).toBe(true);
  });

  it("none:plain is the control role and leaves the PR data unwrapped", () => {
    const p = composePrompt(input());
    expect(p.persona).toMatchObject({ spec: "none:plain", role: V1_CONTROL, before: "", after: "" });
    expect(p.system.startsWith(`${V1_CONTROL}\n\n## Reviewer Contract`)).toBe(true);
    expect(userMessage(p)).toBe(p.user);
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
    // Every piece off: the system prompt starts at the contract.
    const bare = composePrompt(input({ policy: { ...policy, personality: "none:plain-role" } }));
    expect(bare.persona.pieces).toEqual([]);
    expect(bare.system.startsWith("## Reviewer Contract")).toBe(true);
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
