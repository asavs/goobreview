# Publish As A Public Template Repository

This directory is ready to become its own public repository.

## Local Split

From the parent repo:

```bash
cp -R reviewer-daemon-template /tmp/goobreview
cd /tmp/goobreview
git init
git add .
git commit -m "Initial agent reviewer daemon template"
```

## Create The GitHub Repo

Using GitHub CLI:

```bash
gh repo create YOUR_ACCOUNT/goobreview \
  --public \
  --description "End-to-end PR reviewer powered by Gemini CLI and GitHub" \
  --source=. \
  --push
```

Then enable "Template repository" in GitHub repository settings.

## How Forks Personalize Themselves

This repo ships with `.github/workflows/template-cleanup.yml`, which runs once on the first push to `main` of any repo created via "Use this template". It rewrites every `asavschaeffer/goobreview` reference in `*.md`, `*.sh`, and `*.yml` to the new `owner/repo`, then commits. After that first commit, the workflow becomes a self-suppressing no-op (no matches → no diff → no commit).

If you are *forking* (rather than using the template), the workflow won't fire automatically until a push to `main`. You can either trigger it with an empty commit, or run `scripts/personalize.sh OWNER/REPO` (if present) locally.

The upstream repo itself is guarded by `if: github.repository != 'asavschaeffer/goobreview'`, so the job is skipped on upstream pushes.

## Keep Private Details Out

Before publishing, check:

```bash
git grep -n "PRIVATE_OWNER\\|PRIVATE_REPO\\|PRIVATE_IP\\|PRIVATE_NAME" || true
git diff --check
```

Do not publish ignored local config files such as `config/reviewer.env`, `config/project-docs.txt`, `config/head-context-paths.txt`, or `config/required-checks.json` if they contain private repository names, machine paths, or account-specific state.
