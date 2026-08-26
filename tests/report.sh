#!/usr/bin/env bash
# Exercise scripts/report.sh:
# 1. Column integrity: 15-field TSV round trip and field placement
# 2. Absent is not zero: unmeasured tokens and untimed dispatches
# 3. Filters: narrowing by --run, --phase, --since, and empty matches
# 4. Malformed input: non-JSON lines, truncated JSON, missing required fields
# 5. Pricing and cost calculation: --price-in and --price-out formatting
# 6. Multi-run aggregation, verify overrides, and CLI error handling
#
#   tests/report.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_SH="$HERE/../scripts/report.sh"
LEDGER_SH="$HERE/../scripts/ledger.sh"

[ -f "$REPORT_SH" ] || { echo "report-test: report.sh not found next door" >&2; exit 2; }
[ -f "$LEDGER_SH" ] || { echo "report-test: ledger.sh not found next door" >&2; exit 2; }

. "$LEDGER_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/report-test.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() {
  local r="$ROOT/repos/$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  printf '%s' "$r"
}

# =============================================================================
# 1. Column Integrity: 15 fields round trip without shifting
# =============================================================================

R_COL="$(new_repo col-integrity)"
mkdir -p "$R_COL/.agy"

# Record with distinct, identifiable values in every single field of the 17-field TSV:
# 1:run=r-col-integ, 2:phase=CUSTOMPHASE, 3:attempt=2, 4:status=PASSED, 5:elapsed_s=42,
# 6:verdict="STATUS: PASSED | File: x.txt", 7:verify_ran=true, 8:started=2026-08-25T11:22:33Z,
# 9:input_tokens=111, 10:output_tokens=222, 11:thinking_tokens=333, 12:total_tokens=666,
# 13:retries_refunded=0, 14:has_usage=1, 15:issue=888, 16:agy_status=SUCCESS, 17:verdict_route=file
ledger_append "$R_COL" \
  run=r-col-integ \
  phase=CUSTOMPHASE \
  attempt=2 \
  tier=medium \
  model=m-integ \
  backend=agy \
  started=2026-08-25T11:22:33Z \
  elapsed_s=42 \
  worker_rc=0 \
  verdict="STATUS: PASSED | File: x.txt" \
  verdict_route=file \
  verify_ran=true \
  verify_rc=0 \
  status=PASSED \
  retries_spent=0 \
  retries_refunded=0 \
  issue=888 \
  agy_status=SUCCESS \
  usage='{"input_tokens":111,"output_tokens":222,"thinking_tokens":333,"cache_read_tokens":0,"total_tokens":666}'

REPORT_COL="$(bash "$REPORT_SH" --dir "$R_COL")"
RC_COL=$?
check col-report-rc "$RC_COL" 0 "report.sh exits 0 on column integrity fixture"

# Assert each distinct field surfaces in its exact expected location in the rendered report
# Column 1 (run): verify run is parsed and filterable via --run, and aggregated in task efficiency
REP_COL_RUN="$(bash "$REPORT_SH" --dir "$R_COL" --run r-col-integ)"
REP_COL_OTHER="$(bash "$REPORT_SH" --dir "$R_COL" --run r-other)"
if printf '%s\n' "$REP_COL_RUN" | grep -q "Dispatches: 1 valid record(s)" && \
   printf '%s\n' "$REP_COL_OTHER" | grep -q "No dispatches matched the specified criteria." && \
   printf '%s\n' "$REPORT_COL" | grep -q "Successful tasks (runs):[[:space:]]*1 / 1 (100%)"; then
  ok col-run "run correctly parsed and filterable without column shift"
else
  bad col-run "run filtering/aggregation unexpected: $REP_COL_RUN"
fi

# Column 2 (phase) & Column 4 (status): pass rates partition by phase and check PASSED status
if printf '%s\n' "$REPORT_COL" | grep -q "CUSTOMPHASE:[[:space:]]*1 dispatches,   1 passed (100%)"; then
  ok col-phase-status "phase and status correctly parsed in phase pass rates"
else
  bad col-phase-status "phase pass rates unexpected: $REPORT_COL"
fi

# Column 3 (attempt): attempt=2 places record in Round 2 retry distribution
if printf '%s\n' "$REPORT_COL" | grep -q "Round 2 (converged on round 2): 1" && \
   printf '%s\n' "$REPORT_COL" | grep -q "Round 1 (converged on round 1): 0"; then
  ok col-attempt "attempt correctly parsed in retry distribution"
else
  bad col-attempt "attempt unexpected in retry distribution: $REPORT_COL"
fi

# Column 5 (elapsed_s): elapsed seconds appear in phase median/max wall-clock time
if printf '%s\n' "$REPORT_COL" | grep -q "CUSTOMPHASE:[[:space:]]*median[[:space:]]*42s, max[[:space:]]*42s (from 1 timed dispatches)"; then
  ok col-elapsed "elapsed_s correctly parsed in elapsed time distribution"
else
  bad col-elapsed "elapsed_s unexpected in elapsed time: $REPORT_COL"
fi

# Column 6 (verdict): verdict is stored in ledger/TSV for audit/review records
# but is not rendered individually in the summary report. Assert that the record
# containing verdict parses cleanly as a valid dispatch without unparseable errors.
if printf '%s\n' "$REPORT_COL" | grep -q "Dispatches: 1 valid record(s) read" && \
   printf '%s\n' "$REPORT_COL" | grep -q "Unparseable records skipped:[[:space:]]*0"; then
  ok col-verdict "record containing verdict field parsed without data corruption"
else
  bad col-verdict "verdict record parsing unexpected: $REPORT_COL"
fi

# Column 7 (verify_ran): verify_ran is stored in ledger/TSV but is not rendered
# individually in summary output. Assert verify gate overrides count remains 0.
if printf '%s\n' "$REPORT_COL" | grep -q "Verify gate overrides:[[:space:]]*0"; then
  ok col-verify-ran "verify_ran field parsed without triggering spurious gate overrides"
else
  bad col-verify-ran "verify overrides unexpected: $REPORT_COL"
fi

# Column 8 (started): timestamp parsed and filterable via --since
REP_COL_SINCE="$(bash "$REPORT_SH" --dir "$R_COL" --since 2026-08-25T11:00:00Z)"
REP_COL_FUTURE="$(bash "$REPORT_SH" --dir "$R_COL" --since 2026-08-25T12:00:00Z)"
if printf '%s\n' "$REP_COL_SINCE" | grep -q "Dispatches: 1 valid record(s)" && \
   printf '%s\n' "$REP_COL_FUTURE" | grep -q "No dispatches matched the specified criteria."; then
  ok col-started "started timestamp correctly parsed and filterable via --since"
else
  bad col-started "started filter unexpected: $REP_COL_SINCE / $REP_COL_FUTURE"
fi

# Columns 9, 10, 11, 12 (input=111, output=222, thinking=333, total=666): token spend by phase & live total
if printf '%s\n' "$REPORT_COL" | grep -q "CUSTOMPHASE:[[:space:]]*666 tokens (100% of live total) \[inp: 111, out: 222, thk: 333\]"; then
  ok col-usage-tokens "input, output, thinking, and total tokens parsed in phase spend"
else
  bad col-usage-tokens "phase token spend unexpected: $REPORT_COL"
fi

if printf '%s\n' "$REPORT_COL" | grep -q "Live Total:[[:space:]]*666 tokens \[inp: 111, out: 222, thk: 333\]"; then
  ok col-live-total "live total parsed tokens without shift"
else
  bad col-live-total "live total unexpected: $REPORT_COL"
fi

# Column 13 (retries_refunded): retries_refunded=0 keeps spend in live totals, not dead rounds
if printf '%s\n' "$REPORT_COL" | grep -q "0 dead dispatches (no refunded tokens)"; then
  ok col-retries-refunded "retries_refunded=0 correctly leaves dispatch in live total"
else
  bad col-retries-refunded "retries_refunded output unexpected: $REPORT_COL"
fi

# Column 14 (has_usage): usage object presence enables token metrics
if ! printf '%s\n' "$REPORT_COL" | grep -q "No token usage recorded in matching dispatches."; then
  ok col-has-usage "has_usage=1 enables token spend reporting"
else
  bad col-has-usage "has_usage output unexpected: $REPORT_COL"
fi

# Column 15 (issue): issue number is stored in ledger/TSV for issue tracking but is not
# rendered in summary reports. Assert that the record with issue field parses cleanly
# and does not bleed its numeric value into metrics.
if ! printf '%s\n' "$REPORT_COL" | grep -q "888"; then
  ok col-issue "issue field parsed without bleeding into report output metrics"
else
  bad col-issue "issue field unexpectedly rendered: $REPORT_COL"
fi

# Verify no cross-column bleeding / shifting between distinct field values
if ! printf '%s\n' "$REPORT_COL" | grep -E -q "42 tokens|inp: 42|out: 42|thk: 42|111s|222s|333s|666s"; then
  ok col-no-bleed "distinct field values do not bleed across column positions"
else
  bad col-no-bleed "field value bled across columns: $REPORT_COL"
fi

# Also check refunded dead round separation
R_DEAD="$(new_repo dead-round)"
mkdir -p "$R_DEAD/.agy"
ledger_append "$R_DEAD" run=r-dead phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=5 worker_rc=1 verdict=FAILED verify_ran=false status=WORKER_FAILED \
  retries_spent=1 retries_refunded=1 \
  usage='{"input_tokens":400,"output_tokens":100,"thinking_tokens":50,"cache_read_tokens":0,"total_tokens":550}'

REPORT_DEAD="$(bash "$REPORT_SH" --dir "$R_DEAD")"
if printf '%s\n' "$REPORT_DEAD" | grep -q "1 dead dispatch(es), 550 tokens \[inp: 400, out: 100, thk: 50\]"; then
  ok col-dead-rounds "refunded worker failure correctly partitioned into dead rounds"
else
  bad col-dead-rounds "dead rounds output unexpected: $REPORT_DEAD"
fi


# =============================================================================
# 2. Absent is not zero: unmeasured spend and untimed dispatches
# =============================================================================

R_ABS="$(new_repo absent-not-zero)"
mkdir -p "$R_ABS/.agy"

# Dispatches without usage objects and without elapsed_s
ledger_append "$R_ABS" run=run-abs-1 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy \
  started=2026-08-25T10:00:00Z worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0

ledger_append "$R_ABS" run=run-abs-2 phase=REVIEW attempt=1 tier=high model=m backend=agy \
  started=2026-08-25T10:05:00Z worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0

REPORT_ABS="$(bash "$REPORT_SH" --dir "$R_ABS")"
RC_ABS=$?
check absent-rc "$RC_ABS" 0 "report.sh exits 0 when usage is unmeasured"

if printf '%s\n' "$REPORT_ABS" | grep -q "No token usage recorded in matching dispatches."; then
  ok absent-usage-message "report explicitly notes token usage was not recorded"
else
  bad absent-usage-message "missing unmeasured usage message: $REPORT_ABS"
fi

if printf '%s\n' "$REPORT_ABS" | grep -q "Live Total:[[:space:]]*0 tokens"; then
  bad absent-not-zero "report must not print 'Live Total: 0 tokens' when unmeasured"
else
  ok absent-not-zero "report omits 'Live Total: 0 tokens' when usage is unmeasured"
fi

if printf '%s\n' "$REPORT_ABS" | grep -q "IMPLEMENT:[[:space:]]*no timed dispatches"; then
  ok absent-elapsed-message "untimed phase reports 'no timed dispatches' rather than 0s"
else
  bad absent-elapsed-message "untimed phase message unexpected: $REPORT_ABS"
fi


# =============================================================================
# 3. The Filters: narrowing by --run, --phase, --since, and empty matches
# =============================================================================

R_FILT="$(new_repo filters-test)"
mkdir -p "$R_FILT/.agy"

ledger_append "$R_FILT" run=run-alpha phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T08:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":800,"output_tokens":200,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":1000}'

ledger_append "$R_FILT" run=run-alpha phase=REVIEW attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T09:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":1600,"output_tokens":400,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2000}'

ledger_append "$R_FILT" run=run-beta phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":2400,"output_tokens":600,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":3000}'

ledger_append "$R_FILT" run=run-beta phase=QA attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T11:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":3200,"output_tokens":800,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":4000}'

# Test --run filter
REP_RUN="$(bash "$REPORT_SH" --dir "$R_FILT" --run run-alpha)"
if printf '%s\n' "$REP_RUN" | grep -q "Dispatches: 2 valid record(s)" && \
   printf '%s\n' "$REP_RUN" | grep -q "Live Total:[[:space:]]*3000 tokens" && \
   ! printf '%s\n' "$REP_RUN" | grep -q "QA:"; then
  ok filter-run "--run narrows to specified run"
else
  bad filter-run "--run filter failed: $REP_RUN"
fi

# Test --phase filter
REP_PHASE="$(bash "$REPORT_SH" --dir "$R_FILT" --phase IMPLEMENT)"
if printf '%s\n' "$REP_PHASE" | grep -q "Dispatches: 2 valid record(s)" && \
   printf '%s\n' "$REP_PHASE" | grep -q "IMPLEMENT:[[:space:]]*2 dispatches" && \
   ! printf '%s\n' "$REP_PHASE" | grep -q "REVIEW:" && \
   ! printf '%s\n' "$REP_PHASE" | grep -q "QA:"; then
  ok filter-phase "--phase narrows to specified phase"
else
  bad filter-phase "--phase filter failed: $REP_PHASE"
fi

# Test --since filter
REP_SINCE="$(bash "$REPORT_SH" --dir "$R_FILT" --since 2026-08-25T09:30:00Z)"
if printf '%s\n' "$REP_SINCE" | grep -q "Dispatches: 2 valid record(s)" && \
   printf '%s\n' "$REP_SINCE" | grep -q "Live Total:[[:space:]]*7000 tokens"; then
  ok filter-since "--since narrows to records at or after date"
else
  bad filter-since "--since filter failed: $REP_SINCE"
fi

# Test combined --run and --phase filter
REP_COMB="$(bash "$REPORT_SH" --dir "$R_FILT" --run run-beta --phase QA)"
if printf '%s\n' "$REP_COMB" | grep -q "Dispatches: 1 valid record(s)" && \
   printf '%s\n' "$REP_COMB" | grep -q "QA:[[:space:]]*4000 tokens"; then
  ok filter-combined "combined --run and --phase filters narrow correctly"
else
  bad filter-combined "combined filter failed: $REP_COMB"
fi

# Test filter matching nothing produces empty message and exits 0
REP_EMPTY="$(bash "$REPORT_SH" --dir "$R_FILT" --run non-existent-run)"; RC_EMPTY=$?
check filter-empty-rc "$RC_EMPTY" 0 "--run non-existent exits 0"
if printf '%s\n' "$REP_EMPTY" | grep -q "No dispatches matched the specified criteria."; then
  ok filter-empty-message "non-matching filter reports no dispatches matched"
else
  bad filter-empty-message "non-matching filter output unexpected: $REP_EMPTY"
fi


# =============================================================================
# 4. Malformed Input: truncated, non-JSON lines, and unparseable records
# =============================================================================

R_MAL="$(new_repo malformed-test)"
mkdir -p "$R_MAL/.agy"

cat > "$R_MAL/.agy/ledger.jsonl" <<'EOF'
this is plain non-json text
{"run":"r-broken","phase":"TEST"
{"phase":"TEST","status":"PASSED"}
{"run":"r-missing-phase","status":"PASSED"}
{"run":"r-missing-status","phase":"TEST"}
{"run":"r-valid","phase":"IMPLEMENT","status":"PASSED","attempt":1,"started":"2026-08-25T10:00:00Z","elapsed_s":10,"usage":{"input_tokens":400,"output_tokens":100,"thinking_tokens":0,"total_tokens":500}}
EOF

REPORT_MAL="$(bash "$REPORT_SH" --dir "$R_MAL")"; RC_MAL=$?
check malformed-rc "$RC_MAL" 0 "report.sh exits 0 when malformed lines are present"

if printf '%s\n' "$REPORT_MAL" | grep -q "Dispatches: 1 valid record(s) read (total lines read: 6, unparseable skipped: 5)"; then
  ok malformed-header-counts "header correctly counts total lines, valid records, and unparseable skipped"
else
  bad malformed-header-counts "header counts unexpected: $REPORT_MAL"
fi

if printf '%s\n' "$REPORT_MAL" | grep -q "Unparseable records skipped:[[:space:]]*5"; then
  ok malformed-integrity-section "Data Integrity section reports exact unparseable count"
else
  bad malformed-integrity-section "Data Integrity section unexpected: $REPORT_MAL"
fi

if printf '%s\n' "$REPORT_MAL" | grep -q "Live Total:[[:space:]]*500 tokens"; then
  ok malformed-valid-processed "valid record was processed despite malformed siblings"
else
  bad malformed-valid-processed "valid record not counted: $REPORT_MAL"
fi


# =============================================================================
# 5. Pricing and Cost Calculations: --price-in and --price-out
# =============================================================================

R_PRC="$(new_repo pricing-test)"
mkdir -p "$R_PRC/.agy"

# 2,000,000 input tokens @ $3.00/M = $6.00
# 500,000 output tokens @ $15.00/M = $7.50
# Total = $13.50
ledger_append "$R_PRC" run=r-prc phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=20 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":2000000,"output_tokens":500000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2500000}'

REPORT_PRC="$(bash "$REPORT_SH" --dir "$R_PRC" --price-in 3.00 --price-out 15.00)"
RC_PRC=$?
check price-rc "$RC_PRC" 0 "report.sh exits 0 with pricing arguments"

if printf '%s\n' "$REPORT_PRC" | grep -q "Live Total:[[:space:]]*2500000 tokens (\$13.50)"; then
  ok price-live-total "pricing computes and formats live total cost accurately (\$13.50)"
else
  bad price-live-total "pricing live total unexpected: $REPORT_PRC"
fi

if printf '%s\n' "$REPORT_PRC" | grep -q "Avg tokens / successful task:[[:space:]]*2500000 tokens (\$13.50)"; then
  ok price-efficiency "pricing computes cost per successful task accurately"
else
  bad price-efficiency "pricing efficiency unexpected: $REPORT_PRC"
fi


# =============================================================================
# 6. Multi-Run Totals, Verification Overrides, and CLI Errors
# =============================================================================

# Multi-run spend accumulation
R_MULTI="$(new_repo multi-run-spend)"
mkdir -p "$R_MULTI/.agy"

ledger_append "$R_MULTI" run=run-1 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":8000,"output_tokens":2000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":10000}'

ledger_append "$R_MULTI" run=run-2 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy \
  started=2026-08-25T10:05:00Z elapsed_s=15 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":12000,"output_tokens":3000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":15000}'

ledger_append "$R_MULTI" run=run-3 phase=REVIEW attempt=1 tier=high model=m backend=agy \
  started=2026-08-25T10:10:00Z elapsed_s=8 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":4000,"output_tokens":1000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":5000}'

# Verify failure override & No status reported
ledger_append "$R_MULTI" run=run-4 phase=QA attempt=1 tier=high model=m backend=agy \
  started=2026-08-25T10:15:00Z elapsed_s=5 worker_rc=0 verdict=PASSED verify_ran=true verify_rc=1 status=VERIFY_FAILED \
  retries_spent=0 retries_refunded=0

ledger_append "$R_MULTI" run=run-5 phase=QA attempt=1 tier=high model=m backend=agy \
  started=2026-08-25T10:20:00Z elapsed_s=5 worker_rc=0 verdict="" verify_ran=false status=NO_STATUS_REPORTED \
  retries_spent=0 retries_refunded=0

REPORT_MULTI="$(bash "$REPORT_SH" --dir "$R_MULTI")"; RC_MULTI=$?
check report-multi-run-rc "$RC_MULTI" 0 "report.sh exits 0 on multi-run ledger"

if printf '%s\n' "$REPORT_MULTI" | grep -q "Live Total:[[:space:]]*30000 tokens"; then
  ok report-multi-run-total "report correctly totals live spend across runs (30000 tokens)"
else
  bad report-multi-run-total "report total across runs unexpected: $REPORT_MULTI"
fi

if printf '%s\n' "$REPORT_MULTI" | grep -q "IMPLEMENT:[[:space:]]*25000 tokens"; then
  ok report-multi-run-phase-total "report correctly totals phase spend across runs (25000 tokens)"
else
  bad report-multi-run-phase-total "phase total across runs unexpected: $REPORT_MULTI"
fi

if printf '%s\n' "$REPORT_MULTI" | grep -q "Verify gate overrides:[[:space:]]*1"; then
  ok report-verify-overrides "verify gate overrides counted accurately"
else
  bad report-verify-overrides "verify gate overrides unexpected: $REPORT_MULTI"
fi

if printf '%s\n' "$REPORT_MULTI" | grep -q "No status reported dispatches:[[:space:]]*1"; then
  ok report-no-status "no status reported dispatches counted accurately"
else
  bad report-no-status "no status reported unexpected: $REPORT_MULTI"
fi

# CLI exit code checks
R_EMPTY_LEDGER="$(new_repo empty-ledger)"
REP_EMPTY_LEDGER="$(bash "$REPORT_SH" --dir "$R_EMPTY_LEDGER")"; RC_EMPTY_LEDGER=$?
check cli-empty-ledger-rc "$RC_EMPTY_LEDGER" 0 "absent/empty ledger exits 0"
if printf '%s\n' "$REP_EMPTY_LEDGER" | grep -q "Ledger is empty or absent"; then
  ok cli-empty-ledger-msg "absent/empty ledger prints empty message"
else
  bad cli-empty-ledger-msg "absent/empty ledger message unexpected: $REP_EMPTY_LEDGER"
fi

bash "$REPORT_SH" --dir "$ROOT/nonexistent-dir" >/dev/null 2>&1 || RC_BAD_DIR=$?
check cli-bad-dir "${RC_BAD_DIR:-0}" 2 "non-existent dir exits 2"

NON_GIT="$ROOT/non-git-dir"
mkdir -p "$NON_GIT"
bash "$REPORT_SH" --dir "$NON_GIT" >/dev/null 2>&1 || RC_NON_GIT=$?
check cli-non-git "${RC_NON_GIT:-0}" 4 "non-git dir exits 4"

bash "$REPORT_SH" --bogus-arg >/dev/null 2>&1 || RC_BAD_ARG=$?
check cli-bad-arg "${RC_BAD_ARG:-0}" 2 "unknown arg exits 2"


# =============================================================================
# 7. Worker Error and Printed Fallback Counts
# =============================================================================

R_COUNTS="$(new_repo worker-error-and-printed-fallback)"
mkdir -p "$R_COUNTS/.agy"

# Record 1: clean run with file route (verdict_route=file, agy_status=SUCCESS)
ledger_append "$R_COUNTS" run=run-1 phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verdict_route=file verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 agy_status=SUCCESS

# Record 2: worker error with printed route (verdict_route=print, agy_status=ERROR)
ledger_append "$R_COUNTS" run=run-2 phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:05:00Z elapsed_s=12 worker_rc=0 verdict=PASSED verdict_route=print verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 agy_status=ERROR

# Record 3: worker error with file route (verdict_route=file, agy_status=ERROR)
ledger_append "$R_COUNTS" run=run-3 phase=REVIEW attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:10:00Z elapsed_s=8 worker_rc=0 verdict=PASSED verdict_route=file verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 agy_status=ERROR

# Record 4: clean worker with printed fallback route (verdict_route=print, agy_status=SUCCESS)
ledger_append "$R_COUNTS" run=run-4 phase=QA attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:15:00Z elapsed_s=6 worker_rc=0 verdict=PASSED verdict_route=print verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 agy_status=SUCCESS

REPORT_COUNTS="$(bash "$REPORT_SH" --dir "$R_COUNTS")"; RC_COUNTS=$?
check report-counts-rc "$RC_COUNTS" 0 "report.sh exits 0 on counts fixture"

if printf '%s\n' "$REPORT_COUNTS" | grep -q "Worker error dispatches:[[:space:]]*2"; then
  ok report-worker-errors-counted "worker error dispatches counted accurately (2)"
else
  bad report-worker-errors-counted "worker error dispatches count unexpected: $REPORT_COUNTS"
fi

if printf '%s\n' "$REPORT_COUNTS" | grep -q "Printed fallback dispatches:[[:space:]]*2"; then
  ok report-printed-fallbacks-counted "printed fallback dispatches counted accurately (2)"
else
  bad report-printed-fallbacks-counted "printed fallback dispatches count unexpected: $REPORT_COUNTS"
fi

# Zero reporting: ledger with neither worker error nor printed fallback reports zero rather than omitting
R_ZERO="$(new_repo counts-zero)"
mkdir -p "$R_ZERO/.agy"
ledger_append "$R_ZERO" run=run-z phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=5 worker_rc=0 verdict=PASSED verdict_route=file verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 agy_status=SUCCESS

REPORT_ZERO="$(bash "$REPORT_SH" --dir "$R_ZERO")"

if printf '%s\n' "$REPORT_ZERO" | grep -q "Worker error dispatches:[[:space:]]*0"; then
  ok report-worker-errors-zero "worker error dispatches reports 0 when none present"
else
  bad report-worker-errors-zero "worker error dispatches missing or not 0: $REPORT_ZERO"
fi

if printf '%s\n' "$REPORT_ZERO" | grep -q "Printed fallback dispatches:[[:space:]]*0"; then
  ok report-printed-fallbacks-zero "printed fallback dispatches reports 0 when none present"
else
  bad report-printed-fallbacks-zero "printed fallback dispatches missing or not 0: $REPORT_ZERO"
fi


printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

