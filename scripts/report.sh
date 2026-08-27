#!/usr/bin/env bash
# Report summary metrics over the run ledger in <repo>/.agy/ledger.jsonl.
#
#   report.sh [--dir <repo>] [--since <date>] [--phase <NAME>] [--run <id>]
#             [--price-in <usd-per-mtok>] [--price-out <usd-per-mtok>]
#
# Reads:   <repo>/.agy/ledger.jsonl
# Prints:  plain-text summary report of dispatch outcomes, retries, verify overrides,
#          elapsed time distribution, token spend by phase, gate firing counts,
#          never-fired gates, and unparseable records.
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
NO_CONTEXT_COUNT=0
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

# Matched with shell globs rather than sed. Written as one BRE alternation
# — s/.*"key":\(true\|false\).*/\1/ — this returned nothing at all on BSD sed,
# whose basic regex has no \|, so every boolean in the ledger read as absent on
# macOS and nothing said so.
_extract_bool() {
  local key="$1"
  local line="$2"
  case "$line" in
    *"\"$key\":true"*)  printf 'true\n' ;;
    *"\"$key\":false"*) printf 'false\n' ;;
  esac
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
  r_agy_status="$(_extract_str agy_status "$trimmed_top")"
  r_verdict_route="$(_extract_str verdict_route "$trimmed_top")"
  r_dispatched="$(_extract_bool dispatched "$trimmed_top")"
  # The Phase 2 review verdict rides in the nested review object rather than in
  # status, so it has to be read before the nested objects are stripped above.
  r_review_status="$(_extract_nested review status "$trimmed")"

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

  # A well-formed line carrying no dispatch context is not corrupt. issue.sh
  # writes one to note which issue a run came from, and calling that unparseable
  # accuses the ledger of damage it does not have.
  if [ -z "$r_run" ] || [ -z "$r_phase" ] || [ -z "$r_status" ]; then
    NO_CONTEXT_COUNT=$((NO_CONTEXT_COUNT + 1))
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
    "$r_inp" "$r_out" "$r_thk" "$r_tot" "${r_refunded:-0}" "$has_usage" "$r_issue" "$r_agy_status" "$r_verdict_route" \
    "$r_dispatched" "$r_review_status" >> "$VALID_TSV"
done < "$LEDGER_FILE"

TOTAL_VALID="$(grep -c . "$VALID_TSV" 2>/dev/null || true)"
TOTAL_VALID="${TOTAL_VALID:-0}"

# A record marked "dispatched":false is a gate that refused before any worker
# ran. It cost no model call, carries no usage and no elapsed time, and must be
# kept out of dispatch counts, pass rates and spend averages — while still being
# counted as a gate that fired. Records written before the field existed cannot
# be classified either way, so they are named separately rather than guessed at.
DISPATCH_COUNT=0
REFUSAL_COUNT=0
UNMARKED_COUNT=0
while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
  case "$r_disp" in
    false) REFUSAL_COUNT=$((REFUSAL_COUNT + 1)) ;;
    true)  DISPATCH_COUNT=$((DISPATCH_COUNT + 1)) ;;
    *)     UNMARKED_COUNT=$((UNMARKED_COUNT + 1)) ;;
  esac
done < "$VALID_TSV"

echo "Run Ledger Report"
echo "================="
echo "Ledger:     $LEDGER_FILE"
echo "Filters:    since=${SINCE:-all}, phase=${FILTER_PHASE:-all}, run=${FILTER_RUN:-all}"
echo "Records:    $TOTAL_READ line(s) read — $TOTAL_VALID with dispatch context, $NO_CONTEXT_COUNT without, $SKIPPED_COUNT unparseable"
printf 'Dispatches: %d (a worker ran)\n' "$DISPATCH_COUNT"
printf 'Refusals:   %d (a gate fired before any worker ran — no model call, no spend)\n' "$REFUSAL_COUNT"
if [ "$UNMARKED_COUNT" -gt 0 ]; then
  printf 'Unmarked:   %d (recorded before the dispatched field existed — counted as dispatches below)\n' "$UNMARKED_COUNT"
fi
echo ""

if [ "$TOTAL_VALID" -eq 0 ]; then
  echo "No dispatches matched the specified criteria."
  exit 0
fi

echo "Dispatches and Pass Rates by Phase:"
echo "  Refusals are excluded from the rate: a gate that fired before the dispatch"
echo "  is not a worker that failed, and counting it as one understates the worker."
PHASES="$(awk -F'\t' '{print $2}' "$VALID_TSV" 2>/dev/null | sort -u)"
for ph in $PHASES; do
  P_LINES="$(awk -F'\t' -v p="$ph" '$2 == p' "$VALID_TSV")"
  P_TOTAL=0
  P_PASS=0
  P_REFUSED=0
  while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
    _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
    if [ "$r_disp" = "false" ]; then
      P_REFUSED=$((P_REFUSED + 1))
      continue
    fi
    P_TOTAL=$((P_TOTAL + 1))
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
  if [ "$P_TOTAL" -eq 0 ]; then
    printf '  %-16s %3d dispatches, %3d refused (no worker ever ran for this phase)\n' \
      "$ph:" "$P_TOTAL" "$P_REFUSED"
  else
    printf '  %-16s %3d dispatches, %3d passed (%d%%), %3d refused\n' \
      "$ph:" "$P_TOTAL" "$P_PASS" "$P_PCT" "$P_REFUSED"
  fi
done
echo ""

echo "Retry Convergence Distribution:"
ROUND_1=0
ROUND_2=0
ROUND_3_PLUS=0
CAP_REACHED=0

while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
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

while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
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
    while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
      _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
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
  # A run whose every record is a refusal never reached a worker. Counting it as
  # an unsuccessful task measures the gate, not the worker, and drags the rate
  # down by exactly the number of times a brief was caught before it cost
  # anything — which is the opposite of what that number is for.
  SKIPPED_RUNS=0
  for r in $RUN_LIST; do
    R_PASS=0
    R_TOK=0
    R_DISPATCHED=0
    while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
      _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
      [ "$r_run" = "$r" ] || continue
      [ "$r_disp" = "false" ] && continue
      R_DISPATCHED=$((R_DISPATCHED + 1))
      r_has_u="${r_has_u:-0}"
      [ "$r_has_u" -eq 1 ] && R_TOK=$((R_TOK + r_tot))
      case "$r_st" in
        PASSED*|DONE*|READY*|PREPARED*|OK*) R_PASS=1 ;;
        FAILED*|BLOCKED*|ERROR*|REJECTED*|WORKER_FAILED*|VERIFY_FAILED*|RETRY_CAP_REACHED*|BUDGET_EXCEEDED*|REPO_BUDGET_EXCEEDED*) R_PASS=0 ;;
      esac
    done < "$VALID_TSV"
    if [ "$R_DISPATCHED" -eq 0 ]; then
      SKIPPED_RUNS=$((SKIPPED_RUNS + 1))
      continue
    fi
    TOTAL_RUNS=$((TOTAL_RUNS + 1))
    if [ "$R_PASS" -eq 1 ]; then
      PASS_RUNS=$((PASS_RUNS + 1))
      PASS_RUNS_TOKENS=$((PASS_RUNS_TOKENS + R_TOK))
    fi
  done
  if [ "$SKIPPED_RUNS" -gt 0 ]; then
    printf '  Runs refused before dispatch:   %d (excluded — no worker ran, so there is no efficiency to measure)\n' \
      "$SKIPPED_RUNS"
  fi

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

# Every gate this report can count, in one table, so the firing counts and the
# never-fired list cannot disagree about what a gate is. Two lists kept by hand
# is how a gate gets counted and then quietly left out of the list that says it
# never fired — or the reverse.
#
# Field 1 is where the outcome is recorded: "status" for the record's own status
# field, "review" for the Phase 2 verdict, which rides in the nested review
# object rather than in status. Field 2 is the status prefix, field 3 the label.
#
# Field 4 is what kind of claim the gate makes, which decides whether asking "was
# it right?" is even a question:
#
#   mechanical  the gate IS the measurement — a command exited non-zero, git moved.
#               There is nothing to corroborate; a precision figure here would be
#               a restatement of the fact, dressed as an assessment of it.
#   refusal     it fired before any worker ran. Whether the dispatch would have
#               failed is unknowable by construction: the run does not exist.
#               A refusal gate can never be scored, and saying so is the honest
#               answer rather than reporting it as unproven.
#   advisory    a suspicion a later signal can corroborate. Only these can carry
#               a number, and only where the later signal was actually recorded.
GATE_TABLE="
status|VERIFY_FAILED|Verify gate overrides|mechanical
status|DIFF_TESTS_WEAKENED|Diff tests weakened|advisory
status|DIFF_SUSPICIOUS|Diff suspicious|advisory
status|SECRETS_FOUND|Secrets found|refusal
status|BRIEF_INVALID|Brief invalid|refusal
status|BRIEF_IMPOSSIBLE|Brief impossible|mechanical
status|NO_STATUS_REPORTED|No status reported|mechanical
status|WORKER_FAILED|Worker failed|mechanical
status|RETRY_CAP_REACHED|Retry cap reached|refusal
status|BUDGET_EXCEEDED|Run budget exceeded|refusal
status|REPO_BUDGET_EXCEEDED|Repo budget exceeded|refusal
status|WORKER_CAP_EXCEEDED|Worker cap exceeded|refusal
status|PREFLIGHT_FAILED|Preflight failed|refusal
status|GIT_STATE_CHANGED|Git state changed|mechanical
status|RANGE_REFUSED|Phase range refused|refusal
status|TEST_COMMAND_NOT_RUNNABLE|Test command not runnable|mechanical
status|TEST_COMMAND_FAILED|Test command failed|mechanical
status|TEST_COMMAND_TIMEOUT|Test command timed out|mechanical
status|RELEASE_BLOCKED|Release blocked|refusal
status|RELEASE_FAILED|Release failed|mechanical
review|REVIEW_THIN|Review thin|advisory
review|REVIEW_ABSENT|Review absent|advisory
"

GATE_SRC=()
GATE_KEY=()
GATE_LABEL=()
GATE_COUNT=()
GATE_CLASS=()
while IFS='|' read -r g_src g_key g_label g_class; do
  [ -n "$g_key" ] || continue
  GATE_SRC[${#GATE_SRC[@]}]="$g_src"
  GATE_KEY[${#GATE_KEY[@]}]="$g_key"
  GATE_LABEL[${#GATE_LABEL[@]}]="$g_label"
  GATE_CLASS[${#GATE_CLASS[@]}]="$g_class"
  GATE_COUNT[${#GATE_COUNT[@]}]=0
done <<EOF
$GATE_TABLE
EOF
GATE_N=${#GATE_KEY[@]}

WORKER_ERROR_COUNT=0
PRINTED_VERDICT_COUNT=0

# shellcheck disable=SC2034 # TSV columns read to match the recorded schema
while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
  gi=0
  while [ "$gi" -lt "$GATE_N" ]; do
    g_key="${GATE_KEY[$gi]}"
    if [ "${GATE_SRC[$gi]}" = "review" ]; then
      g_field="$r_rev"
    else
      g_field="$r_st"
    fi
    # Prefix rather than glob: a status carries its reason in parentheses
    # (BRIEF_INVALID(missing-verdict-path)), and the reason is not the gate.
    if [ "${g_field:0:${#g_key}}" = "$g_key" ]; then
      GATE_COUNT[$gi]=$(( ${GATE_COUNT[$gi]} + 1 ))
    fi
    gi=$((gi + 1))
  done
  case "$r_agy_st" in
    ERROR*|error*|Error*) WORKER_ERROR_COUNT=$((WORKER_ERROR_COUNT + 1)) ;;
  esac
  case "$r_vd_rt" in
    print*|fallback*) PRINTED_VERDICT_COUNT=$((PRINTED_VERDICT_COUNT + 1)) ;;
  esac
done < "$VALID_TSV"

echo "Gate and Verification Outcomes:"
printf '  Worker error dispatches:        %d (worker recorded ERROR status)\n' "$WORKER_ERROR_COUNT"
printf '  Printed fallback dispatches:    %d (verdict read from printed fallback route rather than file)\n' "$PRINTED_VERDICT_COUNT"
echo ""

echo "Gate Firing Counts:"
gi=0
FIRED_ANY=0
while [ "$gi" -lt "$GATE_N" ]; do
  printf '  %-32s %d\n' "${GATE_LABEL[$gi]}:" "${GATE_COUNT[$gi]}"
  [ "${GATE_COUNT[$gi]}" -gt 0 ] && FIRED_ANY=$((FIRED_ANY + 1))
  gi=$((gi + 1))
done
echo ""

# --- gate corroboration -----------------------------------------------------
#
# "How often was this gate right?" is the question a reader actually has, and for
# most gates it is not answerable — which is itself the answer worth printing. A
# precision column filled in for every row would be mostly invention, and a reader
# deleting a gate on the strength of an invented number is the exact harm the
# never-fired list was rewritten to avoid.
#
# One correlation the ledger does support: a review recorded REVIEW_THIN, and the
# same run later failing --verify. That is the case check-review.sh was written
# for, and it is the only gate here with a later signal to check against.

THIN_RUNS=""
FAILED_RUNS=""
# shellcheck disable=SC2034 # TSV columns read to match the recorded schema
while IFS=$'\t' read -r r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev; do
  _tsv_restore r_run r_ph r_att r_st r_el r_vd r_vr r_st_ts r_inp r_out r_thk r_tot r_ref r_has_u r_iss r_agy_st r_vd_rt r_disp r_rev
  [ -n "$r_run" ] || continue
  case "$r_rev" in
    REVIEW_THIN*) THIN_RUNS="$THIN_RUNS$r_run
" ;;
  esac
  case "$r_st" in
    VERIFY_FAILED*) FAILED_RUNS="$FAILED_RUNS$r_run
" ;;
  esac
done < "$VALID_TSV"

THIN_TOTAL=0
THIN_CORROBORATED=0
if [ -n "$THIN_RUNS" ]; then
  while IFS= read -r tr; do
    [ -n "$tr" ] || continue
    THIN_TOTAL=$((THIN_TOTAL + 1))
    if printf '%s' "$FAILED_RUNS" | grep -Fqx "$tr"; then
      THIN_CORROBORATED=$((THIN_CORROBORATED + 1))
    fi
  done <<EOF
$THIN_RUNS
EOF
fi

echo "Gate Corroboration:"
echo "  Whether a gate was *right* is a different question from how often it fired,"
echo "  and for most gates here it cannot be answered. Each is labelled by what kind"
echo "  of claim it makes rather than given a number that would have to be invented."
gi=0
while [ "$gi" -lt "$GATE_N" ]; do
  if [ "${GATE_COUNT[$gi]}" -gt 0 ]; then
    case "${GATE_CLASS[$gi]}" in
      mechanical)
        printf '  %-32s %d fired — mechanical: the gate is the measurement, not a judgement about it\n' \
          "${GATE_LABEL[$gi]}:" "${GATE_COUNT[$gi]}"
        ;;
      refusal)
        printf '  %-32s %d fired — refused before dispatch: the run does not exist, so it cannot be scored\n' \
          "${GATE_LABEL[$gi]}:" "${GATE_COUNT[$gi]}"
        ;;
      advisory)
        if [ "${GATE_KEY[$gi]}" = "REVIEW_THIN" ] && [ "$THIN_TOTAL" -gt 0 ]; then
          printf '  %-32s %d fired — %d of %d were in a run that later failed --verify\n' \
            "${GATE_LABEL[$gi]}:" "${GATE_COUNT[$gi]}" "$THIN_CORROBORATED" "$THIN_TOTAL"
        else
          printf '  %-32s %d fired — advisory: no later signal is recorded to check it against\n' \
            "${GATE_LABEL[$gi]}:" "${GATE_COUNT[$gi]}"
        fi
        ;;
      *)
        printf '  %-32s %d fired\n' "${GATE_LABEL[$gi]}:" "${GATE_COUNT[$gi]}"
        ;;
    esac
  fi
  gi=$((gi + 1))
done
[ "$FIRED_ANY" -eq 0 ] && echo "  (no gate in the filtered ledger has fired)"
echo ""

echo "Never-Fired Gates:"
echo "  Nothing in the filtered ledger triggered these — either nothing has yet, or"
echo "  the gate is dead code. Every gate above is ledger-visible: a gate that refuses"
echo "  before the dispatch records with \"dispatched\":false rather than not at all,"
echo "  so a zero here means it did not fire, not that it could not be seen."
NEVER=0
gi=0
while [ "$gi" -lt "$GATE_N" ]; do
  if [ "${GATE_COUNT[$gi]}" -eq 0 ]; then
    echo "  - ${GATE_LABEL[$gi]}"
    NEVER=$((NEVER + 1))
  fi
  gi=$((gi + 1))
done
[ "$NEVER" -eq 0 ] && echo "  (none — every gate has fired at least once)"
echo ""

echo "Data Integrity:"
printf '  Records with no dispatch context: %d (well-formed, but carry no run/phase/status — issue markers and the like)\n' "$NO_CONTEXT_COUNT"
printf '  Unparseable records skipped:      %d\n' "$SKIPPED_COUNT"

exit 0
