// Secret patterns shared by logs, artifacts and tool results. Ported from v1's
// artifact_secret_scan, widened to the token shapes we can recognise without
// context. Each pattern is rebuilt per call so global-flag state never leaks.

interface SecretPattern {
  name: string;
  source: string;
  flags: string;
  /** Replace only this capture group (1-based) and keep the rest; default: whole match. */
  valueGroup?: number;
}

// Names of variables whose literal values are credentials (v1 list). The value
// must be literal: one starting with `$` is a reference (`${{ secrets.X }}`,
// `$GH_TOKEN`) and is left alone, or every workflow diff would false-positive.
const CREDENTIAL_VARS = [
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "GITHUB_PAT",
  "REVIEWER_APP_PRIVATE_KEY_PATH",
  "GEMINI_API_KEY",
  "GOOGLE_API_KEY",
  "GOOGLE_APPLICATION_CREDENTIALS",
  "GOOGLE_CLOUD_PROJECT",
  "GCLOUD_PROJECT",
  "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE",
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "AWS_SESSION_TOKEN",
  "AZURE_CLIENT_SECRET",
  "OPENAI_API_KEY",
  "ANTHROPIC_API_KEY",
];

const PATTERNS: SecretPattern[] = [
  {
    // A key block, or an unterminated one (e.g. cut by an upstream cap): eat the
    // base64 body that follows the BEGIN line.
    name: "private-key",
    source:
      "-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----(?:[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|[A-Za-z0-9+/=\\s:,.-]*)",
    flags: "g",
  },
  { name: "github-token", source: "\\bgh[pousr]_[A-Za-z0-9]{36,255}\\b", flags: "g" },
  { name: "github-pat", source: "\\bgithub_pat_[A-Za-z0-9_]{22,255}\\b", flags: "g" },
  { name: "anthropic-key", source: "\\bsk-ant-[A-Za-z0-9_-]{20,}", flags: "g" },
  { name: "openai-key", source: "\\bsk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}", flags: "g" },
  { name: "aws-access-key", source: "\\b(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\\b", flags: "g" },
  {
    name: "aws-secret-key",
    source: "(aws_?secret_?(?:access_?)?key[\"']?\\s*[:=]\\s*[\"']?)([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])",
    flags: "gi",
    valueGroup: 2,
  },
  { name: "google-api-key", source: "\\bAIza[0-9A-Za-z_-]{35}", flags: "g" },
  { name: "slack-token", source: "\\bxox[abposr]-[A-Za-z0-9-]{10,}", flags: "g" },
  { name: "slack-webhook", source: "https://hooks\\.slack\\.com/services/[A-Za-z0-9/_-]{20,}", flags: "g" },
  {
    name: "bearer-token",
    source: "(\\bBearer\\s+)([A-Za-z0-9._~+/-]{16,}=*)",
    flags: "gi",
    valueGroup: 2,
  },
  {
    name: "credential-assignment",
    source: `((?:^|[^A-Za-z0-9_])(?:${CREDENTIAL_VARS.join("|")})["']?[ \\t]*[:=][ \\t]*["']?)([^\\s'",$[][^\\s'",]{2,})`,
    flags: "gi",
    valueGroup: 2,
  },
];

const compile = (p: SecretPattern): RegExp => new RegExp(p.source, p.flags);

/** Names of the secret patterns present in `text` (each at most once). */
export function findSecrets(text: string): string[] {
  const found: string[] = [];
  for (const p of PATTERNS) {
    if (text.search(compile(p)) !== -1) found.push(p.name);
  }
  return found;
}

/** `text` with every recognised secret replaced by `[REDACTED:<pattern>]`. */
export function redact(text: string): string {
  let out = text;
  for (const p of PATTERNS) {
    const marker = `[REDACTED:${p.name}]`;
    const group = p.valueGroup;
    out =
      group === undefined
        ? out.replace(compile(p), marker)
        : out.replace(compile(p), (...m: string[]) => {
            // Keep everything before the value group (the variable name, `Bearer `).
            let prefix = "";
            for (let i = 1; i < group; i++) prefix += m[i] ?? "";
            return prefix + marker;
          });
  }
  return out;
}

const KEY_BEGIN = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----/;
const KEY_END = /-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----/;

/**
 * `redact` for a unified-diff patch, one line at a time so the line count and
 * every line's +/-/space prefix survive (prompt line numbering depends on
 * both). A key block spanning lines has every line replaced, through its END
 * line or the end of the hunk.
 */
export function redactPatch(patch: string): string {
  let inKey = false;
  return patch
    .split("\n")
    .map((line) => {
      if (line.startsWith("@@")) {
        inKey = false;
        return redact(line);
      }
      const prefix = line.slice(0, 1);
      const body = line.slice(1);
      if (inKey) {
        if (KEY_END.test(body)) inKey = false;
        return `${prefix}[REDACTED:private-key]`;
      }
      if (KEY_BEGIN.test(body) && !KEY_END.test(body)) {
        inKey = true;
        return `${prefix}[REDACTED:private-key]`;
      }
      return prefix + redact(body);
    })
    .join("\n");
}

/**
 * Longest prefix of `text` within `maxBytes` UTF-8 bytes, never splitting a
 * code point. Shared by every byte-capped surface (tool results, prompt).
 */
export function truncateUtf8(text: string, maxBytes: number): string {
  if (maxBytes <= 0) return "";
  const buf = Buffer.from(text, "utf8");
  if (buf.length <= maxBytes) return text;
  let end = maxBytes;
  // Back up over continuation bytes (10xxxxxx) to a code-point boundary.
  while (end > 0 && ((buf[end] ?? 0) & 0xc0) === 0x80) end--;
  return buf.subarray(0, end).toString("utf8");
}
