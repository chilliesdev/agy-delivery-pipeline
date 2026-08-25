#!/usr/bin/env bash
# Exercise report.sh: totalling token spend across multiple runs,
# and reporting absence rather than zero when no usage is recorded.
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

# --- 1. report totals token spend across multiple runs ----------------------

R1="$(new_repo multi-run-spend)"
mkdir -p "$R1/.agy"

# Run 1: IMPLEMENT phase, 10,000 tokens
ledger_append "$R1" run=run-1 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":8000,"output_tokens":2000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":10000}'

# Run 2: IMPLEMENT phase, 15,000 tokens
ledger_append "$R1" run=run-2 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy \
  started=2026-08-25T10:05:00Z elapsed_s=15 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":12000,"output_tokens":3000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":15000}'

# Run 3: REVIEW phase, 5,000 tokens
ledger_append "$R1" run=run-3 phase=REVIEW attempt=1 tier=high model=m backend=agy \
  started=2026-08-25T10:10:00Z elapsed_s=8 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0 \
  usage='{"input_tokens":4000,"output_tokens":1000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":5000}'

REPORT1="$(/bin/bash "$REPORT_SH" --dir "$R1")"; RC1=$?
check report-multi-run-rc "$RC1" 0 "report.sh exits 0 on multi-run ledger"

# Total live tokens across all runs: 10000 + 15000 + 5000 = 30000
if printf '%s\n' "$REPORT1" | grep -q "Live Total:[[:space:]]*30000 tokens"; then
  ok report-multi-run-total "report correctly totals live spend across runs (30000 tokens)"
else
  bad report-multi-run-total "report total across runs unexpected: $REPORT1"
fi

# IMPLEMENT phase tokens summed across run-1 and run-2: 10000 + 15000 = 25000
if printf '%s\n' "$REPORT1" | grep -q "IMPLEMENT:[[:space:]]*25000 tokens"; then
  ok report-multi-run-phase-total "report correctly totals phase spend across runs (25000 tokens)"
else
  bad report-multi-run-phase-total "phase total across runs unexpected: $REPORT1"
fi

# --- 2. repository with no recorded usage reports absence rather than zero --

R2="$(new_repo no-usage-records)"
mkdir -p "$R2/.agy"

# Dispatches without usage objects
ledger_append "$R2" run=run-1 phase=IMPLEMENT attempt=1 tier=medium model=m backend=agy \
  started=2026-08-25T10:00:00Z elapsed_s=10 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0

ledger_append "$R2" run=run-2 phase=REVIEW attempt=1 tier=high model=m backend=agy \
  started=2026-08-25T10:05:00Z elapsed_s=8 worker_rc=0 verdict=PASSED verify_ran=false status=PASSED \
  retries_spent=0 retries_refunded=0

REPORT2="$(/bin/bash "$REPORT_SH" --dir "$R2")"; RC2=$?
check report-no-usage-rc "$RC2" 0 "report.sh exits 0 when no usage recorded"

if printf '%s\n' "$REPORT2" | grep -q "No token usage recorded in matching dispatches."; then
  ok report-no-usage-absence "report notes token usage was not recorded"
else
  bad report-no-usage-absence "report missing absence message: $REPORT2"
fi

# Ensure it does not report a confident "0 tokens" for live total
if printf '%s\n' "$REPORT2" | grep -q "Live Total:[[:space:]]*0 tokens"; then
  bad report-no-usage-not-zero "report should not print '0 tokens' when usage was never measured"
else
  ok report-no-usage-not-zero "report omits 'Live Total: 0 tokens' when usage is unmeasured"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
