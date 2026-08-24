#!/usr/bin/env bash
# Run one pipeline phase as an agy delegation.
#
#   phase.sh --phase <NAME> --brief <file> [--tier low|medium|high]
#            [--dir <repo>] [--run <id|current|new>] [--task <string>]
#            [--mode accept-edits|plan|full] [--timeout 30m]
#            [--sandbox] [--no-preflight] [--verify '<command>']
#            [--retry-cap <n>] [--reset-retries]
#            [--ignore-via gitignore|exclude]
#
# Reads:   R/phases/<PHASE>/verdict      the verdict the worker wrote itself
#          R/phases/<PHASE>/retries      retries this phase's cycle has spent
# Writes:  R/phases/<PHASE>/log          full worker transcript (never read whole)
#          R/phases/<PHASE>/verify.log   --verify output, never stdout
#          R/phases/<PHASE>/status       one STATUS line for the orchestrator
#          R/phases/<PHASE>/brief.md     copy of the brief dispatched with
# Prints:  the STATUS line only — keeps the orchestrator context lean.
#
# --verify runs the given check in <repo> after the worker returns and folds the
# result into that one line. It overrides the worker: a PASSED claim whose check
# exits non-zero comes back as STATUS: VERIFY_FAILED(rc=N), exit 5 — distinct
# from WORKER_FAILED, which is the worker itself dying.
#
# The retry counter is mechanical: each dispatch beyond the first bumps
# R/phases/<PHASE>/retries, and past --retry-cap (default 2, matching SKILL.md)
# phase.sh refuses to dispatch at all, returning STATUS: RETRY_CAP_REACHED(n=N),
# exit 6. A clean round clears the counter, as does --reset-retries. A round
# that ends WORKER_FAILED or PREFLIGHT_FAILED is refunded: neither is a worker
# failing to converge, which is the only thing the cap is there to catch.
#
# preflight.sh runs first unless --no-preflight or AGY_SKIP_PREFLIGHT=1.
#
# If this dispatch had to tell git to ignore .agy/, the STATUS line carries a
# trailing `| Gitignore: …` field saying so — a file the tooling authored is one
# wholesale `git add` from the task's own commit. It is never committed here.
#
# --ignore-via chooses where that rule goes. `gitignore` (the default, and what
# every pipeline phase uses) appends to the work tree's tracked .gitignore and
# reports it. `exclude` writes .git/info/exclude instead: same effect on git,
# but the entry is local and untracked, so nothing enters the diff and there is
# nothing to keep out of a commit. The delegate path uses `exclude`, because
# ambient delegation would otherwise edit a tracked file in every repo it ever
# touches, unasked, for a one-line change.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

PHASE=""; BRIEF=""; TIER="medium"; DIR="$PWD"; MODE="accept-edits"; TIMEOUT="30m"
SKIP_PREFLIGHT="${AGY_SKIP_PREFLIGHT:-}"
VERIFY=""; RESET_RETRIES=""; IGNORE_VIA="gitignore"
RETRY_CAP="${AGY_RETRY_CAP:-2}"
RUN_TARGET=""
TASK=""
SANDBOX_ARGS=()   # array, so the flag is never word-split out of an unquoted scalar

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)   PHASE="$2";   shift 2 ;;
    --brief)   BRIEF="$2";   shift 2 ;;
    --tier)    TIER="$2";    shift 2 ;;
    --dir)     DIR="$2";     shift 2 ;;
    --run)     RUN_TARGET="$2"; shift 2 ;;
    --task)    TASK="$2";    shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --verify)  VERIFY="$2";  shift 2 ;;
    --retry-cap) RETRY_CAP="$2"; shift 2 ;;
    --reset-retries) RESET_RETRIES=1; shift ;;
    --ignore-via) IGNORE_VIA="$2"; shift 2 ;;
    --sandbox) SANDBOX_ARGS=("${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"}" --sandbox); shift ;;
    --no-preflight) SKIP_PREFLIGHT=1; shift ;;
    -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
    *) echo "phase.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$PHASE" ] || { echo "phase.sh: --phase required" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "phase.sh: brief not found: $BRIEF" >&2; exit 2; }
case "$RETRY_CAP" in
  ''|*[!0-9]*) echo "phase.sh: --retry-cap wants a whole number, got '$RETRY_CAP'" >&2; exit 2 ;;
esac
case "$IGNORE_VIA" in
  gitignore|exclude) ;;
  *) echo "phase.sh: --ignore-via wants gitignore or exclude, got '$IGNORE_VIA'" >&2; exit 2 ;;
esac

case "$TIER" in
  low|medium|high) MODEL="gemini-3.7-flash-$TIER" ;;
  *) MODEL="$TIER" ;;   # allow an explicit model id (e.g. claude-opus-4-6-thinking)
esac

DIR="$(cd "$DIR" && pwd)"

# Resolve the run directory R and RUN_ID.
if [ -z "$RUN_TARGET" ]; then
  if R="$(run_dir_resolve --dir "$DIR" --run current 2>/dev/null)"; then
    RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
  else
    RUN_TASK="${TASK:-"$PHASE (no task supplied)"}"
    RUN_ID="$(run_dir_new --dir "$DIR" --task "$RUN_TASK")" || exit $?
    R="$DIR/.agy/runs/$RUN_ID"
  fi
elif [ "$RUN_TARGET" = "new" ]; then
  RUN_TASK="${TASK:-"$PHASE (no task supplied)"}"
  RUN_ID="$(run_dir_new --dir "$DIR" --task "$RUN_TASK")" || exit $?
  R="$DIR/.agy/runs/$RUN_ID"
else
  R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET")" || exit $?
  RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
fi

if [ -n "$TASK" ]; then
  EXISTING_TASK="$(run_dir_get "$R" "task" 2>/dev/null || true)"
  if [ -n "$EXISTING_TASK" ] && [ "$TASK" != "$EXISTING_TASK" ]; then
    echo "phase.sh: run $RUN_ID already has task '$EXISTING_TASK' (ignoring passed task '$TASK')" >&2
  fi
fi

PHASE_DIR="$(run_dir_phase_dir "$R" "$PHASE")" || exit $?

# .agy/ is worker state and must never reach the user's history — one `git add
# -A` in a later phase is all it would take. Add the ignore once, where
# --ignore-via says, and only if git does not already ignore .agy (which also
# covers a global or parent-level rule, and either of the two files below that a
# previous dispatch may have written). Must stay *after* the run dir creation
# above: a directory-only rule like `.agy/` only matches a path git can see is a
# directory, so checking first would re-add an entry that is already there.
#
# The edit is not silent, because in the default `gitignore` mode it is the
# tooling authoring a *tracked* file in someone else's repo: a .gitignore this
# created is itself untracked, and the wholesale
# `git add -A` a release phase reaches for would sweep it into the task's commit
# — which is how it turned up in a delivered diffstat as a change nobody asked
# for. It is reported rather than committed: committing writes to the user's
# history as a side effect of a dispatch, which nothing here is licensed to do,
# and would need a clean index, an identity, and no hooks to be safe. The report
# rides the STATUS line, appended as a field so the head of the line never
# shifts, because the orchestrator reads that line and nothing else — stderr
# carries the same sentence for whoever is running phase.sh by hand.
GITIGNORE_FIELD=""
if GITROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" \
   && [ "$(git -C "$DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
   && [ -n "$GITROOT" ] \
   && ! git -C "$DIR" check-ignore -q .agy 2>/dev/null; then
  # check-ignore above sees both files, so whichever one a previous dispatch
  # wrote, this is skipped on the next.
  if [ "$IGNORE_VIA" = "exclude" ]; then
    GITDIR="$(git -C "$DIR" rev-parse --git-dir 2>/dev/null)"
    case "$GITDIR" in /*) ;; *) GITDIR="$GITROOT/$GITDIR" ;; esac
    IGNORE_TARGET="$GITDIR/info/exclude"
    mkdir -p "$GITDIR/info" 2>/dev/null
    WROTE_NOTE="Gitignore: added .agy/ to $IGNORE_TARGET — local to this clone, untracked, nothing to keep out of the commit"
    CREATED_NOTE="$WROTE_NOTE"
  else
    IGNORE_TARGET="$GITROOT/.gitignore"
    WROTE_NOTE="Gitignore: added .agy/ to $IGNORE_TARGET — the tooling's edit, not the task's; keep it out of the task's commit"
    CREATED_NOTE="Gitignore: created $IGNORE_TARGET holding .agy/ — untracked and not the task's; keep it out of the task's commit"
  fi
  [ -e "$IGNORE_TARGET" ] && GI_EXISTED=1 || GI_EXISTED=""
  # An existing file that lacks a trailing newline would otherwise absorb the
  # new entry into its last line.
  if [ -s "$IGNORE_TARGET" ] && [ -n "$(tail -c 1 "$IGNORE_TARGET" 2>/dev/null)" ]; then
    printf '\n' >> "$IGNORE_TARGET" 2>/dev/null
  fi
  if printf '.agy/\n' >> "$IGNORE_TARGET" 2>/dev/null; then
    if [ -n "$GI_EXISTED" ]; then
      GITIGNORE_NOTE="$WROTE_NOTE"
    else
      GITIGNORE_NOTE="$CREATED_NOTE"
    fi
    GITIGNORE_FIELD=" | $GITIGNORE_NOTE"
    echo "phase.sh: $GITIGNORE_NOTE" >&2
  else
    echo "phase.sh: could not add .agy/ to $IGNORE_TARGET" >&2
  fi
fi

LOG="$PHASE_DIR/log"
VERIFY_LOG="$PHASE_DIR/verify.log"
STATUS_FILE="$PHASE_DIR/status"
VERDICT_FILE="$PHASE_DIR/verdict"
RETRY_FILE="$PHASE_DIR/retries"

ESC="$(printf '\033')"
CR="$(printf '\r')"

# Drop ANSI escape sequences and carriage returns from stdin. Worker transcripts
# are coloured, so the STATUS: marker is rarely the first byte of its own line.
strip_ansi() { LC_ALL=C sed -e "s/${ESC}\[[0-9;?]*[a-zA-Z]//g" -e "s/${CR}//g"; }

# Trim markdown decoration and surrounding whitespace from one claim line. Never
# stops at a quote — a verdict naming "src/my file.ts" must survive whole.
trim_claim() { LC_ALL=C sed -e 's/^[[:space:]*#>_`-]*//' -e 's/[[:space:]*`]*$//'; }

# Copy the brief into R/phases/<PHASE>/brief.md before dispatch.
cp -f "$BRIEF" "$PHASE_DIR/brief.md" 2>/dev/null || {
  echo "phase.sh: could not copy brief to $PHASE_DIR/brief.md" >&2
  exit 2
}

# The retry cap SKILL.md asks for, made mechanical. R/phases/<PHASE>/retries holds
# how many *retries* — dispatches beyond the first — this cycle has spent; the
# file being absent means the cycle has not dispatched at all yet. Unlike the
# verdict file below it is deliberately *not* cleared before each dispatch, or
# it could never accumulate; it is cleared by a clean round or --reset-retries.
[ -n "$RESET_RETRIES" ] && rm -f "$RETRY_FILE"
if [ -f "$RETRY_FILE" ]; then
  # tr -cd is the sanitiser: a hand-edited or truncated counter reads as 0
  # rather than aborting the dispatch on a string comparison.
  SPENT="$(tr -cd '0-9' < "$RETRY_FILE" 2>/dev/null)"; SPENT="${SPENT:-0}"
  NEXT=$((SPENT + 1))
  HAD_COUNTER=1
else
  SPENT=0; NEXT=0
  # No file at all is its own state — "this cycle has not dispatched yet" — and
  # a refund below has to be able to put it back, not settle for writing 0.
  HAD_COUNTER=""
fi

# At the cap, refuse before anything is spent — no preflight fetch, no worker,
# no cleared verdict, so REVIEW_FEEDBACK.md and the last verdict survive for
# the orchestrator, which SKILL.md tells to take the work over itself from here.
if [ "$SPENT" -ge "$RETRY_CAP" ]; then
  printf '%s\n' "STATUS: RETRY_CAP_REACHED(n=$SPENT, cap=$RETRY_CAP) | Phase: $PHASE | Run: $RUN_ID | Note: the retry budget for this phase is spent — take the work over yourself, or pass --reset-retries to start a fresh cycle | Log: $LOG$GITIGNORE_FIELD" \
    | tee "$STATUS_FILE"
  exit 6
fi

# The same phase name is re-run by the Phase 2 review loop, so a verdict left by
# the previous round would otherwise be read as this round's answer.
rm -f "$VERDICT_FILE"

# Missing CLI, expired sign-in or a model id this account cannot use otherwise
# surface deep inside the phase, after the brief is written and the time is
# spent. Check first — one live `agy models` fetch, a few seconds against a
# phase measured in minutes — and report the refusal as a STATUS line, because
# the orchestrator never reads stderr. On by default: a sign-in can lapse and a
# model id can be withdrawn mid-pipeline, so Phase 0 alone is not enough.
# AGY_SKIP_PREFLIGHT=1 or --no-preflight drops it for a tight retry loop.
if [ -z "$SKIP_PREFLIGHT" ]; then
  PREFLIGHT_LOG="$PHASE_DIR/preflight.log"
  "$HERE/preflight.sh" --model "$MODEL" --quiet >/dev/null 2>"$PREFLIGHT_LOG"
  PRC=$?
  if [ "$PRC" -ne 0 ]; then
    case "$PRC" in
      127) REASON="agy_not_found" ;;
      3)   REASON="not_signed_in" ;;
      4)   REASON="model_unavailable:$MODEL" ;;
      7)   REASON="timeout" ;;
      *)   REASON="rc=$PRC" ;;
    esac
    printf '%s\n' "STATUS: PREFLIGHT_FAILED($REASON) | Phase: $PHASE | Run: $RUN_ID | Log: $PREFLIGHT_LOG$GITIGNORE_FIELD" \
      | tee "$STATUS_FILE"
    exit "$PRC"
  fi
fi

# Count the dispatch the moment it is committed to, not once it comes back: a
# round killed halfway still spent a retry, and only a counter written up front
# survives to say so.
printf '%s\n' "$NEXT" > "$RETRY_FILE" 2>/dev/null

"$HERE/agy-run.sh" --brief "$BRIEF" --dir "$DIR" --log "$LOG" \
  --model "$MODEL" --mode "$MODE" --timeout "$TIMEOUT" \
  ${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"} >/dev/null 2>&1
RC=$?

# Primary: the verdict the worker wrote to R/phases/<PHASE>/verdict — first non-empty
# line, no transcript involved. Fallback: the last transcript line that *starts*
# with STATUS:, so prose like "I will end with STATUS: PASSED" cannot match.
CLAIM=""
if [ -s "$VERDICT_FILE" ]; then
  CLAIM="$(strip_ansi < "$VERDICT_FILE" 2>/dev/null | awk 'NF { print; exit }' | trim_claim)"
fi
if [ -z "$CLAIM" ] && [ -f "$LOG" ]; then
  CLAIM="$(strip_ansi < "$LOG" 2>/dev/null \
    | grep -a -E '^[[:space:]*#>_`-]*STATUS:' | tail -1 | trim_claim)"
fi
case "$CLAIM" in
  ""|STATUS:*) ;;
  *) CLAIM="STATUS: $CLAIM" ;;   # a verdict file that omitted the marker
esac

# The gate SKILL.md asks the orchestrator to run by hand, run here instead. It
# is a claim the worker cannot make good on by asserting it: the check runs in
# $DIR, through a shell so `&&` and pipelines work, and its own exit code — not
# the verdict — decides. Skipped when the worker itself failed or preflight
# refused: there is no work to check. Output goes to its own log and never to
# stdout, which belongs to the STATUS line alone.
VRC=0
if [ -n "$VERIFY" ] && [ "$RC" -eq 0 ]; then
  printf -- '--- phase.sh: verify %s ---\n$ %s\n' "$PHASE" "$VERIFY" > "$VERIFY_LOG" 2>/dev/null
  # No pipe here on purpose: $? is the check's own code, not a tee's.
  ( cd "$DIR" && /bin/bash -c "$VERIFY" ) >> "$VERIFY_LOG" 2>&1
  VRC=$?
  printf -- '--- phase.sh: verify rc=%s ---\n' "$VRC" >> "$VERIFY_LOG" 2>/dev/null
fi

# Trust the claim only as a claim — the orchestrator still verifies the artifacts
# on disk. rc=0 with no claim at all is not a failure and not a pass; say so.
if [ "$RC" -ne 0 ]; then
  LINE="STATUS: WORKER_FAILED(rc=$RC) | Phase: $PHASE | Run: $RUN_ID | Log: $LOG"
elif [ -n "$VERIFY" ] && [ "$VRC" -ne 0 ]; then
  LINE="STATUS: VERIFY_FAILED(rc=$VRC) | Phase: $PHASE | Run: $RUN_ID | Claimed: ${CLAIM:-none} | Log: $LOG | VerifyLog: $VERIFY_LOG"
elif [ -n "$CLAIM" ]; then
  LINE="$CLAIM | Phase: $PHASE | Run: $RUN_ID | Log: $LOG"
else
  LINE="STATUS: NO_STATUS_REPORTED | Phase: $PHASE | Run: $RUN_ID | Note: worker exited 0 without a verdict — the phase may have succeeded anyway; verify the artifact on disk before advancing or retrying | Log: $LOG"
fi
# Appended, never spliced: every existing caller matches on the head of this
# line, so a passing check adds to it and shifts nothing.
if [ -n "$VERIFY" ] && [ "$VRC" -eq 0 ] && [ "$RC" -eq 0 ]; then
  LINE="$LINE | Verify: ok | VerifyLog: $VERIFY_LOG"
fi
LINE="$LINE$GITIGNORE_FIELD"

# Record the phase outcome in run.json
FINAL_STATUS="$(printf '%s' "${LINE#STATUS: }" | awk '{print $1}')"
FINAL_VERDICT="$(printf '%s' "${CLAIM#STATUS: }" | awk '{print $1}')"
run_dir_record_phase "$R" "$PHASE" "status=$FINAL_STATUS" "verdict=${FINAL_VERDICT:-$FINAL_STATUS}" "attempts=$((SPENT + 1))"

# A round that ends clean ends the cycle, so the next one starts from zero
# without anybody having to remember --reset-retries. Clean means the worker
# returned, the check (if any) held, and the verdict is not one of the phrasings
# every phase uses for "I could not". NO_STATUS_REPORTED is not clean: it is
# unresolved, and an unresolved round is exactly what the cap is counting.
CLEAN=0
if [ "$RC" -eq 0 ] && [ "$VRC" -eq 0 ] && [ -n "$CLAIM" ]; then
  WORD="$(printf '%s' "${CLAIM#STATUS: }" | awk '{print $1}' \
    | tr -d '|' | tr '[:lower:]' '[:upper:]')"
  case "$WORD" in
    FAILED|BLOCKED|ERROR|REJECTED) ;;
    *) CLEAN=1 ;;
  esac
fi
[ "$CLEAN" -eq 1 ] && rm -f "$RETRY_FILE"

# The refund. The cap exists to stop a review-fix loop that is not converging,
# so it should only be spent by a worker that tried and did not converge. A
# WORKER_FAILED round is not that: agy died on its own configuration — an
# unreadable criteria path, a brief it could not open — in seconds, before any
# reasoning happened, and it leaves no feedback file for the next round to work
# from either. Two of those in a row would have retired a review phase that had
# never reviewed anything. So the counter goes back exactly as it was, an absent
# file included. FAILED, VERIFY_FAILED and NO_STATUS_REPORTED all keep spending:
# each of them is a worker that ran and left the round unresolved.
#
# This deliberately does not run from a trap, and that is the whole answer to
# the case writing the counter up front protects — a round killed halfway. A
# user's ^C reaches phase.sh with the worker, phase.sh dies here and never
# reaches this line, so the retry it wrote before dispatching stands. Only a
# worker that returned a non-zero code to a phase.sh still running is refunded.
if [ "$RC" -ne 0 ]; then
  if [ -n "$HAD_COUNTER" ]; then
    printf '%s\n' "$SPENT" > "$RETRY_FILE" 2>/dev/null
  else
    rm -f "$RETRY_FILE"
  fi
fi

printf '%s\n' "$LINE" | tee "$STATUS_FILE"
[ "$RC" -eq 0 ] || exit "$RC"
[ "$VRC" -eq 0 ] || exit 5
exit 0
