// Personas as data: pieces of text, each placed in one slot of the
// conversation, switched on by a recipe and toggled per spec. The format is
// documented in personas/README.md. Persona text is trusted (it ships with
// the engine); it never contains PR-authored text.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { PersonaPiece, PersonaSteer, PersonaTurn, PieceSlot } from "./types.js";

/** Built-in personas, beside src/ and dist/. */
export const PERSONAS_DIR = fileURLToPath(new URL("../personas/", import.meta.url));

export const SLOTS: readonly PieceSlot[] = ["role", "history.user", "history.assistant", "before", "after", "steer"];

const NAME = /^[a-z][a-z0-9_]*$/;
const SPEC = /^([a-z][a-z0-9_]*)(?::([a-z0-9_]+))?((?:[+-][a-z][a-z0-9_]*)*)$/;

export class PersonaError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PersonaError";
  }
}

interface PersonaFile {
  /** Pieces in placement order; steer pieces carry their schedule. */
  pieces: { id: string; slot: PieceSlot; afterToolCalls?: number[] }[];
  recipes: Map<string, Set<string>>;
  default: string;
}

export interface ResolvedPersona {
  /** Canonical spec: "<name>:<recipe>" then sorted "-off" and "+on" toggles. */
  spec: string;
  pieces: (PersonaPiece & { text: string })[];
}

const cache = new Map<string, PersonaFile & { texts: Map<string, string> }>();

function loadFile(dir: string, name: string): PersonaFile & { texts: Map<string, string> } {
  const key = path.join(dir, name);
  const hit = cache.get(key);
  if (hit) return hit;
  const where = `persona "${name}"`;
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path.join(dir, name, "persona.json"), "utf8"));
  } catch (err) {
    throw new PersonaError(`${where}: cannot read persona.json (${(err as Error).message})`);
  }
  const obj = raw as Record<string, unknown>;
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new PersonaError(`${where}: persona.json must be an object`);
  for (const k of Object.keys(obj)) {
    if (!["pieces", "recipes", "default"].includes(k)) throw new PersonaError(`${where}: unknown key "${k}"`);
  }
  const piecesRaw = obj.pieces as Record<string, unknown> | undefined;
  if (typeof piecesRaw !== "object" || piecesRaw === null || Array.isArray(piecesRaw)) throw new PersonaError(`${where}: "pieces" must map piece ids to slots`);
  const pieces: PersonaFile["pieces"] = [];
  const texts = new Map<string, string>();
  for (const [id, value] of Object.entries(piecesRaw)) {
    if (!NAME.test(id)) throw new PersonaError(`${where}: piece id "${id}" must match ${NAME}`);
    // A slot name, or for steer {"slot": "steer", "afterToolCalls": [5, 15]}.
    const isObj = typeof value === "object" && value !== null && !Array.isArray(value);
    const slot = isObj ? (value as Record<string, unknown>).slot : value;
    if (!SLOTS.includes(slot as PieceSlot)) throw new PersonaError(`${where}: piece "${id}" has unknown slot "${String(slot)}" (expected one of ${SLOTS.join(", ")})`);
    let afterToolCalls: number[] | undefined;
    if (slot === "steer") {
      const v = value as Record<string, unknown>;
      const at = isObj ? v.afterToolCalls : undefined;
      if (isObj && Object.keys(v).some((k) => k !== "slot" && k !== "afterToolCalls")) throw new PersonaError(`${where}: piece "${id}" has unknown keys`);
      if (!Array.isArray(at) || at.length === 0 || !at.every((n, i) => Number.isInteger(n) && n >= 1 && (i === 0 || n > (at[i - 1] as number)))) {
        throw new PersonaError(`${where}: steer piece "${id}" needs "afterToolCalls": increasing whole numbers >= 1`);
      }
      afterToolCalls = at as number[];
    } else if (isObj) {
      throw new PersonaError(`${where}: piece "${id}": only steer pieces take an object; use the slot name`);
    }
    let text: string;
    try {
      text = readFileSync(path.join(dir, name, `${id}.md`), "utf8");
    } catch (err) {
      throw new PersonaError(`${where}: cannot read piece "${id}" (${(err as Error).message})`);
    }
    // One trailing newline is the file's, not the piece's; trailing spaces are kept.
    texts.set(id, text.replace(/\r\n?/g, "\n").replace(/\n$/, ""));
    pieces.push({ id, slot: slot as PieceSlot, ...(afterToolCalls ? { afterToolCalls } : {}) });
  }
  const recipesRaw = obj.recipes as Record<string, unknown> | undefined;
  if (typeof recipesRaw !== "object" || recipesRaw === null || Array.isArray(recipesRaw)) throw new PersonaError(`${where}: "recipes" must map recipe names to piece lists`);
  const recipes = new Map<string, Set<string>>();
  for (const [recipe, list] of Object.entries(recipesRaw)) {
    if (!/^[a-z0-9_]+$/.test(recipe)) throw new PersonaError(`${where}: recipe name "${recipe}" must be lowercase letters, digits and _`);
    if (!Array.isArray(list) || !list.every((p) => typeof p === "string")) throw new PersonaError(`${where}: recipe "${recipe}" must be a list of piece ids`);
    for (const p of list) if (!texts.has(p)) throw new PersonaError(`${where}: recipe "${recipe}" names unknown piece "${p}"`);
    recipes.set(recipe, new Set(list));
  }
  if (typeof obj.default !== "string" || !recipes.has(obj.default)) throw new PersonaError(`${where}: "default" must name one of its recipes`);
  const file = { pieces, recipes, default: obj.default, texts };
  cache.set(key, file);
  return file;
}

/** Parse, load and canonicalise a persona spec. Unknown names, recipes and pieces are errors, never skipped. */
export function resolvePersona(spec: string, dir: string = PERSONAS_DIR): ResolvedPersona {
  const m = SPEC.exec(spec);
  if (!m) throw new PersonaError(`persona spec "${spec}" must look like name[:recipe][+piece|-piece]...`);
  const [, name, recipeName, toggles] = m as unknown as [string, string, string | undefined, string];
  const file = loadFile(dir, name);
  const recipe = recipeName ?? file.default;
  const base = file.recipes.get(recipe);
  if (!base) throw new PersonaError(`persona "${name}" has no recipe "${recipe}" (has ${[...file.recipes.keys()].join(", ")})`);
  const on = new Set(base);
  const removed: string[] = [];
  const added: string[] = [];
  for (const t of toggles.match(/[+-][a-z0-9_]+/g) ?? []) {
    const id = t.slice(1);
    if (!file.texts.has(id)) throw new PersonaError(`persona "${name}" has no piece "${id}"`);
    if (t[0] === "-") {
      if (!on.has(id)) throw new PersonaError(`persona spec "${spec}": "${id}" is already off`);
      on.delete(id);
      removed.push(id);
    } else {
      if (on.has(id)) throw new PersonaError(`persona spec "${spec}": "${id}" is already on`);
      on.add(id);
      added.push(id);
    }
  }
  const canonical = `${name}:${recipe}${removed.sort().map((id) => `-${id}`).join("")}${added.sort().map((id) => `+${id}`).join("")}`;
  const resolved: ResolvedPersona = {
    spec: canonical,
    pieces: file.pieces
      .filter((p) => on.has(p.id))
      .map((p) => {
        const text = file.texts.get(p.id)!;
        return { ...p, sha256: createHash("sha256").update(text).digest("hex"), text };
      }),
  };
  // The PR data is the next user message, so seeded turns must alternate,
  // open with the user and leave the last word to the assistant.
  const roles = historyTurns(resolved).map((t) => t.role);
  if (roles.length > 0 && (roles[0] !== "user" || roles.at(-1) !== "assistant" || roles.some((r, i) => i > 0 && r === roles[i - 1]))) {
    throw new PersonaError(`persona spec "${spec}": history turns must alternate user/assistant, starting with user and ending with assistant (got ${roles.join(", ")})`);
  }
  return resolved;
}

/** Seeded conversation turns, in placement order, before the PR data. */
export function historyTurns(persona: ResolvedPersona): PersonaTurn[] {
  return persona.pieces.flatMap((p): PersonaTurn[] =>
    p.slot === "history.user" ? [{ role: "user" as const, text: p.text }] : p.slot === "history.assistant" ? [{ role: "assistant" as const, text: p.text }] : [],
  );
}

/** Messages delivered mid-run, each after the given counts of completed tool calls. */
export function steerMessages(persona: ResolvedPersona): PersonaSteer[] {
  return persona.pieces.flatMap((p) => (p.slot === "steer" && p.afterToolCalls ? [{ text: p.text, afterToolCalls: p.afterToolCalls }] : []));
}

/** Text of one slot: its pieces joined by newlines, or "" when none are on. */
export function slotText(persona: ResolvedPersona, slot: PieceSlot): string {
  return persona.pieces
    .filter((p) => p.slot === slot)
    .map((p) => p.text)
    .join("\n");
}
