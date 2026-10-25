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
| `src/persona.ts` | Load persona pieces (`personas/`) and resolve a spec such as `angry:v1-sigh` to the pieces it switches on. |
| `src/steering.ts` | Index a persona's steer schedule once; report which messages fall due as tool calls complete. |
| `src/prompt.ts` | Compose the trusted system prompt and the untrusted PR payload under byte budgets; wrap the payload in the persona. |
| `src/executor.ts` | Run the pi agent with model fallback, limits, transcript capture; return a validated `ReviewForm`. |
| `src/review.ts` | Turn a `ReviewForm` into a `PlannedReview`: inline placement against the diff, suggestion demotion, downgrade rule, thread actions, body rendering. |
| `src/eval.ts` | Offline eval: the research arms over a known-answer corpus, no GitHub. |
| `src/research.ts` | File research sink: one JSON record per arm run plus an `index.jsonl` of summary rows. |
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

- **Personas are pieces** (`personas/README.md`): small text files, each in
  one slot (`role` is added above the shared `## Role` section, so every arm's
  system prompt is identical apart from it; `history.user` and
  `history.assistant` are earlier turns before the PR message; `before` and
  `after` wrap the PR data in the user message; `steer` messages arrive
  mid-review on a tool-call schedule), switched on by a recipe and toggled
  per spec. Seeded assistant turns are text only, carry a synthetic provider
  so pi replays them as plain prior turns on any model, and are never counted
  as model requests or transcript output. Steer messages go through pi's
  steering queue after the Nth completed snapshot tool call (never during the
  nudge), each delivery is a `steer` transcript entry, and every scheduled
  delivery counts against the prompt budget.
  `angry:v1` is v1's scene byte for byte: the interruption and `User:` above
  the data, the tail ending mid-sentence as the last bytes. Persona text ships
  with the engine and is trusted; the contract, tools, output rules and trust
  boundary are not pieces and are always on. Config specs are loaded and
  canonicalised at startup, so a missing piece fails the config, not a run.
- **Trusted/untrusted split:** the system prompt carries the role, the
  reviewer contract and output rules. PR-authored text (title,
  description, commit subjects, prior review text, thread bodies, file
  contents) appears only in the PR data block, which opens the user message
  at `# Pull Request Data` and runs through the diff, inside clearly delimited
  blocks, and the system prompt says to treat that block and every tool result
  as data (#18, #101). The distrust is scoped to the block, not to "the user
  message", because persona turns and steer messages are user messages too and
  are trusted engine text.
- **Author text is blockquoted** so it cannot impersonate prompt structure
  (#63), and the system prompt says omission markers appear only in a fixed
  form the engine emits; look-alike text in PR data is to be ignored (#64).
- **Guidance files** (AGENTS.md, CONTRIBUTING.md, GUIDELINES.md) are pointed
  out as conventions of the repo under review, not instructions to the
  reviewer; do not follow onboarding checklists in them (#24, #81).
- **Blinding defaults:** author off; description and commit subjects on,
  because the contract has the reviewer check the author's claims against
  the code (scope and "no behaviour change" claims); title and branch names
  always shown.
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
- Model credentials resolve through pi-ai: a pi `auth.json` credential store
  (API keys or OAuth tokens; default `~/.config/goobreview/auth.json`, 0600),
  environment API keys, or ambient cloud credentials (Vertex ADC on GCP).
- `goobreview auth login <provider>` runs pi-ai's own login flow and writes
  the result straight to the store: keys through hidden input, OAuth through a
  browser URL whose redirect can be pasted back, so it works over SSH. `auth
  status` names each chain model's credential source and never prints a value.
- Each review records how its model was authenticated (`ExecutorResult.credential`).
  Subscription logins are allowed but flagged; Anthropic's rewrites the system
  prompt and tools to Claude Code's, so its reviews are not research-comparable.
- Logs and artifacts are redacted; GitHub error messages never include tokens.
- Non-GET GitHub requests are not retried blindly.

## Research capture

With `research.consent` (public repos only unless `allowPrivate`), every
reviewed head yields one `ResearchRecord` (schema v2) per arm:

- `research.arms` is a grid, `{models, personalities}`, expanded to their
  cross product. Each arm runs one model with no fallback, so a quota or
  availability failure is a failed record, never a silent substitution. A
  transient availability error (503, overloaded) gets one retry first.
- Everything per arm is failure-isolated, prompt composition included (an
  angry prompt can exceed the budget the posted one fit): the arm is recorded
  as failed with a null prompt, and the remaining arms and the sweep go on.
- The posted review fills the arm it matches (personality + actual model).
  When it matches none, for example after a fallback, it is recorded as its
  own arm. Every other arm runs unposted on the same snapshot and the same
  PR data; only the persona differs. Arm names use the canonical spec
  (`angry:v1@openai/...`), and each record's prompt stores the persona's
  pieces with a SHA-256 of each.
- A series is an arm name plus a `fingerprint` (`promptFingerprint`): short
  SHA-256s of the shared system prompt (`contract`) and of the persona's texts
  and steer schedule (`persona`), computed without the PR. Every record and
  index row carries it. Editing a piece or the contract changes it, so resume
  and scoring never blend the new text into the old series under one arm name.
- Arms run after the posted review is out, so capture never delays or
  changes it. A head whose posted review fails or is superseded runs no arms;
  its retry does.
- Records share an `itemId` (`owner/repo#N@sha`) and carry the arm, whether
  it was posted, `live` (false in dry run), the engine version, the full
  prompt, and either the planned review with the executor result (form,
  model, credential, transcript, usage) or the failure with its transcript.
- The file sink (`src/research.ts`) writes one JSON file per record under
  `research.dir` plus an `index.jsonl` of summary rows, tagged with the random
  installation id. Exporting and uploading are separate steps.

### Offline eval

`goobreview eval --corpus <dir> --tree <seed> [--repeats N] [--limit N]` runs
the same arms over a known-answer corpus (angry-llm-research
`scripts/generate-mutants.sh`: `<item>/<variant>/{diff.patch, snapshot/,
label.json}`) with no GitHub:

- Each variant becomes a copy of the seed tree (minus `.git`) with its files
  overlaid, packed and extracted through the same snapshot hardening as a PR
  head. The diff becomes a synthetic PR with no CI: titled `Update <path>`
  with no description, unless the variant has a `pr.json` (`{title?, body?,
  commits?}`) supplying the author's claims. A generator gives both twins of
  an item the same claim, so its truth, not its wording, is what differs.
  Records carry `corpus.claims` (a short SHA-256 of the file, null without
  one) and resume keys on it, so adding or editing claims is a new series,
  never a silent mix with runs made without them. A `pr.json` that is
  malformed or unreadable (anything but absent) makes the variant unprepared.
- Labels are never read; records carry `corpus: {name, item, variant}` and
  scoring joins them to `label.json` afterwards.
- Arms interleave within each repeat, so a model running out of quota part-way
  leaves balanced cells. A quota failure stops that model for the rest of the
  invocation; rerunning resumes from `index.jsonl`, retrying quota failures
  and nothing else. A prior run counts only toward its own series (item, arm
  and fingerprint), so after an edit every cell runs again; rows from before
  fingerprints existed match no series. The summary's `incomplete` counts every run still owed
  (quota failures and skips, and all pending runs of a variant that could not
  be prepared); exit 1 whenever it is non-zero.
- Records go to the same `research.dir`, marked `live: false`, item ids
  `eval:<corpus>/<item>/<variant>`.

### Blinding

Anything that blinds a record (judges, uploads; #117) must remove or replace
every place the arm shows, and must still give the judge the diff:

- `arm.name` and `arm.personality` (the persona spec), and `fingerprint.persona`.
- `prompt.persona`: the spec, pieces, and the text of every slot.
- The persona's role at the start of `prompt.system` (`prompt.persona.role`
  followed by a blank line; the rest is shared by every arm).
- `before`/`after` around `prompt.user`: send the judge `prompt.user`, the
  PR data alone, never the user message the model received.
- `steer` transcript entries: they name the piece, never its text, but their
  presence identifies a steering arm.
- The model's own visible text and reasoning in `outcome.result.transcript`
  (and a failed outcome's `transcript`) can voice the persona; a judge of
  decisions should get the planned review, not the transcript.
