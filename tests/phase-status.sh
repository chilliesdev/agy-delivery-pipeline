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
trap 'chmod +x "$HERE/../scripts/check-git-state.sh" 2>/dev/null || true; rm -rf "$ROOT"' EXIT INT TERM

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
if [ -n "${STUB_ACTION:-}" ]; then
  eval "$STUB_ACTION"
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

# run_case <name> <expected substring> <transcript> <verdict> <rc> [stale verdict] [extra args...]
run_case() {
  NAME="$1"; WANT="$2"; TRANSCRIPT="$3"; VERDICT="$4"; WANT_RC="$5"; STALE="${6:-}"
  local i=0
  while [ $# -gt 0 ] && [ "$i" -lt 6 ]; do
    shift
    i=$((i + 1))
  done
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
  OUT="$(STUB_PHASE=TEST STUB_TRANSCRIPT="$TRANSCRIPT" STUB_VERDICT="$VERDICT" \
    STUB_RC="$WANT_RC" STUB_ACTION="${STUB_ACTION:-}" AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$REPO/brief.md" --dir "$REPO" --run "$RUN_ID" --no-brief-lint ${1+"$@"} 2>/dev/null)"
  CODE=$?

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

# --- --check-git-state ----------------------------------------------------

# h. flag passed, checker non-executable, worker commits: phase fails, status names why, round not clean
CHECK_SCRIPT="$HERE/../scripts/check-git-state.sh"
chmod -x "$CHECK_SCRIPT"
STUB_ACTION='git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "worker commit"' \
  run_case h-git-state-non-exec \
  'STATUS: GIT_STATE_CHANGED' \
  '' '\nSTATUS: PASSED | File: CHANGES.md\n' 0 '' --check-git-state
chmod +x "$CHECK_SCRIPT"

if [ "$CODE" -ne 0 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf '%-28s FAIL — expected non-zero exit code when checker was non-executable\n' ""
fi
RUN_ID_H="$(cat "$ROOT/repos/h-git-state-non-exec/.agy/current" 2>/dev/null || true)"
if [ -f "$ROOT/repos/h-git-state-non-exec/.agy/runs/$RUN_ID_H/phases/TEST/retries" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf '%-28s FAIL — expected retries file to remain (round not clean)\n' ""
fi

# i. flag passed, worker commits: changed status, non-zero exit, round not clean
STUB_ACTION='git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "worker commit"' \
  run_case i-git-state-worker-commits \
  'STATUS: GIT_STATE_CHANGED' \
  '' '\nSTATUS: PASSED | File: CHANGES.md\n' 0 '' --check-git-state

if [ "$CODE" -ne 0 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf '%-28s FAIL — expected non-zero exit on git state changed\n' ""
fi
RUN_ID_I="$(cat "$ROOT/repos/i-git-state-worker-commits/.agy/current" 2>/dev/null || true)"
if [ -f "$ROOT/repos/i-git-state-worker-commits/.agy/runs/$RUN_ID_I/phases/TEST/retries" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf '%-28s FAIL — expected retries file to remain (round not clean)\n' ""
fi

# j. flag passed, worker touches nothing: unchanged, clean, exit zero
run_case j-git-state-unchanged \
  'STATUS: PASSED | File: CHANGES.md' \
  '' '\nSTATUS: PASSED | File: CHANGES.md\n' 0 '' --check-git-state

case "$OUT" in
  *"GitState: GIT_STATE_UNCHANGED"*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); printf '%-28s FAIL — wanted GitState: GIT_STATE_UNCHANGED in %s\n' "" "$OUT" ;;
esac
if [ "$CODE" -eq 0 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf '%-28s FAIL — expected exit 0 on clean round\n' ""
fi
RUN_ID_J="$(cat "$ROOT/repos/j-git-state-unchanged/.agy/current" 2>/dev/null || true)"
if [ ! -f "$ROOT/repos/j-git-state-unchanged/.agy/runs/$RUN_ID_J/phases/TEST/retries" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf '%-28s FAIL — expected retries file to be cleared on clean round\n' ""
fi

# k. no flag: no git-state field on the line at all, outcome unchanged
run_case k-git-state-no-flag \
  'STATUS: PASSED | File: CHANGES.md' \
  '' '\nSTATUS: PASSED | File: CHANGES.md\n' 0

case "$OUT" in
  *GitState:*) FAIL=$((FAIL + 1)); printf '%-28s FAIL — unexpected GitState field: %s\n' "" "$OUT" ;;
  *) PASS=$((PASS + 1)) ;;
esac
if [ "$CODE" -eq 0 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf '%-28s FAIL — expected exit 0 without flag\n' ""
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
