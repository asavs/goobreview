# Research network: contributing review data

Status: design for discussion. Local capture is built (engine research arms,
PR #182; offline eval, PR #185). Everything below the "Built" line in the
build order is proposed.

## Goal

Anyone who runs goobreview can opt in, with one setting, to contribute
review data to a shared research dataset. The data has to be trustworthy
enough to support causal claims about reviewer personas, safe to collect from
strangers, and easy to analyse. The question it serves is the one in
angry-llm-research `DESIGN-v2.md`: does a harsh persona make a reviewer better
at telling real problems from non-problems, or only stricter?

## What a contribution is

Every reviewed PR head yields one **item**: the posted review plus the other
arms of the grid, run unposted on the same snapshot and payload
(`research.arms`, e.g. {GPT, Claude} × {neutral, angry}). Each arm is one
**record** (schema v2): the arm, the full prompt, the executor transcript
(tool calls, reasoning, usage, model, how the model was signed in), the
planned review, or the failure with its transcript.

Because every arm sees identical input, the within-item comparison holds
even when contributors run different models, repos and languages. That is
what makes data from strangers usable.

## Participation

Contributors pay for their own model use, in every mode: the shadow arms
multiply it, and they choose to spend it. Two ways in, one record format:

1. **Self-hosted.** A contributor runs goobreview with their own App and
   their own model credentials, and turns on `research.consent` and
   `research.upload`.
2. **Hosted** (after the Cloud Run phase). A repo admin installs the public
   App, adds `.github/goobreview.yml` with `research: contribute`, and signs
   in their own model provider (API key or subscription login) for that
   installation. The file is the consent record: only someone with write
   access can add it, and it is visible to everyone working on the repo.

### Eligibility: the persona pair

A contribution counts toward the research dataset only when its grid runs
**both personalities, `none` and `angry`, on every model it uses**. Models
are the contributor's choice (whatever they pay for); the persona pair is
not, because the primary comparison is persona within model within item.
`research upload` refuses items that lack the pair and says why. Records
without it stay on the contributor's machine.

## Consent and opt-out

- Public repos only. Private repos never upload, in either mode.
- Consent is per repo, given by its admin (config for self-hosted, the repo
  file for hosted).
- Any PR can opt out with a `no-research` label. Records for that PR are
  never uploaded and are deleted if already uploaded.
- The posted review's footer says the review is part of a research study
  and links to this page.
- Deletion: a repo admin can request removal of their repo's records at any
  time; uploads are tombstoned and excluded from every later release.

## What is uploaded

The record, transformed before it leaves the machine:

- **Code by reference.** File contents in tool results and the diff are
  replaced by `{path, sha, byte range, content hash}`. The code is public at
  that SHA, so the export step re-fetches it ("hydration") and checks the
  hash. Nothing that is the repo owner's to license is redistributed.
- **Persona quarantined.** The system prompt is replaced by its hash and the
  arm's personality name. Persona texts are versioned in the goobreview repo,
  so the hash identifies them exactly.
- **People pseudonymised.** PR author and commenter logins are replaced by
  salted hashes, salted per release so releases cannot be joined on them.
- **Secrets re-scanned** with the engine's redaction patterns; a hit
  quarantines the record instead of uploading it.
- **Excluded logins.** Records whose credential has `rewritesRequests` (the
  Anthropic subscription login, which swaps in Claude Code's system prompt)
  are kept locally but not uploaded.

## Trust: making uploads hard to fake

Anyone can POST anything, so the collector verifies what it can:

1. **Contributor identity.** `goobreview research register` signs the
   contributor in with GitHub (device flow) and returns an upload token tied
   to that account. Published data shows only a per-release pseudonym.
2. **Posted reviews are checked against GitHub.** The record names the
   review URL. The collector fetches it and checks that the body hash matches
   and that the author is a bot of an App installed on that repo. A record
   that fails is rejected.
3. **Unposted arms ride on a verified item.** They cannot be checked
   directly, but they must share an item with a verified posted review, carry
   the same snapshot SHA and payload hash, and pass consistency checks (token
   counts plausible for the prompt size, tool results whose hashes match the
   code at that SHA).
4. **Spike-ins.** The collector can ask a contributor's engine to review a
   known-answer item (from the planted-bug tier) and compare. Contributors
   whose engines disagree with everyone else's are flagged for review, not
   silently dropped.

Records carry a trust tier (verified posted, bound shadow, unverified), and
analyses state which tiers they include.

## Randomisation

A contributor who chooses the angry persona because they like it produces
observational data. For causal wild-tier data, the engine assigns the posted
arm itself: with `research.postedArm: "random"`, the posted arm is drawn
from the grid by a hash of the item, so neither the contributor nor the PR
author picks it. Self-chosen personas stay in the dataset as their own
stratum.

## Pipeline

```
engine (research.dir)
  └─ goobreview research upload          transform, sign, POST, mark sent
       └─ ingest (Cloud Run)              auth, size limits, write to quarantine
            └─ validator (Cloud Run job)  schema, secret scan, GitHub checks, tier
                 ├─ rejected/             with reasons, kept 30 days
                 └─ accepted/             immutable, one object per recordId
                      └─ export job       hydrate code, build tables
                           └─ release     versioned snapshot + datasheet
```

- Upload is idempotent by `recordId`; the engine keeps an `uploaded.jsonl`
  beside `index.jsonl`, so a crashed upload resumes.
- Storage is a GCS bucket per stage; accepted objects are write-once.
- **Outcome enrichment** runs periodically over accepted items: was the PR
  merged, were flagged lines changed later, was it reverted, were bot threads
  resolved. Public repos only, read-only API.

## Analysis

The export job writes Parquet tables, partitioned by engine version (prompt or
model changes start a new era and are never pooled silently):

| Table | One row per |
|---|---|
| `items` | PR head or eval variant (repo, language, size, trust tier, label for eval items) |
| `runs` | arm run (arm, model, credential type, posted, verdict, usage, elapsed) |
| `findings` | finding (run, path, line, blocking, title, body) |
| `tool_calls` | tool call (run, tool, path, bytes) |
| `outcomes` | enrichment observation (item, kind, when) |

DuckDB reads them directly. The primary analysis (d′ and criterion per arm on
the planted-bug tier, mixed model with item as a random effect) is committed
and tagged in angry-llm-research before each data run, as DESIGN-v2 requires.

Releases go to a public dataset host (for example Hugging Face) as
versioned snapshots in reference form, with a hydration script, a datasheet,
and the analysis that produced each headline number. Derived annotations are
released under CC BY 4.0.

## Build order

Built:

1. Local capture: research arms, file sink, `index.jsonl` (PR #182).
2. Offline eval over known-answer corpora (PR #185).

Proposed:

3. Record transform (reference form, persona quarantine, pseudonyms) and
   `goobreview research export` to local Parquet, so our own VM data can be
   analysed before anything is uploaded.
4. `research.postedArm: "random"`, the PR footer, and the `no-research` label.
5. Ingest endpoint, quarantine bucket, `research register` and `research upload`.
6. Validator with GitHub verification and trust tiers.
7. Export job, outcome enrichment, first internal release.
   Upload enforces the persona pair (above).
8. Hosted mode and public onboarding docs; first public release.

## Open questions

- Hosted mode needs a safe place for contributors' model credentials
  (per-installation, encrypted, revocable). Worth it, or self-hosted only?
- Dataset host and licence for the code-free annotations.
- Whether private repos may ever contribute numbers only (counts, verdicts,
  no text).
