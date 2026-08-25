#!/usr/bin/env bash
# Second-terminal view: prints run directory and phase status, and tails the active phase log.
#
#   scripts/watch-run.sh [--dir <repo>] [--run <id|current|last>] [--once]
#
# Flags:
#   --dir <path>     Repository directory (default: current directory)
#   --run <id>       Run identifier, 'current', or 'last' (default: current)
#   --once           Print run status and active log tail once without following
#   -h, --help       Show this help
#
# Exit codes:
#   0  Clean exit / interrupted tail
#   2  Argument error or directory / run not found
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"
RUN_TARGET="current"
ONCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2"; shift 2 ;;
    --run)   RUN_TARGET="$2"; shift 2 ;;
    --once)  ONCE=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "watch-run: unknown arg $1" >&2
      exit 2
      ;;
  esac
done

[ -d "$DIR" ] || { echo "watch-run: directory not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET" 2>/dev/null)" || {
  echo "watch-run: cannot resolve run '$RUN_TARGET' in $DIR" >&2
  exit 2
}

[ -d "$R" ] || { echo "watch-run: run directory not found: $R" >&2; exit 2; }

RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
TASK="$(run_dir_get "$R" "task" 2>/dev/null || true)"

printf 'Run:       %s\n' "$RUN_ID"
printf 'Directory: %s\n' "$R"
[ -n "$TASK" ] && printf 'Task:      %s\n' "$TASK"

printf '\nPhases:\n'
for P in DISCOVERY IMPLEMENT REVIEW QA RELEASE DELEGATE; do
  P_STATUS="$(run_dir_get "$R" "phases.${P}.status" 2>/dev/null || true)"
  if [ -n "$P_STATUS" ]; then
    printf '  %-11s %s\n' "$P:" "$P_STATUS"
  elif [ -d "$R/phases/$P" ]; then
    if [ -f "$R/phases/$P/status" ]; then
      ST_LINE="$(cat "$R/phases/$P/status" 2>/dev/null || true)"
      printf '  %-11s %s\n' "$P:" "$ST_LINE"
    elif [ -f "$R/phases/$P/log" ]; then
      printf '  %-11s running\n' "$P:"
    fi
  fi
done

ACTIVE_LOG=""
ACTIVE_PHASE=""

if [ -d "$R/phases" ]; then
  for P_DIR in "$R/phases"/*; do
    [ -d "$P_DIR" ] || continue
    P_NAME="$(basename "$P_DIR")"
    P_LOG="$P_DIR/log"
    if [ -f "$P_LOG" ]; then
      ACTIVE_LOG="$P_LOG"
      ACTIVE_PHASE="$P_NAME"
    fi
  done
fi

if [ -n "$ACTIVE_LOG" ] && [ -f "$ACTIVE_LOG" ]; then
  printf '\nActive phase: %s\n' "$ACTIVE_PHASE"
  printf 'Log:          %s\n' "$ACTIVE_LOG"
  printf '\n--- tail of %s ---\n' "$ACTIVE_LOG"
  if [ "$ONCE" -eq 1 ]; then
    tail -n 20 "$ACTIVE_LOG"
  else
    trap 'exit 0' INT TERM
    tail -n 20 -f "$ACTIVE_LOG"
  fi
else
  printf '\nNo phase logs found in %s\n' "$R"
fi

exit 0
