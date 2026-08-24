# agy-delivery-pipeline

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

On this path `.tmp/` is ignored via `.git/info/exclude` rather than the tracked
`.gitignore`: ambient delegation runs in whatever repo you happen to be in, and
has no business editing a tracked file there for its own scratch directory.

## The pipeline

`/agy:pipeline` only — it does not trigger on description match, which keeps it
from competing with `agy-delegate` over the same requests.

| # | Phase | Tier | Produces |
|---|---|---|---|
| 0 | Discovery — what's needed to build *and test* the task | low | `.tmp/DISCOVERY.md`, `.tmp/TEST_COMMAND` |
| 1 | Implementation | medium | `.tmp/CHANGES.md` |
| 2 | Code review, with a capped retry loop | high | `.tmp/REVIEW_FEEDBACK.md` |
| 3 | QA (`--mode full --sandbox`) | medium | `.tmp/QA_REPORT.md` |
| 4 | Docs, then release *preparation* | low / high | `.tmp/RELEASE_FACTS.md`, `.tmp/RELEASE_PLAN.md` |

All phases run on Gemini 3.7 Flash; the tier sets reasoning effort.

Each phase prints exactly one line back to the orchestrator:

```
STATUS: READY | Phase: DISCOVERY | Log: .tmp/logs/DISCOVERY.log
```

Everything else — the full worker transcript — stays on disk in `.tmp/logs/`.

`--from N` refuses rather than improvising. Phases read what earlier ones wrote,
and a phase dispatched without its inputs does not error — the worker invents a
plausible brief from nothing. `check-phase-range.sh` names the missing files and
the phase that writes each one, and the run stops there.

## Running a phase by hand

The scripts are usable outside Claude Code:

```
scripts/preflight.sh --tier low
scripts/phase.sh --phase DISCOVERY --brief .tmp/briefs/discovery.md --tier low
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
for t in tests/*.sh; do "$t" || echo "FAILED: $t"; done
```

Each suite builds throwaway repos under `$TMPDIR` and writes nothing inside this
one.

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
