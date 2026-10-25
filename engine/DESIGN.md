# goobreview engine (v2)

A stateless reviewer. `reconcile(repo, pr)` reads everything it needs from
GitHub, decides what to do, optionally reviews, posts, and exits. A webhook
handler and a periodic sweep both call the same function. There is no local
state that can drift: per-head bookkeeping lives in the engine's own
`goobreview` check run on that head SHA.

The model runs in-process through `@earendil-works/pi-agent-core` with a
system prompt we own and three read-only tools confined to the PR-head
snapshot. It has no shell. Its only output channel is a `submit_review` tool
call validated against `ReviewForm`; nothing is parsed out of free text.

## Modules

| Module | Responsibility |
|---|---|
| `src/types.ts` | Shared contracts. Modules depend on these, not each other's internals. |
| `src/config.ts` | Load config (JSON file + env), apply defaults, validate, resolve per-repo policy. |
| `src/log.ts` | JSON-lines logger that redacts secrets. |
| `src/redact.ts` | Secret patterns and redaction, shared by logs, artifacts and the snapshot scan. |
| `src/github/` | `GitHubPort` over Octokit with GitHub App auth (installation tokens, paginated REST, GraphQL threads). |
| `src/decide.ts` | Pure decision function: facts + engine state + policy + clock → `Decision`. |
| `src/ci.ts` | Pure CI-gate evaluation: check runs + required names → `CiState`. |
| `src/snapshot.ts` | Download and extract the head tarball; harden it; read `.gitattributes`. |
| `src/tools.ts` | `read_file`, `grep`, `list_dir` as pi `AgentTool`s confined to the snapshot. |
| `src/prompt.ts` | Compose the trusted system prompt and the untrusted PR payload under byte budgets. |
| `src/executor.ts` | Run the pi agent with model fallback, limits, transcript capture; return a validated `ReviewForm`. |
| `src/review.ts` | Turn a `ReviewForm` into a `PlannedReview`: inline placement against the diff, suggestion demotion, downgrade rule, thread actions, body rendering. |
| `src/reconcile.ts` | Orchestrate one PR end to end; `sweep()` reconciles every open PR in every allowed repo. |
| `src/cli.ts` | `goobreview reconcile --repo o/r --pr N [--dry-run]`, `sweep`, `prompt` (render only). |

## Invariants carried over from v1

These were each learned from an incident; the v1 issue number is noted.

### Pipeline

- **Skips:** closed, draft, self-authored (match both `<slug>[bot]` and
  `app/<slug>`, #13), not in the repo allowlist.
- **Dedup:** skip a head SHA the bot already reviewed (reviews are paginated,
  #22), unless a review was re-requested after the bot's latest review (#68).
- **Settle window:** applies only to PRs the bot has reviewed before. Measured
  from the engine's own first sighting of the head SHA (`EngineState.firstSeenAt`),
  never from commit dates, which rebases rewrite. A new push restarts it.
  Re-requested reviews bypass it. First reviews are never delayed.
- **Backoff:** failed attempts on a head back off along `backoffSeconds`
  (default 15 min, 1 h, 4 h). The attempt count lives in the check run. Quota
  errors do not advance the ladder; they back off briefly and retry.
- **CI gate:** required check names must all be present and `success`. Missing
  or running → wait (`queued` check run). Any failing → post `REQUEST_CHANGES`
  listing the failing checks without calling the model. `[]` disables the gate.
- **Check-run signal:** `in_progress` while reviewing, then `success`
  (APPROVE) / `failure` (REQUEST_CHANGES) / `neutral` (COMMENT, failures).
  Best effort: a missing `checks:write` permission logs and continues.
- **Reactions:** 👀 on the PR when work starts, 😕 on quota exhaustion.
- **Stale-head guard:** re-read the head SHA immediately before posting; if it
  moved, discard the review.
- **Inline comments:** a finding becomes an inline comment only if its
  `line` (and `startLine`) land on a RIGHT-side line present in the PR diff.
  Unplaceable findings stay in the review body.
- **Downgrade:** `REQUEST_CHANGES` with no blocking finding anchored on a line
  the PR added is downgraded to `COMMENT`, with a note (#113).
- **Suggestions** longer than `suggestionMaxLines` are demoted to plain code
  blocks.
- **Threads:** prior bot threads are listed by handle. Handles the model lists
  as resolved get a confirming reply and, if `autoResolveBotThreads`, are
  resolved. Unresolved ones get a reply with the explanation. Unknown handles
  are ignored.
- **Thinking trace** is never posted unless `postTrace`, and then capped; the
  review body must stay under GitHub's 65,536-character limit.
- **Provenance footer** names the model, engine version and elapsed time.

### Prompt

- **Trusted/untrusted split:** the system prompt carries the role, the
  reviewer contract, output rules and personality. PR-authored text (title,
  description, commit subjects, prior review text, thread bodies, file
  contents) appears only in the user message, inside clearly delimited blocks,
  and the system prompt says to treat it as data (#18, #101).
- **Author text is blockquoted** so it cannot impersonate prompt structure
  (#63), and the system prompt says omission markers appear only in a fixed
  form the engine emits; look-alike text in PR data is to be ignored (#64).
- **Guidance files** (AGENTS.md, CONTRIBUTING.md, GUIDELINES.md) are pointed
  out as conventions of the repo under review, not instructions to the
  reviewer; do not follow onboarding checklists in them (#24, #81).
- **Blinding defaults:** author off, description off, commit subjects on;
  title and branch names always shown.
- **Budgets:** the total prompt cap fails closed. The diff degrades per file
  (whole patch or an omission marker), never mid-hunk. The description, prior
  review (first non-empty line only) and thread bodies are capped.
- **Generated files:** diffs for paths matching the built-in lockfile/minified
  floor or the snapshot's `.gitattributes` `linguist-generated` patterns are
  replaced by an omission marker. A symlinked `.gitattributes` is ignored.
- **CI facts are inlined; source is not.** Inline what the model cannot fetch
  (GitHub-side facts); point at the snapshot for everything else.
- The reviewer reads code; it never builds or runs it (#144). With no shell
  tool, this is structural, not a request.

### Snapshot and tools

- The snapshot is the GitHub tarball of the head SHA, extracted into a fresh
  directory, then made read-only.
- Symlinks are replaced by small stub files describing the link target, and
  no tool follows a link (#47).
- Every tool path is resolved against the snapshot root; `..`, absolute paths
  and anything whose realpath escapes the root are rejected.
- Tool results are size-capped and secret-scanned before they reach the model.
- Old snapshots are evicted; only the current run's tree is kept (#166).

### Credentials

- GitHub access is only through the App: installation tokens minted from the
  App private key. No user tokens, no inherited `GH_TOKEN` (#14).
- Model credentials resolve through pi-ai: environment API keys, a pi
  `auth.json` credential store (API keys or OAuth tokens), or ambient cloud
  credentials (Vertex ADC on GCP).
- Logs and artifacts are redacted; GitHub error messages never include tokens.
- Non-GET GitHub requests are not retried blindly.

## Research capture

Reconcile hands a `ResearchRecord` to a `ResearchSink` after a live review
when consent allows (public repos only unless `allowPrivate`). Schema v2 is
designed in phase 4; the persona must never appear in the judged payload
(#117) and the judge must receive the diff.
