# Contributing

This template is intentionally small: shell scripts, prompt text, and setup docs for running a VM-side automated PR reviewer.

## Development Loop

1. Make one focused change.
2. Run syntax checks for changed shell scripts.
3. Run `git diff --check`.
4. Keep example config generic and safe to publish.
5. Open a PR that explains the target workflow and the checks run.

Useful checks:

```bash
bash -n scripts/reviewer/*.sh
jq . config/required-checks.example.json
git diff --check
```

## Forks And Reviewer Personalities

Forks are encouraged. The cleanest way to create a different reviewer personality or skillset is to change:

- `scripts/reviewer/review-prompt.md` for tone, severity policy, output format, and specialty.
- `config/project-docs.example.txt` for the project standards each review should enforce.
- `config/head-context-paths.example.txt` for extra files the reviewer should inspect.
- `config/required-checks.example.json` for CI gates.

Good fork themes:

- Security-focused reviewer.
- Frontend accessibility reviewer.
- Infrastructure/deployment reviewer.
- Test coverage reviewer.
- Language-specific reviewer for Rust, Python, TypeScript, Go, or Java.
- Documentation accuracy reviewer.

Keep forks honest about scope. If a reviewer is specialized, make the prompt say what it is good at and when it should use `COMMENT` instead of pretending to approve or block.

### Personalizing A Fork

Click **Use this template** on GitHub rather than **Fork**: it creates a fresh repo with full ownership, and `.github/workflows/template-cleanup.yml` runs once on the first push to rewrite every `asavschaeffer/goobreview` reference (Cloud Shell button URL, bootstrap script, clone URL) to your new `owner/repo`. After that first commit, the workflow becomes a self-suppressing no-op.

If you fork instead, the cleanup workflow won't fire until a push to `main`. Either make an empty commit or run a one-time `sed -i "s|asavschaeffer/goobreview|YOUR/REPO|g"` across `*.md`, `*.sh`, and `*.yml`.

## Prompt Contract

`reviewer.sh` expects Gemini to emit:

```text
VERDICT: APPROVE
```

or:

```text
VERDICT: REQUEST_CHANGES
```

or:

```text
VERDICT: COMMENT
```

The optional `REVIEW_META` block must stay valid JSON. Inline comments only work when metadata findings include a repository `path` and a right-side changed `line`.

## Safety Rules

- Do not commit real `config/reviewer.env` files.
- Do not add tokens, private keys, cloud credentials, or Gemini auth files.
- Do not hard-code private repository names in generic docs or examples.
- Keep local config ignored so `sync-worktree.sh` can safely update clean daemon checkouts.
- Avoid adding dependencies unless they materially improve reliability.

## Testing Real Reviews

Use `REVIEWER_DRY_RUN=1` first. Only post a real review after:

- `scripts/reviewer/get-installation-token.sh token` returns a token (proves the App credentials and installation are wired up).
- Gemini CLI works headlessly from the daemon checkout.
- The configured target repo is correct.
- Required check names match GitHub check-run display names.

