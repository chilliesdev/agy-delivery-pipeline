#!/usr/bin/env bash
# Exercise fake-agy fixture library quirks against real dispatch entry points
# (scripts/phase.sh and scripts/preflight.sh).
#
#   tests/fake-agy.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PREFLIGHT="$ROOT/scripts/preflight.sh"
PHASE_SH="$ROOT/scripts/phase.sh"
RUN_DIR_SH="$ROOT/scripts/run-dir.sh"
FAKE_LIB="$HERE/lib/fake-agy.sh"

[ -f "$PREFLIGHT" ] || { echo "fake-agy-test: scripts/preflight.sh not found" >&2; exit 2; }
[ -f "$PHASE_SH" ]   || { echo "fake-agy-test: scripts/phase.sh not found" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "fake-agy-test: scripts/run-dir.sh not found" >&2; exit 2; }
[ -f "$FAKE_LIB" ]   || { echo "fake-agy-test: tests/lib/fake-agy.sh not found" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"
# shellcheck source=lib/fake-agy.sh
. "$FAKE_LIB"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fake-agy-test.XXXXXX")"
SCRATCH="$(cd "$SCRATCH" && pwd)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-35s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-35s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# Helper to create a throwaway repo
new_repo() {
  local name="$1"
  local r="$SCRATCH/repos/$name"
  mkdir -p "$r"
  r="$(cd "$r" && pwd)"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" \
      && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  local run_id
  run_id="$(run_dir_new --dir "$r" --task "fake-agy test $name")"
  [ -n "$run_id" ] || { echo "fake-agy-test: run_dir_new failed for $name" >&2; exit 2; }
  printf '%s' "$r"
}

# --- 1. drain-stdin-forever --------------------------------------------------
# The worker drains stdin before answering; an unclosed inherited stdin hangs it.
# With preflight.sh redirecting stdin from /dev/null, it returns immediately.
FAKE_DRAIN="$(fake_agy_new --dir "$SCRATCH/bin-drain" --behaviour drain-stdin-forever)"

{ sleep 15 | AGY_BIN="$FAKE_DRAIN" /bin/bash "$PREFLIGHT" --tier medium --timeout 2; } >/dev/null 2>&1
CODE_DRAIN=$?
check drain-stdin-protected "$CODE_DRAIN" 0 "preflight succeeds with unclosed stdin because stdin is redirected"

# --- 2. hang-on-file-stdout --------------------------------------------------
# The worker hangs when stdout is a plain file rather than a pipe.
# driver_run pipes through `cat`, satisfying the pipe requirement.
FAKE_STDOUT="$(fake_agy_new --dir "$SCRATCH/bin-stdout" --behaviour hang-on-file-stdout)"

REPO_STDOUT="$(new_repo hang-stdout)"
RUN_ID_STDOUT="$(cat "$REPO_STDOUT/.agy/current")"
BRIEF_STDOUT="$REPO_STDOUT/.agy/runs/$RUN_ID_STDOUT/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_STDOUT")"
cat > "$BRIEF_STDOUT" <<EOF
# Phase: TEST
Goal: test stdout pipe requirement.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID_STDOUT/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

OUT_STDOUT="$(AGY_BIN="$FAKE_STDOUT" "$PHASE_SH" --phase TEST --brief "$BRIEF_STDOUT" \
  --dir "$REPO_STDOUT" --run "$RUN_ID_STDOUT" --no-preflight --timeout 3s 2>/dev/null)"
CODE_STDOUT=$?

check stdout-pipe-protected "$CODE_STDOUT" 0 "phase succeeds because driver_run pipes worker stdout"
case "$OUT_STDOUT" in
  *"STATUS: DONE"*) ok stdout-pipe-status "STATUS line reports DONE" ;;
  *) bad stdout-pipe-status "unexpected output: $OUT_STDOUT" ;;
esac

# --- 3. scratch-write-without-add-dir ----------------------------------------
# Worker writes to scratch directory instead of repo when --add-dir is omitted.
FAKE_SCRATCH="$(fake_agy_new --dir "$SCRATCH/bin-scratch" --behaviour scratch-write-without-add-dir)"

REPO_SCRATCH="$(new_repo scratch-write)"
RUN_ID_SCRATCH="$(cat "$REPO_SCRATCH/.agy/current")"
BRIEF_SCRATCH="$REPO_SCRATCH/.agy/runs/$RUN_ID_SCRATCH/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_SCRATCH")"
cat > "$BRIEF_SCRATCH" <<EOF
# Phase: TEST
Goal: test add-dir presence.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID_SCRATCH/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

# 3a. With phase.sh (which passes --add-dir), repo is written to
AGY_BIN="$FAKE_SCRATCH" "$PHASE_SH" --phase TEST --brief "$BRIEF_SCRATCH" \
  --dir "$REPO_SCRATCH" --run "$RUN_ID_SCRATCH" --no-preflight >/dev/null 2>&1
CODE_SCRATCH=$?

check scratch-add-dir-present-rc "$CODE_SCRATCH" 0 "phase succeeds when --add-dir is passed"
[ -f "$REPO_SCRATCH/.agy/runs/$RUN_ID_SCRATCH/phases/TEST/verdict" ] \
  && ok scratch-add-dir-verdict-written "verdict written to repository with --add-dir" \
  || bad scratch-add-dir-verdict-written "verdict not written to repository"

# 3b. Without --add-dir, repository is not written to
REPO_NO_ADD_DIR="$(new_repo scratch-write-absent)"
RUN_ID_NO_ADD_DIR="$(cat "$REPO_NO_ADD_DIR/.agy/current")"
( cd "$REPO_NO_ADD_DIR" && "$FAKE_SCRATCH" --output-format json -p="test" >/dev/null 2>&1 )
[ ! -f "$REPO_NO_ADD_DIR/.agy/runs/$RUN_ID_NO_ADD_DIR/phases/TEST/verdict" ] \
  && ok scratch-no-add-dir-repo-untouched "repository untouched when --add-dir is absent" \
  || bad scratch-no-add-dir-repo-untouched "repository was modified without --add-dir"

# --- 4. abort-on-shell-command -----------------------------------------------
# A denied permission aborts the run: work survives on disk but status is lost.
FAKE_ABORT="$(fake_agy_new --dir "$SCRATCH/bin-abort" --behaviour abort-on-shell-command)"

REPO_ABORT="$(new_repo abort-shell)"
RUN_ID_ABORT="$(cat "$REPO_ABORT/.agy/current")"
BRIEF_ABORT="$REPO_ABORT/.agy/runs/$RUN_ID_ABORT/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_ABORT")"
cat > "$BRIEF_ABORT" <<EOF
# Phase: TEST
Goal: test abort on shell command.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID_ABORT/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

OUT_ABORT="$(STUB_ACTION="printf 'surviving work\n' > '$REPO_ABORT/SURVIVED.txt'" \
  AGY_BIN="$FAKE_ABORT" "$PHASE_SH" --phase TEST --brief "$BRIEF_ABORT" \
  --dir "$REPO_ABORT" --run "$RUN_ID_ABORT" --no-preflight 2>/dev/null)" || CODE_ABORT=$?
CODE_ABORT="${CODE_ABORT:-0}"

check abort-shell-rc "$CODE_ABORT" 1 "phase exits non-zero on aborted run"
case "$OUT_ABORT" in
  *"STATUS: WORKER_FAILED"*) ok abort-shell-status "status reported as WORKER_FAILED" ;;
  *) bad abort-shell-status "unexpected status output: $OUT_ABORT" ;;
esac
[ ! -f "$REPO_ABORT/.agy/runs/$RUN_ID_ABORT/phases/TEST/verdict" ] \
  && ok abort-shell-verdict-lost "verdict file was lost on abort" \
  || bad abort-shell-verdict-lost "verdict file was written despite abort"
[ -f "$REPO_ABORT/SURVIVED.txt" ] \
  && ok abort-shell-work-survived "work on disk survived the abort" \
  || bad abort-shell-work-survived "work on disk was not preserved"

# --- 5. deny-write-in-plan-mode ----------------------------------------------
# Plan mode denies the worker writing its own verdict file to disk.
FAKE_PLAN="$(fake_agy_new --dir "$SCRATCH/bin-plan" --behaviour deny-write-in-plan-mode)"

REPO_PLAN="$(new_repo deny-plan)"
RUN_ID_PLAN="$(cat "$REPO_PLAN/.agy/current")"
BRIEF_PLAN="$REPO_PLAN/.agy/runs/$RUN_ID_PLAN/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_PLAN")"
cat > "$BRIEF_PLAN" <<EOF
# Phase: TEST
Goal: test plan mode write denial.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID_PLAN/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

OUT_PLAN="$(AGY_BIN="$FAKE_PLAN" "$PHASE_SH" --phase TEST --brief "$BRIEF_PLAN" \
  --dir "$REPO_PLAN" --run "$RUN_ID_PLAN" --mode plan --no-preflight 2>/dev/null)"
CODE_PLAN=$?

check deny-plan-rc "$CODE_PLAN" 0 "plan mode dispatch completes with exit 0"
[ ! -f "$REPO_PLAN/.agy/runs/$RUN_ID_PLAN/phases/TEST/verdict" ] \
  && ok deny-plan-verdict-denied "verdict file was denied write in plan mode" \
  || bad deny-plan-verdict-denied "verdict file was written in plan mode"
case "$OUT_PLAN" in
  *"STATUS: DONE"*) ok deny-plan-status-fallback "phase.sh recovers status from output fallback" ;;
  *) bad deny-plan-status-fallback "unexpected output in plan mode: $OUT_PLAN" ;;
esac

# --- 6. Options and composition ----------------------------------------------
# Test fake_agy_new with --verdict and --sleep
START_OPTS=$(date +%s)
FAKE_OPTS="$(fake_agy_new --dir "$SCRATCH/bin-opts" --verdict PASSED --sleep 1)"
{ sleep 15 | AGY_BIN="$FAKE_OPTS" /bin/bash "$PREFLIGHT" --tier medium --timeout 5; } >/dev/null 2>&1
CODE_OPTS=$?
ELAPSED_OPTS=$(( $(date +%s) - START_OPTS ))
check opts-preflight-rc "$CODE_OPTS" 0 "preflight succeeds with custom fake_agy"
if [ "$ELAPSED_OPTS" -ge 1 ]; then
  ok opts-sleep-applied "artificial sleep was applied (${ELAPSED_OPTS}s >= 1s)"
else
  bad opts-sleep-applied "sleep was not applied (${ELAPSED_OPTS}s < 1s)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
