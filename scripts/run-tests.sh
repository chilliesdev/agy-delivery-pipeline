#!/usr/bin/env bash
# Run the test suites, capture their output, and report pass/fail summary.
#
#   run-tests.sh [--quiet] [tests/<suite>.sh ...]
#
# Runs:    each test suite as its own process in sorted order.
# Writes:  nothing inside the repo (suites use $TMPDIR).
# Prints:  per-suite pass/fail status and final summary.
#
# Exit codes:
#     0  all test suites passed
#     1  one or more test suites failed
#     2  bad arguments or suite not found
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

QUIET=0
SUITES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "run-tests: unknown arg $1" >&2; exit 2 ;;
    *) SUITES[${#SUITES[@]}]="$1"; shift ;;
  esac
done

if [ ${#SUITES[@]} -eq 0 ]; then
  for S in "$ROOT"/tests/*.sh; do
    [ -f "$S" ] && SUITES[${#SUITES[@]}]="$S"
  done
fi

if [ ${#SUITES[@]} -eq 0 ]; then
  echo "run-tests: no test suites found" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=""

SUITE_FLEET=""
cleanup() {
  [ -n "$SUITE_FLEET" ] && rm -f "$SUITE_FLEET"
}
trap cleanup EXIT INT TERM

for S in "${SUITES[@]}"; do
  TARGET="$S"
  if [ ! -f "$TARGET" ] && [ -f "$ROOT/$S" ]; then
    TARGET="$ROOT/$S"
  fi

  if [ ! -f "$TARGET" ]; then
    echo "run-tests: test suite not found: $S" >&2
    exit 2
  fi

  DISPLAY_NAME="$S"
  case "$TARGET" in
    "$ROOT"/*) DISPLAY_NAME="${TARGET#$ROOT/}" ;;
  esac

  SUITE_FLEET="$(mktemp "${TMPDIR:-/tmp}/run-tests-fleet.XXXXXX")"
  OUT="$(AGY_FLEET="$SUITE_FLEET" bash "$TARGET" 2>&1)"
  CODE=$?
  rm -f "$SUITE_FLEET"
  SUITE_FLEET=""

  if [ $CODE -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    if [ $QUIET -eq 0 ]; then
      printf '%-35s ok\n' "$DISPLAY_NAME"
    fi
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ -z "$FAILED_NAMES" ]; then
      FAILED_NAMES="$DISPLAY_NAME"
    else
      FAILED_NAMES="$FAILED_NAMES $DISPLAY_NAME"
    fi
    printf '%-35s FAIL (exit %d)\n' "$DISPLAY_NAME" "$CODE"
    printf '%s\n\n' "$OUT"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [ $FAIL_COUNT -gt 0 ]; then
  printf 'Failed suites:\n'
  for F in $FAILED_NAMES; do
    printf '  - %s\n' "$F"
  done
  exit 1
fi

exit 0
