#!/usr/bin/env bash
# Reconstruct what a dispatch did, step by step, from the worker's own stream.
#
#   run-trace.sh [--dir <repo>] [--run <id|current|last>] [--phase <NAME>]
#                [--summary] [--stream <path>]
#
# Reads:   <run-dir>/phases/<PHASE>/stream.ndjson   written by drivers/agy.sh
# Writes:  nothing.
# Prints:  one row per completed step. Tab-separated by default:
#
#            step  type  tool  seconds  input  output  thinking  cache_read  total
#
#          --summary prints the same rows as a proportional timing view, with the
#          run totals underneath.
#
# Exit codes:
#     0  the stream was read
#     2  bad arguments
#     3  no stream for that run and phase — the dispatch predates stream capture,
#        or ran under AGY_OUTPUT_FORMAT=json, which emits no stream
#     4  --dir is not a git work tree
#
# How these numbers relate to the ledger's.
#
# The ledger records one row per dispatch, carrying the run total from agy's result
# object. These are the per-step rows underneath it, and they add up to it exactly:
# on the sample this was built against, the step input_tokens sum to 38823 and the
# result reports 38823; output to 278 against 278; total to 39101 against 39101.
# Each step is billed for its own turn, not for the conversation so far.
#
# That makes this a check as well as a view: if the rows stop summing to the
# dispatch total, one of the two is wrong, and --summary prints both so the
# disagreement is visible rather than assumed away.
#
# The one column that does not belong in a spend total is cache_read_tokens, which
# agy reports outside total_tokens — a step with 12191 cache reads and 4981 input
# has a total of 5101. Cache reads are shown because they dominate the raw traffic;
# they are not added to anything.
#
# Only DONE rows are printed. Every step is announced twice, ACTIVE then DONE, and
# only the second carries the duration and the usage. Counting both would report
# every step twice with half the rows empty.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"
RUN_TARGET="current"
PHASE=""
STREAM=""
SUMMARY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="$2";        shift 2 ;;
    --run)     RUN_TARGET="$2"; shift 2 ;;
    --phase)   PHASE="$2";      shift 2 ;;
    --stream)  STREAM="$2";     shift 2 ;;
    --summary) SUMMARY=1;       shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "run-trace: unknown arg $1" >&2; exit 2 ;;
  esac
done

if [ -z "$STREAM" ]; then
  [ -d "$DIR" ] || { echo "run-trace: dir not found: $DIR" >&2; exit 2; }
  DIR="$(cd "$DIR" && pwd)"
  git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "run-trace: not a git repository: $DIR" >&2; exit 4; }

  R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET" 2>/dev/null || true)"
  [ -n "$R" ] && [ -d "$R" ] || { echo "run-trace: no such run: $RUN_TARGET" >&2; exit 3; }

  # With no --phase, take the most recently written stream in the run.
  if [ -z "$PHASE" ]; then
    NEWEST=""
    for f in "$R"/phases/*/stream.ndjson; do
      [ -f "$f" ] || continue
      if [ -z "$NEWEST" ] || [ "$f" -nt "$NEWEST" ]; then NEWEST="$f"; fi
    done
    STREAM="$NEWEST"
  else
    STREAM="$R/phases/$PHASE/stream.ndjson"
  fi
fi

if [ -z "$STREAM" ] || [ ! -f "$STREAM" ] || [ ! -s "$STREAM" ]; then
  echo "run-trace: no step stream found${PHASE:+ for phase $PHASE}" >&2
  echo "run-trace: dispatches recorded before stream capture, or run with" >&2
  echo "run-trace: AGY_OUTPUT_FORMAT=json, have no stream to read" >&2
  exit 3
fi

# Narrow field readers for agy's known stream shape, not a general JSON parser —
# the same choice made in drivers/agy.sh and for the same reason: no jq, no python.
_f_str() { printf '%s\n' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }
_f_num() { printf '%s\n' "$2" | sed -n "s/.*\"$1\":\([0-9][0-9.]*\).*/\1/p" | head -1; }

ROWS=""
STEPS=0
WALL=0

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'"event":"step_update"'*) ;;
    *) continue ;;
  esac
  case "$line" in
    *'"state":"DONE"'*) ;;
    *) continue ;;
  esac

  s_idx="$(_f_num step_index "$line")"
  s_type="$(_f_str step_type "$line")"
  s_tool="$(_f_str tool_name "$line")"
  s_dur="$(_f_num duration_seconds "$line")"
  u_in="$(_f_num input_tokens "$line")"
  u_out="$(_f_num output_tokens "$line")"
  u_thk="$(_f_num thinking_tokens "$line")"
  u_cache="$(_f_num cache_read_tokens "$line")"
  u_tot="$(_f_num total_tokens "$line")"

  ROWS="$ROWS${s_idx:-0}	${s_type:--}	${s_tool:--}	${s_dur:-0}	${u_in:-0}	${u_out:-0}	${u_thk:-0}	${u_cache:-0}	${u_tot:-0}
"
  STEPS=$((STEPS + 1))
  WALL="$(awk -v a="$WALL" -v b="${s_dur:-0}" 'BEGIN { printf "%.3f", a + b }')"
done < "$STREAM"

if [ "$STEPS" -eq 0 ]; then
  echo "run-trace: the stream carries no completed steps" >&2
  exit 3
fi

if [ "$SUMMARY" -eq 0 ]; then
  printf 'step\ttype\ttool\tseconds\tinput\toutput\tthinking\tcache_read\ttotal\n'
  printf '%s' "$ROWS"
  exit 0
fi

# --- summary view -----------------------------------------------------------

printf 'Step trace: %s\n' "$STREAM"
printf '%s completed step(s), %ss of worker time\n\n' "$STEPS" "$WALL"

printf '%s' "$ROWS" | awk -F'\t' -v wall="$WALL" '
  {
    idx = $1; type = $2; tool = $3; dur = $4 + 0; thk = $7 + 0
    label = (tool != "-" ? tool : type)
    width = (wall > 0 ? int((dur / wall) * 40) : 0)
    if (width < 1 && dur > 0) width = 1
    bar = ""
    for (i = 0; i < width; i++) bar = bar "#"
    note = ""
    if (thk > 0) note = sprintf("  thinking %s tok", thk)
    printf "  %3s  %-16.16s %-40s %7.2fs%s\n", idx, label, bar, dur, note
  }
'

# Sum the rows and show the arithmetic. If this stops matching the dispatch total
# the ledger recorded, the two disagree and a reader should see that rather than
# be handed one number and told to trust it.
printf '%s' "$ROWS" | awk -F'\t' '
  { inp += $5; out += $6; thk += $7; cache += $8; tot += $9 }
  END {
    printf "\n  Summed over steps: %d input + %d output = %d total", inp, out, inp + out
    printf " (of which %d thinking)\n", thk
    if (inp + out != tot)
      printf "  NOTE: the step totals column sums to %d, which does not match — the stream disagrees with itself\n", tot
    printf "  Cache reads: %d, reported outside the total and not added to it.\n", cache
    printf "  Compare against the total_tokens the ledger recorded for this dispatch.\n"
  }
'
exit 0
