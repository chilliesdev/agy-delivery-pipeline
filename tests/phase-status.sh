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

# shellcheck source=../scripts/run-dir.sh
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
if [ -n "${STUB_TRANSCRIPT_RAW:-}" ]; then
  printf '%s\n' "$STUB_TRANSCRIPT_RAW"
elif [ -n "${STUB_TRANSCRIPT:-}" ]; then
  printf '%b' "$STUB_TRANSCRIPT"
fi
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0

# run_case <name> <expected substring> <transcript> <verdict> <rc> [stale verdict] [raw transcript] [want_phase_rc]
run_case() {
  NAME="$1"; WANT="$2"; TRANSCRIPT="$3"; VERDICT="$4"; WANT_RC="$5"; STALE="${6:-}"; RAW="${7:-}"; WANT_PHASE_RC="${8:-}"
  REPO="$ROOT/repos/$NAME"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q . )
  printf 'do the thing\n' > "$REPO/brief.md"

  RUN_ID="$(run_dir_new --dir "$REPO" --task "$NAME")"
  if [ -n "$STALE" ]; then
    mkdir -p "$REPO/.agy/runs/$RUN_ID/phases/TEST"
    printf '%b' "$STALE" > "$REPO/.agy/runs/$RUN_ID/phases/TEST/verdict"
  fi

  # Bypass brief lint: this suite tests verdict parsing and status extraction;
  # the brief is a stub by design, and brief validity has its own suite.
  PHASE_RC=0
  OUT="$(STUB_PHASE=TEST STUB_TRANSCRIPT="$TRANSCRIPT" STUB_TRANSCRIPT_RAW="$RAW" STUB_VERDICT="$VERDICT" \
    STUB_RC="$WANT_RC" AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$REPO/brief.md" --dir "$REPO" --run "$RUN_ID" --no-brief-lint 2>/dev/null)" || PHASE_RC=$?

  printf '%-28s %s\n' "$NAME" "$OUT"
  case "$OUT" in
    *"$WANT"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); printf '%-28s FAIL — wanted substring: %s\n' "" "$WANT" ;;
  esac
  # The status file must carry exactly what was printed.
  if [ "$(cat "$REPO/.agy/runs/$RUN_ID/phases/TEST/status" 2>/dev/null)" != "$OUT" ]; then
    FAIL=$((FAIL + 1)); printf '%-28s FAIL — R/phases/TEST/status differs from stdout\n' ""
  fi
  if [ -n "$WANT_PHASE_RC" ] && [ "$PHASE_RC" -ne "$WANT_PHASE_RC" ]; then
    FAIL=$((FAIL + 1)); printf '%-28s FAIL — wanted phase.sh exit code %s, got %s\n' "" "$WANT_PHASE_RC" "$PHASE_RC"
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

# h. a worker writing the impossible verdict to its verdict file: exits 10, collision text intact
run_case h-impossible-verdict-file \
  'STATUS: BRIEF_IMPOSSIBLE(requirement A collides with constraint B)' \
  'investigating codebase...\n' \
  'STATUS: BRIEF_IMPOSSIBLE(requirement A collides with constraint B)\n' 0 '' '' 10

# i. same impossible verdict via transcript fallback line: exits 10, collision text intact
run_case i-impossible-transcript \
  'STATUS: BRIEF_IMPOSSIBLE(cannot modify locked config without violating rule 2)' \
  'reading brief\nSTATUS: BRIEF_IMPOSSIBLE(cannot modify locked config without violating rule 2)\n' \
  '' 0 '' '' 10

# j. retry counter is unchanged across an impossible round, and following ordinary dispatch succeeds
test_impossible_retries() {
  NAME="j-impossible-retries"
  REPO="$ROOT/repos/$NAME"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q . )
  printf 'do the thing\n' > "$REPO/brief.md"

  RUN_ID="$(run_dir_new --dir "$REPO" --task "$NAME")"
  RETRY_PATH="$REPO/.agy/runs/$RUN_ID/phases/TEST/retries"
  mkdir -p "$REPO/.agy/runs/$RUN_ID/phases/TEST"

  # Case j1: When retry counter was absent before dispatch
  BEFORE_ABSENT="absent"
  [ -f "$RETRY_PATH" ] && BEFORE_ABSENT="$(cat "$RETRY_PATH")"

  PHASE_RC=0
  OUT1="$(STUB_PHASE=TEST STUB_TRANSCRIPT="" \
    STUB_VERDICT="STATUS: BRIEF_IMPOSSIBLE(constraint X blocks requirement Y)\n" \
    STUB_RC=0 AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$REPO/brief.md" --dir "$REPO" --run "$RUN_ID" --no-brief-lint 2>/dev/null)" || PHASE_RC=$?

  AFTER_ABSENT="absent"
  [ -f "$RETRY_PATH" ] && AFTER_ABSENT="$(cat "$RETRY_PATH")"

  if [ "$BEFORE_ABSENT" = "$AFTER_ABSENT" ] && [ "$PHASE_RC" -eq 10 ]; then
    PASS=$((PASS + 1))
    printf '%-28s %s (exit %s, retries %s -> %s)\n' "$NAME-absent" "$OUT1" "$PHASE_RC" "$BEFORE_ABSENT" "$AFTER_ABSENT"
  else
    FAIL=$((FAIL + 1))
    printf '%-28s FAIL — retries changed or wrong exit: %s -> %s, rc=%s\n' "$NAME-absent" "$BEFORE_ABSENT" "$AFTER_ABSENT" "$PHASE_RC"
  fi

  # Case j2: When retry counter had 1 retry spent before dispatch
  printf '1\n' > "$RETRY_PATH"
  BEFORE_SPENT="$(cat "$RETRY_PATH")"

  PHASE_RC=0
  OUT2="$(STUB_PHASE=TEST STUB_TRANSCRIPT="" \
    STUB_VERDICT="STATUS: BRIEF_IMPOSSIBLE(constraint X blocks requirement Y)\n" \
    STUB_RC=0 AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$REPO/brief.md" --dir "$REPO" --run "$RUN_ID" --no-brief-lint 2>/dev/null)" || PHASE_RC=$?

  AFTER_SPENT="$(cat "$RETRY_PATH" 2>/dev/null || echo "absent")"

  if [ "$BEFORE_SPENT" = "$AFTER_SPENT" ] && [ "$PHASE_RC" -eq 10 ]; then
    PASS=$((PASS + 1))
    printf '%-28s %s (exit %s, retries %s -> %s)\n' "$NAME-refund" "$OUT2" "$PHASE_RC" "$BEFORE_SPENT" "$AFTER_SPENT"
  else
    FAIL=$((FAIL + 1))
    printf '%-28s FAIL — retries changed: %s -> %s, rc=%s\n' "$NAME-refund" "$BEFORE_SPENT" "$AFTER_SPENT" "$PHASE_RC"
  fi

  # Case j3: A following ordinary dispatch is still permitted (with retry-cap 2 and 1 spent, it must not be blocked)
  PHASE_RC=0
  OUT3="$(STUB_PHASE=TEST STUB_TRANSCRIPT="" \
    STUB_VERDICT="STATUS: PASSED | File: CHANGES.md\n" \
    STUB_RC=0 AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$REPO/brief.md" --dir "$REPO" --run "$RUN_ID" --no-brief-lint --retry-cap 2 2>/dev/null)" || PHASE_RC=$?

  case "$OUT3" in
    *"STATUS: PASSED | File: CHANGES.md"*)
      if [ "$PHASE_RC" -eq 0 ]; then
        PASS=$((PASS + 1))
        printf '%-28s %s (exit %s)\n' "$NAME-following-pass" "$OUT3" "$PHASE_RC"
      else
        FAIL=$((FAIL + 1))
        printf '%-28s FAIL — following dispatch failed with rc=%s\n' "$NAME-following-pass" "$PHASE_RC"
      fi
      ;;
    *)
      FAIL=$((FAIL + 1))
      printf '%-28s FAIL — following dispatch did not pass: %s\n' "$NAME-following-pass" "$OUT3"
      ;;
  esac
}
test_impossible_retries

# h. worker refused verdict file write, reported ERROR, but printed verdict line
run_case h-refused-verdict-file \
  'Note: file route failed; printed route carried the verdict' \
  '' '' 0 '' \
  '{"status":"ERROR","response":"Refused to write verdict file to path outside workspace\nSTATUS: PASSED | File: CHANGES.md\n"}'

# h2. assert h-refused-verdict-file produced a passing status line and clean round
H_REPO="$ROOT/repos/h-refused-verdict-file"
H_RUN="$(cat "$H_REPO/.agy/current")"
H_OUT="$(cat "$H_REPO/.agy/runs/$H_RUN/phases/TEST/status" 2>/dev/null || true)"
case "$H_OUT" in
  "STATUS: PASSED | File: CHANGES.md"*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); printf '%-28s FAIL — wanted STATUS: PASSED prefix: %s\n' "" "$H_OUT" ;;
esac
if [ ! -e "$H_REPO/.agy/runs/$H_RUN/phases/TEST/retries" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); printf '%-28s FAIL — retries file exists; round was not clean\n' ""
fi

# i. worker reported ERROR status but wrote verdict file — must NOT carry the note
run_case i-verdict-file-with-error-status \
  'STATUS: PASSED | File: CHANGES.md' \
  '' \
  'STATUS: PASSED | File: CHANGES.md\n' 0 '' \
  '{"status":"ERROR","response":"some error occurred\n"}'

I_REPO="$ROOT/repos/i-verdict-file-with-error-status"
I_OUT="$(cat "$I_REPO"/.agy/runs/*/phases/TEST/status 2>/dev/null || true)"
case "$I_OUT" in
  *"Note: file route failed"*) FAIL=$((FAIL + 1)); printf '%-28s FAIL — note must not appear when verdict came from file: %s\n' "" "$I_OUT" ;;
  *) PASS=$((PASS + 1)) ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
