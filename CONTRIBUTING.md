# Contributing

This template is intentionally small: shell scripts, prompt text, and setup docs for running a VM-side automated PR reviewer.

## Development Loop

1. Make one focused change.
2. Run the canonical Linux validation command.
3. Run `git diff --check`.
4. Keep example config generic and safe to publish.
5. Open a PR that explains the target workflow and the checks run.

Canonical local validation:

```bash
set -euo pipefail
mapfile -t shell_files < <(git ls-files '*.sh')
bash -n "${shell_files[@]}"
bash scripts/reviewer/tests/run-fixtures.sh
mapfile -t json_files < <(git ls-files '*.json')
for file in "${json_files[@]}"; do jq -e . "$file" >/dev/null; done
if command -v shellcheck >/dev/null; then shellcheck "${shell_files[@]}"; else echo "shellcheck not installed; skipping"; fi
git diff --check
```

The GitHub Actions workflow in `.github/workflows/linux-validation.yml` runs
the same required checks on Ubuntu and installs `jq` through apt. It also
enforces ShellCheck when apt can provide it; local runs may skip ShellCheck if
it is not installed. The fixture runner covers reviewer-core parser, prompt,
and CI-gate behavior without GitHub credentials, Gemini auth, or network
access. Run the shell checks from Linux or a working WSL environment; a
Windows host with no WSL distribution is not authoritative for Bash syntax.

## Forks And Reviewer Personalities

Forks are encouraged. The reviewer is designed to be specialized through
**config files**, not by editing scripts. To change personality, edit (in
order of impact):

1. `config/personalities/<name>.md` — role, voice, focus areas. Add new personalities by dropping a `.md` file in this directory. Existing entries (e.g. `linus.md`, `control.md`) are committed verbatim; pick one via `REVIEWER_PERSONALITY_FILE` in `reviewer.env`. (The severity scale and verdict mapping live in the engine prompt, not here.)
2. `config/project-docs.example.txt` — repo paths whose contents the reviewer should treat as your house standards.
3. `config/head-context-paths.example.txt` — extra files the reviewer should fetch to ground itself against PR-head reality.
4. `config/required-checks.example.json` — CI gates that must pass before the reviewer calls Gemini.

Edit the `.example.*` siblings in your fork. End users will copy them to
their non-example names with `scripts/configure.sh`. (Personalities are the
exception — gallery files have no `.example` layer; users select an existing
gallery entry or write a new one and PR it.)

Keep forks honest about scope. If a reviewer is specialized, make the
personality file say what it is good at and when it should use `COMMENT`
instead of pretending to approve or block.

The engine prompt at `scripts/reviewer/review-prompt.md` owns the
verdict-line format and markdown review shape that `reviewer.sh`
parses. Don't edit it unless you are intentionally changing the engine's
output contract.

### Personalizing A Fork

Click **Use this template** on GitHub rather than **Fork**: it creates a fresh repo with full ownership, and `.github/workflows/template-cleanup.yml` runs once on the first push to rewrite every `asavschaeffer/goobreview` reference (Cloud Shell button URL, bootstrap script, clone URL) to your new `owner/repo`. After that first commit, the workflow becomes a self-suppressing no-op.

If you fork instead, the cleanup workflow won't fire until a push to `main`. Either make an empty commit or run a one-time `sed -i "s|asavschaeffer/goobreview|YOUR/REPO|g"` across `*.md`, `*.sh`, and `*.yml`.

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

