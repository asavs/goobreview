import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { AuthPrompt } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { AuthCommandError, authLogin, authLogout, authStatus, type AuthIO } from "../src/auth.js";
import { main } from "../src/cli.js";
import { createModelsCollection, credentialsPath, describeCredential, installationId } from "../src/credentials.js";

let dir: string;
const fresh = () => (dir = mkdtempSync(path.join(tmpdir(), "goob-auth-")));
afterEach(() => rmSync(dir, { recursive: true, force: true }));

function scriptedIO(answers: string[]) {
  const lines: string[] = [];
  const prompts: AuthPrompt[] = [];
  const io: AuthIO = {
    out: (l) => lines.push(l),
    prompt: async (p) => {
      prompts.push(p);
      const a = answers.shift();
      if (a === undefined) throw new Error(`unexpected prompt: ${p.message}`);
      return a;
    },
  };
  return { io, lines, prompts };
}

const LOGIN = { agentName: "goobreview", getDeviceId: () => "test-device" };

describe("authLogin", () => {
  it("stores an API key through a hidden prompt and never echoes it", async () => {
    const file = path.join(fresh(), "auth.json");
    const models = createModelsCollection({ credentialsFile: file });
    const { io, lines, prompts } = scriptedIO(["sk-test-SECRET"]);
    expect(await authLogin(models, "openai", "api_key", io, LOGIN)).toBe("api_key");
    expect(prompts.map((p) => p.type)).toEqual(["secret"]);
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({ openai: { type: "api_key", key: "sk-test-SECRET" } });
    expect(lines.join("\n")).not.toContain("SECRET");
    if (process.platform !== "win32") expect(statSync(file).mode & 0o777).toBe(0o600);
  });

  it("asks which method when a provider offers both", async () => {
    const file = path.join(fresh(), "auth.json");
    const { io, prompts } = scriptedIO(["api_key", "sk-ant-x"]);
    await authLogin(createModelsCollection({ credentialsFile: file }), "anthropic", undefined, io, LOGIN);
    expect(prompts[0]).toMatchObject({ type: "select" });
    expect((prompts[0] as Extract<AuthPrompt, { type: "select" }>).options.map((o) => o.id)).toEqual(["api_key", "oauth"]);
  });

  it("rejects unknown providers and unsupported methods", async () => {
    const models = createModelsCollection({ credentialsFile: path.join(fresh(), "auth.json") });
    const { io } = scriptedIO([]);
    await expect(authLogin(models, "nope", undefined, io, LOGIN)).rejects.toThrow(AuthCommandError);
    await expect(authLogin(models, "google", "oauth", io, LOGIN)).rejects.toThrow(/does not support OAuth/);
  });

  it("logout removes the stored credential", async () => {
    const file = path.join(fresh(), "auth.json");
    writeFileSync(file, JSON.stringify({ openai: { type: "api_key", key: "k" } }));
    await authLogout(createModelsCollection({ credentialsFile: file }), "openai", scriptedIO([]).io);
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({});
  });
});

describe("credential description", () => {
  it("flags Anthropic subscription logins as rewriting requests", async () => {
    const file = path.join(fresh(), "auth.json");
    const future = Date.now() + 3_600_000;
    writeFileSync(
      file,
      JSON.stringify({
        anthropic: { type: "oauth", access: "a", refresh: "r", expires: future },
        openai: { type: "oauth", access: "a", refresh: "r", expires: future },
      }),
    );
    const models = createModelsCollection({ credentialsFile: file });
    expect(await describeCredential(models, "anthropic")).toMatchObject({ type: "oauth", subscription: true, rewritesRequests: true });
    expect(await describeCredential(models, "openai")).toMatchObject({ type: "oauth", subscription: true, rewritesRequests: false });
  });

  it("status reports each chain model without printing values", async () => {
    const file = path.join(fresh(), "auth.json");
    writeFileSync(file, JSON.stringify({ openai: { type: "api_key", key: "sk-VALUE" } }));
    const models = createModelsCollection({ credentialsFile: file });
    const openaiModel = models.getModels("openai")[0]!;
    const { io, lines } = scriptedIO([]);
    await authStatus(models, [{ provider: "openai", id: openaiModel.id, thinking: "low" }, { provider: "openai", id: "no-such-model", thinking: "low" }], file, io);
    const text = lines.join("\n");
    expect(text).toContain(`1. openai/${openaiModel.id}  ready (API key, stored credential)`);
    expect(text).toContain("2. openai/no-such-model  unknown model");
    expect(text).not.toContain("sk-VALUE");
  });

  it("status lists every stored credential by provider, even one no configured model uses", async () => {
    const file = path.join(fresh(), "auth.json");
    writeFileSync(file, JSON.stringify({ openai: { type: "api_key", key: "sk-A" }, openrouter: { type: "api_key", key: "sk-or-B" } }));
    const models = createModelsCollection({ credentialsFile: file });
    const openaiModel = models.getModels("openai")[0]!;
    const { io, lines } = scriptedIO([]);
    const chain = [{ provider: "openai", id: openaiModel.id, thinking: "low" as const }];
    await authStatus(models, chain, file, io);
    expect(lines).toContain("stored credentials:");
    expect(lines).toContain(`  openai  API key; used by openai/${openaiModel.id}`);
    expect(lines).toContain("  openrouter  API key; used by no configured model");

    // Once a research arm uses it, the arm model is listed and the credential names it.
    const arm = { provider: "openrouter", id: "deepseek/deepseek-v4-pro", thinking: "high" as const };
    lines.length = 0;
    await authStatus(models, chain, file, io, [chain[0]!, arm]);
    expect(lines).toContain("research arm models (not in the chain):");
    expect(lines.some((l) => l.startsWith("  1. openrouter/deepseek/deepseek-v4-pro  ready (API key"))).toBe(true);
    expect(lines).toContain("  openrouter  API key; used by openrouter/deepseek/deepseek-v4-pro");
    expect(lines.join("\n")).not.toMatch(/sk-/);
  });
});

describe("credentials paths", () => {
  it("defaults under XDG_CONFIG_HOME and honours the override", () => {
    expect(credentialsPath({ XDG_CONFIG_HOME: "/x" })).toBe(path.join("/x", "goobreview", "auth.json"));
    expect(credentialsPath({ GOOBREVIEW_CREDENTIALS_FILE: "/y/a.json", XDG_CONFIG_HOME: "/x" })).toBe("/y/a.json");
  });

  it("keeps the installation id stable", async () => {
    const file = path.join(fresh(), "sub", "auth.json");
    const id = await installationId(file);
    expect(id).toMatch(/^[0-9a-f-]{36}$/);
    expect(await installationId(file)).toBe(id);
  });
});

describe("cli auth", () => {
  it("validates arguments", async () => {
    const env = { GOOBREVIEW_CREDENTIALS_FILE: path.join(fresh(), "auth.json") };
    const { io } = scriptedIO([]);
    expect(await main(["auth", "login"], env, io)).toBe(2);
    expect(await main(["auth", "status", "openai"], env, io)).toBe(2);
    expect(await main(["auth", "login", "openai", "--api-key", "--oauth"], env, io)).toBe(2);
    expect(await main(["reconcile", "--api-key"], env, io)).toBe(2);
  });

  it("logs in with an API key end to end", async () => {
    const file = path.join(fresh(), "auth.json");
    const { io } = scriptedIO(["sk-cli"]);
    expect(await main(["auth", "login", "openai", "--api-key"], { GOOBREVIEW_CREDENTIALS_FILE: file }, io)).toBe(0);
    expect(JSON.parse(readFileSync(file, "utf8")).openai).toEqual({ type: "api_key", key: "sk-cli" });
  });
});
