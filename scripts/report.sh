#!/usr/bin/env bash
# Report summary metrics over the run ledger in <repo>/.agy/ledger.jsonl.
#
#   report.sh [--dir <repo>] [--since <date>] [--phase <NAME>] [--run <id>]
#             [--price-in <usd-per-mtok>] [--price-out <usd-per-mtok>]
#
# Reads:   <repo>/.agy/ledger.jsonl
# Prints:  plain-text summary report of dispatch outcomes, retries, verify overrides,
#          elapsed time distribution, token spend by phase, and unparseable records.
#
# Exit codes:
#     0  fine (including empty or absent ledger)
#     2  bad arguments
#     4  --dir is not a git work tree
#
# Pricing note:
# Budget in tokens, not dollars. Do not hardcode a price per token anywhere.
# Prices change, differ per model and account, and a stale number presented as a cost
# is worse than no number. A dollar figure may be derived for display when the user
# supplies rates — --price-in and --price-out (USD per million tokens) — and when
# they do not, report tokens and say nothing about money.
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
PRICE_IN=""
PRICE_OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --phase) FILTER_PHASE="$2"; shift 2 ;;
    --run) FILTER_RUN="$2"; shift 2 ;;
    --price-in) PRICE_IN="$2"; shift 2 ;;
    --price-out) PRICE_OUT="$2"; shift 2 ;;
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
: > "$VALID_TSV"

SKIPPED_COUNT=0
TOTAL_READ=0

_parse_price_to_micro() {
  local str="$1"
  [ -z "$str" ] && { printf '0\n'; return 0; }
  str="${str#\$}"
  local int_part="${str%%.*}"
  local frac_part=""
  case "$str" in
    *.*) frac_part="${str#*.}" ;;
  esac
  frac_part="${frac_part}000000"
  frac_part="${frac_part:0:6}"
  int_part="${int_part:-0}"
  int_part="$((10#$int_part))"
  frac_part="$((10#$frac_part))"
  printf '%s\n' "$(( int_part * 1000000 + frac_part ))"
}

_format_cost() {
  local inp="$1"
  local out="$2"
  local p_in_micro="$3"
  local p_out_micro="$4"
  local c_in=$(( (inp * p_in_micro) / 1000000 ))
  local c_out=$(( (out * p_out_micro) / 1000000 ))
  local tot_micro=$(( c_in + c_out ))
  local d=$(( tot_micro / 1000000 ))
  local c=$(( (tot_micro % 1000000) / 10000 ))
  printf '$%d.%02d' "$d" "$c"
}

_extract_str() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" 2>/dev/null
}

_extract_num() {
  local key="$1"
  local line="$2"
  local num
  num="$(printf '%s\n' "$line" | sed -n "s/.*\"$key\":\([0-9][0-9]*\)[^0-9].*/\1/p" 2>/dev/null)"
  if [ -n "$num" ]; then
    printf '%s\n' "$num"
  else
    printf '%s\n' "$line" | sed -n "s/.*\"$key\":\([0-9][0-9]*\)$/\1/p" 2>/dev/null
  fi
}

_extract_bool() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"$key\":\(true\|false\).*/\1/p" 2>/dev/null
}

# Deliberately narrow reader for a known one-line shape rather than a JSON parser.
# The single-line JSON shape it depends on is written by ledger.sh — so the two change together.
_extract_nested() {
  local obj_name="$1"
  local key="$2"
  local line="$3"
  local obj
  obj="$(printf '%s\n' "$line" | sed -n "s/.*\"$obj_name\":{\([^}]*\)}.*/\1/p" 2>/dev/null)"
  [ -z "$obj" ] && return 0
  obj="{$obj}"
  local val
  val="$(_extract_num "$key" "$obj")"
  [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
  val="$(_extract_str "$key" "$obj")"
  [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
  val="$(_extract_bool "$key" "$obj")"
  [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
  return 0
}

# Tab is an IFS whitespace character in bash. When IFS=$'\t', `read` collapses
# runs of consecutive tabs (empty fields) into a single delimiter, shifting all
# subsequent columns left. To prevent column collapse, empty values are replaced
# with a sentinel ('-') before writing and restored when reading back.
_tsv_write_row() {
  local sep=""
  local f
  for f in "$@"; do
    printf '%s%s' "$sep" "${f:-"-"}"
    sep=$'\t'
  done
  printf '\n'
}

_tsv_restore() {
  local var
  for var in "$@"; do
    eval "[ \"\${$var:-}\" = '-' ] && $var=''"
  done
}


while IFS= read -r line || [ -n "$line" ]; do
  trimmed="${line#"${line%%[! ]*}"}"
  [ -z "$trimmed" ] && continue

  TOTAL_READ=$((TOTAL_READ + 1))

  if [ "${trimmed:0:1}" != "{" ] || [ "${trimmed: -1}" != "}" ]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # Strip nested objects before extracting top-level keys to prevent collisions with nested keys
  trimmed_top="$(printf '%s\n' "$trimmed" | sed 's/"[A-Za-z0-9_]*":{[^{}]*}//g')"

  r_run="$(_extract_str run "$trimmed_top")"
  r_phase="$(_extract_str phase "$trimmed_top")"
  r_status="$(_extract_str status "$trimmed_top")"
  r_started="$(_extract_str started "$trimmed_top")"
  r_attempt="$(_extract_num attempt "$trimmed_top")"
  r_elapsed="$(_extract_num elapsed_s "$trimmed_top")"
  r_verdict="$(_extract_str verdict "$trimmed_top")"
  r_verify_ran="$(_extract_bool verify_ran "$trimmed_top")"
  r_refunded="$(_extract_num retries_refunded "$trimmed_top")"
  r_issue="$(_extract_num issue "$trimmed_top")"

  has_usage=0
  case "$trimmed" in
    *"\"usage\":{"*) has_usage=1 ;;
  esac

  if [ $has_usage -eq 1 ]; then
    r_inp="$(_extract_nested usage input_tokens "$trimmed")"
    r_out="$(_extract_nested usage output_tokens "$trimmed")"
    r_thk="$(_extract_nested usage thinking_tokens "$trimmed")"
    r_tot="$(_extract_nested usage total_tokens "$trimmed")"
    r_inp="${r_inp:-0}"
    r_out="${r_out:-0}"
    r_thk="${r_thk:-0}"
    r_tot="${r_tot:-0}"
  else
    r_inp="0"
    r_out="0"
    r_thk="0"
    r_tot="0"
  fi

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

  _tsv_write_row \
    "$r_run" "$r_phase" "$r_attempt" "$r_status" "$r_elapsed" "$r_verdict" "$r_verify_ran" "$r_started" \
    "$r_inp" "$r_out" "$r_thk" "$r_tot" "${r_refunded:-0}" "$has_usage" "$r_issue" >> "$VALID_TSV"
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
  while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss; do
    _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss
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

while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss
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

echo "Token Spend by Phase:"
TOTAL_MEASURED_TOKENS=0
LIVE_TOTAL_TOKENS=0
LIVE_INP_TOKENS=0
LIVE_OUT_TOKENS=0
LIVE_THK_TOKENS=0

DEAD_COUNT=0
DEAD_TOTAL_TOKENS=0
DEAD_INP_TOKENS=0
DEAD_OUT_TOKENS=0
DEAD_THK_TOKENS=0
MEASURED_COUNT=0

HAVE_RATES=0
P_IN_MICRO=0
P_OUT_MICRO=0
if [ -n "$PRICE_IN" ] || [ -n "$PRICE_OUT" ]; then
  HAVE_RATES=1
  P_IN_MICRO="$(_parse_price_to_micro "${PRICE_IN:-0}")"
  P_OUT_MICRO="$(_parse_price_to_micro "${PRICE_OUT:-0}")"
fi

while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss
  r_has_u="${r_has_u:-0}"
  [ "$r_has_u" -eq 1 ] || continue

  MEASURED_COUNT=$((MEASURED_COUNT + 1))
  TOTAL_MEASURED_TOKENS=$((TOTAL_MEASURED_TOKENS + r_tot))
  case "$r_st" in
    WORKER_FAILED*)
      DEAD_COUNT=$((DEAD_COUNT + 1))
      DEAD_TOTAL_TOKENS=$((DEAD_TOTAL_TOKENS + r_tot))
      DEAD_INP_TOKENS=$((DEAD_INP_TOKENS + r_inp))
      DEAD_OUT_TOKENS=$((DEAD_OUT_TOKENS + r_out))
      DEAD_THK_TOKENS=$((DEAD_THK_TOKENS + r_thk))
      ;;
    *)
      if [ "$r_ref" = "1" ]; then
        DEAD_COUNT=$((DEAD_COUNT + 1))
        DEAD_TOTAL_TOKENS=$((DEAD_TOTAL_TOKENS + r_tot))
        DEAD_INP_TOKENS=$((DEAD_INP_TOKENS + r_inp))
        DEAD_OUT_TOKENS=$((DEAD_OUT_TOKENS + r_out))
        DEAD_THK_TOKENS=$((DEAD_THK_TOKENS + r_thk))
      else
        LIVE_TOTAL_TOKENS=$((LIVE_TOTAL_TOKENS + r_tot))
        LIVE_INP_TOKENS=$((LIVE_INP_TOKENS + r_inp))
        LIVE_OUT_TOKENS=$((LIVE_OUT_TOKENS + r_out))
        LIVE_THK_TOKENS=$((LIVE_THK_TOKENS + r_thk))
      fi
      ;;
  esac
done < "$VALID_TSV"

if [ "$MEASURED_COUNT" -eq 0 ]; then
  echo "  No token usage recorded in matching dispatches."
else
  for ph in $PHASES; do
    P_INP=0; P_OUT=0; P_THK=0; P_TOT=0
    while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss; do
      _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss
      [ "$r_ph" = "$ph" ] || continue
      r_has_u="${r_has_u:-0}"
      [ "$r_has_u" -eq 1 ] || continue
      case "$r_st" in
        WORKER_FAILED*) continue ;;
      esac
      [ "$r_ref" = "1" ] && continue
      P_INP=$((P_INP + r_inp))
      P_OUT=$((P_OUT + r_out))
      P_THK=$((P_THK + r_thk))
      P_TOT=$((P_TOT + r_tot))
    done < "$VALID_TSV"

    P_PCT=0
    if [ "$LIVE_TOTAL_TOKENS" -gt 0 ]; then
      P_PCT=$(( (P_TOT * 100) / LIVE_TOTAL_TOKENS ))
    fi

    if [ $HAVE_RATES -eq 1 ]; then
      P_COST="$(_format_cost "$P_INP" "$P_OUT" "$P_IN_MICRO" "$P_OUT_MICRO")"
      printf '  %-16s %7d tokens (%s, %3d%% of live total) [inp: %d, out: %d, thk: %d]\n' \
        "$ph:" "$P_TOT" "$P_COST" "$P_PCT" "$P_INP" "$P_OUT" "$P_THK"
    else
      printf '  %-16s %7d tokens (%3d%% of live total) [inp: %d, out: %d, thk: %d]\n' \
        "$ph:" "$P_TOT" "$P_PCT" "$P_INP" "$P_OUT" "$P_THK"
    fi
  done

  if [ $HAVE_RATES -eq 1 ]; then
    TOT_COST="$(_format_cost "$LIVE_INP_TOKENS" "$LIVE_OUT_TOKENS" "$P_IN_MICRO" "$P_OUT_MICRO")"
    printf '  %-16s %7d tokens (%s) [inp: %d, out: %d, thk: %d]\n' \
      "Live Total:" "$LIVE_TOTAL_TOKENS" "$TOT_COST" "$LIVE_INP_TOKENS" "$LIVE_OUT_TOKENS" "$LIVE_THK_TOKENS"
  else
    printf '  %-16s %7d tokens [inp: %d, out: %d, thk: %d]\n' \
      "Live Total:" "$LIVE_TOTAL_TOKENS" "$LIVE_INP_TOKENS" "$LIVE_OUT_TOKENS" "$LIVE_THK_TOKENS"
  fi

  echo ""
  echo "Dead Rounds (refunded worker failures):"
  if [ "$DEAD_COUNT" -gt 0 ]; then
    if [ $HAVE_RATES -eq 1 ]; then
      DEAD_COST="$(_format_cost "$DEAD_INP_TOKENS" "$DEAD_OUT_TOKENS" "$P_IN_MICRO" "$P_OUT_MICRO")"
      printf '  %d dead dispatch(es), %d tokens (%s) [inp: %d, out: %d, thk: %d] (excluded from phase spend)\n' \
        "$DEAD_COUNT" "$DEAD_TOTAL_TOKENS" "$DEAD_COST" "$DEAD_INP_TOKENS" "$DEAD_OUT_TOKENS" "$DEAD_THK_TOKENS"
    else
      printf '  %d dead dispatch(es), %d tokens [inp: %d, out: %d, thk: %d] (excluded from phase spend)\n' \
        "$DEAD_COUNT" "$DEAD_TOTAL_TOKENS" "$DEAD_INP_TOKENS" "$DEAD_OUT_TOKENS" "$DEAD_THK_TOKENS"
    fi
  else
    printf '  0 dead dispatches (no refunded tokens)\n'
  fi

  echo ""
  if [ $HAVE_RATES -eq 1 ]; then
    echo "Token Efficiency and Cost per Successful Task:"
  else
    echo "Token Efficiency per Successful Task:"
  fi
  RUN_LIST="$(awk -F'\t' '{print $1}' "$VALID_TSV" 2>/dev/null | sort -u)"
  TOTAL_RUNS=0
  PASS_RUNS=0
  PASS_RUNS_TOKENS=0
  for r in $RUN_LIST; do
    TOTAL_RUNS=$((TOTAL_RUNS + 1))
    R_PASS=0
    R_TOK=0
    while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss; do
      _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss
      [ "$r_run" = "$r" ] || continue
      r_has_u="${r_has_u:-0}"
      [ "$r_has_u" -eq 1 ] && R_TOK=$((R_TOK + r_tot))
      case "$r_st" in
        PASSED*|DONE*|READY*|PREPARED*|OK*) R_PASS=1 ;;
        FAILED*|BLOCKED*|ERROR*|REJECTED*|WORKER_FAILED*|VERIFY_FAILED*|RETRY_CAP_REACHED*|BUDGET_EXCEEDED*|REPO_BUDGET_EXCEEDED*) R_PASS=0 ;;
      esac
    done < "$VALID_TSV"
    if [ "$R_PASS" -eq 1 ]; then
      PASS_RUNS=$((PASS_RUNS + 1))
      PASS_RUNS_TOKENS=$((PASS_RUNS_TOKENS + R_TOK))
    fi
  done

  if [ "$PASS_RUNS" -gt 0 ]; then
    AVG_TOKENS=$(( PASS_RUNS_TOKENS / PASS_RUNS ))
    if [ $HAVE_RATES -eq 1 ]; then
      AVG_INP=0
      AVG_OUT=0
      if [ "$LIVE_TOTAL_TOKENS" -gt 0 ]; then
        AVG_INP=$(( (AVG_TOKENS * LIVE_INP_TOKENS) / LIVE_TOTAL_TOKENS ))
        AVG_OUT=$(( AVG_TOKENS - AVG_INP ))
      fi
      AVG_COST="$(_format_cost "$AVG_INP" "$AVG_OUT" "$P_IN_MICRO" "$P_OUT_MICRO")"
      printf '  Successful tasks (runs):        %d / %d (%d%%)\n' "$PASS_RUNS" "$TOTAL_RUNS" "$(( (PASS_RUNS * 100) / TOTAL_RUNS ))"
      printf '  Avg tokens / successful task:   %d tokens (%s)\n' "$AVG_TOKENS" "$AVG_COST"
    else
      printf '  Successful tasks (runs):        %d / %d (%d%%)\n' "$PASS_RUNS" "$TOTAL_RUNS" "$(( (PASS_RUNS * 100) / TOTAL_RUNS ))"
      printf '  Avg tokens / successful task:   %d tokens\n' "$AVG_TOKENS"
    fi
  else
    printf '  Successful tasks (runs):        0 / %d (no successful tasks)\n' "$TOTAL_RUNS"
  fi
fi
echo ""

VERIFY_OVERRIDES=0
NO_STATUS_COUNT=0

# shellcheck disable=SC2034 # TSV columns read to match 15-column schema
while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss
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
