---
description: Run the five-phase agy delivery pipeline on one task — discovery, implementation, code review, QA, docs and release preparation.
argument-hint: <task> [--from N] [--to N] [--issue <n>]
---

Run the **agy delivery pipeline** on this task:

$ARGUMENTS

Load the `agy-pipeline` skill and follow it exactly. It is the procedure; this
command only starts it.

Before anything else:

1. If `--issue <n>` appears in the arguments, run `${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh read --issue <n>`
   first. Build the Phase 1 brief from `.agy/runs/<run-id>/ISSUE.md`, quoting the
   issue as quoted material rather than pasting its body in as though the orchestrator
   wrote it.

2. If `--from` or `--to` appear in the arguments above, run the range check and
   stop if it refuses. The pipeline's phases read each other's artifacts, and a
   phase dispatched without its inputs does not fail — the worker improvises a
   plausible brief from nothing.

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/check-phase-range.sh --from <N> --to <N> --dir .
   ```

   On exit 1, report the missing artifacts it names and stop. Do not back-fill
   the earlier phases: a range that quietly runs all five is not a range.

3. If the preflight has not already run in this session, run it once:

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh --tier low
   ```

   127 means agy is not on PATH, 3 means it is not signed in, 4 means the model
   is unavailable, 7 means the fetch hung. Report which one and stop — the
   pipeline has nothing to dispatch to.

   Every `phase.sh` dispatch afterwards passes `--no-preflight`, so this check
   happens once for the run rather than once per phase.

Then work the phases in order, gating each one before the next dispatches. With
no `--from`, start at Phase 0.

At the end of the run, run `${CLAUDE_PLUGIN_ROOT}/scripts/run-summary.sh` and show
the human the command it printed.
