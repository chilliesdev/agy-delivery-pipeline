#!/usr/bin/env bash
# Exercise ledger.sh, phase.sh ledger integration, and report.sh:
# record format, privacy hashing, unknown field omission, single-line invariant,
# additive appends, corrupt line tolerance, diff/review sub-objects, and reporting.
#
#   tests/ledger.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_SH="$HERE/../scripts/ledger.sh"
REPORT_SH="$HERE/../scripts/report.sh"
PHASE_SH="$HERE/../scripts/phase.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"

[ -f "$LEDGER_SH" ] || { echo "ledger-test: ledger.sh not found next door" >&2; exit 2; }
[ -f "$REPORT_SH" ] || { echo "ledger-test: report.sh not found next door" >&2; exit 2; }
[ -f "$PHASE_SH" ] || { echo "ledger-test: phase.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "ledger-test: run-dir.sh not found next door" >&2; exit 2; }

. "$RUN_DIR_SH"
. "$LEDGER_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ledger-test.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

# The stub agy: answers `models` for preflight, otherwise writes the verdict
# named by STUB_VERDICT and exits STUB_RC.
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
  exit 0
fi
[ -n "${STUB_RAN:-}" ] && printf 'ran\n' >> "$STUB_RAN"
if [ -f .agy/current ]; then
  CUR_RUN="$(cat .agy/current 2>/dev/null || true)"
  if [ -n "$CUR_RUN" ] && [ -z "${STUB_NO_VERDICT_FILE:-}" ]; then
    mkdir -p ".agy/runs/$CUR_RUN/phases/$STUB_PHASE"
    printf '%s\n' "${STUB_VERDICT:-STATUS: PASSED | File: CHANGES.md}" > ".agy/runs/$CUR_RUN/phases/$STUB_PHASE/verdict"
  fi
fi
if [ -n "${STUB_OUTPUT:-}" ]; then
  printf '%s\n' "$STUB_OUTPUT"
elif [ -n "${STUB_VERDICT:-}" ]; then
  printf '%s\n' "$STUB_VERDICT"
else
  printf '{"conversation_id":"c-123","status":"SUCCESS","response":"STATUS: PASSED | File: CHANGES.md\\n","duration_seconds":1.5,"num_turns":1,"usage":{"input_tokens":16813,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":16814}}\n'
fi
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
count_lines() { local c; c="$(grep -c . "$1" 2>/dev/null || true)"; printf '%s' "${c:-0}"; }

new_repo() {
  local r="$ROOT/repos/$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  printf 'do the thing\n' > "$r/brief.md"
  printf '%s' "$r"
}

# Dispatch helper for ledger tests: passes --no-brief-lint because this suite
# tests dispatch mechanics and ledger accounting; the brief is a stub by design,
# and brief validity has its own suite (tests/check-brief.sh).
run_phase() {
  local repo="$1"
  shift
  STUB_PHASE="${STUB_PHASE:-TEST}" STUB_VERDICT="${STUB_VERDICT:-}" \
  STUB_OUTPUT="${STUB_OUTPUT:-}" STUB_RAN="${STUB_RAN:-}" STUB_NO_VERDICT_FILE="${STUB_NO_VERDICT_FILE:-}" \
  AGY_BIN="$STUB" \
    /bin/bash "$PHASE_SH" --phase TEST --brief "$repo/brief.md" --dir "$repo" --no-brief-lint "$@" 2>/dev/null
}

# --- 1. single dispatch appends exactly one valid single-line JSON -----------

R1="$(new_repo single-dispatch)"
OUT1="$(run_phase "$R1" --task "my secret task")"
LEDGER1="$R1/.agy/ledger.jsonl"

[ -f "$LEDGER1" ] && ok single-dispatch-file-exists "ledger file created on dispatch" \
                  || bad single-dispatch-file-exists "ledger file missing"

check single-dispatch-one-line "$(count_lines "$LEDGER1")" "1" "exactly one line appended"

LINE1="$(cat "$LEDGER1" 2>/dev/null)"
IS_JSON_ONELINE=bad
if [ "${LINE1:0:1}" = "{" ] && [ "${LINE1: -1}" = "}" ]; then
  IS_JSON_ONELINE=ok
fi
check single-dispatch-json-format "$IS_JSON_ONELINE" "ok" "line is single-line JSON object"

# --- 2. fields present are correct; genuinely unknown fields are absent -----

# Check presence of expected keys in line 1
if printf '%s\n' "$LINE1" | grep -q '"phase":"TEST"' \
   && printf '%s\n' "$LINE1" | grep -q '"model":"gemini-3.7-flash-medium"' \
   && printf '%s\n' "$LINE1" | grep -q '"backend":"agy"' \
   && printf '%s\n' "$LINE1" | grep -q '"elapsed_s":' \
   && printf '%s\n' "$LINE1" | grep -q '"worker_rc":0' \
   && printf '%s\n' "$LINE1" | grep -q '"verdict":"PASSED"' \
   && printf '%s\n' "$LINE1" | grep -q '"status":"PASSED"' \
   && printf '%s\n' "$LINE1" | grep -q '"retries_spent":0' \
   && printf '%s\n' "$LINE1" | grep -q '"retries_refunded":0' \
   && printf '%s\n' "$LINE1" | grep -q '"verify_ran":false'; then
  ok fields-present-correct "standard dispatch fields are present and accurate"
else
  bad fields-present-correct "missing expected field in record: $LINE1"
fi

# Assert verify_rc is absent (unknown, not zero) when --verify was not passed
if printf '%s\n' "$LINE1" | grep -q '"verify_rc"'; then
  bad verify-rc-absent-not-zero "verify_rc present when --verify was not passed"
else
  ok verify-rc-absent-not-zero "verify_rc absent when --verify was not passed"
fi

# --- 3. task is hashed by default and never appears verbatim ----------------

if printf '%s\n' "$LINE1" | grep -q "my secret task"; then
  bad task-hashed-privacy "task string appeared verbatim in ledger"
else
  ok task-hashed-privacy "task string does not appear verbatim by default"
fi

WANT_HASH="$(printf '%s' "my secret task" | git -C "$R1" hash-object --stdin | cut -c 1-12)"
if printf '%s\n' "$LINE1" | grep -q "\"task_id\":\"$WANT_HASH\""; then
  ok task-hash-matches "task_id matches git hash-object 12-char prefix"
else
  bad task-hash-matches "task_id does not match expected hash $WANT_HASH: $LINE1"
fi

# --- 4. same task string twice produces same task_id -----------------------

R2="$(new_repo same-task)"
run_phase "$R2" --task "repeatable task" >/dev/null
LINE2_A="$(cat "$R2/.agy/ledger.jsonl")"

run_phase "$R2" --run new --task "repeatable task" >/dev/null
LINE2_B="$(tail -1 "$R2/.agy/ledger.jsonl")"

TID_A="$(printf '%s\n' "$LINE2_A" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p')"
TID_B="$(printf '%s\n' "$LINE2_B" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p')"

check task-hash-deterministic "$TID_A" "$TID_B" "same task string produces identical task_id"

# --- 5. AGY_LEDGER_TASK=plain records the literal string -------------------

R3="$(new_repo plain-task)"
AGY_LEDGER_TASK=plain run_phase "$R3" --task "explicit plaintext task" >/dev/null
LINE3="$(cat "$R3/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE3" | grep -q '"task":"explicit plaintext task"'; then
  ok task-plain-opt-in "AGY_LEDGER_TASK=plain records task string verbatim"
else
  bad task-plain-opt-in "plain task string not found: $LINE3"
fi

# --- 6. special characters in task do not break single-line invariant -------

R4="$(new_repo special-task)"
SPECIAL_TASK='task with quotes "and" \backslashes\ and '$'\n''newlines'
AGY_LEDGER_TASK=plain ledger_append "$R4" run=run-4 phase=TEST tier=medium model=m backend=agy started=2026-08-24T10:00:00Z elapsed_s=5 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED retries_spent=0 retries_refunded=0 task="$SPECIAL_TASK"
LINE_COUNT4="$(count_lines "$R4/.agy/ledger.jsonl")"
check special-task-single-line "$LINE_COUNT4" "1" "task with quotes, backslash, newline stays one line"

LINE4="$(cat "$R4/.agy/ledger.jsonl" 2>/dev/null)"
if [ "${LINE4:0:1}" = "{" ] && [ "${LINE4: -1}" = "}" ]; then
  ok special-task-valid-json "special char task produced valid single-line json"
else
  bad special-task-valid-json "special char task produced invalid json: $LINE4"
fi

if printf '%s\n' "$LINE4" | grep -F -q '"task":"task with quotes \"and\" \\backslashes\\ and newlines"'; then
  ok special-task-flattened "newline replaced by space rather than dropped or escaped"
else
  bad special-task-flattened "task value newline not flattened to space: $LINE4"
fi

# --- 7. appends are additive: three dispatches leave three lines in order --

R5="$(new_repo additive)"
run_phase "$R5" --task "task 1" >/dev/null
run_phase "$R5" --run new --task "task 2" >/dev/null
run_phase "$R5" --run new --task "task 3" >/dev/null

check additive-three-lines "$(count_lines "$R5/.agy/ledger.jsonl")" "3" "three dispatches leave 3 lines"

# --- 8. corrupt line in middle does not stop append; report.sh counts it ---

R6="$(new_repo corrupt-middle)"
run_phase "$R6" --task "first good dispatch" >/dev/null
# Inject corrupt lines
printf 'CORRUPT RAW TEXT\n' >> "$R6/.agy/ledger.jsonl"
printf '{"broken_json": true\n' >> "$R6/.agy/ledger.jsonl"
run_phase "$R6" --run new --task "second good dispatch" >/dev/null

check corrupt-append-resilience "$(count_lines "$R6/.agy/ledger.jsonl")" "4" "append succeeded despite corrupt line"

REPORT6="$(/bin/bash "$REPORT_SH" --dir "$R6")"; CODE=$?
check report-corrupt-rc "$CODE" 0 "report.sh exits 0 over ledger with corrupt lines"

if printf '%s\n' "$REPORT6" | grep -q "unparseable skipped: 2" \
   || printf '%s\n' "$REPORT6" | grep -q "Unparseable records skipped:[[:space:]]*2"; then
  ok report-counts-skipped "report.sh correctly counts skipped corrupt lines"
else
  bad report-counts-skipped "report.sh did not report 2 skipped lines: $REPORT6"
fi

# --- 9. report.sh on absent ledger exits 0 and says so ---------------------

R7="$(new_repo absent-ledger)"
REPORT7="$(/bin/bash "$REPORT_SH" --dir "$R7")"; CODE=$?
check report-absent-rc "$CODE" 0 "report.sh exits 0 on absent ledger"
if printf '%s\n' "$REPORT7" | grep -iq "empty or absent"; then
  ok report-absent-message "report.sh clearly states ledger is empty or absent"
else
  bad report-absent-message "report.sh did not state empty or absent: $REPORT7"
fi

# --- 10. report.sh computes verify-override count from fixture -------------

R8="$(new_repo verify-fixture)"
mkdir -p "$R8/.agy"

# Record 1: normal pass
ledger_append "$R8" run=run-1 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy started=2026-08-24T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=true verify_rc=0 status=PASSED retries_spent=0 retries_refunded=0
# Record 2: verify override
ledger_append "$R8" run=run-2 phase=REVIEW attempt=1 tier=high model=m backend=agy started=2026-08-24T10:05:00Z elapsed_s=20 worker_rc=0 verdict=PASSED verify_ran=true verify_rc=1 status='VERIFY_FAILED(rc=1)' retries_spent=0 retries_refunded=0
# Record 3: verify override 2
ledger_append "$R8" run=run-2 phase=REVIEW attempt=2 tier=high model=m backend=agy started=2026-08-24T10:10:00Z elapsed_s=25 worker_rc=0 verdict=PASSED verify_ran=true verify_rc=2 status='VERIFY_FAILED(rc=2)' retries_spent=1 retries_refunded=0
# Record 4: NO_STATUS_REPORTED
ledger_append "$R8" run=run-3 phase=QA attempt=1 tier=low model=m backend=agy started=2026-08-24T10:15:00Z elapsed_s=15 worker_rc=0 verify_ran=false status=NO_STATUS_REPORTED retries_spent=0 retries_refunded=0
# Record 5: RETRY_CAP_REACHED
ledger_append "$R8" run=run-4 phase=REVIEW attempt=3 tier=high model=m backend=agy started=2026-08-24T10:20:00Z status='RETRY_CAP_REACHED(n=2, cap=2)' retries_spent=2 retries_refunded=0 verify_ran=false

REPORT8="$(/bin/bash "$REPORT_SH" --dir "$R8")"; CODE=$?
check report-fixture-rc "$CODE" 0 "report on fixture exits 0"

if printf '%s\n' "$REPORT8" | grep -q "Verify gate overrides:[[:space:]]*2"; then
  ok report-fixture-verify-overrides "verify overrides count is exactly 2"
else
  bad report-fixture-verify-overrides "verify overrides count incorrect: $REPORT8"
fi

if printf '%s\n' "$REPORT8" | grep -q "No status reported dispatches:[[:space:]]*1"; then
  ok report-fixture-no-status "NO_STATUS_REPORTED count is exactly 1"
else
  bad report-fixture-no-status "NO_STATUS_REPORTED count incorrect: $REPORT8"
fi

if printf '%s\n' "$REPORT8" | grep -q "Retry cap reached (unresolved): 1"; then
  ok report-fixture-cap-reached "Retry cap reached count is exactly 1"
else
  bad report-fixture-cap-reached "Retry cap reached count incorrect: $REPORT8"
fi

# Test filter --phase REVIEW
REPORT8_PHASE="$(/bin/bash "$REPORT_SH" --dir "$R8" --phase REVIEW)"
if printf '%s\n' "$REPORT8_PHASE" | grep -q "3 valid record(s) read"; then
  ok report-filter-phase "filtering by --phase matches only matching records"
else
  bad report-filter-phase "phase filter count unexpected: $REPORT8_PHASE"
fi

# --- 11. diff and review sub-objects ---------------------------------------

R9="$(new_repo diff-review-subobjects)"
RUN_ID9="$(run_dir_new --dir "$R9" --task "diff and review test")"
RUN_DIR9="$R9/.agy/runs/$RUN_ID9"

# Fake REVIEW_DIFF.patch and REVIEW_DIFF.stat
printf '# REVIEW_DIFF.patch\n#\n# base: HEAD\n# files changed: 7\n# changed lines: 245 (+214 / -31)\n# patch lines: 100\n#\n--- a/src/app.py\n+++ b/src/app.py\n@@ -1,3 +1,5 @@\n+line1\n+line2\n' > "$RUN_DIR9/REVIEW_DIFF.patch"
printf 'some stat content\n' > "$RUN_DIR9/REVIEW_DIFF.stat"
printf '# Review Feedback\n\n## Verdict\nPASSED\n\n## Examined\n- `src/app.py` (+10 / -1)\n' > "$RUN_DIR9/REVIEW_FEEDBACK.md"

STUB_VERDICT="STATUS: PASSED | File: REVIEW_FEEDBACK.md" run_phase "$R9" --run "$RUN_ID9" --phase REVIEW >/dev/null
LINE9="$(tail -1 "$R9/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE9" | grep -q "\"run\":\"$RUN_ID9\""; then
  ok diff-review-run-id "ledger line run matches dispatch run"
else
  bad diff-review-run-id "ledger line run does not match dispatch run $RUN_ID9: $LINE9"
fi

if printf '%s\n' "$LINE9" | grep -q '"phase":"REVIEW"'; then
  ok diff-review-phase "ledger line phase is REVIEW"
else
  bad diff-review-phase "ledger line phase is not REVIEW: $LINE9"
fi

if printf '%s\n' "$LINE9" | grep -q '"review":{"anchors":1,"status":"REVIEW_EVIDENCED"}'; then
  ok review-subobject-extracted "review sub-object correctly extracted and formatted"
else
  bad review-subobject-extracted "review sub-object missing or formatted incorrectly: $LINE9"
fi

if printf '%s\n' "$LINE9" | grep -q '"diff":{"files":7,"insertions":214,"deletions":31'; then
  ok diff-subobject-extracted "diff sub-object correctly extracted and formatted"
else
  bad diff-subobject-extracted "diff sub-object missing or formatted incorrectly: $LINE9"
fi

# Review whose anchors cannot be read records no anchors key at all
R9_NOANCH="$(new_repo diff-review-absent)"
RUN_ID9_NOANCH="$(run_dir_new --dir "$R9_NOANCH" --task "review absent test")"
RUN_DIR9_NOANCH="$R9_NOANCH/.agy/runs/$RUN_ID9_NOANCH"

# Empty feedback produces REVIEW_ABSENT where anchors cannot be measured
touch "$RUN_DIR9_NOANCH/REVIEW_FEEDBACK.md"

STUB_VERDICT="STATUS: PASSED | File: REVIEW_FEEDBACK.md" run_phase "$R9_NOANCH" --run "$RUN_ID9_NOANCH" --phase REVIEW >/dev/null
LINE9_NOANCH="$(cat "$R9_NOANCH/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE9_NOANCH" | grep -q '"review":{"status":"REVIEW_ABSENT"}'; then
  ok review-subobject-no-anchors "review with unmeasured anchors records no anchors key at all"
else
  bad review-subobject-no-anchors "review sub-object should omit unmeasured anchors: $LINE9_NOANCH"
fi

# --- 12. RETRY_CAP_REACHED and PREFLIGHT_FAILED records ---------------------

R10="$(new_repo refusal-records)"
# Force retry cap reached: retry-cap 0
run_phase "$R10" --retry-cap 0 >/dev/null; RC10=$?
check retry-cap-exit-code "$RC10" 6 "exit 6 on retry cap reached"
LINE10_CAP="$(cat "$R10/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE10_CAP" | grep -q '"status":"RETRY_CAP_REACHED(n=0, cap=0)"'; then
  ok retry-cap-ledger-recorded "RETRY_CAP_REACHED recorded in ledger"
else
  bad retry-cap-ledger-recorded "RETRY_CAP_REACHED missing in ledger: $LINE10_CAP"
fi

if printf '%s\n' "$LINE10_CAP" | grep -q '"elapsed_s"'; then
  bad retry-cap-no-elapsed "elapsed_s should be absent on RETRY_CAP_REACHED"
else
  ok retry-cap-no-elapsed "elapsed_s absent on RETRY_CAP_REACHED"
fi

if printf '%s\n' "$LINE10_CAP" | grep -q '"worker_rc"'; then
  bad retry-cap-no-worker-rc "worker_rc should be absent on RETRY_CAP_REACHED"
else
  ok retry-cap-no-worker-rc "worker_rc absent on RETRY_CAP_REACHED"
fi

# --- 13. stub agy emitting JSON produces record with usage object intact ---

R11="$(new_repo json-usage)"
run_phase "$R11" --task "json usage test" >/dev/null
LINE11="$(cat "$R11/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE11" | grep -q '"usage":{"input_tokens":16813,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":16814}'; then
  ok json-usage-intact "ledger record carries full usage object"
else
  bad json-usage-intact "usage object missing or wrong: $LINE11"
fi

if printf '%s\n' "$LINE11" | grep -q '"num_turns":1' \
   && printf '%s\n' "$LINE11" | grep -q '"agy_status":"SUCCESS"'; then
  ok json-metadata-intact "num_turns and agy_status recorded"
else
  bad json-metadata-intact "num_turns or agy_status missing: $LINE11"
fi

# --- 14. stub emitting no usage key produces record with no usage object ---

R12="$(new_repo json-no-usage)"
STUB_OUTPUT='{"conversation_id":"c-no-usage","status":"SUCCESS","response":"STATUS: PASSED | File: CHANGES.md\n","duration_seconds":1.0,"num_turns":1}' \
  run_phase "$R12" --task "no usage test" >/dev/null
LINE12="$(cat "$R12/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE12" | grep -q '"usage"'; then
  bad no-usage-absent-not-zero "usage key present when agy emitted no usage"
else
  ok no-usage-absent-not-zero "usage key absent when agy emitted no usage"
fi

# --- 15. malformed JSON yields usable dispatch with text fallback note ----

R13="$(new_repo malformed-json)"
OUT13="$(STUB_OUTPUT='{"status":"SUCCESS", broken json' run_phase "$R13" --task "malformed json test")"
LINE13="$(cat "$R13/.agy/ledger.jsonl" 2>/dev/null)"

case "$OUT13" in
  *"STATUS: PASSED | File: CHANGES.md"*) ok malformed-json-usable "malformed JSON yielded usable dispatch" ;;
  *) bad malformed-json-usable "malformed JSON dispatch failed: $OUT13" ;;
esac

case "$OUT13" in
  *"Note: worker output was not valid JSON; fell back to raw text"*)
    ok malformed-json-status-note "status line notes fallback to text" ;;
  *) bad malformed-json-status-note "status line missing fallback note: $OUT13" ;;
esac

if printf '%s\n' "$LINE13" | grep -q '"usage"'; then
  bad malformed-json-no-usage "usage key should not exist on malformed JSON"
else
  ok malformed-json-no-usage "usage key omitted on malformed JSON"
fi

# --- 16. printed-line verdict fallback inside JSON response ----------------

R14="$(new_repo json-verdict-fallback)"
STUB_OUTPUT='{"conversation_id":"c-fb","status":"SUCCESS","response":"Some thinking...\nSTATUS: PASSED | File: CHANGES.md\n","duration_seconds":2.0,"num_turns":1,"usage":{"input_tokens":100,"output_tokens":10,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":110}}' \
  STUB_NO_VERDICT_FILE=1 run_phase "$R14" --task "verdict fallback test" >/dev/null
LINE14="$(cat "$R14/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE14" | grep -q '"verdict":"PASSED"' \
   && printf '%s\n' "$LINE14" | grep -q '"status":"PASSED"'; then
  ok json-verdict-fallback "verdict extracted from inside JSON response field without verdict file"
else
  bad json-verdict-fallback "failed to extract verdict from JSON response: $LINE14"
fi

# --- 17. --budget-tokens refuses before dispatch when spent exceeds ceiling -

R15="$(new_repo budget-refusal)"
RAN15="$R15/ran.txt"

# First dispatch: spends 16,814 tokens
STUB_RAN="$RAN15" run_phase "$R15" --task "budget test" >/dev/null

BEFORE15="$(count_lines "$RAN15")"
check budget-first-dispatched "$BEFORE15" "1" "first dispatch executed worker"

# Second dispatch with budget lower than spent (e.g. 10000 tokens < 16814 spent)
OUT15="$(STUB_RAN="$RAN15" run_phase "$R15" --run current --budget-tokens 10000)"; RC15=$?
check budget-exceeded-rc "$RC15" 7 "budget exceeded exits 7"

case "$OUT15" in
  *"STATUS: BUDGET_EXCEEDED(spent=16814, budget=10000)"*)
    ok budget-exceeded-status "STATUS line reports BUDGET_EXCEEDED with spent and budget" ;;
  *) bad budget-exceeded-status "unexpected STATUS line: $OUT15" ;;
esac

AFTER15="$(count_lines "$RAN15")"
check budget-exceeded-no-dispatch "$AFTER15" "$BEFORE15" "worker was never invoked on budget refusal"

LINE15_BUDGET="$(tail -1 "$R15/.agy/ledger.jsonl")"
if printf '%s\n' "$LINE15_BUDGET" | grep -q '"status":"BUDGET_EXCEEDED(spent=16814, budget=10000)"'; then
  ok budget-exceeded-ledger-recorded "BUDGET_EXCEEDED recorded in ledger"
else
  bad budget-exceeded-ledger-recorded "BUDGET_EXCEEDED missing in ledger: $LINE15_BUDGET"
fi

if printf '%s\n' "$LINE15_BUDGET" | grep -q '"usage"'; then
  bad budget-exceeded-no-usage "usage key must be absent on budget refusal"
else
  ok budget-exceeded-no-usage "usage key absent on budget refusal"
fi

# Third dispatch under budget (budget 50000 > 16814) succeeds and dispatches
OUT15_OK="$(STUB_RAN="$RAN15" run_phase "$R15" --run current --budget-tokens 50000)"; RC15_OK=$?
check budget-under-rc "$RC15_OK" 0 "under budget dispatch succeeds"
check budget-under-dispatched "$(count_lines "$RAN15")" "$((BEFORE15 + 1))" "worker invoked when under budget"

# --- 18. report.sh separates dead WORKER_FAILED round from real spend -------

R16="$(new_repo report-spend-separation)"
mkdir -p "$R16/.agy"

# Record 1: live IMPLEMENT round, 10,000 tokens
ledger_append "$R16" run=run-1 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy \
  started=2026-08-24T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":8000,"output_tokens":2000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":10000}'
# Record 2: dead IMPLEMENT round (WORKER_FAILED, retries_refunded=1), 1,000 tokens
ledger_append "$R16" run=run-1 phase=IMPLEMENT attempt=2 tier=medium model=m backend=agy \
  started=2026-08-24T10:05:00Z elapsed_s=2 worker_rc=1 status='WORKER_FAILED(rc=1)' \
  retries_spent=0 retries_refunded=1 verify_ran=false \
  usage='{"input_tokens":900,"output_tokens":100,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":1000}'
# Record 3: live REVIEW round, 5,000 tokens
ledger_append "$R16" run=run-1 phase=REVIEW attempt=1 tier=high model=m backend=agy \
  started=2026-08-24T10:10:00Z elapsed_s=15 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":4000,"output_tokens":1000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":5000}'

REPORT16="$(/bin/bash "$REPORT_SH" --dir "$R16")"

# Check IMPLEMENT tokens reported as 10000 (not 11000)
if printf '%s\n' "$REPORT16" | grep "IMPLEMENT:" | grep -q "10000 tokens"; then
  ok report-phase-excludes-dead "live IMPLEMENT spend reported as 10,000 tokens (excludes dead round)"
else
  bad report-phase-excludes-dead "IMPLEMENT tokens incorrect in report: $REPORT16"
fi

# Check dead rounds reported separately
if printf '%s\n' "$REPORT16" | grep -q "1 dead dispatch(es), 1000 tokens" \
   && printf '%s\n' "$REPORT16" | grep -q "excluded from phase spend"; then
  ok report-dead-rounds-separate "dead rounds reported separately with refunded tokens"
else
  bad report-dead-rounds-separate "dead rounds missing or incorrect: $REPORT16"
fi

# Check rates pricing when provided
REPORT16_RATES="$(/bin/bash "$REPORT_SH" --dir "$R16" --price-in 3.00 --price-out 15.00)"
if printf '%s\n' "$REPORT16_RATES" | grep -qF '$'; then
  ok report-rates-printed "report prints dollar figures when rates supplied"
else
  bad report-rates-printed "dollar figures missing with rates: $REPORT16_RATES"
fi

if printf '%s\n' "$REPORT16" | grep -qF '$'; then
  bad report-rates-absent "report should not print dollar figures when rates not supplied"
else
  ok report-rates-absent "report omits dollar figures when rates not supplied"
fi

# --- 19. issue key recording, omission when absent, and unknown key error ---

R17="$(new_repo issue-and-unknown-keys)"
ledger_append "$R17" run=run-17 issue=58 phase=TEST tier=medium model=m backend=agy \
  started=2026-08-24T10:00:00Z elapsed_s=5 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0
LINE17_A="$(cat "$R17/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE17_A" | grep -q '"issue":58'; then
  ok issue-key-recorded "issue key recorded in ledger line"
else
  bad issue-key-recorded "issue key missing in ledger line: $LINE17_A"
fi

# Run without issue produces line with no issue field
ledger_append "$R17" run=run-17-no-issue phase=TEST tier=medium model=m backend=agy \
  started=2026-08-24T10:05:00Z elapsed_s=5 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0
LINE17_B="$(tail -1 "$R17/.agy/ledger.jsonl" 2>/dev/null)"

if printf '%s\n' "$LINE17_B" | grep -q '"issue"'; then
  bad issue-absent-omitted "issue key present in ledger for run without issue: $LINE17_B"
else
  ok issue-absent-omitted "issue key omitted entirely for run without issue"
fi

# Unknown key returns 2 and names the key on stderr
ERR17="$ROOT/err17.txt"
/bin/bash "$LEDGER_SH" append --dir "$R17" run=run-17-bad retries_spend=1 2> "$ERR17"; RC17=$?
check unknown-key-rc "$RC17" 2 "unknown key returns exit code 2"

if grep -q "retries_spend" "$ERR17" 2>/dev/null; then
  ok unknown-key-names-key "stderr names unrecognised key"
else
  bad unknown-key-names-key "stderr did not name unrecognised key: $(cat "$ERR17" 2>/dev/null)"
fi

# --- 20. repository spend ceiling and _ledger_repo_spent_tokens helper ------

R18="$(new_repo repo-budget-ceiling)"
RAN18="$R18/ran.txt"

# Run 1: spends 16,814 tokens
STUB_RAN="$RAN18" run_phase "$R18" --task "repo run 1" >/dev/null
RUN1_ID_18="$(cat "$R18/.agy/current")"

# Run 2: spends another 16,814 tokens (total repo spent = 33,628)
STUB_RAN="$RAN18" run_phase "$R18" --run new --task "repo run 2" >/dev/null
RUN2_ID_18="$(cat "$R18/.agy/current")"

REPO_SPENT_18="$(_ledger_repo_spent_tokens "$R18")"
check repo-spent-tokens-sums "$REPO_SPENT_18" "33628" "_ledger_repo_spent_tokens sums tokens across runs"

RUN1_SPENT_18="$(_ledger_spent_tokens "$R18" "$RUN1_ID_18")"
check run1-spent-tokens-intact "$RUN1_SPENT_18" "16814" "_ledger_spent_tokens sums tokens for run 1 only"

# 20a. Repository ceiling refuses when per-run budget is nowhere near (or unset)
OUT18_REPO_EXCEEDED="$(STUB_RAN="$RAN18" run_phase "$R18" --run new --task "repo run 3" --budget-tokens 50000 --repo-budget-tokens 20000)"; RC18_REPO=$?
check repo-budget-exceeded-rc "$RC18_REPO" 9 "repo budget exceeded exits 9"

case "$OUT18_REPO_EXCEEDED" in
  *"STATUS: REPO_BUDGET_EXCEEDED(spent=33628, budget=20000)"*)
    ok repo-budget-exceeded-status "STATUS line reports REPO_BUDGET_EXCEEDED with spent and budget" ;;
  *) bad repo-budget-exceeded-status "unexpected STATUS line: $OUT18_REPO_EXCEEDED" ;;
esac

LINE18_REPO="$(tail -1 "$R18/.agy/ledger.jsonl")"
if printf '%s\n' "$LINE18_REPO" | grep -q '"status":"REPO_BUDGET_EXCEEDED(spent=33628, budget=20000)"'; then
  ok repo-budget-exceeded-ledger-recorded "REPO_BUDGET_EXCEEDED recorded in ledger"
else
  bad repo-budget-exceeded-ledger-recorded "REPO_BUDGET_EXCEEDED missing in ledger: $LINE18_REPO"
fi

if printf '%s\n' "$LINE18_REPO" | grep -q '"usage"'; then
  bad repo-budget-exceeded-no-usage "usage key must be absent on repo budget refusal"
else
  ok repo-budget-exceeded-no-usage "usage key absent on repo budget refusal"
fi

# 20b. Per-run ceiling still refuses when repository ceiling is generous
OUT18_RUN_EXCEEDED="$(STUB_RAN="$RAN18" run_phase "$R18" --run "$RUN1_ID_18" --budget-tokens 10000 --repo-budget-tokens 100000)"; RC18_RUN=$?
check per-run-ceiling-still-refuses-rc "$RC18_RUN" 7 "per-run budget exceeded exits 7 even when repo budget generous"

case "$OUT18_RUN_EXCEEDED" in
  *"STATUS: BUDGET_EXCEEDED(spent=16814, budget=10000)"*)
    ok per-run-ceiling-still-refuses-status "STATUS reports BUDGET_EXCEEDED when per-run exceeded and repo generous" ;;
  *) bad per-run-ceiling-still-refuses-status "unexpected STATUS line: $OUT18_RUN_EXCEEDED" ;;
esac

# 20c. Both ceilings absent by default: dispatch proceeds normally
OUT18_DEFAULT="$(STUB_RAN="$RAN18" run_phase "$R18" --run new --task "repo run 4 default")"; RC18_DEF=$?
check ceilings-absent-by-default-rc "$RC18_DEF" 0 "dispatch succeeds when both ceilings absent by default"
case "$OUT18_DEFAULT" in
  *"STATUS: PASSED"*) ok ceilings-absent-by-default-status "dispatch passes with STATUS: PASSED by default" ;;
  *) bad ceilings-absent-by-default-status "dispatch failed: $OUT18_DEFAULT" ;;
esac

# 20d. AGY_REPO_BUDGET_TOKENS environment variable is honoured
OUT18_ENV="$(AGY_REPO_BUDGET_TOKENS=30000 STUB_RAN="$RAN18" run_phase "$R18" --run new --task "repo run 5 env")"; RC18_ENV=$?
check repo-budget-env-rc "$RC18_ENV" 9 "AGY_REPO_BUDGET_TOKENS env var triggers exit 9 on refusal"
case "$OUT18_ENV" in
  *"STATUS: REPO_BUDGET_EXCEEDED"*) ok repo-budget-env-status "AGY_REPO_BUDGET_TOKENS env var reports REPO_BUDGET_EXCEEDED" ;;
  *) bad repo-budget-env-status "unexpected STATUS line from env var: $OUT18_ENV" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
