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
| 4 | Docs and release | low / high | — |

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

## Status

Phase 0 and Phase 1 are verified end to end against a real repo. Phases 2–4 are
specified but not yet exercised — see the open issues.
