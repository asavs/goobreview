import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createFileCredentialStore, createModelsCollection } from "../src/credentials.js";

let dir: string;
const fresh = () => (dir = mkdtempSync(path.join(tmpdir(), "goob-cred-")));
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe("createFileCredentialStore", () => {
  it("round-trips credentials in pi auth.json format", async () => {
    const file = path.join(fresh(), "nested", "auth.json");
    const store = createFileCredentialStore(file);
    expect(await store.read("google")).toBeUndefined();
    await store.modify("google", async () => ({ type: "api_key", key: "k1" }));
    await store.modify("anthropic", async () => ({ type: "oauth", access: "a", refresh: "r", expires: 1 }));
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({
      google: { type: "api_key", key: "k1" },
      anthropic: { type: "oauth", access: "a", refresh: "r", expires: 1 },
    });
    expect(await createFileCredentialStore(file).read("anthropic")).toMatchObject({ refresh: "r" });
    expect(await store.list()).toEqual([
      { providerId: "google", type: "api_key" },
      { providerId: "anthropic", type: "oauth" },
    ]);
    await store.delete("google");
    expect(await store.read("google")).toBeUndefined();
  });

  it("leaves the entry unchanged when fn returns undefined and passes the current value", async () => {
    const file = path.join(fresh(), "auth.json");
    writeFileSync(file, JSON.stringify({ openai: { type: "api_key", key: "old" } }));
    const store = createFileCredentialStore(file);
    const seen: unknown[] = [];
    const out = await store.modify("openai", async (cur) => (seen.push(cur), undefined));
    expect(seen).toEqual([{ type: "api_key", key: "old" }]);
    expect(out).toEqual({ type: "api_key", key: "old" });
  });

  it("writes atomically: serialized writers, no temp or lock files left behind", async () => {
    const file = path.join(fresh(), "auth.json");
    const store = createFileCredentialStore(file);
    await Promise.all(
      Array.from({ length: 10 }, (_, i) => store.modify(`p${i}`, async () => ({ type: "api_key", key: String(i) }))),
    );
    expect(Object.keys(JSON.parse(readFileSync(file, "utf8")))).toHaveLength(10);
    expect(readdirSync(dir)).toEqual(["auth.json"]);
  });

  it.skipIf(process.platform === "win32")("creates the file with mode 0600", async () => {
    const file = path.join(fresh(), "auth.json");
    await createFileCredentialStore(file).modify("x", async () => ({ type: "api_key", key: "k" }));
    expect(statSync(file).mode & 0o777).toBe(0o600);
  });

  it("rejects malformed JSON without echoing its contents", async () => {
    const file = path.join(fresh(), "auth.json");
    writeFileSync(file, "{ secret-ish");
    await expect(createFileCredentialStore(file).read("x")).rejects.toThrow(/not valid JSON$/);
  });
});

describe("createModelsCollection", () => {
  it("registers the providers the engine needs", () => {
    fresh();
    const ids = createModelsCollection({}).getProviders().map((p) => p.id);
    for (const id of ["google", "google-vertex", "anthropic", "openai", "openrouter"]) expect(ids).toContain(id);
  });
});
