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
if [ -f .agy/current ]; then
  CUR_RUN="$(cat .agy/current 2>/dev/null || true)"
  if [ -n "$CUR_RUN" ]; then
    mkdir -p ".agy/runs/$CUR_RUN/phases/$STUB_PHASE"
    printf '%s\n' "${STUB_VERDICT:-STATUS: PASSED | File: CHANGES.md}" > ".agy/runs/$CUR_RUN/phases/$STUB_PHASE/verdict"
  fi
fi
printf '%s\n' "${STUB_VERDICT:-STATUS: PASSED | File: CHANGES.md}"
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

run_phase() {
  local repo="$1"
  shift
  STUB_PHASE="${STUB_PHASE:-TEST}" STUB_VERDICT="${STUB_VERDICT:-}" AGY_BIN="$STUB" \
    /bin/bash "$PHASE_SH" --phase TEST --brief "$repo/brief.md" --dir "$repo" "$@" 2>/dev/null
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
