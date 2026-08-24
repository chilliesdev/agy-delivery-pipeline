# agy-delivery-pipeline

[![CI](https://github.com/chilliesdev/agy-delivery-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/chilliesdev/agy-delivery-pipeline/actions/workflows/ci.yml)

A Claude Code **plugin** that hands coding work to the
[Antigravity CLI](https://antigravity.google/docs/cli/overview/) (`agy`) while
Claude Code stays the orchestrator — writing briefs, running the checks, reading
the diff, and gating every result.

Two halves:

- **Ambient delegation.** Once installed, non-trivial implementation work goes to
  `agy` as a single headless worker instead of Claude editing the code itself.
- **The pipeline.** One task driven end to end — discovery, implementation, a
  code-review retry loop, QA, docs and release preparation — on `/agy:pipeline`.

There are no sub-agents anywhere. Every dispatch is one `agy -p` process, and
exactly one is ever running.

## Requirements

- Antigravity CLI — `curl -fsSL https://antigravity.google/cli/install.sh | bash`
  (installs `agy` to `~/.local/bin`)
- Claude Code
- bash (works on macOS's bash 3.2)

## Install

```
/plugin marketplace add chilliesdev/agy-delivery-pipeline
/plugin install agy@agy-delivery-pipeline
```

Then check the setup once:

```
/agy:preflight
```

> The old `ln -s "$PWD" ~/.claude/skills/multi-agent-delivery-pipeline` install no
> longer works. `SKILL.md` now lives at `skills/agy-pipeline/SKILL.md` and reaches
> its scripts through `${CLAUDE_PLUGIN_ROOT}`, which only a plugin install sets.
> Remove any old symlink; the plugin replaces it.

## Commands

| command | does |
|---|---|
| `/agy:pipeline <task>` | the five phases; `--from N --to N` runs part of the range |
| `/agy:delegate <task>` | one bounded task, one worker — the explicit form of ambient mode |
| `/agy:preflight` | fresh check that agy is installed, signed in, and has the model |
| `/agy:phase <PHASE> <brief>` | dispatch a single phase by hand, to recover a stalled run |

## Ambient delegation

The `agy-delegate` skill triggers on its own. It claims implementation work that
touches more than one file or changes behaviour rather than fixing something
already written — judgement against a stated bar, not a line count. Claude keeps
conversation, planning, git, running tests, the gate, and small edits.

The first delegation in a session asks; after that it dispatches and reports.
That consent lives in the conversation and nowhere else, so no stale marker file
can ever answer for a session that has not agreed.

One `agy -p` at tier `medium`. No review phase — `--verify` plus Claude reading
the diff is the whole gate. Work wanting a review loop wants `/agy:pipeline`.

**If agy is missing, signed out, or the model is unavailable, the plugin says so
once and Claude does the work itself.** It degrades to a no-op, never to a wall.

On this path `.agy/` is ignored via `.git/info/exclude` rather than the tracked
`.gitignore`: ambient delegation runs in whatever repo you happen to be in, and
has no business editing a tracked file there for its own scratch directory.

## The pipeline

`/agy:pipeline` only — it does not trigger on description match, which keeps it
from competing with `agy-delegate` over the same requests.

| # | Phase | Tier | Produces |
|---|---|---|---|
| 0 | Discovery — what's needed to build *and test* the task | low | `.agy/runs/<run-id>/DISCOVERY.md`, `.agy/runs/<run-id>/TEST_COMMAND` |
| 1 | Implementation | medium | `.agy/runs/<run-id>/CHANGES.md` |
| 2 | Code review, with a capped retry loop | high | `.agy/runs/<run-id>/REVIEW_FEEDBACK.md` |
| 3 | QA (`--mode full --sandbox`) | medium | `.agy/runs/<run-id>/QA_REPORT.md` |
| 4 | Docs, then release *preparation* | low / high | `.agy/runs/<run-id>/RELEASE_FACTS.md`, `.agy/runs/<run-id>/RELEASE_PLAN.md` |

All phases run on Gemini 3.7 Flash; the tier sets reasoning effort.

Each phase prints exactly one line back to the orchestrator:

```
STATUS: READY | Phase: DISCOVERY | Run: 2026-08-24T09-51-03Z-a4f1 | Log: /path/to/.agy/runs/2026-08-24T09-51-03Z-a4f1/phases/DISCOVERY/log
```

Everything else — the full worker transcript — stays on disk in
`.agy/runs/<run-id>/phases/<PHASE>/log`.

`--from N` refuses rather than improvising. Phases read what earlier ones wrote,
and a phase dispatched without its inputs does not error — the worker invents a
plausible brief from nothing. `check-phase-range.sh` checks `run.json` to verify
that earlier phases completed with a passing status and left their artifacts in
the run directory. A filename cannot say which task it was written for, and a
record can. If anything is missing or unrecorded, the script names the missing
files and the phase that writes each one, and the run stops there.

## The run directory

Every run is scoped under `.agy/runs/<run-id>/`:

```
.agy/
  current                  # plain file holding current run id
  last                     # plain file holding last run id
  runs/
    <run-id>/
      run.json             # machine-readable provenance: task, base commit, phase outcomes
      DISCOVERY.md         # phase artifacts directly under the run dir
      TEST_COMMAND
      CHANGES.md
      REVIEW_DIFF.patch
      REVIEW_DIFF.stat
      REVIEW_FEEDBACK.md
      QA_REPORT.md
      RELEASE_FACTS.md
      RELEASE_PLAN.md
      criteria/            # resolved criteria copied inside --add-dir
      phases/
        <PHASE>/
          brief.md         # copy of the dispatched brief
          verdict          # worker verdict (authoritative)
          status           # phase.sh STATUS line
          log              # full worker transcript
          verify.log       # --verify output
```

`current` and `last` are plain one-line files holding a run id rather than
symlinks (for portability across platforms and Git Bash).

Inspect past runs with `run-dir.sh`:

```
scripts/run-dir.sh list
scripts/run-dir.sh show [--run <id|current|last>]
```

## The run ledger

Every dispatch — pipeline phase or standalone delegation — appends one record
to `.agy/ledger.jsonl`. It is a single append-only line per dispatch, spanning
all runs in the repository. It is never rewritten, never truncated, and never
sorted.

Every gate in this repository was added in response to a single incident. That
is a sound way to *find* a gate and a poor way to *keep* one. Nothing here would
ever have told you that a rule had stopped earning its place, or that a
paragraph added to `criteria/code-review.md` made reviews better rather than
merely longer.

`REVIEW_THIN` is the standing example: it exists because one review came back as
empty scaffolding, and it is deliberately **not** wired into `--verify` because
nobody could tell whether it was reliable enough to override a verdict. With a
hundred runs recorded, whether thin reviews predict a later `VERIFY_FAILED`
becomes a question with an answer, and the rule can be promoted or deleted on
evidence instead of staying a maybe forever.

And the number that matters most: **how often `--verify` overrides a worker's
`PASSED`.** That figure is the entire justification for the gate, and until now
nobody knew it.

A record holds dispatch metadata, timings, exit codes, gate verdicts, retry
counters, and diff/review summaries:

```json
{"run":"2026-08-24T09-51-03Z-a4f1","phase":"REVIEW","attempt":1,"tier":"high","model":"gemini-3.7-flash-high","backend":"agy","started":"2026-08-24T09:51:20Z","elapsed_s":42,"worker_rc":0,"verdict":"PASSED","verify_ran":true,"verify_rc":0,"status":"PASSED","retries_spent":0,"retries_refunded":0,"task_id":"b3f81e62a1c0","diff":{"files":3,"insertions":45,"deletions":12,"truncated":false},"review":{"anchors":4,"status":"REVIEW_EVIDENCED"}}
```

**The privacy stance, plainly.** The task string is recorded as a 12-character
hash by default (`git hash-object`, requiring no extra dependencies). Setting
`AGY_LEDGER_TASK=plain` opts into recording literal task strings. Brief bodies,
diffs, logs, and file contents stay in the run directory and never enter the
ledger. The intent that follows is deliberate: *the ledger should be safe to
share; the run directory should not have to be.*

A failed ledger append never fails a dispatch. Recording is a side effect, not
the job.

### Inspecting the ledger

Query summary metrics across recorded runs with `scripts/report.sh`:

```
scripts/report.sh [--dir <repo>] [--since <date>] [--phase <NAME>] [--run <id>]
```

It parses the JSONL records in portable bash 3.2 (no `jq` or Python required)
and prints:

- dispatch counts and pass rates by phase
- retry convergence distribution (rounds 1, 2, 3+, and unresolved cap hits)
- median and max elapsed wall-clock times per phase
- gate and verification outcomes, including `--verify` overrides and missing
  worker statuses
- corrupt or unparseable line counts

## Running a phase by hand

The scripts are usable outside Claude Code:

```
scripts/preflight.sh --tier low
RUN_ID=$(scripts/run-dir.sh new --task "my task")
scripts/phase.sh --phase DISCOVERY --run "$RUN_ID" --brief .agy/runs/$RUN_ID/phases/DISCOVERY/brief.md --tier low
```

## agy behaviours worth knowing

Established by testing, not from the docs. The scripts and briefs are shaped
around them:

- **`--add-dir` is mandatory.** Without it agy ignores the cwd and writes into
  `~/.gemini/antigravity-cli/scratch`.
- **A denied permission aborts the whole headless run.** In `accept-edits` a
  worker that tries to run `npm test` dies with rc=1 *after* doing its work
  correctly. Briefs therefore say "do not run shell commands; the orchestrator
  runs the checks."
- **`--mode plan` denies every write**, including the worker writing its own
  report — so read-only phases still run in `accept-edits`, constrained by the
  brief rather than the mode.
- **agy hangs when its stdout is a plain file**, and **drains stdin before it
  answers**, so anything reading it uses a pipe and `</dev/null`.

## Design stance

The orchestrator gates every dispatch. A worker's `STATUS: PASSED` is a claim,
not evidence: the orchestrator runs the tests itself and reads the diff before
advancing. Workers never push, never handle secrets, never publish.

Nor does anything else here. **No script and no worker in this repository runs
`git push`, creates a tag, or merges** — the release phase inspects, prepares and
proposes, printing the commands a person then runs by hand.

Delegation is a skill rather than a hook. A `PreToolUse` deny on `Edit` would
mean Claude cannot edit code in any repo where the plugin is enabled — including
this one — and a broken agy install would brick the session. Ambient routing is a
judgement call about what counts as non-trivial, and a skill that Claude can
decline is the right shape for a judgement call.

## Tests

```
scripts/run-tests.sh
```

Runs all suites in sorted order and exits non-zero if any fails. Pass suite
paths to run a subset, or `--quiet` to report only failures and the summary:

```
scripts/run-tests.sh tests/manifest.sh tests/doc-links.sh
```

CI runs the full suite on macOS (bash 3.2) and Ubuntu (bash 5). Each suite
builds throwaway repos under `$TMPDIR` and writes nothing inside this one.

## Status

Phases 0 through 3 and the docs half of Phase 4 have been run end to end against
a real repo, and the pipeline produced working code. **The release step has never
run against a real project.** It has a script (`check-release.sh`), a vendored
flow (`criteria/release.md`) and a refusal status — but "mechanized and tested"
is not the same as "exercised", and the first real release through it should be
watched closely.

**The plugin packaging is new and equally unexercised.** The ambient delegate
skill, the phase range, and the `.git/info/exclude` path all have test coverage,
but none of them has been through a real session yet.
