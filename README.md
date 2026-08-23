# agy-delivery-pipeline

A Claude Code skill that runs a single task end to end — discovery, implementation,
code review, QA, docs and release — with **Claude Code as the orchestrator** and the
**Antigravity CLI (`agy`) as the worker** executing every phase headlessly.

There are no sub-agents. Each phase is one `agy -p` process. The orchestrator writes
briefs, dispatches, and gates on the result; it never edits code or reads a full
worker transcript.

## Requirements

- [Antigravity CLI](https://antigravity.google/docs/cli/overview/) — `curl -fsSL https://antigravity.google/cli/install.sh | bash` (installs `agy` to `~/.local/bin`)
- Claude Code
- bash (works on macOS's bash 3.2)

## Install

Clone anywhere, then symlink into your skills directory:

```bash
ln -s "$PWD" ~/.claude/skills/multi-agent-delivery-pipeline
```

## Usage

Check the setup once before starting — that agy is installed, signed in, and
offers the model the tier resolves to:

```bash
scripts/preflight.sh --tier low
```

Invoke the skill from Claude Code, or dispatch a phase directly:

```bash
scripts/phase.sh --phase DISCOVERY --brief .tmp/briefs/discovery.md --tier low
```

Each phase prints exactly one line back to the orchestrator:

```
STATUS: READY | Phase: DISCOVERY | Log: .tmp/logs/DISCOVERY.log
```

Everything else — the full worker transcript — stays on disk in `.tmp/logs/`.

## Phases

| # | Phase | Tier | Produces |
|---|---|---|---|
| 0 | Discovery — what's needed to build *and test* the task | low | `.tmp/DISCOVERY.md`, `.tmp/TEST_COMMAND` |
| 1 | Implementation | medium | `.tmp/CHANGES.md` |
| 2 | Code review, with a capped retry loop | high | `.tmp/REVIEW_FEEDBACK.md` |
| 3 | QA (`--mode full --sandbox`) | medium | `.tmp/QA_REPORT.md` |
| 4 | Docs, then release *preparation* | low / high | `.tmp/RELEASE_FACTS.md`, `.tmp/RELEASE_PLAN.md` |

All phases run on Gemini 3.7 Flash; the tier sets reasoning effort.

## agy behaviours worth knowing

These were established by testing, not from the docs, and the scripts and briefs
are shaped around them:

- **`--add-dir` is mandatory.** Without it agy ignores the cwd and writes into
  `~/.gemini/antigravity-cli/scratch`.
- **A denied permission aborts the whole headless run.** In `accept-edits` a
  worker that tries to run `npm test` dies with rc=1 *after* doing its work
  correctly. Briefs therefore say "do not run shell commands; the orchestrator
  runs the checks."
- **`--mode plan` denies every write**, including the worker writing its own
  report — so read-only phases still run in `accept-edits`, constrained by the
  brief rather than the mode.

## Design stance

The orchestrator gates every phase. A worker's `STATUS: PASSED` is a claim, not
evidence: the orchestrator runs the tests itself and reads `git diff --stat`
before advancing. Workers never push, never handle secrets, never publish.

Nor does anything else here. **No script and no worker in this repository runs
`git push`, creates a tag, or merges** — the release phase inspects, prepares and
proposes, printing the commands a person then runs by hand.

## Status

Phases 0 through 3 and the docs half of Phase 4 have been run end to end against
a real repo, and the pipeline produced working code. **The release step has never
run against a real project.** It is no longer a dead end — it has a script
(`check-release.sh`), a vendored flow (`criteria/release.md`) and a refusal
status — but "mechanized and tested" is not the same as "exercised", and the
first real release through it should be watched closely.

What that run taught, now fixed: a criteria file outside the repo aborts a phase
outright, and Phase 2 was reviewing file contents rather than the change, which
is why it returned a confidently empty report. Both are closed. The remaining
open issues are the rest of what it found.
