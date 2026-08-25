#!/usr/bin/env bash
# Exercise phase.sh's verdict parsing against a stub agy worker.
#
#   tests/phase-status.sh
#
# Builds a fake `agy` that replays a canned transcript (and optionally writes a
# R/phases/<PHASE>/verdict), points agy-run.sh at it with AGY_BIN, and runs phase.sh
# against a throwaway repo under ${TMPDIR:-/tmp}. Nothing is written inside this
# repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_SH="$HERE/../scripts/phase.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
[ -f "$PHASE_SH" ] || { echo "phase-status: phase.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "phase-status: run-dir.sh not found next door" >&2; exit 2; }

. "$RUN_DIR_SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase-status.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

# The stub agy: cwd is the repo agy-run.sh cd'd into. Behaviour comes from the
# STUB_* environment. `agy models` is answered first and on its own terms — it is
# preflight.sh's call, not the worker's, so STUB_RC and STUB_TRANSCRIPT must not
# reach it.
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
  if [ -n "$CUR_RUN" ] && [ -n "${STUB_VERDICT:-}" ]; then
    mkdir -p ".agy/runs/$CUR_RUN/phases/$STUB_PHASE"
    printf '%b' "$STUB_VERDICT" > ".agy/runs/$CUR_RUN/phases/$STUB_PHASE/verdict"
  fi
fi
[ -n "${STUB_TRANSCRIPT:-}" ] && printf '%b' "$STUB_TRANSCRIPT"
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0

# run_case <name> <expected substring> <transcript> <verdict> <rc> [stale verdict]
run_case() {
  NAME="$1"; WANT="$2"; TRANSCRIPT="$3"; VERDICT="$4"; WANT_RC="$5"; STALE="${6:-}"
  REPO="$ROOT/repos/$NAME"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q . )
  printf 'do the thing\n' > "$REPO/brief.md"

  RUN_ID="$(run_dir_new --dir "$REPO" --task "$NAME")"
  if [ -n "$STALE" ]; then
    mkdir -p "$REPO/.agy/runs/$RUN_ID/phases/TEST"
    printf '%b' "$STALE" > "$REPO/.agy/runs/$RUN_ID/phases/TEST/verdict"
  fi

  OUT="$(STUB_PHASE=TEST STUB_TRANSCRIPT="$TRANSCRIPT" STUB_VERDICT="$VERDICT" \
    STUB_RC="$WANT_RC" AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$REPO/brief.md" --dir "$REPO" --run "$RUN_ID" 2>/dev/null)"

  printf '%-28s %s\n' "$NAME" "$OUT"
  case "$OUT" in
    *"$WANT"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); printf '%-28s FAIL — wanted substring: %s\n' "" "$WANT" ;;
  esac
  # The status file must carry exactly what was printed.
  if [ "$(cat "$REPO/.agy/runs/$RUN_ID/phases/TEST/status" 2>/dev/null)" != "$OUT" ]; then
    FAIL=$((FAIL + 1)); printf '%-28s FAIL — R/phases/TEST/status differs from stdout\n' ""
  fi
}

# a. the worker's own verdict file wins, transcript ignored
run_case a-verdict-file \
  'STATUS: PASSED | File: CHANGES.md' \
  'working...\nSTATUS: FAILED | File: WRONG.md\n' \
  '\nSTATUS: PASSED | File: CHANGES.md\n' 0

# b. no verdict file, transcript's final line is the verdict
run_case b-transcript-final \
  'STATUS: PASSED | File: CHANGES.md' \
  'read files\nSTATUS: PASSED | File: CHANGES.md\n' '' 0

# c. prose decoy earlier, real verdict last — decoy must not win
run_case c-decoy-ignored \
  'STATUS: FAILED | File: REVIEW_FEEDBACK.md' \
  'I will end with STATUS: PASSED when done\n**STATUS: FAILED | File: REVIEW_FEEDBACK.md**\n' '' 0

# c2. decoy *after* the real verdict — anchoring, not tail -1, is what saves us
run_case c2-trailing-decoy \
  'STATUS: FAILED | File: REVIEW_FEEDBACK.md' \
  'STATUS: FAILED | File: REVIEW_FEEDBACK.md\nAs promised I ended with STATUS: PASSED\n' '' 0

# d. a double-quoted filename must survive the whole way through
run_case d-quoted-filename \
  'STATUS: FAILED | File: "src/my file.ts"' \
  '\033[32mSTATUS: FAILED | File: "src/my file.ts"\033[0m\r\n' '' 0

# e. no verdict anywhere, rc=0 — actionable marker, never an invented PASSED
run_case e-no-status \
  'NO_STATUS_REPORTED | Phase: TEST | Run: ' \
  'I looked around and stopped.\n' '' 0

# f. worker exited non-zero
run_case f-worker-failed \
  'STATUS: WORKER_FAILED(rc=3)' \
  'boom\nSTATUS: PASSED | File: CHANGES.md\n' '' 3

# g. a verdict left by a previous run of the same phase must be cleared first
run_case g-stale-verdict \
  'STATUS: FAILED | File: REVIEW_FEEDBACK.md' \
  'retry round\nSTATUS: FAILED | File: REVIEW_FEEDBACK.md\n' '' 0 \
  'STATUS: PASSED | File: STALE.md\n'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
