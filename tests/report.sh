#!/usr/bin/env bash
# Exercise scripts/report.sh:
# 1. Column integrity: 15-field TSV round trip and field placement
# 2. Absent is not zero: unmeasured tokens and untimed dispatches
# 3. Filters: narrowing by --run, --phase, --since, and empty matches
# 4. Malformed input: non-JSON lines, truncated JSON, missing required fields
# 5. Pricing and cost calculation: --price-in and --price-out formatting
# 6. Multi-run aggregation, verify overrides, and CLI error handling
# 7. Worker Error and Printed Fallback Counts
# 8. Gate Firing Counts and Never-Fired Gates
# 9. Refusals: gates that fire before any dispatch
# 10. Machine-readable TSV output: --format tsv
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

# shellcheck source=../scripts/ledger.sh
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
if printf '%s\n' "$REP_COL_RUN" | grep -q "1 with dispatch context" && \
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
if printf '%s\n' "$REPORT_COL" | grep -q "1 with dispatch context" && \
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
if printf '%s\n' "$REP_COL_SINCE" | grep -q "1 with dispatch context" && \
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
if printf '%s\n' "$REP_RUN" | grep -q "2 with dispatch context" && \
   printf '%s\n' "$REP_RUN" | grep -q "Live Total:[[:space:]]*3000 tokens" && \
   ! printf '%s\n' "$REP_RUN" | grep -q "QA:"; then
  ok filter-run "--run narrows to specified run"
else
  bad filter-run "--run filter failed: $REP_RUN"
fi

# Test --phase filter
REP_PHASE="$(bash "$REPORT_SH" --dir "$R_FILT" --phase IMPLEMENT)"
if printf '%s\n' "$REP_PHASE" | grep -q "2 with dispatch context" && \
   printf '%s\n' "$REP_PHASE" | grep -q "IMPLEMENT:[[:space:]]*2 dispatches" && \
   ! printf '%s\n' "$REP_PHASE" | grep -q "REVIEW:" && \
   ! printf '%s\n' "$REP_PHASE" | grep -q "QA:"; then
  ok filter-phase "--phase narrows to specified phase"
else
  bad filter-phase "--phase filter failed: $REP_PHASE"
fi

# Test --since filter
REP_SINCE="$(bash "$REPORT_SH" --dir "$R_FILT" --since 2026-08-25T09:30:00Z)"
if printf '%s\n' "$REP_SINCE" | grep -q "2 with dispatch context" && \
   printf '%s\n' "$REP_SINCE" | grep -q "Live Total:[[:space:]]*7000 tokens"; then
  ok filter-since "--since narrows to records at or after date"
else
  bad filter-since "--since filter failed: $REP_SINCE"
fi

# Test combined --run and --phase filter
REP_COMB="$(bash "$REPORT_SH" --dir "$R_FILT" --run run-beta --phase QA)"
if printf '%s\n' "$REP_COMB" | grep -q "1 with dispatch context" && \
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

if printf '%s\n' "$REPORT_MAL" | grep -q "Records:    6 line(s) read — 1 with dispatch context, 3 without, 2 unparseable"; then
  ok malformed-header-counts "header separates unparseable lines from well-formed ones carrying no dispatch context"
else
  bad malformed-header-counts "header counts unexpected: $REPORT_MAL"
fi

if printf '%s\n' "$REPORT_MAL" | grep -q "Unparseable records skipped:[[:space:]]*2" && \
   printf '%s\n' "$REPORT_MAL" | grep -q "Records with no dispatch context:[[:space:]]*3"; then
  ok malformed-integrity-section "Data Integrity counts unparseable and no-context records separately"
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

if printf '%s\n' "$REPORT_MULTI" | grep -q "No status reported:[[:space:]]*1"; then
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


# =============================================================================
# 8. Gate Firing Counts and Never-Fired Gates
# =============================================================================

# 8.1 All gates fired: fixture containing at least one record for each gate
R_ALL_GATES="$(new_repo all-gates)"
mkdir -p "$R_ALL_GATES/.agy"

ledger_append "$R_ALL_GATES" run=run-1 phase=PHASE1 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=true verify_rc=1 status='VERIFY_FAILED(rc=1)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_ALL_GATES" run=run-2 phase=PHASE2 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:05:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status='DIFF_TESTS_WEAKENED(test_foo.py)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_ALL_GATES" run=run-3 phase=PHASE3 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:10:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status='DIFF_SUSPICIOUS(rm -rf)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_ALL_GATES" run=run-4 phase=PHASE4 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:15:00Z elapsed_s=10 worker_rc=0 verdict=FAILED verify_ran=false status='SECRETS_FOUND(api_key)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_ALL_GATES" run=run-5 phase=PHASE5 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:20:00Z elapsed_s=10 worker_rc=0 verdict=FAILED verify_ran=false status='BRIEF_INVALID(missing_verdict)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_ALL_GATES" run=run-6 phase=PHASE6 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:25:00Z elapsed_s=10 worker_rc=0 verdict='' verify_ran=false status=NO_STATUS_REPORTED \
  retries_spent=0 retries_refunded=0

ledger_append "$R_ALL_GATES" run=run-7 phase=PHASE7 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:30:00Z elapsed_s=10 worker_rc=0 verdict=FAILED verify_ran=false status='RETRY_CAP_REACHED(n=2, cap=2)' \
  retries_spent=2 retries_refunded=0

ledger_append "$R_ALL_GATES" run=run-8 phase=PHASE8 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:35:00Z elapsed_s=10 worker_rc=0 verdict='STATUS: BRIEF_IMPOSSIBLE(conflict)' verify_ran=false status='BRIEF_IMPOSSIBLE(conflict)' \
  retries_spent=0 retries_refunded=1

ledger_append "$R_ALL_GATES" run=run-9 phase=PHASE9 attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:40:00Z elapsed_s=10 worker_rc=0 verdict=FAILED verify_ran=false status='GIT_STATE_CHANGED(head)' \
  retries_spent=0 retries_refunded=0

REPORT_ALL="$(bash "$REPORT_SH" --dir "$R_ALL_GATES")"; RC_ALL=$?
check gate-all-rc "$RC_ALL" 0 "report.sh exits 0 on all-gates fixture"

for gate_label in \
  "Verify gate overrides:[[:space:]]*1" \
  "Diff tests weakened:[[:space:]]*1" \
  "Diff suspicious:[[:space:]]*1" \
  "Secrets found:[[:space:]]*1" \
  "Brief invalid:[[:space:]]*1" \
  "No status reported:[[:space:]]*1" \
  "Retry cap reached:[[:space:]]*1" \
  "Brief impossible:[[:space:]]*1" \
  "Git state changed:[[:space:]]*1"; do
  if printf '%s\n' "$REPORT_ALL" | grep -q "$gate_label"; then
    ok "gate-count-${gate_label%%:*}" "$gate_label accurately counted as 1"
  else
    bad "gate-count-${gate_label%%:*}" "expected count 1 for $gate_label: $REPORT_ALL"
  fi
done

# When all gates fired, none should be listed under Never-Fired Gates
NEVER_SECTION_ALL="$(printf '%s\n' "$REPORT_ALL" | sed -n '/Never-Fired Gates:/,/Data Integrity:/p')"
if ! printf '%s\n' "$NEVER_SECTION_ALL" | grep -q -E -- '- (Verify gate overrides|Diff tests weakened|Diff suspicious|Secrets found|Brief invalid|No status reported|Retry cap reached|Brief impossible|Git state changed)'; then
  ok gate-all-none-never-fired "no gates listed under never-fired heading when all fired"
else
  bad gate-all-none-never-fired "gates unexpectedly listed under never-fired: $NEVER_SECTION_ALL"
fi

# 8.2 None of them fired: fixture containing none of the gate statuses
R_NO_GATES="$(new_repo no-gates)"
mkdir -p "$R_NO_GATES/.agy"

ledger_append "$R_NO_GATES" run=run-1 phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0

REPORT_NONE="$(bash "$REPORT_SH" --dir "$R_NO_GATES")"; RC_NONE=$?
check gate-none-rc "$RC_NONE" 0 "report.sh exits 0 on no-gates fixture"

NEVER_SECTION_NONE="$(printf '%s\n' "$REPORT_NONE" | sed -n '/Never-Fired Gates:/,/Data Integrity:/p')"
if printf '%s\n' "$NEVER_SECTION_NONE" | grep -q "Nothing in the filtered ledger triggered these"; then
  ok gate-none-expl-line "never-fired section carries explanation line"
else
  bad gate-none-expl-line "never-fired explanation line missing: $NEVER_SECTION_NONE"
fi

for gate_name in \
  "Verify gate overrides" \
  "Diff tests weakened" \
  "Diff suspicious" \
  "Secrets found" \
  "Brief invalid" \
  "No status reported" \
  "Retry cap reached" \
  "Brief impossible" \
  "Git state changed"; do
  if printf '%s\n' "$NEVER_SECTION_NONE" | grep -q -- "- $gate_name"; then
    ok "gate-none-listed-${gate_name// /-}" "$gate_name listed under never-fired heading"
  else
    bad "gate-none-listed-${gate_name// /-}" "$gate_name missing from never-fired: $NEVER_SECTION_NONE"
  fi
done

# 8.3 Mixed fixture: exactly absent ones under never-fired heading and no others
R_MIXED="$(new_repo mixed-gates)"
mkdir -p "$R_MIXED/.agy"

# Fired gates: VERIFY_FAILED, SECRETS_FOUND, RETRY_CAP_REACHED
ledger_append "$R_MIXED" run=run-1 phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=true verify_rc=1 status='VERIFY_FAILED(rc=1)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_MIXED" run=run-2 phase=REVIEW attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:05:00Z elapsed_s=5 worker_rc=0 verdict=FAILED verify_ran=false status='SECRETS_FOUND(token)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_MIXED" run=run-3 phase=QA attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T10:10:00Z elapsed_s=8 worker_rc=0 verdict=FAILED verify_ran=false status='RETRY_CAP_REACHED(n=2, cap=2)' \
  retries_spent=2 retries_refunded=0

REPORT_MIXED="$(bash "$REPORT_SH" --dir "$R_MIXED")"; RC_MIXED=$?
check gate-mixed-rc "$RC_MIXED" 0 "report.sh exits 0 on mixed fixture"

NEVER_SECTION_MIXED="$(printf '%s\n' "$REPORT_MIXED" | sed -n '/Never-Fired Gates:/,/Data Integrity:/p')"

# Fired gates must NOT be in never-fired
for fired_gate in "Verify gate overrides" "Secrets found" "Retry cap reached"; do
  if ! printf '%s\n' "$NEVER_SECTION_MIXED" | grep -q -- "- $fired_gate"; then
    ok "gate-mixed-fired-omitted-${fired_gate// /-}" "fired gate $fired_gate omitted from never-fired"
  else
    bad "gate-mixed-fired-omitted-${fired_gate// /-}" "fired gate $fired_gate unexpectedly in never-fired: $NEVER_SECTION_MIXED"
  fi
done

# Absent gates MUST be in never-fired
for absent_gate in \
  "Diff tests weakened" \
  "Diff suspicious" \
  "Brief invalid" \
  "No status reported" \
  "Brief impossible" \
  "Git state changed"; do
  if printf '%s\n' "$NEVER_SECTION_MIXED" | grep -q -- "- $absent_gate"; then
    ok "gate-mixed-absent-listed-${absent_gate// /-}" "absent gate $absent_gate listed in never-fired"
  else
    bad "gate-mixed-absent-listed-${absent_gate// /-}" "absent gate $absent_gate missing from never-fired: $NEVER_SECTION_MIXED"
  fi
done

# 8.4 Filters narrow gate counts
R_FILT_GATES="$(new_repo filt-gates)"
mkdir -p "$R_FILT_GATES/.agy"

ledger_append "$R_FILT_GATES" run=run-1 phase=IMPLEMENT attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T08:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=true verify_rc=1 status='VERIFY_FAILED(rc=1)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_FILT_GATES" run=run-2 phase=REVIEW attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T09:00:00Z elapsed_s=5 worker_rc=0 verdict=FAILED verify_ran=false status='SECRETS_FOUND(key)' \
  retries_spent=0 retries_refunded=0

ledger_append "$R_FILT_GATES" run=run-2 phase=QA attempt=1 tier=m model=m backend=agy \
  started=2026-08-25T11:00:00Z elapsed_s=8 worker_rc=0 verdict=FAILED verify_ran=false status='BRIEF_INVALID(empty)' \
  retries_spent=0 retries_refunded=0

# Filter by --phase IMPLEMENT
REP_FILT_PH="$(bash "$REPORT_SH" --dir "$R_FILT_GATES" --phase IMPLEMENT)"
if printf '%s\n' "$REP_FILT_PH" | grep -q "Verify gate overrides:[[:space:]]*1" && \
   printf '%s\n' "$REP_FILT_PH" | grep -q "Secrets found:[[:space:]]*0" && \
   printf '%s\n' "$REP_FILT_PH" | grep -q "Brief invalid:[[:space:]]*0"; then
  ok gate-filt-phase "--phase narrows gate firing counts"
else
  bad gate-filt-phase "--phase gate counts unexpected: $REP_FILT_PH"
fi

# Filter by --run run-2
REP_FILT_RN="$(bash "$REPORT_SH" --dir "$R_FILT_GATES" --run run-2)"
if printf '%s\n' "$REP_FILT_RN" | grep -q "Verify gate overrides:[[:space:]]*0" && \
   printf '%s\n' "$REP_FILT_RN" | grep -q "Secrets found:[[:space:]]*1" && \
   printf '%s\n' "$REP_FILT_RN" | grep -q "Brief invalid:[[:space:]]*1"; then
  ok gate-filt-run "--run narrows gate firing counts"
else
  bad gate-filt-run "--run gate counts unexpected: $REP_FILT_RN"
fi

# Filter by --since
REP_FILT_SN="$(bash "$REPORT_SH" --dir "$R_FILT_GATES" --since 2026-08-25T10:00:00Z)"
if printf '%s\n' "$REP_FILT_SN" | grep -q "Verify gate overrides:[[:space:]]*0" && \
   printf '%s\n' "$REP_FILT_SN" | grep -q "Secrets found:[[:space:]]*0" && \
   printf '%s\n' "$REP_FILT_SN" | grep -q "Brief invalid:[[:space:]]*1"; then
  ok gate-filt-since "--since narrows gate firing counts"
else
  bad gate-filt-since "--since gate counts unexpected: $REP_FILT_SN"
fi



# =============================================================================
# 9. Refusals: gates that fire before any dispatch
# =============================================================================
#
# A gate that refuses before the worker runs costs no model call. It is still a
# real event with a real cause, so it belongs in the ledger — but counting it as
# a dispatch understates the worker's pass rate and pollutes spend averages, and
# not counting it as a gate has someone delete working code.

R_REF="$(new_repo refusals)"
ledger_append "$R_REF" run=r-ref phase=IMPLEMENT status=BRIEF_INVALID'(missing_verdict_path)' \
  dispatched=false attempt=1 started=2026-08-25T10:00:00Z
ledger_append "$R_REF" run=r-ref phase=IMPLEMENT status=SECRETS_FOUND dispatched=false \
  attempt=1 started=2026-08-25T10:01:00Z
ledger_append "$R_REF" run=r-ref phase=IMPLEMENT status=DONE dispatched=true attempt=1 \
  started=2026-08-25T10:02:00Z elapsed_s=30 \
  usage='{"input_tokens":800,"output_tokens":200,"thinking_tokens":0,"total_tokens":1000}'

REP_REF="$(bash "$REPORT_SH" --dir "$R_REF")"

if printf '%s\n' "$REP_REF" | grep -qE '^Dispatches: 1 '; then
  ok refusal-dispatch-count "only the record that ran a worker counts as a dispatch"
else
  bad refusal-dispatch-count "dispatch count unexpected: $REP_REF"
fi

if printf '%s\n' "$REP_REF" | grep -qE '^Refusals:   2 '; then
  ok refusal-count "both refusals are counted, and counted separately"
else
  bad refusal-count "refusal count unexpected: $REP_REF"
fi

# 1 of 1 rather than 1 of 3: a gate that fired before the dispatch is not a
# worker that failed.
if printf '%s\n' "$REP_REF" | grep -qE 'IMPLEMENT:[[:space:]]+1 dispatches,[[:space:]]+1 passed \(100%\),[[:space:]]+2 refused'; then
  ok refusal-pass-rate "refusals are excluded from the pass rate and reported beside it"
else
  bad refusal-pass-rate "pass rate line unexpected: $REP_REF"
fi

if printf '%s\n' "$REP_REF" | grep -qE 'Live Total:[[:space:]]+1000 tokens'; then
  ok refusal-no-spend "a refusal contributes nothing to spend"
else
  bad refusal-no-spend "spend unexpected: $REP_REF"
fi

for G in "Brief invalid" "Secrets found"; do
  SLUG="$(printf '%s' "$G" | tr ' ' '-')"
  if printf '%s\n' "$REP_REF" | grep -qE "$G:[[:space:]]+1"; then
    ok "refusal-gate-$SLUG" "$G is counted as a gate that fired"
  else
    bad "refusal-gate-$SLUG" "$G not counted: $REP_REF"
  fi
  if printf '%s\n' "$REP_REF" | sed -n '/Never-Fired Gates:/,$p' | grep -q "^  - $G\$"; then
    bad "refusal-notdead-$SLUG" "$G fired but is listed as never having fired"
  else
    ok "refusal-notdead-$SLUG" "$G is kept out of the never-fired list"
  fi
done

# A run whose every record is a refusal never reached a worker, so there is no
# efficiency to measure and no failed task to report.
R_REFRUN="$(new_repo refusal-only-run)"
ledger_append "$R_REFRUN" run=r-ok phase=IMPLEMENT status=DONE dispatched=true attempt=1 \
  usage='{"input_tokens":800,"output_tokens":200,"thinking_tokens":0,"total_tokens":1000}'
ledger_append "$R_REFRUN" run=r-refused-only phase=IMPLEMENT status=BRIEF_INVALID dispatched=false attempt=1
REP_REFRUN="$(bash "$REPORT_SH" --dir "$R_REFRUN")"
if printf '%s\n' "$REP_REFRUN" | grep -qE 'Successful tasks \(runs\):[[:space:]]+1 / 1 \(100%\)'; then
  ok refusal-run-excluded "a run that never dispatched is left out of the successful-task rate"
else
  bad refusal-run-excluded "task rate unexpected: $REP_REFRUN"
fi
if printf '%s\n' "$REP_REFRUN" | grep -qE 'Runs refused before dispatch:[[:space:]]+1'; then
  ok refusal-run-named "the excluded run is named rather than silently dropped"
else
  bad refusal-run-named "excluded-run line missing: $REP_REFRUN"
fi

# A record written before the dispatched field existed cannot be classified, and
# saying so is better than guessing either way.
R_UNM="$(new_repo unmarked)"
ledger_append "$R_UNM" run=r-unm phase=IMPLEMENT status=DONE attempt=1
REP_UNM="$(bash "$REPORT_SH" --dir "$R_UNM")"
if printf '%s\n' "$REP_UNM" | grep -qE '^Unmarked:   1 '; then
  ok unmarked-named "a record with no dispatched field is named rather than guessed at"
else
  bad unmarked-named "unmarked line missing: $REP_UNM"
fi
if printf '%s\n' "$REP_UNM" | grep -qE '^Refusals:   0 '; then
  ok unmarked-not-refusal "an unmarked record is not silently counted as a refusal"
else
  bad unmarked-not-refusal "refusal count unexpected: $REP_UNM"
fi

# The gates that only ever fire outside a dispatch — the phase-range check, the
# test-command check, the release check — and the preflight and cap refusals
# that phase.sh makes before spending anything.
R_ALL="$(new_repo every-gate)"
i=0
for ST in RANGE_REFUSED TEST_COMMAND_FAILED TEST_COMMAND_NOT_RUNNABLE TEST_COMMAND_TIMEOUT \
          RELEASE_BLOCKED RELEASE_FAILED PREFLIGHT_FAILED BUDGET_EXCEEDED \
          REPO_BUDGET_EXCEEDED WORKER_CAP_EXCEEDED RETRY_CAP_REACHED; do
  i=$((i + 1))
  ledger_append "$R_ALL" run=r-all phase=GATE "status=$ST" dispatched=false attempt=1
done
REP_ALL="$(bash "$REPORT_SH" --dir "$R_ALL")"
GATE_MISSING=0
for LBL in "Phase range refused" "Test command failed" "Test command not runnable" \
           "Test command timed out" "Release blocked" "Release failed" "Preflight failed" \
           "Run budget exceeded" "Repo budget exceeded" "Worker cap exceeded" "Retry cap reached"; do
  printf '%s\n' "$REP_ALL" | grep -qE "$LBL:[[:space:]]+1" || {
    bad "gate-counted-$(printf '%s' "$LBL" | tr ' ' '-')" "$LBL is not counted at 1"
    GATE_MISSING=$((GATE_MISSING + 1))
  }
done
check every-gate-counted "$GATE_MISSING" "0" "every refusal gate has a firing count of its own"

# REPO_BUDGET_EXCEEDED must not be swallowed by the BUDGET_EXCEEDED count, and a
# status carrying its reason in parentheses must still match its gate.
R_PFX="$(new_repo gate-prefixes)"
ledger_append "$R_PFX" run=r-pfx phase=GATE 'status=REPO_BUDGET_EXCEEDED(spent=9, budget=8)' dispatched=false
REP_PFX="$(bash "$REPORT_SH" --dir "$R_PFX")"
if printf '%s\n' "$REP_PFX" | grep -qE 'Repo budget exceeded:[[:space:]]+1' \
   && printf '%s\n' "$REP_PFX" | grep -qE 'Run budget exceeded:[[:space:]]+0'; then
  ok gate-prefix-distinct "a reason in parentheses matches its gate, and the two budget gates stay apart"
else
  bad gate-prefix-distinct "budget gate counts unexpected: $REP_PFX"
fi

# The Phase 2 review verdict rides in the nested review object rather than in
# status, and was never counted as a gate at all.
R_REV="$(new_repo review-gate)"
ledger_append "$R_REV" run=r-rev phase=REVIEW status=DONE dispatched=true attempt=1 \
  review='{"anchors":0,"status":"REVIEW_THIN"}'
REP_REV="$(bash "$REPORT_SH" --dir "$R_REV")"
if printf '%s\n' "$REP_REV" | grep -qE 'Review thin:[[:space:]]+1'; then
  ok review-gate-counted "a review verdict in the nested object counts as a gate that fired"
else
  bad review-gate-counted "review gate not counted: $REP_REV"
fi
if printf '%s\n' "$REP_REV" | grep -qE 'Review absent:[[:space:]]+0'; then
  ok review-gate-distinct "REVIEW_THIN is not counted as REVIEW_ABSENT"
else
  bad review-gate-distinct "review gate counts unexpected: $REP_REV"
fi

# The firing counts and the never-fired list are two views of one table. Kept by
# hand they drift, and a gate ends up counted in one and missing from the other.
GATES_LISTED="$(printf '%s\n' "$REP_REV" | sed -n '/^Gate Firing Counts:/,/^$/p' \
  | sed -n 's/^  \(.*\):[[:space:]]*[0-9][0-9]*$/\1/p' | sort)"
GATES_ZERO="$(printf '%s\n' "$REP_REV" | sed -n '/^Gate Firing Counts:/,/^$/p' \
  | sed -n 's/^  \(.*\):[[:space:]]*0$/\1/p' | sort)"
GATES_NEVER="$(printf '%s\n' "$REP_REV" | sed -n '/^Never-Fired Gates:/,/^$/p' \
  | sed -n 's/^  - //p' | sort)"
check gate-lists-agree "$GATES_NEVER" "$GATES_ZERO" \
  "the never-fired list is exactly the gates counted at zero"
GATES_N="$(printf '%s\n' "$GATES_LISTED" | grep -c . || true)"
if [ "${GATES_N:-0}" -ge 20 ]; then
  ok gate-table-complete "the report counts $GATES_N gates, not just the handful that had counters"
else
  bad gate-table-complete "only $GATES_N gates counted — the table has shrunk"
fi

# _extract_bool read booleans with a BRE alternation, which BSD sed does not
# support: every boolean in the ledger read as absent on macOS, silently.
R_BOOL="$(new_repo bool-extract)"
ledger_append "$R_BOOL" run=r-bool phase=IMPLEMENT status=DONE dispatched=true verify_ran=true attempt=1
ledger_append "$R_BOOL" run=r-bool phase=IMPLEMENT status=BRIEF_INVALID dispatched=false verify_ran=false attempt=1
REP_BOOL="$(bash "$REPORT_SH" --dir "$R_BOOL")"
if printf '%s\n' "$REP_BOOL" | grep -qE '^Dispatches: 1 ' \
   && printf '%s\n' "$REP_BOOL" | grep -qE '^Refusals:   1 ' \
   && printf '%s\n' "$REP_BOOL" | grep -qE '^Unmarked:' ; then
  bad bool-extract "a boolean that is present read as absent: $REP_BOOL"
else
  if printf '%s\n' "$REP_BOOL" | grep -qE '^Dispatches: 1 ' \
     && printf '%s\n' "$REP_BOOL" | grep -qE '^Refusals:   1 '; then
    ok bool-extract "booleans are read on a sed whose basic regex has no alternation"
  else
    bad bool-extract "boolean read unexpected: $REP_BOOL"
  fi
fi

# =============================================================================
# Gate corroboration: say what kind of claim each gate makes, and only put a
# number where a later signal actually exists to check it against.
#
# The risk being managed is the same one the never-fired list was rewritten for:
# a reader deleting a working gate on the strength of a figure nothing supports.
# =============================================================================

R_CORR="$(new_repo gate-corroboration)"

# A run whose review was thin and which then failed --verify: the one correlation
# the ledger can actually support.
ledger_append "$R_CORR" run=corr-1 phase=REVIEW status=DONE dispatched=true \
  review='{"anchors":0,"status":"REVIEW_THIN"}'
ledger_append "$R_CORR" run=corr-1 phase=QA "status=VERIFY_FAILED(rc=1)" dispatched=true

# A thin review in a run that went on to pass: the gate fired and nothing
# corroborated it.
ledger_append "$R_CORR" run=corr-2 phase=REVIEW status=DONE dispatched=true \
  review='{"anchors":0,"status":"REVIEW_THIN"}'

# A refusal, which can never be scored: the dispatch it refused does not exist.
ledger_append "$R_CORR" run=corr-3 phase=IMPLEMENT status=BRIEF_INVALID dispatched=false

OUT_CORR="$(/bin/bash "$REPORT_SH" --dir "$R_CORR" 2>/dev/null)"

if printf '%s\n' "$OUT_CORR" | grep -q "Gate Corroboration:"; then
  ok corr-section "the report carries a gate corroboration section"
else
  bad corr-section "no corroboration section in the report"
fi

CORR_THIN="$(printf '%s\n' "$OUT_CORR" | grep "Review thin:" || true)"
if printf '%s\n' "$CORR_THIN" | grep -q "1 of 2 were in a run that later failed --verify"; then
  ok corr-thin-correlation "a thin review is scored against whether its run later failed --verify"
else
  bad corr-thin-correlation "correlation wrong or missing: $CORR_THIN"
fi

CORR_REFUSAL="$(printf '%s\n' "$OUT_CORR" | grep "Brief invalid:" | grep "Corrobo" || \
  printf '%s\n' "$OUT_CORR" | sed -n '/Gate Corroboration/,/^$/p' | grep "Brief invalid:" || true)"
if printf '%s\n' "$CORR_REFUSAL" | grep -q "cannot be scored"; then
  ok corr-refusal-unscorable "a refusal is reported as unscorable rather than as unproven"
else
  bad corr-refusal-unscorable "refusal not labelled: $CORR_REFUSAL"
fi

CORR_MECH="$(printf '%s\n' "$OUT_CORR" | sed -n '/Gate Corroboration/,/^$/p' | grep "Verify gate overrides:" || true)"
if printf '%s\n' "$CORR_MECH" | grep -q "the gate is the measurement"; then
  ok corr-mechanical "a mechanical gate is not given a precision figure"
else
  bad corr-mechanical "mechanical gate not labelled: $CORR_MECH"
fi

# A gate that never fired stays out of the corroboration list entirely — it
# belongs to the never-fired list, which says something different.
if printf '%s\n' "$OUT_CORR" | sed -n '/Gate Corroboration/,/^$/p' | grep -q "Release blocked:"; then
  bad corr-only-fired "a gate that never fired appeared in the corroboration list"
else
  ok corr-only-fired "only gates that actually fired are scored"
fi

# An advisory gate with no later signal must say so rather than show a number.
R_ADV="$(new_repo gate-advisory-nosignal)"
ledger_append "$R_ADV" run=adv-1 phase=IMPLEMENT "status=DIFF_SUSPICIOUS(scope: src/x.ts)" dispatched=true
OUT_ADV="$(/bin/bash "$REPORT_SH" --dir "$R_ADV" 2>/dev/null)"
ADV_LINE="$(printf '%s\n' "$OUT_ADV" | sed -n '/Gate Corroboration/,/^$/p' | grep "Diff suspicious:" || true)"
if printf '%s\n' "$ADV_LINE" | grep -q "no later signal is recorded"; then
  ok corr-advisory-honest "an advisory gate with nothing to check against says so"
else
  bad corr-advisory-honest "advisory gate not labelled honestly: $ADV_LINE"
fi


# =============================================================================
# 10. Machine-Readable TSV Output: --format tsv
# =============================================================================

# 10.1 Byte-identical prose output with and without --format text
OUT_TEXT_DEFAULT="$(bash "$REPORT_SH" --dir "$R_COL")"
OUT_TEXT_EXPLICIT="$(bash "$REPORT_SH" --dir "$R_COL" --format text)"
check tsv-text-default-match "$OUT_TEXT_DEFAULT" "$OUT_TEXT_EXPLICIT" "text output is byte-identical with and without --format text"

# 10.2 Empty ledger and absent ledger in TSV mode
R_TSV_NO_LEDGER="$(new_repo tsv-no-ledger)"
OUT_TSV_NO_LEDGER="$(bash "$REPORT_SH" --dir "$R_TSV_NO_LEDGER" --format tsv)"; RC_NO_LEDGER=$?
check tsv-no-ledger-rc "$RC_NO_LEDGER" 0 "absent ledger in TSV mode exits 0"
check tsv-no-ledger-row "$OUT_TSV_NO_LEDGER" "$(printf 'records\t0\t0\t0\t0')" "absent ledger prints record accounting row and nothing else"

R_TSV_EMPTY_FILE="$(new_repo tsv-empty-file)"
mkdir -p "$R_TSV_EMPTY_FILE/.agy"
: > "$R_TSV_EMPTY_FILE/.agy/ledger.jsonl"
OUT_TSV_EMPTY_FILE="$(bash "$REPORT_SH" --dir "$R_TSV_EMPTY_FILE" --format tsv)"; RC_EMPTY_FILE=$?
check tsv-empty-file-rc "$RC_EMPTY_FILE" 0 "empty ledger file in TSV mode exits 0"
check tsv-empty-file-row "$OUT_TSV_EMPTY_FILE" "$(printf 'records\t0\t0\t0\t0')" "empty ledger file prints record accounting row and nothing else"

# 10.3 Unparseable and no-context records in TSV mode
R_TSV_MAL="$(new_repo tsv-malformed)"
mkdir -p "$R_TSV_MAL/.agy"
cat > "$R_TSV_MAL/.agy/ledger.jsonl" <<'EOF'
corrupt plain text
{"run":"r1","status":"PASSED"}
{"run":"r1","phase":"CUSTOM","status":"PASSED","attempt":1,"dispatched":true}
EOF
OUT_TSV_MAL="$(bash "$REPORT_SH" --dir "$R_TSV_MAL" --format tsv)"
MAL_REC_LINE="$(printf '%s\n' "$OUT_TSV_MAL" | grep $'^records\t')"
check tsv-malformed-records "$MAL_REC_LINE" "$(printf 'records\t3\t1\t1\t1')" "TSV records row reports total_read, valid, no_context, unparseable"

# 10.4 Section names, field count of every row, and field order
R_TSV_SCHEMA="$(new_repo tsv-schema)"
mkdir -p "$R_TSV_SCHEMA/.agy"
ledger_append "$R_TSV_SCHEMA" run=r1 phase=PHASEA attempt=1 status=PASSED elapsed_s=10 dispatched=true \
  declared=true fallback=false max_idle_s=2 verify_ran=true verify_rc=0 \
  usage='{"input_tokens":100,"output_tokens":20,"thinking_tokens":5,"cache_read_tokens":10,"total_tokens":125}'
ledger_append "$R_TSV_SCHEMA" run=r1 phase=PHASEB attempt=2 status='VERIFY_FAILED(rc=1)' elapsed_s=20 dispatched=true \
  declared=true fallback=false max_idle_s=4 verify_ran=true verify_rc=1 verdict=PASSED \
  usage='{"input_tokens":200,"output_tokens":40,"thinking_tokens":10,"cache_read_tokens":0,"total_tokens":250}'
ledger_append "$R_TSV_SCHEMA" run=r1 phase=PHASEB status='SECRETS_FOUND(api_key)' dispatched=false attempt=1
ledger_append "$R_TSV_SCHEMA" run=r1 phase=PHASEC attempt=1 status=PASSED dispatched=true \
  review='{"anchors":0,"status":"REVIEW_THIN"}'

OUT_SCHEMA="$(bash "$REPORT_SH" --dir "$R_TSV_SCHEMA" --format tsv)"
SCHEMA_RC=$?
check tsv-schema-rc "$SCHEMA_RC" 0 "TSV schema fixture exits 0"

# Verify section order and field counts
SECTION_NAMES="$(printf '%s\n' "$OUT_SCHEMA" | awk -F'\t' '{print $1}' | awk '!seen[$0]++')"
EXPECTED_SECTIONS="$(printf 'records\nabsent\nphase\nretry\nelapsed\ntokens\ngate\ngate_never\nverify')"
check tsv-section-order "$SECTION_NAMES" "$EXPECTED_SECTIONS" "TSV sections appear in exact canonical order"

FIELD_COUNT_ERRORS=0
while read -r sec nf; do
  [ -n "$sec" ] || continue
  case "$sec" in
    records)    [ "$nf" -eq 5 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    absent)     [ "$nf" -eq 3 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    phase)      [ "$nf" -eq 7 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    retry)      [ "$nf" -eq 7 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    elapsed)    [ "$nf" -eq 6 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    tokens)     [ "$nf" -eq 8 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    gate)       [ "$nf" -eq 4 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    gate_never) [ "$nf" -eq 2 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    verify)     [ "$nf" -eq 5 ] || FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
    *)          FIELD_COUNT_ERRORS=$((FIELD_COUNT_ERRORS + 1)) ;;
  esac
done <<EOF
$(printf '%s\n' "$OUT_SCHEMA" | awk -F'\t' '{ print $1, NF }')
EOF
check tsv-field-counts "$FIELD_COUNT_ERRORS" "0" "every TSV row has the exact expected field count"

# 10.5 Unknown renders as dash (-) and measured zero renders as 0 in same run
R_TSV_DASH_ZERO="$(new_repo tsv-dash-zero)"
mkdir -p "$R_TSV_DASH_ZERO/.agy"
# Phase MEASURED: token thinking=0 and cache_read=0 are measured zeros, elapsed=15
ledger_append "$R_TSV_DASH_ZERO" run=r-dz phase=MEASURED attempt=1 status=PASSED elapsed_s=15 dispatched=true \
  usage='{"input_tokens":100,"output_tokens":50,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":150}'
# Phase UNKNOWN: usage absent, elapsed_s absent
ledger_append "$R_TSV_DASH_ZERO" run=r-dz phase=UNKNOWN attempt=1 status=PASSED dispatched=true
# Phase REFUSED_ONLY: 0 dispatches, pass rate must be -
ledger_append "$R_TSV_DASH_ZERO" run=r-dz phase=REFUSED_ONLY status=BRIEF_INVALID dispatched=false attempt=1

OUT_DZ="$(bash "$REPORT_SH" --dir "$R_TSV_DASH_ZERO" --format tsv)"
TOK_MEASURED="$(printf '%s\n' "$OUT_DZ" | grep $'^tokens\tMEASURED\t')"
TOK_UNKNOWN="$(printf '%s\n' "$OUT_DZ" | grep $'^tokens\tUNKNOWN\t')"
EL_MEASURED="$(printf '%s\n' "$OUT_DZ" | grep $'^elapsed\tMEASURED\t')"
EL_UNKNOWN="$(printf '%s\n' "$OUT_DZ" | grep $'^elapsed\tUNKNOWN\t')"
PH_REFUSED="$(printf '%s\n' "$OUT_DZ" | grep $'^phase\tREFUSED_ONLY\t')"

check tsv-tok-measured "$TOK_MEASURED" "$(printf 'tokens\tMEASURED\t100\t50\t0\t150\t0\t0')" "measured zero tokens render as 0"
check tsv-tok-unknown "$TOK_UNKNOWN" "$(printf 'tokens\tUNKNOWN\t-\t-\t-\t-\t-\t1')" "unknown tokens render as dash with unknown records counted"
check tsv-el-measured "$EL_MEASURED" "$(printf 'elapsed\tMEASURED\t15\t15\t15\t0')" "measured elapsed renders min/p50/max with 0 untimed"
check tsv-el-unknown "$EL_UNKNOWN" "$(printf 'elapsed\tUNKNOWN\t-\t-\t-\t1')" "unknown elapsed renders as dash with untimed count"
check tsv-ph-refused "$PH_REFUSED" "$(printf 'phase\tREFUSED_ONLY\t0\t0\t0\t1\t-')" "0 dispatches phase renders pass_rate as dash"

# 10.6 Late-added fields raise absent counts rather than reporting zeros
R_TSV_OLD="$(new_repo tsv-old-records)"
mkdir -p "$R_TSV_OLD/.agy"
# 2 records predating late-added fields (no dispatched, no max_idle_s, no fallback, no declared, no usage)
ledger_append "$R_TSV_OLD" run=old1 phase=LEGACY attempt=1 status=PASSED started=2026-08-25T10:00:00Z
ledger_append "$R_TSV_OLD" run=old2 phase=LEGACY attempt=1 status=PASSED started=2026-08-25T10:05:00Z
# 1 modern record with all fields
ledger_append "$R_TSV_OLD" run=modern phase=LEGACY attempt=1 status=PASSED started=2026-08-25T10:10:00Z \
  dispatched=true max_idle_s=5 fallback=false declared=true \
  usage='{"input_tokens":100,"output_tokens":50,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":150}'

OUT_OLD="$(bash "$REPORT_SH" --dir "$R_TSV_OLD" --format tsv)"
ABS_DISP="$(printf '%s\n' "$OUT_OLD" | grep $'^absent\tdispatched\t')"
ABS_IDLE="$(printf '%s\n' "$OUT_OLD" | grep $'^absent\tmax_idle_s\t')"
ABS_FALL="$(printf '%s\n' "$OUT_OLD" | grep $'^absent\tfallback\t')"
ABS_DECL="$(printf '%s\n' "$OUT_OLD" | grep $'^absent\tdeclared\t')"
ABS_USAG="$(printf '%s\n' "$OUT_OLD" | grep $'^absent\tusage\t')"

check tsv-abs-disp "$ABS_DISP" "$(printf 'absent\tdispatched\t2')" "absent dispatched counted for vintage records"
check tsv-abs-idle "$ABS_IDLE" "$(printf 'absent\tmax_idle_s\t2')" "absent max_idle_s counted for vintage records"
check tsv-abs-fall "$ABS_FALL" "$(printf 'absent\tfallback\t2')" "absent fallback counted for vintage records"
check tsv-abs-decl "$ABS_DECL" "$(printf 'absent\tdeclared\t2')" "absent declared counted for vintage records"
check tsv-abs-usag "$ABS_USAG" "$(printf 'absent\tusage\t2')" "absent usage counted for vintage records"

# 10.7 Refusals excluded from dispatches and pass rate
R_TSV_REF="$(new_repo tsv-refusal-rate)"
mkdir -p "$R_TSV_REF/.agy"
ledger_append "$R_TSV_REF" run=r-r1 phase=PHASE1 status=PASSED dispatched=true attempt=1 \
  usage='{"input_tokens":500,"output_tokens":100,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":600}'
ledger_append "$R_TSV_REF" run=r-r2 phase=PHASE1 status=WORKER_FAILED dispatched=true attempt=1 \
  usage='{"input_tokens":200,"output_tokens":50,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":250}'
ledger_append "$R_TSV_REF" run=r-r3 phase=PHASE1 status=BRIEF_INVALID dispatched=false attempt=1
ledger_append "$R_TSV_REF" run=r-r4 phase=PHASE1 status=SECRETS_FOUND dispatched=false attempt=1

OUT_REF="$(bash "$REPORT_SH" --dir "$R_TSV_REF" --format tsv)"
PH_REF_ROW="$(printf '%s\n' "$OUT_REF" | grep $'^phase\tPHASE1\t')"
check tsv-phase-ref-row "$PH_REF_ROW" "$(printf 'phase\tPHASE1\t2\t1\t1\t2\t0.50')" "refusals excluded from dispatches and pass rate in TSV"

# 10.8 Filters narrow TSV rows
R_TSV_FILT="$(new_repo tsv-filt)"
mkdir -p "$R_TSV_FILT/.agy"
ledger_append "$R_TSV_FILT" run=run-a phase=ALPHA attempt=1 status=PASSED dispatched=true started=2026-08-25T08:00:00Z
ledger_append "$R_TSV_FILT" run=run-b phase=BETA attempt=1 status=PASSED dispatched=true started=2026-08-25T12:00:00Z

OUT_FILT_PH="$(bash "$REPORT_SH" --dir "$R_TSV_FILT" --format tsv --phase ALPHA)"
if printf '%s\n' "$OUT_FILT_PH" | grep -q $'^phase\tALPHA\t' && ! printf '%s\n' "$OUT_FILT_PH" | grep -q $'^phase\tBETA\t'; then
  ok tsv-filt-phase "--phase narrows TSV phase rows"
else
  bad tsv-filt-phase "--phase filter failed in TSV mode: $OUT_FILT_PH"
fi

OUT_FILT_RN="$(bash "$REPORT_SH" --dir "$R_TSV_FILT" --format tsv --run run-b)"
if printf '%s\n' "$OUT_FILT_RN" | grep -q $'^phase\tBETA\t' && ! printf '%s\n' "$OUT_FILT_RN" | grep -q $'^phase\tALPHA\t'; then
  ok tsv-filt-run "--run narrows TSV phase rows"
else
  bad tsv-filt-run "--run filter failed in TSV mode: $OUT_FILT_RN"
fi

# 10.9 CLI error handling for invalid format
bash "$REPORT_SH" --dir "$R_TSV_FILT" --format xml >/dev/null 2>&1 || RC_BAD_FMT=$?
check tsv-bad-format-rc "${RC_BAD_FMT:-0}" 2 "--format with unknown format exits 2"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

