#!/usr/bin/env bash
# Exercise preflight.sh's failure classes, each of which the orchestrator maps
# to its own STATUS: PREFLIGHT_FAILED reason.
#
#   tests/preflight.sh
#
# Builds a fake `agy` whose `models` output, exit code and stalling come from
# the environment, points preflight.sh at it with AGY_BIN, and asserts the exit
# code and the message. The stalling cases cover the watchdog: a fetch that
# outlives its bound must be killed outright, process group and all, rather than
# hanging every dispatch behind it. Nothing is written inside this repo. Prints
# one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$HERE/../scripts/preflight.sh"
[ -f "$PREFLIGHT" ] || { echo "preflight-test: preflight.sh not found next door" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

# The stub agy: answers `models` from $STUB_MODELS with exit code $STUB_RC, and
# stalls first for $STUB_SLEEP seconds when asked to — a hung fetch is the thing
# the watchdog exists for. The stall is a pipeline on purpose: killing the stub
# alone would leave the sleep running, so only a process-group kill clears it.
# Anything else is not preflight's business and exits 0.
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'Fetching available models...\n' >&2
  [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP" | cat
  [ -n "${STUB_MODELS:-}" ] && printf '%b' "$STUB_MODELS"
  exit "${STUB_RC:-0}"
fi
exit 0
STUB_EOF
chmod +x "$STUB"

LISTING='gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\nclaude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)\n'

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-30s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-30s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# run <models> <rc> <args...> — runs preflight with the stub, capturing both
# streams into $OUT and the exit code into $CODE. $STUB_SLEEP, if the caller set
# it on the way in, reaches the stub with the rest.
run() {
  RM="$1"; RR="$2"; shift 2
  OUT="$(STUB_MODELS="$RM" STUB_RC="$RR" AGY_BIN="$STUB" \
         /bin/bash "$PREFLIGHT" "$@" 2>&1)"
  CODE=$?
}

# 1. agy missing from PATH entirely.
OUT="$(AGY_BIN="$ROOT/definitely-not-here" /bin/bash "$PREFLIGHT" --tier medium 2>&1)"; CODE=$?
check agy-missing "$CODE" 127 "exit 127 when agy is not on PATH"
case "$OUT" in *"not found on PATH"*) ok agy-missing-msg "names the missing binary" ;;
  *) bad agy-missing-msg "message did not mention PATH: $OUT" ;; esac

# 2. `agy models` fails — an expired or absent sign-in.
run "" 1 --tier medium
check not-signed-in "$CODE" 3 "exit 3 when \`agy models\` fails"
case "$OUT" in *"not to be signed in"*) ok not-signed-in-msg "says it is not signed in" ;;
  *) bad not-signed-in-msg "message did not mention sign-in: $OUT" ;; esac

# 3. `agy models` succeeds but lists nothing — same class as a failed fetch.
run "" 0 --tier medium
check empty-listing "$CODE" 3 "exit 3 when the listing is empty"

# 4. the requested model is there.
run "$LISTING" 0 --tier medium
check model-present "$CODE" 0 "exit 0 when the model is available"

# 5. the requested model is absent, and the error lists what is.
run "$LISTING" 0 --model gemini-9.9-flash-ultra
check model-absent "$CODE" 4 "exit 4 when the model is unavailable"
case "$OUT" in *gemini-3.7-flash-medium*claude-opus-4-6-thinking*)
    ok model-absent-lists "the error lists the available ids" ;;
  *) bad model-absent-lists "available ids missing from the error: $OUT" ;; esac
case "$OUT" in *"Fetching available models"*)
    bad model-absent-clean "the raw banner leaked into the error" ;;
  *) ok model-absent-clean "only parsed ids are printed, not raw output" ;; esac

# 6. --tier maps exactly as phase.sh maps it.
run "$LISTING" 0 --tier high
check tier-high "$CODE" 0 "--tier high resolves to gemini-3.7-flash-high"
run 'gemini-3.7-flash-low\tLow\n' 0 --tier high
check tier-high-absent "$CODE" 4 "--tier high fails when only low is listed"
run "$LISTING" 0 --tier claude-opus-4-6-thinking
check tier-raw-id "$CODE" 0 "--tier also accepts a raw model id"

# 7. --quiet says nothing on success, and still speaks up on failure.
run "$LISTING" 0 --tier medium --quiet
check quiet-rc "$CODE" 0 "--quiet still exits 0"
check quiet-silent "$OUT" "" "--quiet prints nothing on success"
run "$LISTING" 0 --model nope --quiet
check quiet-fail-rc "$CODE" 4 "--quiet still fails on a bad model"
case "$OUT" in "") bad quiet-fail-msg "--quiet swallowed the failure message" ;;
  *) ok quiet-fail-msg "--quiet still reports the failure" ;; esac

# 8. a bad argument is a usage error, not a preflight verdict.
run "$LISTING" 0 --bogus
check bad-arg "$CODE" 2 "exit 2 on an unknown argument"

# 9. the hang this script's watchdog exists for: a fetch that never comes back
# is killed and reported as its own class, instead of stalling every dispatch.
START=$(date +%s)
STUB_SLEEP=4791 run "$LISTING" 0 --timeout 1
ELAPSED=$(( $(date +%s) - START ))
check hang-rc "$CODE" 7 "exit 7 when the listing never arrives"
case "$OUT" in *"did not return within 1s"*) ok hang-msg "the message names the bound" ;;
  *) bad hang-msg "no timeout message: $OUT" ;; esac
if [ "$ELAPSED" -le 10 ]; then ok hang-prompt "gave up after ${ELAPSED}s, not on agy's schedule"
  else bad hang-prompt "waited ${ELAPSED}s for a 1s bound"; fi

# 9b. and nothing survives it. The stub stalls inside a pipeline, so a kill
# aimed at the stub alone would leave `sleep 4791` orphaned and running.
sleep 1
LEFT="$(pgrep -f 'sleep 4791' 2>/dev/null | grep -c .)"
check hang-no-orphan "${LEFT:-0}" "0" "the whole process group was killed"

# 9c. a fetch slower than nothing but well inside the bound is not a timeout.
STUB_SLEEP=1 run "$LISTING" 0 --timeout 20
check slow-ok "$CODE" 0 "a slow-but-answering fetch still passes"

# 10. --timeout takes what check-test-command.sh's takes, 0 included.
STUB_SLEEP=1 run "$LISTING" 0 --timeout 0
check timeout-zero "$CODE" 0 "--timeout 0 disables the bound"
run "$LISTING" 0 --timeout 2m
check timeout-suffix "$CODE" 0 "--timeout accepts an m suffix"
run "$LISTING" 0 --timeout soon
check timeout-junk "$CODE" 2 "exit 2 on a non-numeric timeout"

# 11. the environment sets the default, which is how phase.sh's callers reach a
# bound they never pass a flag for.
STUB_SLEEP=4793 AGY_PREFLIGHT_TIMEOUT=1 run "$LISTING" 0 --tier medium
check timeout-env "$CODE" 7 "AGY_PREFLIGHT_TIMEOUT bounds the fetch too"
sleep 1
LEFT="$(pgrep -f 'sleep 4793' 2>/dev/null | grep -c .)"
check timeout-env-no-orphan "${LEFT:-0}" "0" "and kills the group just the same"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
