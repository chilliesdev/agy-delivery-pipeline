#!/usr/bin/env bash
# Exercise preflight.sh's failure classes, each of which the orchestrator maps
# to its own STATUS: PREFLIGHT_FAILED reason.
#
#   tests/preflight.sh
#
# Builds a fake `agy` whose `models` output and exit code come from the
# environment, points preflight.sh at it with AGY_BIN, and asserts the exit code
# and the message. Nothing is written inside this repo. Prints one line per case
# and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$HERE/../scripts/preflight.sh"
[ -f "$PREFLIGHT" ] || { echo "preflight-test: preflight.sh not found next door" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

# The stub agy: answers `models` from $STUB_MODELS with exit code $STUB_RC.
# Anything else is not preflight's business and exits 0.
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'Fetching available models...\n' >&2
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
# streams into $OUT and the exit code into $CODE.
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
