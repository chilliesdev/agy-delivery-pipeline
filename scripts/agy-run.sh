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
#   -p takes the next argument as its prompt, so the prompt must be attached
#   (-p='…') with --output-format json elsewhere on the command line.
#   stdout must be a pipe, never a plain file, and stdin must be </dev/null.
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
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "agy-run: unknown arg $1" >&2; exit 2 ;;
  esac
done

command -v "$AGY" >/dev/null 2>&1 || { echo "agy not found on PATH (~/.local/bin/agy)" >&2; exit 127; }
[ -f "$BRIEF" ] || { echo "agy-run: brief not found: $BRIEF" >&2; exit 2; }
[ -d "$DIR" ]   || { echo "agy-run: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"
LOG="${LOG:-${BRIEF%.*}.log}"
PHASE_DIR="$(dirname "$LOG")"
mkdir -p "$PHASE_DIR"
RESULT_JSON="$PHASE_DIR/result.json"

set -- "$AGY" --output-format json "-p=$(cat "$BRIEF")" --add-dir "$DIR" --model "$MODEL" --print-timeout "$TIMEOUT"
case "$MODE" in
  full)             set -- "$@" --dangerously-skip-permissions ;;
  plan|accept-edits) set -- "$@" --mode "$MODE" ;;
  *) echo "agy-run: bad --mode $MODE" >&2; exit 2 ;;
esac
[ -n "$EFFORT" ]  && set -- "$@" --effort "$EFFORT"
[ -n "$SANDBOX" ] && set -- "$@" --sandbox

START=$(date +%s)
RAW_OUTPUT="$( ( cd "$DIR" && "$@" </dev/null ) 2>&1 )"
RC=$?

rm -f "$RESULT_JSON"

# Deliberately narrow parser for agy's known JSON output shape, not a general JSON parser.
IS_JSON=0
JSON_CANDIDATE="$(printf '%s\n' "$RAW_OUTPUT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -a '^{' | grep -a '}$' | head -1 || true)"

if [ -n "$JSON_CANDIDATE" ] && case "$JSON_CANDIDATE" in *'"response":'*) true ;; *) false ;; esac; then
  RESP_ESCAPED="$(printf '%s\n' "$JSON_CANDIDATE" | sed -n 's/.*"response":"\(.*\)","duration_seconds":.*/\1/p' 2>/dev/null || true)"
  if [ -z "$RESP_ESCAPED" ]; then
    RESP_ESCAPED="$(printf '%s\n' "$JSON_CANDIDATE" | sed -n 's/.*"response":"\(.*\)","num_turns":.*/\1/p' 2>/dev/null || true)"
  fi
  if [ -z "$RESP_ESCAPED" ]; then
    RESP_ESCAPED="$(printf '%s\n' "$JSON_CANDIDATE" | sed -n 's/.*"response":"\(.*\)","usage":.*/\1/p' 2>/dev/null || true)"
  fi
  if [ -z "$RESP_ESCAPED" ]; then
    RESP_ESCAPED="$(printf '%s\n' "$JSON_CANDIDATE" | sed -n 's/.*"response":"\(.*\)"[},].*/\1/p' 2>/dev/null || true)"
  fi

  RESP_CLEAN="${RESP_ESCAPED//\\\"/\"}"
  EXTRACTED_RESPONSE="$(printf '%b' "$RESP_CLEAN")"
  IS_JSON=1
  printf '%s\n' "$JSON_CANDIDATE" > "$RESULT_JSON" 2>/dev/null || true
else
  EXTRACTED_RESPONSE="$RAW_OUTPUT"
fi

printf '%s\n' "$EXTRACTED_RESPONSE" > "$LOG"
printf '\n--- agy-run: rc=%s elapsed=%ss brief=%s dir=%s ---\n' \
  "$RC" "$(( $(date +%s) - START ))" "$BRIEF" "$DIR" >> "$LOG"

printf '%s\n' "$EXTRACTED_RESPONSE"
printf '\n--- agy-run: rc=%s elapsed=%ss brief=%s dir=%s ---\n' \
  "$RC" "$(( $(date +%s) - START ))" "$BRIEF" "$DIR"

exit "$RC"
