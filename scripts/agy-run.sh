#!/usr/bin/env bash
# Run one brief through the Antigravity CLI (agy) headlessly.
#
#   agy-run.sh --brief <file> [--dir <workdir>] [--log <file>]
#              [--model <id>] [--mode accept-edits|plan|full]
#              [--effort low|medium|high] [--timeout 30m] [--sandbox]
#
# Notes:
#   --dir is passed to agy as --add-dir. Without it agy ignores the cwd and
#   writes into ~/.gemini/antigravity-cli/scratch instead of your repo.
#   mode=full maps to --dangerously-skip-permissions (shell commands, no prompts).
set -uo pipefail

AGY="${AGY_BIN:-agy}"
BRIEF=""; DIR="$PWD"; LOG=""
MODEL="${AGY_MODEL:-gemini-3.7-flash-medium}"
MODE="${AGY_MODE:-accept-edits}"
EFFORT="${AGY_EFFORT:-}"
TIMEOUT="${AGY_TIMEOUT:-30m}"
SANDBOX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --brief)   BRIEF="$2";   shift 2 ;;
    --dir)     DIR="$2";     shift 2 ;;
    --log)     LOG="$2";     shift 2 ;;
    --model)   MODEL="$2";   shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
    --effort)  EFFORT="$2";  shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --sandbox) SANDBOX=1;    shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "agy-run: unknown arg $1" >&2; exit 2 ;;
  esac
done

command -v "$AGY" >/dev/null 2>&1 || { echo "agy not found on PATH (~/.local/bin/agy)" >&2; exit 127; }
[ -f "$BRIEF" ] || { echo "agy-run: brief not found: $BRIEF" >&2; exit 2; }
[ -d "$DIR" ]   || { echo "agy-run: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"
LOG="${LOG:-${BRIEF%.*}.log}"
mkdir -p "$(dirname "$LOG")"

set -- "$AGY" -p "$(cat "$BRIEF")" --add-dir "$DIR" --model "$MODEL" --print-timeout "$TIMEOUT"
case "$MODE" in
  full)             set -- "$@" --dangerously-skip-permissions ;;
  plan|accept-edits) set -- "$@" --mode "$MODE" ;;
  *) echo "agy-run: bad --mode $MODE" >&2; exit 2 ;;
esac
[ -n "$EFFORT" ]  && set -- "$@" --effort "$EFFORT"
[ -n "$SANDBOX" ] && set -- "$@" --sandbox

START=$(date +%s)
( cd "$DIR" && "$@" ) 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"
printf '\n--- agy-run: rc=%s elapsed=%ss brief=%s dir=%s ---\n' \
  "$RC" "$(( $(date +%s) - START ))" "$BRIEF" "$DIR" | tee -a "$LOG"
exit "$RC"
