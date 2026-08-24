#!/usr/bin/env bash
# Refuse a partial pipeline run whose starting phase has nothing to read.
#
#   check-phase-range.sh --from <0-4> [--to <0-4>] [--dir <repo>]
#
# Exit codes:
#     0  every artifact the range needs is on disk
#     1  at least one is missing — the names and their producing phase are
#        printed, one per line
#     2  bad arguments
#
# Why this exists. `--from 3` asks Phase 3 to run against `.tmp/CHANGES.md`,
# `.tmp/DISCOVERY.md` and `.tmp/TEST_COMMAND` — files that Phases 0 and 1 write
# and that nothing else in the repo produces. Dispatched without them, the phase
# does not fail: the worker improvises a plausible brief from nothing, and the
# file-based state contract that makes each phase's input auditable quietly
# stops holding. The failure is invisible until someone reads the diff.
#
# Back-filling the missing phases instead would mean `--from 3` can silently run
# all five, which is the opposite of what a range is asked for. So this refuses,
# names the files, and names the phase that makes each one.
#
# An empty file counts as missing. A zero-byte `.tmp/TEST_COMMAND` is what a
# Phase 0 that gave up leaves behind, and it briefs a worker no better than an
# absent one does.
set -uo pipefail

FROM=""; TO="4"; DIR="$PWD"

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to)   TO="$2";   shift 2 ;;
    --dir)  DIR="$2";  shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "check-phase-range: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -n "$FROM" ] || { echo "check-phase-range: --from required" >&2; exit 2; }
for N in "$FROM" "$TO"; do
  case "$N" in
    [0-4]) ;;
    *) echo "check-phase-range: phases are 0-4, got '$N'" >&2; exit 2 ;;
  esac
done
[ "$FROM" -le "$TO" ] || {
  echo "check-phase-range: --from $FROM is after --to $TO" >&2; exit 2; }
[ -d "$DIR" ] || { echo "check-phase-range: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

# What a run starting at each phase needs to already exist. Cumulative on
# purpose: Phase 2 reviews against the discovery notes as well as the change, and
# Phase 4 writes release facts that cite the QA report. Starting at 0 needs
# nothing, which is the whole pipeline and the default.
case "$FROM" in
  0) NEED="" ;;
  1) NEED="DISCOVERY.md TEST_COMMAND" ;;
  2|3) NEED="DISCOVERY.md TEST_COMMAND CHANGES.md" ;;
  4) NEED="DISCOVERY.md TEST_COMMAND CHANGES.md QA_REPORT.md" ;;
esac

# Which phase writes each one, so the refusal tells you what to run rather than
# only what is absent.
producer() {
  case "$1" in
    DISCOVERY.md|TEST_COMMAND) echo "Phase 0 (Discovery)" ;;
    CHANGES.md)               echo "Phase 1 (Implementation)" ;;
    QA_REPORT.md)             echo "Phase 3 (QA)" ;;
    *)                        echo "an earlier phase" ;;
  esac
}

MISSING=""
for ART in $NEED; do
  [ -s "$DIR/.tmp/$ART" ] || MISSING="$MISSING $ART"
done

if [ -n "$MISSING" ]; then
  echo "STATUS: RANGE_REFUSED(from=$FROM) | Note: the starting phase reads artifacts that no phase in this range produces"
  for ART in $MISSING; do
    echo "  missing: .tmp/$ART — written by $(producer "$ART")"
  done
  echo "  fix: run the earlier phases, or start the range at 0"
  exit 1
fi

echo "STATUS: RANGE_OK(from=$FROM, to=$TO)"
exit 0
