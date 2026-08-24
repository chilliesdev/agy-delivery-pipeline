#!/usr/bin/env bash
# Report summary metrics over the run ledger in <repo>/.agy/ledger.jsonl.
#
#   report.sh [--dir <repo>] [--since <date>] [--phase <NAME>] [--run <id>]
#
# Reads:   <repo>/.agy/ledger.jsonl
# Prints:  plain-text summary report of dispatch outcomes, retries, verify overrides,
#          elapsed time distribution, and unparseable records.
#
# Exit codes:
#     0  fine (including empty or absent ledger)
#     2  bad arguments
#     4  --dir is not a git work tree
#
# Constraint:
# Parses single-line JSONL records using sed/grep/awk in portable bash 3.2 without
# jq or python. The records are written by ledger.sh in a known structure, which
# is why parsing remains simple. Corrupt or unparseable lines are skipped and
# reported in the unparseable count.
set -uo pipefail

DIR="$PWD"
SINCE=""
FILTER_PHASE=""
FILTER_RUN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --phase) FILTER_PHASE="$2"; shift 2 ;;
    --run) FILTER_RUN="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "report: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -d "$DIR" ] || { echo "report: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "report: not a git repository: $DIR" >&2
  exit 4
}

LEDGER_FILE="$DIR/.agy/ledger.jsonl"

if [ ! -f "$LEDGER_FILE" ] || [ ! -s "$LEDGER_FILE" ]; then
  echo "Run Ledger Report"
  echo "================="
  echo "Ledger is empty or absent at $LEDGER_FILE"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/report-sh.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

VALID_TSV="$WORK/valid.tsv"
> "$VALID_TSV"

SKIPPED_COUNT=0
TOTAL_READ=0

_extract_str() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" 2>/dev/null
}

_extract_num() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"$key\":\([0-9][0-9]*\).*/\1/p" 2>/dev/null
}

_extract_bool() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"$key\":\(true\|false\).*/\1/p" 2>/dev/null
}

while IFS= read -r line || [ -n "$line" ]; do
  trimmed="${line#"${line%%[! ]*}"}"
  [ -z "$trimmed" ] && continue

  TOTAL_READ=$((TOTAL_READ + 1))

  if [ "${trimmed:0:1}" != "{" ] || [ "${trimmed: -1}" != "}" ]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  r_run="$(_extract_str run "$trimmed")"
  r_phase="$(_extract_str phase "$trimmed")"
  r_status="$(_extract_str status "$trimmed")"
  r_started="$(_extract_str started "$trimmed")"
  r_attempt="$(_extract_num attempt "$trimmed")"
  r_elapsed="$(_extract_num elapsed_s "$trimmed")"
  r_verdict="$(_extract_str verdict "$trimmed")"
  r_verify_ran="$(_extract_bool verify_ran "$trimmed")"
  r_verify_rc="$(_extract_num verify_rc "$trimmed")"

  if [ -z "$r_run" ] || [ -z "$r_phase" ] || [ -z "$r_status" ]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  if [ -n "$FILTER_RUN" ] && [ "$r_run" != "$FILTER_RUN" ]; then
    continue
  fi

  if [ -n "$FILTER_PHASE" ] && [ "$r_phase" != "$FILTER_PHASE" ]; then
    continue
  fi

  if [ -n "$SINCE" ] && [ -n "$r_started" ]; then
    if [ "$r_started" \< "$SINCE" ]; then
      continue
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$r_run" "$r_phase" "$r_attempt" "$r_status" "$r_elapsed" "$r_verdict" "$r_verify_ran" "$r_started" >> "$VALID_TSV"
done < "$LEDGER_FILE"

TOTAL_VALID="$(grep -c . "$VALID_TSV" 2>/dev/null || true)"
TOTAL_VALID="${TOTAL_VALID:-0}"

echo "Run Ledger Report"
echo "================="
echo "Ledger:     $LEDGER_FILE"
echo "Filters:    since=${SINCE:-all}, phase=${FILTER_PHASE:-all}, run=${FILTER_RUN:-all}"
echo "Dispatches: $TOTAL_VALID valid record(s) read (total lines read: $TOTAL_READ, unparseable skipped: $SKIPPED_COUNT)"
echo ""

if [ "$TOTAL_VALID" -eq 0 ]; then
  echo "No dispatches matched the specified criteria."
  exit 0
fi

echo "Dispatches and Pass Rates by Phase:"
PHASES="$(awk -F'\t' '{print $2}' "$VALID_TSV" 2>/dev/null | sort -u)"
for ph in $PHASES; do
  P_LINES="$(awk -F'\t' -v p="$ph" '$2 == p' "$VALID_TSV")"
  P_TOTAL="$(printf '%s\n' "$P_LINES" | grep -c . || true)"
  P_TOTAL="${P_TOTAL:-0}"
  P_PASS=0
  while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts; do
    case "$r_st" in
      PASSED*|DONE*|READY*|PREPARED*|OK*) P_PASS=$((P_PASS + 1)) ;;
    esac
  done <<EOF
$P_LINES
EOF
  P_PCT=0
  if [ "$P_TOTAL" -gt 0 ]; then
    P_PCT=$(( (P_PASS * 100) / P_TOTAL ))
  fi
  printf '  %-16s %3d dispatches, %3d passed (%d%%)\n' "$ph:" "$P_TOTAL" "$P_PASS" "$P_PCT"
done
echo ""

echo "Retry Convergence Distribution:"
ROUND_1=0
ROUND_2=0
ROUND_3_PLUS=0
CAP_REACHED=0

while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts; do
  case "$r_st" in
    RETRY_CAP_REACHED*) CAP_REACHED=$((CAP_REACHED + 1)) ;;
  esac
  case "$r_st" in
    PASSED*|DONE*|READY*|PREPARED*|OK*)
      if [ "$r_att" = "1" ]; then
        ROUND_1=$((ROUND_1 + 1))
      elif [ "$r_att" = "2" ]; then
        ROUND_2=$((ROUND_2 + 1))
      elif [ -n "$r_att" ] && [ "$r_att" -ge 3 ] 2>/dev/null; then
        ROUND_3_PLUS=$((ROUND_3_PLUS + 1))
      fi
      ;;
  esac
done < "$VALID_TSV"

printf '  Round 1 (converged on round 1): %d\n' "$ROUND_1"
printf '  Round 2 (converged on round 2): %d\n' "$ROUND_2"
printf '  Round 3+ (converged round 3+):  %d\n' "$ROUND_3_PLUS"
printf '  Retry cap reached (unresolved): %d\n' "$CAP_REACHED"
echo ""

echo "Elapsed Wall-Clock Time (seconds):"
for ph in $PHASES; do
  ELAPSED_LIST="$(awk -F'\t' -v p="$ph" '$2 == p && $5 ~ /^[0-9]+$/ { print $5 }' "$VALID_TSV" | sort -n)"
  EL_COUNT="$(printf '%s\n' "$ELAPSED_LIST" | grep -c . || true)"
  EL_COUNT="${EL_COUNT:-0}"
  if [ "$EL_COUNT" -gt 0 ]; then
    EL_MAX="$(printf '%s\n' "$ELAPSED_LIST" | tail -1)"
    MID_IDX=$(( (EL_COUNT + 1) / 2 ))
    EL_MEDIAN="$(printf '%s\n' "$ELAPSED_LIST" | sed -n "${MID_IDX}p")"
    printf '  %-16s median %4ds, max %4ds (from %d timed dispatches)\n' "$ph:" "$EL_MEDIAN" "$EL_MAX" "$EL_COUNT"
  else
    printf '  %-16s no timed dispatches\n' "$ph:"
  fi
done
echo ""

VERIFY_OVERRIDES=0
NO_STATUS_COUNT=0

while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts; do
  case "$r_st" in
    VERIFY_FAILED*) VERIFY_OVERRIDES=$((VERIFY_OVERRIDES + 1)) ;;
  esac
  case "$r_st" in
    NO_STATUS_REPORTED*) NO_STATUS_COUNT=$((NO_STATUS_COUNT + 1)) ;;
  esac
done < "$VALID_TSV"

echo "Gate and Verification Outcomes:"
printf '  Verify gate overrides:          %d (worker claimed PASSED, --verify failed; number that justifies the gate)\n' "$VERIFY_OVERRIDES"
printf '  No status reported dispatches:  %d\n' "$NO_STATUS_COUNT"
echo ""

echo "Data Integrity:"
printf '  Unparseable records skipped:    %d\n' "$SKIPPED_COUNT"

exit 0
