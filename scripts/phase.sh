#!/usr/bin/env bash
# Run one pipeline phase as an agy delegation.
#
#   phase.sh --phase <NAME> --brief <file> [--tier low|medium|high]
#            [--dir <repo>] [--mode accept-edits|plan|full] [--timeout 30m]
#            [--sandbox]
#
# Reads:   .tmp/<PHASE>.verdict      the verdict the worker wrote itself
# Writes:  .tmp/logs/<PHASE>.log     full worker transcript (never read whole)
#          .tmp/<PHASE>.status       one STATUS line for the orchestrator
# Prints:  the STATUS line only — keeps the orchestrator context lean.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE=""; BRIEF=""; TIER="medium"; DIR="$PWD"; MODE="accept-edits"; TIMEOUT="30m"
SANDBOX_ARGS=()   # array, so the flag is never word-split out of an unquoted scalar

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)   PHASE="$2";   shift 2 ;;
    --brief)   BRIEF="$2";   shift 2 ;;
    --tier)    TIER="$2";    shift 2 ;;
    --dir)     DIR="$2";     shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --sandbox) SANDBOX_ARGS=("${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"}" --sandbox); shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "phase.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$PHASE" ] || { echo "phase.sh: --phase required" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "phase.sh: brief not found: $BRIEF" >&2; exit 2; }

case "$TIER" in
  low|medium|high) MODEL="gemini-3.7-flash-$TIER" ;;
  *) MODEL="$TIER" ;;   # allow an explicit model id (e.g. claude-opus-4-6-thinking)
esac

DIR="$(cd "$DIR" && pwd)"
mkdir -p "$DIR/.tmp/logs"

# .tmp/ is worker scratch and must never reach the user's history — one `git add
# -A` in a later phase is all it would take. Add the ignore once, in the work
# tree root's .gitignore, and only if git does not already ignore .tmp (which
# also covers a global or parent-level rule). Silent on success: stdout belongs
# to the STATUS line alone. Must stay *after* the mkdir above: a directory-only
# rule like `.tmp/` only matches a path git can see is a directory, so checking
# first would re-add an entry that is already there.
if GITROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" \
   && [ "$(git -C "$DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
   && [ -n "$GITROOT" ] \
   && ! git -C "$DIR" check-ignore -q .tmp 2>/dev/null; then
  GITIGNORE="$GITROOT/.gitignore"
  # An existing file that lacks a trailing newline would otherwise absorb the
  # new entry into its last line.
  if [ -s "$GITIGNORE" ] && [ -n "$(tail -c 1 "$GITIGNORE" 2>/dev/null)" ]; then
    printf '\n' >> "$GITIGNORE" 2>/dev/null
  fi
  printf '.tmp/\n' >> "$GITIGNORE" 2>/dev/null \
    || echo "phase.sh: could not add .tmp/ to $GITIGNORE" >&2
fi

LOG="$DIR/.tmp/logs/$PHASE.log"
STATUS_FILE="$DIR/.tmp/$PHASE.status"
VERDICT_FILE="$DIR/.tmp/$PHASE.verdict"

ESC="$(printf '\033')"
CR="$(printf '\r')"

# Drop ANSI escape sequences and carriage returns from stdin. Worker transcripts
# are coloured, so the STATUS: marker is rarely the first byte of its own line.
strip_ansi() { LC_ALL=C sed -e "s/${ESC}\[[0-9;?]*[a-zA-Z]//g" -e "s/${CR}//g"; }

# Trim markdown decoration and surrounding whitespace from one claim line. Never
# stops at a quote — a verdict naming "src/my file.ts" must survive whole.
trim_claim() { LC_ALL=C sed -e 's/^[[:space:]*#>_`-]*//' -e 's/[[:space:]*`]*$//'; }

# The same phase name is re-run by the Phase 2 review loop, so a verdict left by
# the previous round would otherwise be read as this round's answer.
rm -f "$VERDICT_FILE"

"$HERE/agy-run.sh" --brief "$BRIEF" --dir "$DIR" --log "$LOG" \
  --model "$MODEL" --mode "$MODE" --timeout "$TIMEOUT" \
  ${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"} >/dev/null 2>&1
RC=$?

# Primary: the verdict the worker wrote to .tmp/<PHASE>.verdict — first non-empty
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

# Trust the claim only as a claim — the orchestrator still verifies the artifacts
# on disk. rc=0 with no claim at all is not a failure and not a pass; say so.
if [ "$RC" -ne 0 ]; then
  LINE="STATUS: WORKER_FAILED(rc=$RC) | Phase: $PHASE | Log: $LOG"
elif [ -n "$CLAIM" ]; then
  LINE="$CLAIM | Phase: $PHASE | Log: $LOG"
else
  LINE="STATUS: NO_STATUS_REPORTED | Phase: $PHASE | Note: worker exited 0 without a verdict — the phase may have succeeded anyway; verify the artifact on disk before advancing or retrying | Log: $LOG"
fi

printf '%s\n' "$LINE" | tee "$STATUS_FILE"
[ "$RC" -eq 0 ] || exit "$RC"
