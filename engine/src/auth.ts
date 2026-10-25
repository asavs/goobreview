// `goobreview auth`: add, inspect and remove model credentials. Logins are
// pi-ai's own provider flows; their result goes straight into the credential
// store. Keys are read with hidden input and nothing here prints a secret.

import { createInterface } from "node:readline";
import type { AuthEvent, AuthPrompt, AuthType, LoginOptions, Models } from "@earendil-works/pi-ai";
import { describeCredential } from "./credentials.js";
import type { ModelRef } from "./types.js";

export interface AuthIO {
  out(line: string): void;
  prompt(p: AuthPrompt): Promise<string>;
}

export class AuthCommandError extends Error {}

export async function authStatus(models: Models, chain: readonly ModelRef[], credentialsFile: string, io: AuthIO): Promise<void> {
  io.out(`credentials file: ${credentialsFile}`);
  io.out("");
  io.out("model chain (tried in order):");
  for (const [i, ref] of chain.entries()) {
    const name = `${i + 1}. ${ref.provider}/${ref.id}`;
    if (!models.getModel(ref.provider, ref.id)) {
      io.out(`  ${name}  unknown model`);
      continue;
    }
    const cred = await describeCredential(models, ref.provider);
    if (!cred) {
      io.out(`  ${name}  not configured: goobreview auth login ${ref.provider}`);
      continue;
    }
    const kind = cred.type === "oauth" ? (cred.subscription ? "subscription login" : "OAuth") : "API key";
    const note = cred.rewritesRequests ? "; pi rewrites the system prompt, not research-comparable" : "";
    io.out(`  ${name}  ready (${kind}, ${cred.source ?? "configured"}${note})`);
  }
}

export async function authLogin(
  models: Models,
  providerId: string,
  requested: AuthType | undefined,
  io: AuthIO,
  options: LoginOptions,
): Promise<AuthType> {
  const provider = models.getProvider(providerId);
  if (!provider) throw new AuthCommandError(`unknown provider "${providerId}"; see: goobreview auth providers`);
  const methods: { id: AuthType; label: string }[] = [];
  if (provider.auth.apiKey?.login) methods.push({ id: "api_key", label: provider.auth.apiKey.name });
  if (provider.auth.oauth) methods.push({ id: "oauth", label: provider.auth.oauth.loginLabel ?? provider.auth.oauth.name });
  if (methods.length === 0) throw new AuthCommandError(`${provider.name} uses ambient credentials only (environment or cloud identity)`);

  let type = requested;
  if (type === undefined) {
    type = methods.length === 1 ? methods[0]!.id : ((await io.prompt({ type: "select", message: `How should goobreview sign in to ${provider.name}?`, options: methods })) as AuthType);
  }
  if (!methods.some((m) => m.id === type)) throw new AuthCommandError(`${provider.name} does not support ${type === "oauth" ? "OAuth" : "API key"} login`);

  await models.login(providerId, type, { prompt: (p) => io.prompt(p), notify: (e) => io.out(renderEvent(e)) }, options);
  const cred = await describeCredential(models, providerId);
  io.out(`saved ${providerId} (${type === "oauth" ? "OAuth" : "API key"})`);
  if (cred?.rewritesRequests) io.out("note: this login rewrites the system prompt; its reviews are marked not research-comparable");
  return type;
}

export async function authLogout(models: Models, providerId: string, io: AuthIO): Promise<void> {
  if (!models.getProvider(providerId)) throw new AuthCommandError(`unknown provider "${providerId}"`);
  await models.logout(providerId);
  io.out(`removed stored credential for ${providerId}`);
}

export function authProviders(models: Models, io: AuthIO): void {
  for (const p of [...models.getProviders()].sort((a, b) => a.id.localeCompare(b.id))) {
    const ways = [p.auth.apiKey?.login ? "api key" : undefined, p.auth.oauth ? (p.auth.oauth.isSubscription ? "subscription login" : "oauth") : undefined]
      .filter(Boolean)
      .join(", ");
    io.out(`  ${p.id.padEnd(28)} ${p.name}${ways ? ` (${ways})` : " (ambient only)"}`);
  }
}

export function renderEvent(e: AuthEvent): string {
  switch (e.type) {
    case "auth_url":
      return `\nOpen this URL in a browser:\n  ${e.url}${e.instructions ? `\n${e.instructions}` : ""}`;
    case "device_code":
      return `\nOpen ${e.verificationUri} and enter the code: ${e.userCode}`;
    case "info":
      return [e.message, ...(e.links ?? []).map((l) => `  ${l.label ? `${l.label}: ` : ""}${l.url}`)].join("\n");
    case "progress":
      return e.message;
  }
}

// ---------------------------------------------------------------------------
// Terminal prompts. Prompts go to stderr so stdout carries only results.

export function terminalIO(
  input: NodeJS.ReadStream = process.stdin,
  output: NodeJS.WriteStream = process.stderr,
  results: NodeJS.WritableStream = process.stdout,
): AuthIO {
  // Piped input is read through one shared reader so buffered lines are not lost between prompts.
  let lines: AsyncIterator<string> | undefined;
  const nextPipedLine = async (): Promise<string> => {
    lines ??= createInterface({ input, terminal: false })[Symbol.asyncIterator]();
    const r = await lines.next();
    if (r.done) throw new AuthCommandError("input ended before the prompt was answered");
    return r.value;
  };

  const ask = async (message: string, signal?: AbortSignal): Promise<string> => {
    if (!input.isTTY) {
      output.write(message);
      return nextPipedLine();
    }
    const rl = createInterface({ input, output, terminal: true });
    try {
      return await new Promise<string>((resolve, reject) => {
        signal?.addEventListener("abort", () => reject(signal.reason), { once: true });
        rl.question(message, resolve);
      });
    } finally {
      rl.close();
    }
  };

  const askHidden = async (message: string): Promise<string> => {
    if (!input.isTTY) {
      output.write(message);
      return nextPipedLine();
    }
    output.write(message);
    input.setRawMode(true);
    input.setEncoding("utf8");
    input.resume();
    return new Promise<string>((resolve, reject) => {
      let buf = "";
      const finish = () => {
        input.off("data", onData);
        input.setRawMode(false);
        input.pause();
        output.write("\n");
      };
      const onData = (chunk: string) => {
        for (const ch of chunk) {
          if (ch === "\r" || ch === "\n") return finish(), resolve(buf);
          if (ch === "\u0003" || ch === "\u0004") return finish(), reject(new AuthCommandError("cancelled"));
          if (ch === "\u007f" || ch === "\b") buf = buf.slice(0, -1);
          else if (ch >= " ") buf += ch;
        }
      };
      input.on("data", onData);
    });
  };

  return {
    out: (line) => results.write(`${line}\n`),
    async prompt(p) {
      const hint = "placeholder" in p && p.placeholder ? ` (${p.placeholder})` : "";
      switch (p.type) {
        case "secret":
          for (;;) {
            const v = (await askHidden(`${p.message}${hint} (input hidden): `)).trim();
            if (v) return v;
            output.write("nothing entered; try again or press Ctrl-C\n");
          }
        case "select": {
          output.write(`${p.message}\n`);
          p.options.forEach((o, i) => output.write(`  ${i + 1}. ${o.label}${o.description ? ` - ${o.description}` : ""}\n`));
          for (;;) {
            const choice = p.options[Number((await ask(`choose 1-${p.options.length}: `, p.signal)).trim()) - 1];
            if (choice) return choice.id;
          }
        }
        case "text":
        case "manual_code":
          return (await ask(`${p.message}${hint}: `, p.signal)).trim();
      }
    },
  };
}
