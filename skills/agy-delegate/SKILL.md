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

Write it to `.tmp/briefs/delegate.md`. The worker sees only this file, so
everything it needs is in it and nothing else is.

State: **the task**, in enough detail to act on; **the files** it should touch,
by path, and any it must not; **the constraints** — existing patterns to follow,
APIs that already exist, what not to invent; and **what done looks like**.

Three rules the brief must carry, each earned by a failure:

1. **Do not run shell commands.** In `accept-edits` a denied permission aborts
   the whole headless run — a worker that tries `npm test` dies with rc=1 *after*
   doing its work correctly. The orchestrator runs the checks.
2. **Do not touch git.** No staging, no commits, no branches.
3. **Write nothing outside the repo**, and nothing in `.tmp/` except the two
   verdict outputs below.

Then the verdict contract, verbatim in shape:

> When you are done, write one line — nothing else — to `.tmp/DELEGATE.verdict`,
> and print that same line as the last line of your output, in the form
> `STATUS: <verdict> | File: <path>`. Use `STATUS: DONE` if you completed the
> task, `STATUS: BLOCKED` with the reason if you could not. Never write
> `.tmp/DELEGATE.status` — that file belongs to the tooling.

Both routes, because they are not redundant: the file is authoritative and is
read first, and the printed line is the fallback for a worker that ignored it.

## Dispatch

```
${CLAUDE_PLUGIN_ROOT}/scripts/phase.sh --phase DELEGATE \
  --brief .tmp/briefs/delegate.md --tier medium \
  --ignore-via exclude --no-preflight --verify '<the test command>'
```

`--tier medium` matches the pipeline's Implementation phase, because that is what
this is — implementation without the surrounding phases.

`--ignore-via exclude` puts `.tmp/` in `.git/info/exclude` rather than the tracked
`.gitignore`. Ambient delegation runs in whatever repo the user happens to be in;
it has no business editing a tracked file there for its own scratch directory.
The pipeline keeps the `.gitignore` default, where the edit is reported and
expected.

**The test command for `--verify`.** Reuse `.tmp/TEST_COMMAND` if a previous
pipeline run left one non-empty — Phase 0 wrote it and verified it runs. Otherwise
work it out yourself while writing the brief: you are already reading the repo,
and `package.json`, a Makefile or the CI config will say. Pass the narrowest
command that would actually catch a break.

If there is genuinely no test command, dispatch without `--verify` and say so in
the final report. Do not invent one — a `--verify` that passes because it tested
nothing is worse than none, because it comes back as `Verify: ok`.

You get back exactly one line. Read it, not the log.

| status | means | do |
|---|---|---|
| `STATUS: DONE …` | the worker finished and the check held | gate it below |
| `STATUS: BLOCKED …` | it could not proceed | read the reason, then take the work over yourself |
| `VERIFY_FAILED(rc=N)` | it claimed success; the tests disagree | read `VerifyLog:`, then fix it yourself or re-brief once |
| `WORKER_FAILED(rc=N)` | agy died | check the brief path and the criteria, then retry once |
| `PREFLIGHT_FAILED(…)` | setup broke mid-session | report the cause, do the work yourself |
| `NO_STATUS_REPORTED` | rc=0, no verdict — neither pass nor fail | check the diff; it may well have worked |

**One retry, then stop.** This is a one-shot path; a second failure means the
task was underspecified or wants the pipeline. Take it over yourself and say so.

## The gate

The worker's verdict is a claim. `--verify` makes part of the check mechanical;
the rest is yours and cannot be delegated:

```
git diff --stat
git diff
```

Read the diff for the two things a passing test suite does not catch: **tests
weakened or deleted** to make things green, and **APIs invented** that do not
exist in this codebase. Also check it did what was asked and not more — an
unrequested refactor riding along in the same diff is a finding, not a bonus.

If the diff is empty, the phase did nothing regardless of what it claimed.

Nothing here commits, stages, branches, pushes or tags. That is the user's, and
this skill does not do it on their behalf even when asked to "finish up".

## Reporting

Short, and honest about what was checked mechanically versus by eye:

- what was delegated, and the tier
- `git diff --stat` — the real one
- the test command, and whether it passed through `--verify` or was skipped
- what you found reading the diff
- anything you took over yourself, and why

Say plainly if the verdict was `NO_STATUS_REPORTED` or if `--verify` was skipped.
A report that reads as clean because nothing checked it is the failure this whole
design exists to prevent.
