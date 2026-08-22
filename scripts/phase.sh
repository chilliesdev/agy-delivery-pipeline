#!/usr/bin/env bash
# Run one pipeline phase as an agy delegation.
#
#   phase.sh --phase <NAME> --brief <file> [--tier low|medium|high]
#            [--dir <repo>] [--mode accept-edits|plan|full] [--timeout 30m]
#            [--sandbox]
#
# Writes:  .tmp/logs/<PHASE>.log      full worker transcript (never read whole)
#          .tmp/<PHASE>.status        one STATUS line for the orchestrator
# Prints:  the STATUS line only — keeps the orchestrator context lean.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE=""; BRIEF=""; TIER="medium"; DIR="$PWD"; MODE="accept-edits"; TIMEOUT="30m"; SANDBOX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)   PHASE="$2";   shift 2 ;;
    --brief)   BRIEF="$2";   shift 2 ;;
    --tier)    TIER="$2";    shift 2 ;;
    --dir)     DIR="$2";     shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --sandbox) SANDBOX="--sandbox"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
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
LOG="$DIR/.tmp/logs/$PHASE.log"
STATUS_FILE="$DIR/.tmp/$PHASE.status"

"$HERE/agy-run.sh" --brief "$BRIEF" --dir "$DIR" --log "$LOG" \
  --model "$MODEL" --mode "$MODE" --timeout "$TIMEOUT" $SANDBOX >/dev/null 2>&1
RC=$?

# The brief instructs the worker to end with a STATUS: line. Trust it only as a
# claim — the orchestrator still verifies the artifacts on disk.
CLAIM="$(grep -a -o 'STATUS:[^"]*' "$LOG" 2>/dev/null | tail -1)"
if [ "$RC" -ne 0 ]; then
  LINE="STATUS: WORKER_FAILED(rc=$RC) | Phase: $PHASE | Log: $LOG"
elif [ -n "$CLAIM" ]; then
  LINE="$CLAIM | Phase: $PHASE | Log: $LOG"
else
  LINE="STATUS: NO_STATUS_REPORTED | Phase: $PHASE | Log: $LOG"
fi

printf '%s\n' "$LINE" | tee "$STATUS_FILE"
[ "$RC" -eq 0 ] || exit "$RC"
