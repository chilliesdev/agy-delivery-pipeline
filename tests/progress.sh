#!/usr/bin/env bash
# Exercise streaming progress, heartbeat, liveness watchdog, failure log surfacing,
# watch-run command, and table-driven Next: guidance on refusal status lines.
#
#   tests/progress.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PHASE_SH="$ROOT/scripts/phase.sh"
CHECK_BRIEF="$ROOT/scripts/check-brief.sh"
CHECK_SECRETS="$ROOT/scripts/check-secrets.sh"
CAPTURE_DIFF="$ROOT/scripts/capture-diff.sh"
CHECK_REVIEW="$ROOT/scripts/check-review.sh"
CHECK_DIFF_INTEG="$ROOT/scripts/check-diff-integrity.sh"
CHECK_RELEASE="$ROOT/scripts/check-release.sh"
CHECK_RANGE="$ROOT/scripts/check-phase-range.sh"
CHECK_TEST_CMD="$ROOT/scripts/check-test-command.sh"
WATCH_RUN="$ROOT/scripts/watch-run.sh"
RUN_DIR_SH="$ROOT/scripts/run-dir.sh"

[ -f "$PHASE_SH" ] || { echo "progress-test: scripts/phase.sh not found" >&2; exit 2; }
[ -f "$WATCH_RUN" ] || { echo "progress-test: scripts/watch-run.sh not found" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "progress-test: scripts/run-dir.sh not found" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/progress-test.XXXXXX")"
SCRATCH="$(cd "$SCRATCH" && pwd)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

export AGY_FLEET="$SCRATCH/fleet"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-36s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-36s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
count_lines() { local c; c="$(grep -c . "$1" 2>/dev/null || true)"; printf '%s' "${c:-0}"; }

# Create a throwaway repo
new_repo() {
  local name="$1"
  local r="$SCRATCH/repos/$name"
  mkdir -p "$r"
  r="$(cd "$r" && pwd)"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" \
      && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  local run_id
  run_id="$(run_dir_new --dir "$r" --task "progress test $name")"
  [ -n "$run_id" ] || { echo "progress-test: run_dir_new failed for $name" >&2; exit 2; }
  printf '%s' "$r"
}

# Stub agy binary for controlling worker output and execution
STUB_AGY="$SCRATCH/stub_agy"
cat > "$STUB_AGY" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  if [ -n "${STUB_PREFLIGHT_FAIL:-}" ]; then
    exit 4
  fi
  printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
  exit 0
fi

if [ -n "${STUB_SLEEP_SEC:-}" ]; then
  sleep "$STUB_SLEEP_SEC"
fi

if [ -n "${STUB_WRITE_LINES:-}" ]; then
  i=1
  while [ "$i" -le "$STUB_WRITE_LINES" ]; do
    printf 'Worker output log line %d\n' "$i"
    i=$((i + 1))
  done
fi

if [ -n "${STUB_VERDICT_VAL:-}" ]; then
  if [ -f .agy/current ]; then
    CUR_RUN="$(cat .agy/current 2>/dev/null || true)"
    if [ -n "$CUR_RUN" ] && [ -n "${STUB_PHASE:-}" ]; then
      mkdir -p ".agy/runs/$CUR_RUN/phases/$STUB_PHASE"
      printf '%s\n' "$STUB_VERDICT_VAL" > ".agy/runs/$CUR_RUN/phases/$STUB_PHASE/verdict"
    fi
  fi
fi

if [ -n "${STUB_OUTPUT_VAL:-}" ]; then
  printf '%s\n' "$STUB_OUTPUT_VAL"
elif [ -z "${STUB_WRITE_LINES:-}" ]; then
  printf '{"response":"%s","status":"SUCCESS","num_turns":1,"usage":{"total_tokens":10}}\n' "${STUB_VERDICT_VAL:-STATUS: DONE | File: CHANGES.md}"
fi

exit "${STUB_EXIT_CODE:-0}"
STUB_EOF
chmod +x "$STUB_AGY"

# Valid sample brief for phase.sh
make_valid_brief() {
  local repo="$1"
  local phase="$2"
  local run_id="$3"
  local bfile="$repo/brief_$phase.md"
  cat > "$bfile" <<EOF
# Phase: $phase
Goal: progress test.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Output Contract:
Write your one-line verdict to .agy/runs/$run_id/phases/$phase/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF
  printf '%s' "$bfile"
}

# =============================================================================
# 1. Table-driven Next: guidance across refusal statuses
# =============================================================================

# Case 1a: RETRY_CAP_REACHED
R_RC="$(new_repo retry-cap)"
RUN_ID_RC="$(cat "$R_RC/.agy/current")"
B_RC="$(make_valid_brief "$R_RC" TEST "$RUN_ID_RC")"
OUT_RC="$(AGY_BIN="$STUB_AGY" "$PHASE_SH" --phase TEST --brief "$B_RC" --dir "$R_RC" --retry-cap 0 --no-preflight 2>/dev/null)" || true
case "$OUT_RC" in
  *"STATUS: RETRY_CAP_REACHED"*"| Next: "*) ok next-retry-cap "RETRY_CAP_REACHED carries Next: field" ;;
  *) bad next-retry-cap "missing Next: in RETRY_CAP_REACHED: $OUT_RC" ;;
esac

# Case 1b: NO_STATUS_REPORTED
R_NS="$(new_repo no-status)"
RUN_ID_NS="$(cat "$R_NS/.agy/current")"
B_NS="$(make_valid_brief "$R_NS" TEST "$RUN_ID_NS")"
OUT_NS="$(AGY_BIN="$STUB_AGY" STUB_OUTPUT_VAL="raw output with no verdict marker" "$PHASE_SH" --phase TEST --brief "$B_NS" --dir "$R_NS" --no-preflight 2>/dev/null)" || true
case "$OUT_NS" in
  *"STATUS: NO_STATUS_REPORTED"*"| Next: "*) ok next-no-status "NO_STATUS_REPORTED carries Next: field" ;;
  *) bad next-no-status "missing Next: in NO_STATUS_REPORTED: $OUT_NS" ;;
esac

# Case 1c: VERIFY_FAILED
R_VF="$(new_repo verify-failed)"
RUN_ID_VF="$(cat "$R_VF/.agy/current")"
B_VF="$(make_valid_brief "$R_VF" TEST "$RUN_ID_VF")"
OUT_VF="$(AGY_BIN="$STUB_AGY" STUB_PHASE=TEST STUB_VERDICT_VAL="STATUS: PASSED | File: CHANGES.md" "$PHASE_SH" --phase TEST --brief "$B_VF" --dir "$R_VF" --verify "exit 1" --no-preflight 2>/dev/null)" || true
case "$OUT_VF" in
  *"STATUS: VERIFY_FAILED"*"| Next: "*) ok next-verify-failed "VERIFY_FAILED carries Next: field" ;;
  *) bad next-verify-failed "missing Next: in VERIFY_FAILED: $OUT_VF" ;;
esac

# Case 1d: WORKER_FAILED
R_WF="$(new_repo worker-failed)"
RUN_ID_WF="$(cat "$R_WF/.agy/current")"
B_WF="$(make_valid_brief "$R_WF" TEST "$RUN_ID_WF")"
OUT_WF="$(AGY_BIN="$STUB_AGY" STUB_EXIT_CODE=1 "$PHASE_SH" --phase TEST --brief "$B_WF" --dir "$R_WF" --no-preflight 2>/dev/null)" || true
case "$OUT_WF" in
  *"STATUS: WORKER_FAILED"*"| Next: "*) ok next-worker-failed "WORKER_FAILED carries Next: field" ;;
  *) bad next-worker-failed "missing Next: in WORKER_FAILED: $OUT_WF" ;;
esac

# Case 1e: PREFLIGHT_FAILED
R_PF="$(new_repo preflight-failed)"
RUN_ID_PF="$(cat "$R_PF/.agy/current")"
B_PF="$(make_valid_brief "$R_PF" TEST "$RUN_ID_PF")"
OUT_PF="$(AGY_BIN="$STUB_AGY" STUB_PREFLIGHT_FAIL=1 "$PHASE_SH" --phase TEST --brief "$B_PF" --dir "$R_PF" 2>/dev/null)" || true
case "$OUT_PF" in
  *"STATUS: PREFLIGHT_FAILED"*"| Next: "*) ok next-preflight-failed "PREFLIGHT_FAILED carries Next: field" ;;
  *) bad next-preflight-failed "missing Next: in PREFLIGHT_FAILED: $OUT_PF" ;;
esac

# Case 1f: BUDGET_EXCEEDED
R_BE="$(new_repo budget-exceeded)"
RUN_ID_BE="$(cat "$R_BE/.agy/current")"
B_BE="$(make_valid_brief "$R_BE" TEST "$RUN_ID_BE")"
OUT_BE="$(AGY_BIN="$STUB_AGY" "$PHASE_SH" --phase TEST --brief "$B_BE" --dir "$R_BE" --budget-tokens 0 --no-preflight 2>/dev/null)" || true
case "$OUT_BE" in
  *"STATUS: BUDGET_EXCEEDED"*"| Next: "*) ok next-budget-exceeded "BUDGET_EXCEEDED carries Next: field" ;;
  *) bad next-budget-exceeded "missing Next: in BUDGET_EXCEEDED: $OUT_BE" ;;
esac

# Case 1g: BRIEF_INVALID
R_BI="$(new_repo brief-invalid)"
B_EMPTY="$R_BI/empty_brief.md"
touch "$B_EMPTY"
OUT_BI="$("$CHECK_BRIEF" --phase TEST --brief "$B_EMPTY" --dir "$R_BI" 2>/dev/null)" || true
case "$OUT_BI" in
  *"STATUS: BRIEF_INVALID"*"| Next: "*) ok next-brief-invalid "BRIEF_INVALID carries Next: field" ;;
  *) bad next-brief-invalid "missing Next: in BRIEF_INVALID: $OUT_BI" ;;
esac

# Case 1h: SECRETS_FOUND
R_SF="$(new_repo secrets-found)"
B_SEC="$R_SF/secret_brief.md"
cat > "$B_SEC" <<'EOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0Y1
-----END RSA PRIVATE KEY-----
EOF
OUT_SF="$("$CHECK_SECRETS" --dir "$R_SF" --brief "$B_SEC" 2>/dev/null)" || true
case "$OUT_SF" in
  *"STATUS: SECRETS_FOUND"*"| Next: "*) ok next-secrets-found "SECRETS_FOUND carries Next: field" ;;
  *) bad next-secrets-found "missing Next: in SECRETS_FOUND: $OUT_SF" ;;
esac

# Case 1i: DIFF_TESTS_WEAKENED
R_DW="$(new_repo diff-weakened)"
mkdir -p "$R_DW/tests"
printf 'test\n' > "$R_DW/tests/app.test.js"
git -C "$R_DW" add tests/app.test.js && git -C "$R_DW" commit -q -m "add test"
# Delete test file
rm -f "$R_DW/tests/app.test.js"
"$CAPTURE_DIFF" --dir "$R_DW" >/dev/null 2>&1 || true
OUT_DW="$("$CHECK_DIFF_INTEG" --dir "$R_DW" 2>/dev/null)" || true
case "$OUT_DW" in
  *"STATUS: DIFF_TESTS_WEAKENED"*"| Next: "*) ok next-diff-weakened "DIFF_TESTS_WEAKENED carries Next: field" ;;
  *) bad next-diff-weakened "missing Next: in DIFF_TESTS_WEAKENED: $OUT_DW" ;;
esac

# Case 1j: DIFF_EMPTY
R_DE="$(new_repo diff-empty)"
OUT_DE="$("$CAPTURE_DIFF" --dir "$R_DE" 2>/dev/null)" || true
case "$OUT_DE" in
  *"STATUS: DIFF_EMPTY"*"| Next: "*) ok next-diff-empty "DIFF_EMPTY carries Next: field" ;;
  *) bad next-diff-empty "missing Next: in DIFF_EMPTY: $OUT_DE" ;;
esac

# Case 1k: REVIEW_THIN
R_RT="$(new_repo review-thin)"
RUN_ID_RT="$(cat "$R_RT/.agy/current")"
FEEDBACK_THIN="$R_RT/.agy/runs/$RUN_ID_RT/REVIEW_FEEDBACK.md"
printf '# Review\nPASSED\nLooks great to me!\n' > "$FEEDBACK_THIN"
OUT_RT="$("$CHECK_REVIEW" --dir "$R_RT" 2>/dev/null)" || true
case "$OUT_RT" in
  *"STATUS: REVIEW_THIN"*"| Next: "*) ok next-review-thin "REVIEW_THIN carries Next: field" ;;
  *) bad next-review-thin "missing Next: in REVIEW_THIN: $OUT_RT" ;;
esac

# Case 1l: REVIEW_ABSENT
R_RA="$(new_repo review-absent)"
OUT_RA="$("$CHECK_REVIEW" --dir "$R_RA" 2>/dev/null)" || true
case "$OUT_RA" in
  *"STATUS: REVIEW_ABSENT"*"| Next: "*) ok next-review-absent "REVIEW_ABSENT carries Next: field" ;;
  *) bad next-review-absent "missing Next: in REVIEW_ABSENT: $OUT_RA" ;;
esac

# Case 1m: RELEASE_BLOCKED
R_RB="$(new_repo release-blocked)"
# Uncommitted tracked change creates dirty state which blocks release
printf 'dirty\n' > "$R_RB/dirty.txt"
git -C "$R_RB" add dirty.txt
OUT_RB="$("$CHECK_RELEASE" --dir "$R_RB" 2>/dev/null)" || true
case "$OUT_RB" in
  *"STATUS: RELEASE_BLOCKED"*"| Next: "*) ok next-release-blocked "RELEASE_BLOCKED carries Next: field" ;;
  *) bad next-release-blocked "missing Next: in RELEASE_BLOCKED: $OUT_RB" ;;
esac

# Case 1n: RANGE_REFUSED
R_RR="$(new_repo range-refused)"
OUT_RR="$("$CHECK_RANGE" --dir "$R_RR" --from 2 2>/dev/null)" || true
case "$OUT_RR" in
  *"STATUS: RANGE_REFUSED"*"| Next: "*) ok next-range-refused "RANGE_REFUSED carries Next: field" ;;
  *) bad next-range-refused "missing Next: in RANGE_REFUSED: $OUT_RR" ;;
esac

# Case 1o: TEST_COMMAND_NOT_RUNNABLE
R_TCNR="$(new_repo test-cmd-not-runnable)"
OUT_TCNR="$("$CHECK_TEST_CMD" --dir "$R_TCNR" --command "nonexistent_command_xyz" 2>/dev/null)" || true
case "$OUT_TCNR" in
  *"STATUS: TEST_COMMAND_NOT_RUNNABLE"*"| Next: "*) ok next-test-cmd-not-run "TEST_COMMAND_NOT_RUNNABLE carries Next: field" ;;
  *) bad next-test-cmd-not-run "missing Next: in TEST_COMMAND_NOT_RUNNABLE: $OUT_TCNR" ;;
esac

# Case 1p: TEST_COMMAND_TIMEOUT
R_TCTO="$(new_repo test-cmd-timeout)"
OUT_TCTO="$("$CHECK_TEST_CMD" --dir "$R_TCTO" --command "sleep 5" --timeout 1 2>/dev/null)" || true
case "$OUT_TCTO" in
  *"STATUS: TEST_COMMAND_TIMEOUT"*"| Next: "*) ok next-test-cmd-timeout "TEST_COMMAND_TIMEOUT carries Next: field" ;;
  *) bad next-test-cmd-timeout "missing Next: in TEST_COMMAND_TIMEOUT: $OUT_TCTO" ;;
esac


# =============================================================================
# 2. Heartbeats appear on stderr and stdout is exactly one line
# =============================================================================

R_HB="$(new_repo heartbeat-test)"
RUN_ID_HB="$(cat "$R_HB/.agy/current")"
B_HB="$(make_valid_brief "$R_HB" IMPLEMENT "$RUN_ID_HB")"

OUT_FILE="$SCRATCH/hb_out.txt"
ERR_FILE="$SCRATCH/hb_err.txt"

AGY_BIN="$STUB_AGY" STUB_PHASE=IMPLEMENT STUB_SLEEP_SEC=2 AGY_HEARTBEAT_INTERVAL=1 \
  "$PHASE_SH" --phase IMPLEMENT --brief "$B_HB" --dir "$R_HB" --no-preflight >"$OUT_FILE" 2>"$ERR_FILE"
RC_HB=$?

check hb-rc "$RC_HB" 0 "phase.sh exits 0 with heartbeat enabled"
check hb-stdout-lines "$(count_lines "$OUT_FILE")" "1" "stdout is exactly one line"

case "$(cat "$OUT_FILE")" in
  "STATUS: DONE"*) ok hb-stdout-status "stdout contains single STATUS line" ;;
  *) bad hb-stdout-status "unexpected stdout: $(cat "$OUT_FILE")" ;;
esac

if grep -qF -- "Phase: IMPLEMENT" "$ERR_FILE" && grep -qF -- "phase.sh:" "$ERR_FILE"; then
  ok hb-stderr-received "heartbeat lines appeared on stderr"
else
  bad hb-stderr-received "missing heartbeat on stderr: $(cat "$ERR_FILE")"
fi

if grep -qF -- "phase.sh:" "$OUT_FILE"; then
  bad hb-no-leak-stdout "heartbeat leaked into stdout"
else
  ok hb-no-leak-stdout "heartbeat stayed off stdout"
fi


# =============================================================================
# 3. AGY_NO_PROGRESS=1 silences heartbeats
# =============================================================================

OUT_NOPROG="$SCRATCH/noprog_out.txt"
ERR_NOPROG="$SCRATCH/noprog_err.txt"

AGY_BIN="$STUB_AGY" STUB_PHASE=IMPLEMENT STUB_SLEEP_SEC=2 AGY_HEARTBEAT_INTERVAL=1 AGY_NO_PROGRESS=1 \
  "$PHASE_SH" --phase IMPLEMENT --brief "$B_HB" --dir "$R_HB" --no-preflight >"$OUT_NOPROG" 2>"$ERR_NOPROG"

check noprog-stdout-lines "$(count_lines "$OUT_NOPROG")" "1" "stdout is still exactly one line with AGY_NO_PROGRESS=1"
if grep -qF -- "Phase: IMPLEMENT" "$ERR_NOPROG"; then
  bad noprog-stderr-empty "heartbeat appeared on stderr despite AGY_NO_PROGRESS=1: $(cat "$ERR_NOPROG")"
else
  ok noprog-stderr-empty "AGY_NO_PROGRESS=1 silenced heartbeats"
fi


# =============================================================================
# 4. --quiet flag silences heartbeats
# =============================================================================

OUT_QUIET="$SCRATCH/quiet_out.txt"
ERR_QUIET="$SCRATCH/quiet_err.txt"

AGY_BIN="$STUB_AGY" STUB_PHASE=IMPLEMENT STUB_SLEEP_SEC=2 AGY_HEARTBEAT_INTERVAL=1 \
  "$PHASE_SH" --phase IMPLEMENT --brief "$B_HB" --dir "$R_HB" --quiet --no-preflight >"$OUT_QUIET" 2>"$ERR_QUIET"

check quiet-stdout-lines "$(count_lines "$OUT_QUIET")" "1" "stdout is still exactly one line with --quiet"
if grep -qF -- "Phase: IMPLEMENT" "$ERR_QUIET"; then
  bad quiet-stderr-empty "heartbeat appeared on stderr despite --quiet: $(cat "$ERR_QUIET")"
else
  ok quiet-stderr-empty "--quiet silenced heartbeats"
fi


# =============================================================================
# 5. Liveness watchdog fires when idle and does NOT abort the run
# =============================================================================

R_WD="$(new_repo watchdog-test)"
RUN_ID_WD="$(cat "$R_WD/.agy/current")"
B_WD="$(make_valid_brief "$R_WD" IMPLEMENT "$RUN_ID_WD")"

OUT_WD="$SCRATCH/wd_out.txt"
ERR_WD="$SCRATCH/wd_err.txt"

AGY_BIN="$STUB_AGY" STUB_PHASE=IMPLEMENT STUB_SLEEP_SEC=2 AGY_LIVENESS_INTERVAL=1 AGY_HEARTBEAT_INTERVAL=60 \
  "$PHASE_SH" --phase IMPLEMENT --brief "$B_WD" --dir "$R_WD" --no-preflight >"$OUT_WD" 2>"$ERR_WD"
RC_WD=$?

check wd-rc "$RC_WD" 0 "watchdog warning did NOT abort dispatch (exits 0)"
check wd-stdout-lines "$(count_lines "$OUT_WD")" "1" "stdout is exactly one line"

if grep -qF -- "no output for" "$ERR_WD" && grep -qF -- "the worker may be hung" "$ERR_WD"; then
  ok wd-warning-fired "liveness watchdog warning fired on stderr"
else
  bad wd-warning-fired "watchdog warning missing from stderr: $(cat "$ERR_WD")"
fi


# =============================================================================
# 6. Failing dispatch surfaces log tail on stderr and stdout is one line
# =============================================================================

R_FAIL="$(new_repo fail-log-test)"
RUN_ID_FAIL="$(cat "$R_FAIL/.agy/current")"
B_FAIL="$(make_valid_brief "$R_FAIL" IMPLEMENT "$RUN_ID_FAIL")"

OUT_FAIL="$SCRATCH/fail_out.txt"
ERR_FAIL="$SCRATCH/fail_err.txt"

FAIL_WRITE_LINES=50
AGY_BIN="$STUB_AGY" STUB_EXIT_CODE=1 STUB_WRITE_LINES="$FAIL_WRITE_LINES" \
  "$PHASE_SH" --phase IMPLEMENT --brief "$B_FAIL" --dir "$R_FAIL" --no-preflight >"$OUT_FAIL" 2>"$ERR_FAIL"
RC_FAIL=$?

check fail-rc "$RC_FAIL" 1 "failing worker exits with worker code 1"
check fail-stdout-lines "$(count_lines "$OUT_FAIL")" "1" "stdout is still exactly one line on failure"

case "$(cat "$OUT_FAIL")" in
  *"STATUS: WORKER_FAILED(rc=1)"*) ok fail-stdout-status "stdout reports WORKER_FAILED" ;;
  *) bad fail-stdout-status "unexpected stdout: $(cat "$OUT_FAIL")" ;;
esac

LAST_WORKER_LINE="Worker output log line $FAIL_WRITE_LINES"
if grep -qF -- "--- phase.sh: log tail" "$ERR_FAIL" && grep -qF -- "$LAST_WORKER_LINE" "$ERR_FAIL"; then
  ok fail-stderr-log-tail "stderr surfaced log tail on failure"
else
  bad fail-stderr-log-tail "missing log tail on stderr: $(cat "$ERR_FAIL")"
fi

if grep -qF -- "Worker output log line 1" "$ERR_FAIL"; then
  bad fail-stderr-tail-bounded "tail leaked entire log to stderr"
else
  ok fail-stderr-tail-bounded "tail is bounded (early log lines omitted)"
fi


# =============================================================================
# 7. watch-run.sh command inspection
# =============================================================================

R_WATCH="$(new_repo watch-cmd-test)"
RUN_ID_WATCH="$(cat "$R_WATCH/.agy/current")"
mkdir -p "$R_WATCH/.agy/runs/$RUN_ID_WATCH/phases/IMPLEMENT"
printf 'Log line 1 for watcher\nLog line 2 for watcher\n' > "$R_WATCH/.agy/runs/$RUN_ID_WATCH/phases/IMPLEMENT/log"
printf 'STATUS: DONE | File: CHANGES.md\n' > "$R_WATCH/.agy/runs/$RUN_ID_WATCH/phases/IMPLEMENT/status"
run_dir_record_phase "$R_WATCH/.agy/runs/$RUN_ID_WATCH" IMPLEMENT status=DONE verdict=DONE attempts=1

OUT_WATCH="$("$WATCH_RUN" --dir "$R_WATCH" --once 2>&1)"
RC_WATCH=$?

check watch-rc "$RC_WATCH" 0 "watch-run.sh --once exits 0"

if printf '%s\n' "$OUT_WATCH" | grep -q "Run:[[:space:]]*$RUN_ID_WATCH"; then
  ok watch-reports-run "watch-run.sh reports Run ID"
else
  bad watch-reports-run "watch-run.sh missing Run ID: $OUT_WATCH"
fi

if printf '%s\n' "$OUT_WATCH" | grep -qF -- "IMPLEMENT:" && printf '%s\n' "$OUT_WATCH" | grep -qF -- "Log line 2 for watcher"; then
  ok watch-reports-log "watch-run.sh reports phase status and active log tail"
else
  bad watch-reports-log "watch-run.sh missing phase or log content: $OUT_WATCH"
fi

# watch-run.sh usage error on missing directory
"$WATCH_RUN" --dir "$SCRATCH/nonexistent_dir" >/dev/null 2>&1 || RC_WATCH_BAD=$?
check watch-bad-dir "${RC_WATCH_BAD:-0}" 2 "watch-run.sh exits 2 on invalid dir"


# =============================================================================
# The heartbeat file: liveness that outlives the dispatch
#
# The watchdog warned on stderr and forgot. An unattended run — the mode this
# pipeline is built for — is exactly the one nobody is watching, so the idle
# counter has to reach disk or it may as well not exist.
# =============================================================================

R_HBF="$(new_repo heartbeat-file)"
RUN_HBF="$(cat "$R_HBF/.agy/current")"
B_HBF="$(make_valid_brief "$R_HBF" IMPLEMENT "$RUN_HBF")"
HB_PATH="$R_HBF/.agy/runs/$RUN_HBF/phases/IMPLEMENT/heartbeat"

AGY_BIN="$STUB_AGY" STUB_PHASE=IMPLEMENT STUB_VERDICT_VAL="STATUS: DONE | File: CHANGES.md" \
  STUB_SLEEP_SEC=2 AGY_HEARTBEAT_INTERVAL=1 \
  "$PHASE_SH" --phase IMPLEMENT --brief "$B_HBF" --dir "$R_HBF" --no-preflight >/dev/null 2>&1

if [ -f "$HB_PATH" ]; then
  ok heartbeat-file-written "a dispatch leaves a heartbeat file behind"
else
  bad heartbeat-file-written "no heartbeat at $HB_PATH"
fi

HB_STATE="$(sed -n 's/^state=//p' "$HB_PATH" 2>/dev/null | tail -1)"
check heartbeat-final-state "$HB_STATE" "finished" "the heartbeat is frozen at finished, not deleted"

for K in run phase started last_write max_idle_s elapsed_s log_bytes worker_rc; do
  if grep -q "^$K=" "$HB_PATH" 2>/dev/null; then
    ok "heartbeat-key-$K" "the finished heartbeat carries $K"
  else
    bad "heartbeat-key-$K" "$K missing from $HB_PATH"
  fi
done

# --quiet and AGY_NO_PROGRESS ask for a silent terminal. They were never asking
# for a run that cannot be observed at all, which is what gating the file on them
# would mean.
R_HBQ="$(new_repo heartbeat-quiet)"
RUN_HBQ="$(cat "$R_HBQ/.agy/current")"
B_HBQ="$(make_valid_brief "$R_HBQ" IMPLEMENT "$RUN_HBQ")"
HBQ_PATH="$R_HBQ/.agy/runs/$RUN_HBQ/phases/IMPLEMENT/heartbeat"
ERR_HBQ="$SCRATCH/hbq_err.txt"

AGY_BIN="$STUB_AGY" STUB_PHASE=IMPLEMENT STUB_VERDICT_VAL="STATUS: DONE | File: CHANGES.md" \
  STUB_SLEEP_SEC=2 AGY_HEARTBEAT_INTERVAL=1 AGY_NO_PROGRESS=1 \
  "$PHASE_SH" --phase IMPLEMENT --brief "$B_HBQ" --dir "$R_HBQ" --no-preflight \
  >/dev/null 2>"$ERR_HBQ"

if [ -f "$HBQ_PATH" ]; then
  ok heartbeat-survives-quiet "AGY_NO_PROGRESS silences stderr without silencing the file"
else
  bad heartbeat-survives-quiet "no heartbeat written under AGY_NO_PROGRESS"
fi
if grep -qF -- "Phase: IMPLEMENT" "$ERR_HBQ" 2>/dev/null; then
  bad heartbeat-quiet-still-silent "heartbeat printing leaked to stderr under AGY_NO_PROGRESS"
else
  ok heartbeat-quiet-still-silent "stderr is still silent — only the printing was ever gated"
fi

# No half-written record is ever visible: the file is moved into place.
if [ -f "$HB_PATH.tmp" ] || [ -f "$HBQ_PATH.tmp" ]; then
  bad heartbeat-no-temp-left "a heartbeat temporary file was left behind"
else
  ok heartbeat-no-temp-left "the heartbeat temporary is cleaned up"
fi

# The quiet stretch reaches the ledger, so a stall is answerable after the fact.
L_HBF="$(tail -1 "$R_HBF/.agy/ledger.jsonl" 2>/dev/null)"
if printf '%s\n' "$L_HBF" | grep -q '"max_idle_s":[0-9]'; then
  ok heartbeat-ledger-max-idle "the longest quiet stretch is recorded in the ledger"
else
  bad heartbeat-ledger-max-idle "max_idle_s missing from the record: $L_HBF"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
