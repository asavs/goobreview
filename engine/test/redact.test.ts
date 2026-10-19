import { describe, expect, it } from "vitest";
import { findSecrets, redact, truncateUtf8 } from "../src/redact.js";

const gh = "ghp_" + "A1b2C3d4E5".repeat(4);

describe("redact", () => {
  const cases: [string, string][] = [
    ["github-token", `token ${gh} here`],
    ["github-token", "ghs_" + "x".repeat(36)],
    ["github-pat", "github_pat_" + "11ABCDEFG0".repeat(4)],
    ["private-key", "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabc==\n-----END RSA PRIVATE KEY-----"],
    ["private-key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA"],
    ["aws-access-key", "AKIAIOSFODNN7EXAMPLE"],
    ["aws-secret-key", "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"],
    ["google-api-key", "key=AIza" + "S".repeat(35)],
    ["slack-token", "xoxb-1234567890-abcdefghij"],
    ["bearer-token", "Authorization: Bearer abcdefghijklmnop1234"],
    ["openai-key", "sk-proj-" + "a".repeat(40)],
    ["anthropic-key", "sk-ant-api03-" + "b".repeat(40)],
    ["credential-assignment", "GITHUB_TOKEN: should_not_be_written"],
  ];

  it.each(cases)("finds and redacts %s", (name, text) => {
    expect(findSecrets(text)).toContain(name);
    const out = redact(text);
    expect(out).toContain(`[REDACTED:${name}]`);
    expect(findSecrets(out)).toEqual([]);
  });

  it("keeps context around replaced values", () => {
    expect(redact("Authorization: Bearer abcdefghijklmnop1234")).toBe("Authorization: Bearer [REDACTED:bearer-token]");
    expect(redact("export GH_TOKEN=hunter2hunter2")).toBe("export GH_TOKEN=[REDACTED:credential-assignment]");
  });

  it("leaves variable references and ordinary text alone", () => {
    const benign = [
      "GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}",
      'GH_TOKEN="$GH_TOKEN"',
      "Bearer $JWT",
      "the task-runner sk-learn",
      "const ghp = 'ghp_short';",
    ].join("\n");
    expect(findSecrets(benign)).toEqual([]);
    expect(redact(benign)).toBe(benign);
  });

  it("is stable across repeated calls (no shared regex state)", () => {
    expect(findSecrets(gh)).toEqual(["github-token"]);
    expect(findSecrets(gh)).toEqual(["github-token"]);
  });
});

describe("truncateUtf8", () => {
  it("never splits a code point", () => {
    expect(truncateUtf8("aé", 2)).toBe("a");
    expect(truncateUtf8("aé", 3)).toBe("aé");
    expect(truncateUtf8("€€", 4)).toBe("€");
  });
});
