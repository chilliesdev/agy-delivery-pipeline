#!/usr/bin/env bash
# Exercise run-trace.sh: reading a dispatch's step stream, and refusing clearly
# when there is no stream to read.
#
#   tests/run-trace.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE="$HERE/../scripts/run-trace.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"

[ -f "$TRACE" ] || { echo "run-trace-test: run-trace.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "run-trace-test: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/run-trace.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# A stream in the shape a real agy stream-json dispatch emits. The usage figures
# are taken from an actual dispatch, because the arithmetic below is the point:
# the steps must sum to what the result reports.
write_stream() {
  cat > "$1" <<'NDJSON'
{"event":"init","conversation_id":"c-1","init":{"model":"gemini-3.7-flash-low","cwd":"/tmp"}}
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":0,"state":"DONE","step_type":"user_input"}}
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":1,"state":"DONE","step_type":"agent_response","duration_seconds":1.772,"usage":{"input_tokens":16847,"output_tokens":69,"thinking_tokens":6,"cache_read_tokens":0,"total_tokens":16916}}}
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"find_by_name"}}
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":2,"state":"DONE","step_type":"tool","tool_name":"find_by_name","duration_seconds":0.100}}
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":3,"state":"DONE","step_type":"agent_response","duration_seconds":1.321,"usage":{"input_tokens":16995,"output_tokens":89,"thinking_tokens":8,"cache_read_tokens":0,"total_tokens":17084}}}
jetski: a human-facing notice that is not JSON at all
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":5,"state":"DONE","step_type":"agent_response","duration_seconds":2.524,"usage":{"input_tokens":4981,"output_tokens":120,"thinking_tokens":21,"cache_read_tokens":12191,"total_tokens":5101}}}
{"event":"result","result":{"conversation_id":"c-1","status":"SUCCESS","response":"done","duration_seconds":5.7,"num_turns":3,"usage":{"input_tokens":38823,"output_tokens":278,"thinking_tokens":35,"cache_read_tokens":12191,"total_tokens":39101}}}
NDJSON
}

S="$ROOT/stream.ndjson"
write_stream "$S"

# --- the TSV view -----------------------------------------------------------

OUT="$(/bin/bash "$TRACE" --stream "$S" 2>/dev/null)"; CODE=$?
check tsv-rc "$CODE" 0 "reading a stream exits 0"

BODY="$(printf '%s\n' "$OUT" | tail -n +2)"
check tsv-rows "$(printf '%s\n' "$BODY" | grep -c .)" "5" \
  "one row per DONE step — the ACTIVE announcement is not counted twice"

if printf '%s\n' "$BODY" | grep -q '	find_by_name	'; then
  ok tsv-tool-name "a tool step carries the tool that ran"
else
  bad tsv-tool-name "tool name missing: $BODY"
fi

if printf '%s\n' "$OUT" | grep -q 'jetski'; then
  bad tsv-ignores-noise "a non-JSON notice was parsed as a step"
else
  ok tsv-ignores-noise "non-JSON lines in the stream are stepped over"
fi

# --- the arithmetic this exists to make checkable ---------------------------
#
# Per-step usage adds up to the dispatch total exactly. If that ever stops being
# true, the stream and the ledger disagree and somebody is reading a wrong number.

SUM_IN="$(printf '%s\n' "$BODY" | awk -F'\t' '{ n += $5 } END { print n+0 }')"
SUM_OUT="$(printf '%s\n' "$BODY" | awk -F'\t' '{ n += $6 } END { print n+0 }')"
SUM_THK="$(printf '%s\n' "$BODY" | awk -F'\t' '{ n += $7 } END { print n+0 }')"
SUM_TOT="$(printf '%s\n' "$BODY" | awk -F'\t' '{ n += $9 } END { print n+0 }')"
SUM_CACHE="$(printf '%s\n' "$BODY" | awk -F'\t' '{ n += $8 } END { print n+0 }')"

check sum-input "$SUM_IN" "38823" "step input tokens sum to the input the result reports"
check sum-output "$SUM_OUT" "278" "step output tokens sum to the output the result reports"
check sum-total "$SUM_TOT" "39101" "step totals sum to the total the result reports"
check total-is-in-plus-out "$((SUM_IN + SUM_OUT))" "$SUM_TOT" \
  "total is input plus output — thinking is not a third addend"

if [ "$SUM_THK" -le "$SUM_OUT" ]; then
  ok thinking-within-output "thinking is a portion of output, not a slice beside it"
else
  bad thinking-within-output "thinking ($SUM_THK) exceeds output ($SUM_OUT)"
fi

check cache-outside-total "$SUM_CACHE" "12191" \
  "cache reads are reported and are not folded into the total"

# The case that breaks a naive reader. On a long conversation the cache reads run
# an order of magnitude above the billed total — these are the figures from an
# actual DELEGATE dispatch in this repo's ledger. Anything that adds cache reads
# into a spend bar reports this run at eight times its real cost.
S_CACHE="$ROOT/cache-heavy.ndjson"
cat > "$S_CACHE" <<'NDJSON'
{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","duration_seconds":121.6,"usage":{"input_tokens":163607,"output_tokens":24892,"thinking_tokens":21062,"cache_read_tokens":1410239,"total_tokens":188499}}}
NDJSON
OUT_CACHE="$(/bin/bash "$TRACE" --stream "$S_CACHE" 2>/dev/null | tail -n +2)"
C_IN="$(printf '%s\n' "$OUT_CACHE" | awk -F'\t' '{ print $5 }')"
C_OUT="$(printf '%s\n' "$OUT_CACHE" | awk -F'\t' '{ print $6 }')"
C_THK="$(printf '%s\n' "$OUT_CACHE" | awk -F'\t' '{ print $7 }')"
C_CACHE="$(printf '%s\n' "$OUT_CACHE" | awk -F'\t' '{ print $8 }')"
C_TOT="$(printf '%s\n' "$OUT_CACHE" | awk -F'\t' '{ print $9 }')"

check cache-heavy-total "$((C_IN + C_OUT))" "$C_TOT" \
  "total is still input plus output when cache reads are large"
if [ "$C_CACHE" -gt "$C_TOT" ]; then
  ok cache-heavy-dominates "cache reads run far above the billed total on a real dispatch"
else
  bad cache-heavy-dominates "cache ($C_CACHE) did not exceed total ($C_TOT)"
fi
if [ "$C_THK" -lt "$C_OUT" ]; then
  ok cache-heavy-thinking "thinking stays inside output at scale, not beside it"
else
  bad cache-heavy-thinking "thinking ($C_THK) is not within output ($C_OUT)"
fi

# --- the summary view -------------------------------------------------------

SUMM="$(/bin/bash "$TRACE" --stream "$S" --summary 2>/dev/null)"; CODE=$?
check summary-rc "$CODE" 0 "the summary view exits 0"
if printf '%s\n' "$SUMM" | grep -q '38823 input + 278 output = 39101 total'; then
  ok summary-arithmetic "the summary shows the arithmetic rather than one unexplained number"
else
  bad summary-arithmetic "summary arithmetic missing: $SUMM"
fi
if printf '%s\n' "$SUMM" | grep -q 'not added to it'; then
  ok summary-cache-note "the summary says cache reads are outside the total"
else
  bad summary-cache-note "no cache note in the summary"
fi
if printf '%s\n' "$SUMM" | grep -q 'disagrees with itself'; then
  bad summary-no-false-alarm "the mismatch warning fired on a consistent stream"
else
  ok summary-no-false-alarm "no mismatch warning when the stream agrees with itself"
fi

# A stream whose columns do not add up must say so rather than pick a number.
S_BAD="$ROOT/bad.ndjson"
cat > "$S_BAD" <<'NDJSON'
{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","duration_seconds":1.0,"usage":{"input_tokens":100,"output_tokens":10,"thinking_tokens":2,"cache_read_tokens":0,"total_tokens":999}}}
NDJSON
SUMM_BAD="$(/bin/bash "$TRACE" --stream "$S_BAD" --summary 2>/dev/null)"
if printf '%s\n' "$SUMM_BAD" | grep -q 'disagrees with itself'; then
  ok summary-flags-mismatch "a stream that does not add up is flagged, not silently reconciled"
else
  bad summary-flags-mismatch "inconsistent stream went unreported: $SUMM_BAD"
fi

# --- resolving a stream through a run directory -----------------------------

R="$ROOT/repo"; mkdir -p "$R"
( cd "$R" && git init -q . && git config user.email t@e.com && git config user.name T \
    && git commit -q --allow-empty -m initial )
RUN_ID="$(run_dir_new --dir "$R" --task "trace test")"
mkdir -p "$R/.agy/runs/$RUN_ID/phases/REVIEW"
write_stream "$R/.agy/runs/$RUN_ID/phases/REVIEW/stream.ndjson"

/bin/bash "$TRACE" --dir "$R" --run "$RUN_ID" --phase REVIEW >/dev/null 2>&1
check resolve-by-phase "$?" 0 "a stream is found through --run and --phase"

/bin/bash "$TRACE" --dir "$R" --run "$RUN_ID" >/dev/null 2>&1
check resolve-without-phase "$?" 0 "with no --phase, the run's most recent stream is used"

# --- refusing clearly where there is no stream ------------------------------
#
# Every dispatch recorded before stream capture is this case, as is any run under
# AGY_OUTPUT_FORMAT=json. It must be distinguishable from an error.

mkdir -p "$R/.agy/runs/$RUN_ID/phases/QA"
/bin/bash "$TRACE" --dir "$R" --run "$RUN_ID" --phase QA >/dev/null 2>&1
check no-stream-rc "$?" 3 "a phase with no stream exits 3, distinct from a bad argument"

ERR="$(/bin/bash "$TRACE" --dir "$R" --run "$RUN_ID" --phase QA 2>&1 >/dev/null)"
if printf '%s\n' "$ERR" | grep -q 'AGY_OUTPUT_FORMAT=json'; then
  ok no-stream-explains "the refusal names the two reasons a stream can be absent"
else
  bad no-stream-explains "unhelpful refusal: $ERR"
fi

/bin/bash "$TRACE" --bogus >/dev/null 2>&1
check bad-arg "$?" 2 "exit 2 on an unknown flag"

# --- read-only --------------------------------------------------------------

BEFORE="$(find "$R" -type f | sort)"
/bin/bash "$TRACE" --dir "$R" --run "$RUN_ID" --phase REVIEW >/dev/null 2>&1
/bin/bash "$TRACE" --dir "$R" --run "$RUN_ID" --phase REVIEW --summary >/dev/null 2>&1
AFTER="$(find "$R" -type f | sort)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok read-only "reading a trace writes nothing"
else
  bad read-only "run-trace.sh wrote files"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
