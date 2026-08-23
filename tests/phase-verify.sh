#!/usr/bin/env bash
# Exercise the two gates phase.sh makes mechanical: --verify, which overrides a
# worker's claim, and the retry counter that caps the review loop — including
# which rounds that counter charges for and which it hands back.
#
#   tests/phase-verify.sh
#
# Builds a fake `agy` that answers preflight's `models` call and then plays the
# worker, points agy-run.sh at it with AGY_BIN, and runs phase.sh against
# throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside this repo.
# Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_SH="$HERE/../scripts/phase.sh"
[ -f "$PHASE_SH" ] || { echo "phase-verify: phase.sh not found next door" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase-verify.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

# The stub agy: answers `models` for preflight, otherwise writes the verdict
# named by STUB_VERDICT, touches $STUB_RAN so a refused dispatch is provable,
# and exits STUB_RC. The `models` answer has its own knobs — STUB_MODELS_RC to
# fail the fetch and STUB_MODELS_SLEEP to hang it — because a preflight that
# refuses is one of the rounds the retry counter must not charge for.
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  [ -n "${STUB_MODELS_SLEEP:-}" ] && sleep "$STUB_MODELS_SLEEP"
  [ "${STUB_MODELS_RC:-0}" = "0" ] && printf 'gemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\n'
  exit "${STUB_MODELS_RC:-0}"
fi
[ -n "${STUB_RAN:-}" ] && printf 'ran\n' >> "$STUB_RAN"
mkdir -p .tmp
printf '%s\n' "${STUB_VERDICT:-STATUS: PASSED | File: .tmp/CHANGES.md}" > ".tmp/$STUB_PHASE.verdict"
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-30s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-30s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# new_repo <name> — a throwaway git repo with a brief in it; echoes its path.
new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q . )
  printf 'do the thing\n' > "$R/brief.md"
  printf '%s' "$R"
}

# run <repo> [args...] — one phase.sh dispatch; STATUS line into $OUT, code into
# $CODE. STUB_* come from the caller's environment.
run() {
  R="$1"; shift
  OUT="$(STUB_PHASE=TEST AGY_BIN="$STUB" \
         /bin/bash "$PHASE_SH" --phase TEST --brief "$R/brief.md" --dir "$R" "$@" 2>/dev/null)"
  CODE=$?
}

head_of() { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }

# --- --verify -------------------------------------------------------------

# 1. no --verify: unchanged from before this flag existed.
R="$(new_repo no-verify)"
run "$R"
check no-verify-rc "$CODE" 0 "exit 0 without --verify"
check no-verify-status "$(head_of "$OUT")" "PASSED" "worker's verdict passes through"
case "$OUT" in *Verify:*) bad no-verify-quiet "mentioned Verify without --verify" ;;
  *) ok no-verify-quiet "no Verify field when the flag is absent" ;; esac

# 2. worker passed and the check holds.
R="$(new_repo verify-ok)"
run "$R" --verify 'true'
check verify-ok-rc "$CODE" 0 "exit 0 when the check passes"
check verify-ok-status "$(head_of "$OUT")" "PASSED" "still PASSED"
case "$OUT" in *"Verify: ok"*) ok verify-ok-field "the passing check is recorded" ;;
  *) bad verify-ok-field "no Verify field: $OUT" ;; esac

# 3. the case the issue is about: worker claims PASSED, the check disagrees.
R="$(new_repo verify-override)"
run "$R" --verify 'exit 3'
check verify-fail-rc "$CODE" 5 "exit 5 when the check fails"
case "$(head_of "$OUT")" in PASSED)
    bad verify-override "a PASSED claim survived a failing check" ;;
  VERIFY_FAILED*) ok verify-override "PASSED claim overridden by the check" ;;
  *) bad verify-override "unexpected verdict: $OUT" ;; esac
case "$OUT" in *"Claimed: STATUS: PASSED"*)
    ok verify-override-claim "the overridden claim is still reported" ;;
  *) bad verify-override-claim "claim not carried through: $OUT" ;; esac

# 4. nothing to check when the worker itself died.
R="$(new_repo verify-skipped)"
STUB_RC=4 run "$R" --verify 'exit 9'
case "$(head_of "$OUT")" in WORKER_FAILED*)
    ok verify-skipped "worker failure wins over the check" ;;
  *) bad verify-skipped "unexpected verdict: $OUT" ;; esac
[ -f "$R/.tmp/logs/TEST.verify.log" ] \
  && bad verify-skipped-log "the check ran anyway" \
  || ok verify-skipped-log "the check did not run"

# 5. stdout stays exactly one line, however loud the check is.
R="$(new_repo verify-quiet)"
run "$R" --verify 'echo noise; echo more noise >&2; true'
check verify-stdout-lines "$(printf '%s\n' "$OUT" | grep -c .)" 1 "stdout is one line"
case "$OUT" in *noise*) bad verify-stdout-clean "check output leaked to stdout" ;;
  *) ok verify-stdout-clean "check output stayed out of stdout" ;; esac
case "$(cat "$R/.tmp/logs/TEST.verify.log" 2>/dev/null)" in *noise*more\ noise*)
    ok verify-log "both streams landed in the verify log" ;;
  *) bad verify-log "verify log missing output" ;; esac

# 6. the check runs in the repo, and a shell runs it, so && and pipes work.
R="$(new_repo verify-shell)"
printf 'marker\n' > "$R/here.txt"
run "$R" --verify 'test -f here.txt && grep -q marker here.txt'
check verify-shell "$CODE" 0 "runs in \$DIR through a shell"

# --- retry counter --------------------------------------------------------

# 7. a failing round accumulates, and the third dispatch is refused.
R="$(new_repo retry-cap)"; RAN="$R/ran.txt"
export STUB_VERDICT='STATUS: FAILED | File: .tmp/REVIEW_FEEDBACK.md'
STUB_RAN="$RAN" run "$R"
check retry-1 "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "0" "first dispatch spends no retry"
STUB_RAN="$RAN" run "$R"
check retry-2 "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "1" "second dispatch is retry 1"
STUB_RAN="$RAN" run "$R"
check retry-3 "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "2" "third dispatch is retry 2"
BEFORE="$(grep -c . "$RAN" 2>/dev/null)"
STUB_RAN="$RAN" run "$R"
check retry-cap-rc "$CODE" 6 "exit 6 at the cap"
case "$(head_of "$OUT")" in RETRY_CAP_REACHED*)
    ok retry-cap-status "the cap is reported as its own verdict" ;;
  *) bad retry-cap-status "unexpected verdict: $OUT" ;; esac
check retry-cap-nodispatch "$(grep -c . "$RAN" 2>/dev/null)" "$BEFORE" "no worker ran at the cap"
[ -f "$R/.tmp/TEST.verdict" ] \
  && ok retry-cap-keeps "the last verdict survives the refusal" \
  || bad retry-cap-keeps "the refusal cleared the previous verdict"

# 8. --reset-retries starts a fresh cycle.
STUB_RAN="$RAN" run "$R" --reset-retries
check reset-rc "$CODE" 0 "exit 0 after a reset"
check reset-count "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "0" "the counter starts over"

# 9. the cap is configurable. It counts retries, not dispatches, so --retry-cap 1
# allows the opening round and one retry, then refuses.
R="$(new_repo retry-cap-1)"
run "$R" --retry-cap 1
check retry-cap-1-open "$CODE" 0 "--retry-cap 1 allows the opening round"
run "$R" --retry-cap 1
check retry-cap-1-retry "$CODE" 0 "--retry-cap 1 allows one retry"
run "$R" --retry-cap 1
check retry-cap-1-stop "$CODE" 6 "--retry-cap 1 refuses the second retry"
unset STUB_VERDICT

# 10. a clean round ends the cycle by itself.
R="$(new_repo retry-clean)"
STUB_VERDICT='STATUS: FAILED | File: x' run "$R"
check clean-before "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "0" "the failing round counted"
run "$R"
[ -f "$R/.tmp/TEST.retries" ] \
  && bad clean-after "a PASSED round left the counter behind" \
  || ok clean-after "a PASSED round cleared the counter"

# 11. a failing check keeps the cycle open even when the worker claimed PASSED.
R="$(new_repo retry-verify)"
run "$R" --verify 'false'
[ -f "$R/.tmp/TEST.retries" ] \
  && ok verify-keeps-count "a failed check is not a clean round" \
  || bad verify-keeps-count "the counter was cleared despite a failing check"

# 12. a junk counter degrades to zero rather than aborting the dispatch.
R="$(new_repo retry-junk)"
mkdir -p "$R/.tmp"; printf 'not a number\n' > "$R/.tmp/TEST.retries"
run "$R"
check retry-junk "$CODE" 0 "a corrupt counter reads as zero"

# --- the refund -----------------------------------------------------------

# 13. a round the worker died in is refunded whole. It spent the counter at
# dispatch, as every round does, and gets it back because a worker that fell
# over on its own configuration never tried to converge on anything.
R="$(new_repo retry-worker-failed)"; RAN="$R/ran.txt"
STUB_RC=7 STUB_RAN="$RAN" run "$R"
case "$(head_of "$OUT")" in WORKER_FAILED*) ok refund-verdict "the round is WORKER_FAILED" ;;
  *) bad refund-verdict "unexpected verdict: $OUT" ;; esac
check refund-dispatched "$(grep -c . "$RAN" 2>/dev/null)" "1" \
  "the worker really was dispatched, so the counter really was spent"
[ -f "$R/.tmp/TEST.retries" ] \
  && bad refund-opening "a dead worker left the opening round on the counter" \
  || ok refund-opening "an opening round the worker died in leaves no counter"

# 13b. refunded, not cleared: what earlier rounds spent stays spent.
R="$(new_repo retry-refund-restores)"
STUB_VERDICT='STATUS: FAILED | File: x' run "$R"
STUB_VERDICT='STATUS: FAILED | File: x' run "$R"
check refund-before "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "1" "two failing rounds, one retry spent"
STUB_RC=4 run "$R"
check refund-restores "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "1" \
  "the dead round is given back, the earlier retry is not"
STUB_VERDICT='STATUS: FAILED | File: x' run "$R"
check refund-resumes "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "2" \
  "the next real round picks the count up where it was"

# 14. a round preflight refuses spends nothing — it never dispatched at all.
R="$(new_repo retry-preflight-first)"
STUB_MODELS_RC=1 run "$R"
check preflight-rc "$CODE" 3 "phase.sh exits with preflight's own code"
case "$(head_of "$OUT")" in PREFLIGHT_FAILED*) ok preflight-verdict "reported as PREFLIGHT_FAILED" ;;
  *) bad preflight-verdict "unexpected verdict: $OUT" ;; esac
[ -f "$R/.tmp/TEST.retries" ] \
  && bad preflight-no-spend "a refused preflight wrote the counter" \
  || ok preflight-no-spend "a refused preflight spends no retry"

# 14b. and does not disturb what a real round spent before it.
R="$(new_repo retry-preflight-after)"
STUB_VERDICT='STATUS: FAILED | File: x' run "$R"
STUB_MODELS_RC=1 run "$R"
check preflight-keeps "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "0" \
  "the earlier round's count is left exactly as it was"

# 14c. a preflight that hangs is the same class, under its own reason — the
# STATUS line is where the orchestrator learns which one it hit.
R="$(new_repo retry-preflight-timeout)"
STUB_MODELS_SLEEP=45 AGY_PREFLIGHT_TIMEOUT=1 run "$R"
check preflight-timeout-rc "$CODE" 7 "exit 7 when preflight times out"
case "$OUT" in *"PREFLIGHT_FAILED(timeout)"*)
    ok preflight-timeout-reason "the hang is named as its own reason" ;;
  *) bad preflight-timeout-reason "unexpected line: $OUT" ;; esac
[ -f "$R/.tmp/TEST.retries" ] \
  && bad preflight-timeout-spend "a timed-out preflight spent a retry" \
  || ok preflight-timeout-spend "a timed-out preflight spends no retry"

# 15. the verdicts that keep spending. A failing check is a worker that ran and
# whose work did not hold up; an empty verdict is a round left unresolved.
R="$(new_repo retry-verify-spends)"
run "$R" --verify 'false'
check verify-spends "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "0" "a VERIFY_FAILED round is recorded"
run "$R" --verify 'false'
check verify-spends-2 "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "1" "and the next one spends a retry"

R="$(new_repo retry-no-status)"
STUB_VERDICT=' ' run "$R"
case "$(head_of "$OUT")" in NO_STATUS_REPORTED*) ok no-status-verdict "the round is NO_STATUS_REPORTED" ;;
  *) bad no-status-verdict "unexpected verdict: $OUT" ;; esac
check no-status-spends "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "0" "an unresolved round is recorded"
STUB_VERDICT=' ' run "$R"
check no-status-spends-2 "$(cat "$R/.tmp/TEST.retries" 2>/dev/null)" "1" "and the next one spends a retry"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
