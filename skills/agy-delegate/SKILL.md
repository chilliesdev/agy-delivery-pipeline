---
name: agy-delegate
description: Hand one bounded implementation task to the Antigravity CLI (agy) as a single headless worker instead of editing the code directly, then verify what comes back. Use for implementation work that touches more than one file or changes behaviour rather than fixing something already written. Not for one-line fixes, exploration, or anything needing a review loop, QA or a release — that is the agy-pipeline skill via /agy:pipeline.
---

# Delegate one task to agy

Claude Code stays the **orchestrator**: it decides what to build, writes the
brief, runs the checks, reads the diff and reports. The Antigravity CLI writes
the code. There are no sub-agents — one `agy -p` process, once.

This is the ambient half of the `agy` plugin. The five-phase pipeline, for a task
driven through review, QA and release, is [agy-pipeline](../agy-pipeline/SKILL.md)
via `/agy:pipeline`. Both run through the same `phase.sh`.

## When this applies

Delegate implementation work that clears **both** bars:

- it is **implementation** — code that changes what the software does — and not
  planning, exploration, reading, a git operation, or answering a question; and
- it is **not trivial**: it touches more than one file, or it changes behaviour
  rather than correcting something already written.

That second bar is judgement, not arithmetic. A one-line change can be the
hardest thing in the repo; if the hard part is deciding *what* the line should
be, that decision is yours and the typing is not worth a delegation. Conversely
a mechanical rename across nine files is trivial per file and worth delegating
whole.

**Keep for yourself, always:** conversation and planning; reading code to decide
what to ask for; every git operation; running tests; the gate on what comes back;
anything using tools agy does not have. **Never delegate** work you cannot state
in a brief, or work whose acceptance you could not check afterward.

When it does not apply, just do the work. Do not mention this skill.

## Consent

**Ask before the first ambient delegation in a session.** One sentence naming the
task and the model, then wait:

> This is multi-file implementation work — hand it to agy (gemini-3.7-flash-medium)
> and I'll run the tests and review the diff? I'll stop asking after this.

Once they agree, delegate for the rest of the session without asking again.
That consent lives in this conversation and nowhere else — no marker file, so a
stale marker can never speak for a session that has not agreed. If the context is
compacted and you cannot recall an answer, ask again; one extra question is the
cheap failure here.

Invoked as `/agy:delegate`, skip this entirely. The command *is* the consent.

If they decline, do the work yourself and do not raise it again that session.

## Preflight

Once per session, before the first dispatch:

```
${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh --tier medium
```

Run it here, before writing the brief, so a broken setup costs seconds rather
than surfacing after the brief is written. Every dispatch below then passes
`--no-preflight`: `phase.sh` would otherwise repeat this bounded 30-second fetch
in front of every task, for a setup that has not changed.

Later dispatches in the session assume this result. `/agy:preflight` forces a
fresh check — reach for it if a dispatch starts failing mid-session, because a
sign-in can lapse and this is then the fastest way to find out.

**If it fails, say so once and do the work yourself.** Name the specific cause —
127 not on `PATH`, 3 not signed in, 4 model unavailable, 7 the fetch hung — and
carry on. A broken agy install must never block a task; the plugin degrades to a
no-op, not to a wall.

## The brief

A brief must name the verdict path by absolute path inside `--add-dir`, and that
path contains the run id. So **the run must be minted before the brief is
written**:

```
RUN_ID=$(${CLAUDE_PLUGIN_ROOT}/scripts/run-dir.sh new --task "<the task>")
```

Minting the run up front gives the run an identity before any work happens under
it, and records the task in `run.json` — an unrecorded task is a run that cannot
answer which work it belonged to.

Write the brief to `.agy/runs/$RUN_ID/phases/DELEGATE/brief.md`. The worker sees
only this file, so everything it needs is in it and nothing else is.

State: **the task**, in enough detail to act on; **the files** it should touch,
by path, and any it must not; **the constraints** — existing patterns to follow,
APIs that already exist, what not to invent; and **what done looks like**.

Three rules the brief must carry, each earned by a failure:

1. **Do not run shell commands.** In `accept-edits` a denied permission aborts
   the whole headless run — a worker that tries `npm test` dies with rc=1 *after*
   doing its work correctly. The orchestrator runs the checks.
2. **Do not touch git.** No staging, no commits, no branches.
3. **Write nothing outside the repo**, and nothing in `.agy/` except the verdict
   file named below.

Then the verdict contract, verbatim in shape:

> When you are done, write one line — nothing else — to
> `.agy/runs/<run-id>/phases/DELEGATE/verdict`, and print that same line as the
> last line of your output, in the form `STATUS: <verdict> | File: <path>`. Use
> `STATUS: DONE` if you completed the task, `STATUS: BLOCKED` with the reason
> if you could not. Never write `.agy/runs/<run-id>/phases/DELEGATE/status` —
> that file belongs to the tooling.

Both routes, because they are not redundant: the file is authoritative and is
read first, and the printed line is the fallback for a worker that ignored it.

Each brief is linted by [check-brief.sh](../../scripts/check-brief.sh) before
dispatch. A `BRIEF_INVALID(<reason>)` refusal means the brief itself violates
rules — it is not a worker failure; fix the brief and re-dispatch at zero token
cost. Start from [briefs/DELEGATE.md](../../briefs/DELEGATE.md).

## Dispatch

```
${CLAUDE_PLUGIN_ROOT}/scripts/phase.sh --phase DELEGATE --run "$RUN_ID" \
  --brief .agy/runs/$RUN_ID/phases/DELEGATE/brief.md --tier medium \
  --ignore-via exclude --no-preflight --verify '<the test command>'
```

`--tier medium` matches the pipeline's Implementation phase, because that is what
this is — implementation without the surrounding phases.

`--ignore-via exclude` puts `.agy/` in `.git/info/exclude` rather than the tracked
`.gitignore`. Ambient delegation runs in whatever repo the user happens to be in;
it has no business editing a tracked file there for its own scratch directory.
The pipeline keeps the `.gitignore` default, where the edit is reported and
expected.

**The test command for `--verify`.** Reuse `TEST_COMMAND` from the run
directory if a previous pipeline run left one non-empty — Phase 0 wrote it and
verified it runs. Otherwise work it out yourself while writing the brief: you
are already reading the repo, and `package.json`, a Makefile or the CI config
will say. Pass the narrowest command that would actually catch a break.

If there is genuinely no test command, dispatch without `--verify` and say so in
the final report. Do not invent one — a `--verify` that passes because it tested
nothing is worse than none, because it comes back as `Verify: ok`.

You get back exactly one line:

```
STATUS: DONE | Phase: DELEGATE | Run: 2026-08-24T09-51-03Z-a4f1 | Log: /path/to/.agy/runs/2026-08-24T09-51-03Z-a4f1/phases/DELEGATE/log | Verify: ok | VerifyLog: /path/to/.agy/runs/2026-08-24T09-51-03Z-a4f1/phases/DELEGATE/verify.log
```

Read it, not the log.

| status | means | do |
|---|---|---|
| `STATUS: DONE …` | the worker finished and the check held | gate it below |
| `STATUS: BLOCKED …` | it could not proceed | read the reason, then take the work over yourself |
| `BRIEF_INVALID(…)` | brief violates contract rules | fix the brief and re-dispatch (zero token cost) |
| `SECRETS_FOUND(…)` | secret detected in brief or diff | remove secret and re-dispatch (or --no-secret-scan) |
| `VERIFY_FAILED(rc=N)` | it claimed success; the tests disagree | read `VerifyLog:`, then fix it yourself or re-brief once |
| `WORKER_FAILED(rc=N)` | agy died | check the brief path and the criteria, then retry once |
| `PREFLIGHT_FAILED(…)` | setup broke mid-session | report the cause, do the work yourself |
| `NO_STATUS_REPORTED` | rc=0, no verdict — neither pass nor fail | check the diff; it may well have worked |

**One retry, then stop.** This is a one-shot path; a second failure means the
task was underspecified or wants the pipeline. Take it over yourself and say so.

Dispatches are recorded automatically to `.agy/ledger.jsonl` as an append-only
ledger line tracking spend and token usage. `--budget-tokens <n>` is available
to cap spend across a run. The orchestrator does nothing with this during a run;
questions about historical performance and token spend are answered between
runs by `${CLAUDE_PLUGIN_ROOT}/scripts/report.sh`.

## The gate

The worker's verdict is a claim. `--verify` proves tests exited zero;
`check-diff-integrity.sh` makes detecting gutted tests and scope creep
mechanical. First capture the diff and inspect its integrity:

```
${CLAUDE_PLUGIN_ROOT}/scripts/capture-diff.sh --dir <repo>
${CLAUDE_PLUGIN_ROOT}/scripts/check-diff-integrity.sh --dir <repo> \
  --brief .agy/runs/$RUN_ID/phases/DELEGATE/brief.md
```

| STATUS | exit | means | do |
|---|---|---|---|
| `DIFF_CLEAN` | 0 | checks ran and found nothing; names what was checked | proceed to diff spot-check |
| `DIFF_SUSPICIOUS(…)` | 0 | scope creep, falling assertions, or edited literals | inspect the flagged diff hunks |
| `DIFF_TESTS_WEAKENED(…)` | 3 | deleted test file, added skip, or trivial assertion | **fail the gate** — fix or re-brief |
| `DIFF_UNCHECKED(lang=…)` | 0 | no rules available for detected language(s) | human diff read is the whole gate |

`DIFF_TESTS_WEAKENED` overrides a successful claim, exactly as a failing
`--verify` does: deleted test files, added test skips (`@pytest.mark.skip`,
`it.only`, `t.Skip`), or trivial assertions (`assert True`) fail the gate.
`DIFF_SUSPICIOUS` flags scope creep (files touched outside the brief) or
falling assertion counts for human inspection without overriding the verdict
automatically. `DIFF_UNCHECKED` reports that the language has no rules,
signalling that the diff was not analysed mechanically.

Then inspect the diff yourself:

```
git diff --stat
git diff
```

Read the diff for what static pattern checks cannot catch: **invented APIs**,
subtle semantic bugs, and any languages reported as unchecked. Also check it did
what was asked and not more — an unrequested refactor riding along in the same
diff is a finding, not a bonus.

If the diff is empty, the phase did nothing regardless of what it claimed.

Nothing here commits, stages, branches, pushes or tags. That is the user's, and
this skill does not do it on their behalf even when asked to "finish up".

## Reporting

Short, and honest about what was checked mechanically versus by eye:

- what was delegated, and the tier
- `git diff --stat` — the real one
- the test command, and whether it passed through `--verify` or was skipped
- the diff integrity status (`DIFF_CLEAN`, `DIFF_SUSPICIOUS`, `DIFF_UNCHECKED`)
- what you found reading the diff
- anything you took over yourself, and why

Say plainly if the verdict was `NO_STATUS_REPORTED` or if `--verify` was skipped.
A report that reads as clean because nothing checked it is the failure this whole
design exists to prevent.
