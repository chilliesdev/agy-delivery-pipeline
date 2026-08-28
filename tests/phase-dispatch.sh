#!/usr/bin/env bash
# Exercise phase.sh's dispatch side effects: the .gitignore guard it installs
# before running a worker — which it reports on the STATUS line and never
# commits — and the sandbox flag it forwards to agy-run.sh.
#
#   tests/phase-dispatch.sh
#
# Builds a fake `agy` that records the argv it was handed, points agy-run.sh at
# it with AGY_BIN, and runs phase.sh against throwaway repos under
# ${TMPDIR:-/tmp}. Nothing is written inside this repo. Prints one line per case
# and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_SH="$HERE/../scripts/phase.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
[ -f "$PHASE_SH" ] || { echo "phase-dispatch: phase.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "phase-dispatch: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase-dispatch.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

export AGY_FLEET="$ROOT/fleet"

# The stub agy: writes the verdict phase.sh expects and dumps its own argv, one
# argument per line, to $STUB_ARGV (absolute — agy-run.sh cd's into the repo).
# `agy models` returns before the argv dump, so preflight.sh's call never
# overwrites the dispatch argv these cases assert on.
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
  exit 0
fi
if [ -n "${STUB_SLEEP_SEC:-}" ]; then
  sleep "$STUB_SLEEP_SEC"
fi
[ -n "${STUB_ARGV:-}" ] && printf '%s\n' "$@" > "$STUB_ARGV"
if [ -n "${STUB_MUTATE_SCRIPT:-}" ] && [ -f "$STUB_MUTATE_SCRIPT" ]; then
  printf '\nthis is a syntax error that would kill bash if executed mid-run: (\n' >> "$STUB_MUTATE_SCRIPT"
fi
if [ -n "${STUB_ACTION:-}" ]; then
  eval "$STUB_ACTION"
fi
if [ -f .agy/current ]; then
  CUR_RUN="$(cat .agy/current 2>/dev/null || true)"
  if [ -n "$CUR_RUN" ]; then
    mkdir -p ".agy/runs/$CUR_RUN/phases/$STUB_PHASE"
    printf '%b\n' "${STUB_VERDICT:-STATUS: DONE | File: CHANGES.md}" > ".agy/runs/$CUR_RUN/phases/$STUB_PHASE/verdict"
  fi
fi
printf '%b\n' "${STUB_VERDICT:-STATUS: DONE | File: CHANGES.md}"
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
# grep -c both prints 0 and exits 1 on no match, so `|| echo 0` would double up.
count() { C="$(grep -c -- "$2" "$1" 2>/dev/null)"; printf '%s' "${C:-0}"; }

# Bounded wait ceiling in seconds. Set to thirty seconds because these waits are
# on a machine that may be running several workers, and the ceiling is the point
# at which we conclude the outcome is never coming, not the point at which we
# expect it.
WAIT_CEILING_SEC=30

# wait_for <condition_eval_string> [ceiling_sec]
# Polls every 50ms up to ceiling_sec (default $WAIT_CEILING_SEC) until condition exits 0.
wait_for() {
  local cond="$1"
  local ceiling="${2:-$WAIT_CEILING_SEC}"
  local attempts
  attempts=$(( ceiling * 20 ))
  [ "$attempts" -gt 0 ] || attempts=$(( WAIT_CEILING_SEC * 20 ))
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    if eval "$cond" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  eval "$cond" 2>/dev/null
}

# new_repo <name> — a throwaway git repo with a brief in it; echoes its path.
new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  printf 'do the thing\n' > "$R/brief.md"
  git -C "$R" init -q >/dev/null 2>&1
  printf '%s\n' "$R"
}

# run_phase <repo> <dir> [extra phase.sh args...] — dispatch, capture stdout.
# Passes --no-brief-lint because this suite tests dispatch mechanics (.gitignore
# guards, sandbox forwarding, isolation); the brief is a stub by design, and
# brief validity has its own suite (tests/check-brief.sh).
run_phase() {
  RP_REPO="$1"; RP_DIR="$2"; shift 2
  STUB_PHASE=TEST STUB_ARGV="${STUB_ARGV_FILE:-}" STUB_ACTION="${STUB_ACTION:-}" AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$RP_REPO/brief.md" --dir "$RP_DIR" --no-brief-lint "$@" 2>/dev/null
}

# --- .gitignore guard -------------------------------------------------------

# a. a fresh git repo gains .agy/ on the first run
REPO="$(new_repo a-fresh-repo)"
OUT="$(run_phase "$REPO" "$REPO")"
check a-fresh-repo "$(count "$REPO/.gitignore" '^\.agy/$')" "1" \
  ".gitignore gained one .agy/ entry"
case "$OUT" in
  "STATUS: DONE | File: CHANGES.md | Phase: TEST | Run: "*) ok a-fresh-repo-stdout "stdout is still one STATUS line" ;;
  *) bad a-fresh-repo-stdout "stdout was: $OUT" ;;
esac
check a-fresh-repo-oneline "$(printf '%s\n' "$OUT" | grep -c .)" "1" \
  "the report did not cost a second line"

# a2. the file the tooling just authored is reported, because it is untracked
# and one `git add -A` from the task's own commit. The path in the line comes
# from `git rev-parse --show-toplevel`, which is physical — $TMPDIR on macOS is
# /var/folders/…, a symlink to /private/var/folders/… — so compare against the
# resolved path, not the one mktemp handed back.
REPO_REAL="$(cd "$REPO" && pwd -P)"
case "$OUT" in *"| Gitignore: created $REPO_REAL/.gitignore holding .agy/"*)
    ok a-fresh-repo-reported "the STATUS line names the file it created" ;;
  *) bad a-fresh-repo-reported "no Gitignore field: $OUT" ;; esac

RUN_ID_A="$(cat "$REPO/.agy/current" 2>/dev/null)"
check a-fresh-repo-status-file "$(sed -n '1p' "$REPO/.agy/runs/$RUN_ID_A/phases/TEST/status")" "$OUT" \
  "R/phases/TEST/status carries the same line"

# a3. reported, not committed: phase.sh writes nothing to the user's history.
check a-fresh-repo-no-commit "$(git -C "$REPO" rev-list --count --all 2>/dev/null)" "0" \
  "no commit was made on the user's behalf"
check a-fresh-repo-untracked "$(git -C "$REPO" status --porcelain -- .gitignore 2>/dev/null)" \
  "?? .gitignore" "the file is left untracked for the orchestrator to deal with"

# b. running twice must not duplicate the entry, and must not repeat the report
run_phase "$REPO" "$REPO" >/dev/null
check b-run-twice "$(count "$REPO/.gitignore" '^\.agy/$')" "1" \
  "still exactly one .agy/ entry after a second run"
OUT="$(run_phase "$REPO" "$REPO")"
case "$OUT" in *Gitignore:*) bad b-run-twice-quiet "the second run reported an edit it did not make" ;;
  *) ok b-run-twice-quiet "only the dispatch that wrote it says so" ;; esac

# c. a repo that already ignores .agy is left byte-identical. `.agy/` is
# directory-only, so this also pins phase.sh's mkdir-before-check ordering:
# check-ignore cannot match it until .agy exists as a directory.
REPO="$(new_repo c-already-ignored)"
printf 'node_modules/\n.agy/\ndist/\n' > "$REPO/.gitignore"
BEFORE="$(cksum < "$REPO/.gitignore")"
OUT="$(run_phase "$REPO" "$REPO")"
check c-already-ignored "$(cksum < "$REPO/.gitignore")" "$BEFORE" \
  "existing .gitignore untouched"
case "$OUT" in *Gitignore:*) bad c-already-ignored-quiet "reported an edit that never happened" ;;
  *) ok c-already-ignored-quiet "nothing edited, nothing reported" ;; esac

# c2. same, via a differently-spelled rule that git still honours
REPO="$(new_repo c2-ignored-other-spelling)"
printf '/.agy\n' > "$REPO/.gitignore"
BEFORE="$(cksum < "$REPO/.gitignore")"
run_phase "$REPO" "$REPO" >/dev/null
check c2-ignored-other-spelling "$(cksum < "$REPO/.gitignore")" "$BEFORE" \
  "'/.agy' recognised as already ignoring"

# d. a .gitignore with no trailing newline must not have its last line corrupted
REPO="$(new_repo d-no-trailing-newline)"
printf 'node_modules/' > "$REPO/.gitignore"
OUT="$(run_phase "$REPO" "$REPO")"
check d-no-trailing-newline "$(printf '%s' "$(cat "$REPO/.gitignore")" | tr '\n' '|')" \
  "node_modules/|.agy/" "last line intact, .agy/ on its own line"

# d2. an edit to a file that was already there is still an edit the task did not
# ask for, and is reported as one — in the other wording, since nothing was
# created here.
REPO_REAL="$(cd "$REPO" && pwd -P)"
case "$OUT" in *"| Gitignore: added .agy/ to $REPO_REAL/.gitignore"*)
    ok d-existing-reported "an edit to an existing .gitignore is reported too" ;;
  *) bad d-existing-reported "no Gitignore field: $OUT" ;; esac
check d-existing-no-commit "$(git -C "$REPO" rev-list --count --all 2>/dev/null)" "0" \
  "still nothing committed"

# e. a plain directory that is not a git repo: exits 4, no .gitignore invented
REPO="$ROOT/repos/e-not-a-repo"; mkdir -p "$REPO"
printf 'do the thing\n' > "$REPO/brief.md"
OUT="$(run_phase "$REPO" "$REPO")"; RC=$?
check e-not-a-repo "$RC" "4" "phase.sh exited 4 outside a git repo"
check e-not-a-repo-clean "$([ -e "$REPO/.gitignore" ] && echo present || echo absent)" "absent" \
  "no .gitignore created"

# f. --dir is a subdirectory: the work tree root's .gitignore is the one written
REPO="$(new_repo f-subdir)"
mkdir -p "$REPO/packages/app"
run_phase "$REPO" "$REPO/packages/app" >/dev/null
check f-subdir-root "$(count "$REPO/.gitignore" '^\.agy/$')" "1" \
  "root .gitignore got the entry"
check f-subdir-leaf "$([ -e "$REPO/packages/app/.gitignore" ] && echo present || echo absent)" \
  "absent" "subdirectory .gitignore not created"

# --- sandbox flag forwarding ------------------------------------------------

# g. without --sandbox the flag must not reach agy at all
REPO="$(new_repo g-no-sandbox)"
STUB_ARGV_FILE="$ROOT/argv-no-sandbox"
run_phase "$REPO" "$REPO" >/dev/null
check g-no-sandbox-recorded "$(count "$STUB_ARGV_FILE" '^--add-dir$')" "1" \
  "the stub really recorded an argv"
check g-no-sandbox "$(count "$STUB_ARGV_FILE" '^--sandbox$')" "0" \
  "agy invoked without --sandbox"
check g-no-sandbox-empty "$(count "$STUB_ARGV_FILE" '^$')" "0" \
  "no stray empty argument from the expansion"

# h. with --sandbox the flag reaches agy exactly once
REPO="$(new_repo h-sandbox)"
STUB_ARGV_FILE="$ROOT/argv-sandbox"
run_phase "$REPO" "$REPO" --sandbox >/dev/null
check h-sandbox "$(count "$STUB_ARGV_FILE" '^--sandbox$')" "1" \
  "agy invoked with --sandbox once"

# --- Run ID and isolation assertions ----------------------------------------

# i. STATUS line carries Run: <id> matching the directory artifacts landed in
REPO="$(new_repo i-run-id)"
OUT="$(run_phase "$REPO" "$REPO")"
RUN_ID_I="$(cat "$REPO/.agy/current" 2>/dev/null)"
case "$OUT" in
  *"| Run: $RUN_ID_I |"*) ok i-status-has-run-id "STATUS line carries Run: <id>" ;;
  *) bad i-status-has-run-id "Run id missing from STATUS line: $OUT" ;;
esac
[ -d "$REPO/.agy/runs/$RUN_ID_I/phases/TEST" ] && ok i-run-dir-matches "artifacts landed in matching run dir" \
  || bad i-run-dir-matches "artifacts did not land in matching run dir"

# j. two runs in the same repo do not overwrite each other's artifacts
REPO="$(new_repo j-multi-run)"
STUB_VERDICT="STATUS: DONE | File: RUN1.md" run_phase "$REPO" "$REPO" --run new >/dev/null
RUN1_ID="$(cat "$REPO/.agy/current")"
RUN1_DIR="$REPO/.agy/runs/$RUN1_ID/phases/TEST"
RUN1_STATUS="$(cat "$RUN1_DIR/status" 2>/dev/null)"
RUN1_LOG="$(cat "$RUN1_DIR/log" 2>/dev/null)"
RUN1_VERDICT="$(cat "$RUN1_DIR/verdict" 2>/dev/null)"

STUB_VERDICT="STATUS: DONE | File: RUN2.md" run_phase "$REPO" "$REPO" --run new >/dev/null
RUN2_ID="$(cat "$REPO/.agy/current")"

[ "$RUN1_ID" != "$RUN2_ID" ] && ok j-runs-distinct "runs have distinct ids" || bad j-runs-distinct "run ids collided"
check j-run1-status-preserved "$(cat "$RUN1_DIR/status" 2>/dev/null)" "$RUN1_STATUS" "first run status preserved"
check j-run1-log-preserved "$(cat "$RUN1_DIR/log" 2>/dev/null)" "$RUN1_LOG" "first run log preserved"
check j-run1-verdict-preserved "$(cat "$RUN1_DIR/verdict" 2>/dev/null)" "$RUN1_VERDICT" "first run verdict preserved"

# k. --run <id> with an id that does not exist exits 3 and creates nothing
REPO="$(new_repo k-nonexistent-run)"
OUT="$(run_phase "$REPO" "$REPO" --run "nonexistent-id-1234")"; CODE=$?
check k-nonexistent-rc "$CODE" 3 "--run nonexistent-id exits 3"
[ ! -e "$REPO/.agy/runs/nonexistent-id-1234" ] && ok k-nonexistent-nocreate "no directory created for missing run" \
  || bad k-nonexistent-nocreate "created missing run directory"

# --- Task recording and immutability ----------------------------------------

# l. a dispatch with --task 'some task' produces a run.json whose task field holds that string verbatim
REPO="$(new_repo l-task-verbatim)"
run_phase "$REPO" "$REPO" --task 'some task' >/dev/null
RUN_ID_L="$(cat "$REPO/.agy/current" 2>/dev/null)"
TASK_L="$(run_dir_get "$REPO/.agy/runs/$RUN_ID_L" "task" 2>/dev/null || true)"
check l-task-verbatim "$TASK_L" "some task" "task recorded verbatim in run.json"

# m. a second dispatch into the same run with a different --task leaves the first task recorded, and does not fail
STUB_VERDICT="STATUS: DONE | File: PHASE2.md" run_phase "$REPO" "$REPO" --run current --task 'different task' >/dev/null; CODE=$?
check m-second-dispatch-rc "$CODE" 0 "second dispatch into same run does not fail"
TASK_M="$(run_dir_get "$REPO/.agy/runs/$RUN_ID_L" "task" 2>/dev/null || true)"
check m-task-preserved "$TASK_M" "some task" "first task preserved when different task passed"

# n. a dispatch with no --task produces a run directory accepted by check-phase-range.sh --from 0
REPO="$(new_repo n-no-task)"
run_phase "$REPO" "$REPO" >/dev/null
RUN_ID_N="$(cat "$REPO/.agy/current" 2>/dev/null)"
TASK_N="$(run_dir_get "$REPO/.agy/runs/$RUN_ID_N" "task" 2>/dev/null || true)"
[ -n "$TASK_N" ] && ok n-task-fallback-nonempty "task fallback is non-empty ($TASK_N)" || bad n-task-fallback-nonempty "task fallback was empty"
CHECK_SH="$HERE/../scripts/check-phase-range.sh"
CHECK_RC="$("$CHECK_SH" --dir "$REPO" --from 0 >/dev/null 2>&1; printf '%s' "$?")"
check n-range-from-0-accepted "$CHECK_RC" 0 "check-phase-range.sh --from 0 accepts run directory created without --task"

# --- brief lint integration -------------------------------------------------

# o. dispatch with invalid brief and no --no-brief-lint is refused before worker invocation
REPO="$(new_repo o-invalid-brief)"
STUB_ARGV_FILE="$ROOT/argv-invalid-brief"
OUT="$(STUB_PHASE=TEST STUB_ARGV="$STUB_ARGV_FILE" AGY_BIN="$STUB" \
  "$PHASE_SH" --phase TEST --brief "$REPO/brief.md" --dir "$REPO" 2>/dev/null)"; CODE=$?
check o-invalid-brief-rc "$CODE" 3 "dispatch with invalid brief exits non-zero (3)"
case "$OUT" in
  *"STATUS: BRIEF_INVALID"*) ok o-invalid-brief-status "STATUS line reports BRIEF_INVALID" ;;
  *) bad o-invalid-brief-status "unexpected output on invalid brief: $OUT" ;;
esac
check o-invalid-brief-no-worker "$(count "$STUB_ARGV_FILE" '^--add-dir$')" "0" \
  "worker was never invoked on invalid brief"

# p. dispatch with a valid brief proceeds normally
REPO="$(new_repo p-valid-brief)"
RUN_ID_P="$(run_dir_new --dir "$REPO" --task "valid brief dispatch")"
VALID_BRIEF="$REPO/valid_brief.md"
cat > "$VALID_BRIEF" <<EOF
# Phase: TEST
Do the work.

Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.

Contract:
Write verdict to .agy/runs/$RUN_ID_P/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

STUB_ARGV_FILE="$ROOT/argv-valid-brief"
OUT="$(STUB_PHASE=TEST STUB_ARGV="$STUB_ARGV_FILE" AGY_BIN="$STUB" \
  "$PHASE_SH" --phase TEST --brief "$VALID_BRIEF" --dir "$REPO" --run "$RUN_ID_P" 2>/dev/null)"; CODE=$?
check p-valid-brief-rc "$CODE" 0 "dispatch with valid brief exits 0"
case "$OUT" in
  *"STATUS: DONE | File: CHANGES.md"*) ok p-valid-brief-status "valid brief dispatch succeeds" ;;
  *) bad p-valid-brief-status "unexpected output on valid brief: $OUT" ;;
esac
check p-valid-brief-worker-invoked "$(count "$STUB_ARGV_FILE" '^--add-dir$')" "1" \
  "worker was invoked on valid brief"

# --- brief placement and copy handling --------------------------------------

# q. a dispatch whose --brief is <run-dir>/phases/<PHASE>/brief.md succeeds, and
# the brief is still there afterwards with its content intact
REPO="$(new_repo q-inplace-brief)"
RUN_ID_Q="$(run_dir_new --dir "$REPO" --task "inplace brief dispatch")"
PHASE_DIR_Q="$REPO/.agy/runs/$RUN_ID_Q/phases/TEST"
mkdir -p "$PHASE_DIR_Q"
BRIEF_CONTENT="Phase TEST brief written directly into run directory."
printf '%s\n' "$BRIEF_CONTENT" > "$PHASE_DIR_Q/brief.md"
STUB_ARGV_FILE="$ROOT/argv-inplace-brief"
OUT="$(STUB_PHASE=TEST STUB_ARGV="$STUB_ARGV_FILE" AGY_BIN="$STUB" \
  "$PHASE_SH" --phase TEST --brief "$PHASE_DIR_Q/brief.md" --dir "$REPO" --run "$RUN_ID_Q" --no-brief-lint 2>/dev/null)"; CODE=$?
check q-inplace-brief-rc "$CODE" 0 "inplace brief dispatch exits 0"
case "$OUT" in
  *"STATUS: DONE | File: CHANGES.md"*) ok q-inplace-brief-status "inplace brief dispatch succeeds" ;;
  *) bad q-inplace-brief-status "unexpected output on inplace brief: $OUT" ;;
esac
check q-inplace-brief-content "$(cat "$PHASE_DIR_Q/brief.md" 2>/dev/null)" "$BRIEF_CONTENT" \
  "brief content intact after inplace dispatch"
check q-inplace-brief-worker-invoked "$(count "$STUB_ARGV_FILE" '^--add-dir$')" "1" \
  "worker was invoked on inplace brief"

# r. a dispatch whose --brief is elsewhere still copies it in, and the copy matches the original
REPO="$(new_repo r-external-brief)"
RUN_ID_R="$(run_dir_new --dir "$REPO" --task "external brief dispatch")"
EXT_BRIEF="$ROOT/external_brief.md"
EXT_CONTENT="External brief to be copied into phase dir."
printf '%s\n' "$EXT_CONTENT" > "$EXT_BRIEF"
STUB_ARGV_FILE="$ROOT/argv-external-brief"
OUT="$(STUB_PHASE=TEST STUB_ARGV="$STUB_ARGV_FILE" AGY_BIN="$STUB" \
  "$PHASE_SH" --phase TEST --brief "$EXT_BRIEF" --dir "$REPO" --run "$RUN_ID_R" --no-brief-lint 2>/dev/null)"; CODE=$?
check r-external-brief-rc "$CODE" 0 "external brief dispatch exits 0"
COPIED_BRIEF="$REPO/.agy/runs/$RUN_ID_R/phases/TEST/brief.md"
[ -f "$COPIED_BRIEF" ] && ok r-external-brief-copied "brief was copied into phase dir" \
  || bad r-external-brief-copied "brief was not copied into phase dir"
check r-external-brief-match "$(cat "$COPIED_BRIEF" 2>/dev/null)" "$EXT_CONTENT" \
  "copied brief matches original content"

# s. a dispatch whose --brief does not exist still refuses
REPO="$(new_repo s-nonexistent-brief)"
OUT="$(STUB_PHASE=TEST AGY_BIN="$STUB" \
  "$PHASE_SH" --phase TEST --brief "$REPO/missing_brief.md" --dir "$REPO" --no-brief-lint 2>/dev/null)"; CODE=$?
check s-nonexistent-brief-rc "$CODE" 2 "missing brief dispatch exits 2"

# --- self-snapshot execution when running from within target repo -----------

# t. when the orchestrating script lives inside the target repo and the worker
# rewrites the script mid-run, phase.sh completes normally: prints status line,
# runs verification, and writes status file.
REPO_T="$(new_repo t-self-snapshot)"
mkdir -p "$REPO_T/scripts" "$REPO_T/drivers"
cp -R "$HERE/../scripts/." "$REPO_T/scripts/"
if [ -d "$HERE/../drivers" ]; then
  cp -R "$HERE/../drivers/." "$REPO_T/drivers/"
fi
RUN_ID_T="$(run_dir_new --dir "$REPO_T" --task "self-modifying dispatch")"
STDERR_T="$ROOT/stderr-self-snapshot"

OUT="$(STUB_PHASE=TEST AGY_BIN="$STUB" STUB_MUTATE_SCRIPT="$REPO_T/scripts/phase.sh" \
  "$REPO_T/scripts/phase.sh" --phase TEST --brief "$REPO_T/brief.md" --dir "$REPO_T" --run "$RUN_ID_T" --verify 'true' --no-brief-lint 2>"$STDERR_T")"
CODE=$?

check t-self-snapshot-rc "$CODE" 0 "self-modifying dispatch exits 0"
case "$OUT" in
  *"STATUS: DONE | File: CHANGES.md"*"Verify: ok"*) ok t-self-snapshot-status "status line reported with verify ok" ;;
  *) bad t-self-snapshot-status "unexpected output from self-modifying dispatch: $OUT" ;;
esac

STATUS_CONTENT_T="$(cat "$REPO_T/.agy/runs/$RUN_ID_T/phases/TEST/status" 2>/dev/null)"
check t-self-snapshot-status-file "$STATUS_CONTENT_T" "$OUT" "status file written correctly"

VERIFY_LOG_T="$REPO_T/.agy/runs/$RUN_ID_T/phases/TEST/verify.log"
[ -f "$VERIFY_LOG_T" ] && ok t-self-snapshot-verify-log "verify log was written" \
  || bad t-self-snapshot-verify-log "verify log missing"

if wait_for 'grep -q "phase\.sh: re-executing from snapshot" "$STDERR_T"'; then
  ok t-self-snapshot-stderr "re-execution diagnostic printed on stderr"
else
  bad t-self-snapshot-stderr "re-execution diagnostic missing from stderr (waited ${WAIT_CEILING_SEC}s for diagnostic in $STDERR_T)"
fi

# Check that the script file was indeed mutated
case "$(tail -1 "$REPO_T/scripts/phase.sh" 2>/dev/null)" in
  *"syntax error"*) ok t-self-snapshot-mutated "target script was mutated by worker mid-run" ;;
  *) bad t-self-snapshot-mutated "target script was not mutated" ;;
esac

# Check that the temporary snapshot directory was removed on exit
SNAP_DIR_T="$(sed -n 's/.*phase\.sh: re-executing from snapshot \([^[:space:]]*\).*/\1/p' "$STDERR_T" 2>/dev/null)"
if [ -n "$SNAP_DIR_T" ] && wait_for '[ ! -d "$SNAP_DIR_T" ]'; then
  ok t-self-snapshot-cleanup "snapshot directory cleaned up on exit"
else
  bad t-self-snapshot-cleanup "snapshot directory still exists: ${SNAP_DIR_T:-unknown} (waited ${WAIT_CEILING_SEC}s for snapshot dir to be removed)"
fi

# u. negative case: when the script lives outside the target repo, no re-execution
# happens and no diagnostic is printed.
REPO_U="$(new_repo u-external-script)"
STDERR_U="$ROOT/stderr-external-script"
OUT="$(STUB_PHASE=TEST AGY_BIN="$STUB" \
  "$PHASE_SH" --phase TEST --brief "$REPO_U/brief.md" --dir "$REPO_U" --no-brief-lint 2>"$STDERR_U")"
CODE=$?
check u-external-rc "$CODE" 0 "external script dispatch exits 0"
case "$(cat "$STDERR_U" 2>/dev/null)" in
  *re-executing*) bad u-external-no-reexec "unexpected re-execution diagnostic for external script" ;;
  *) ok u-external-no-reexec "no re-execution diagnostic when script is outside target repo" ;;
esac

# --- concurrency cap & in-flight worker accounting -------------------------

# v. default cap allows exactly one worker and refuses a second concurrent dispatch
REPO_V="$(new_repo v-concurrency-default)"
RUN_ID_V1="$(run_dir_new --dir "$REPO_V" --task "concurrency test 1")"
RUN_ID_V2="$(run_dir_new --dir "$REPO_V" --task "concurrency test 2")"

STUB_SLEEP_SEC=2 run_phase "$REPO_V" "$REPO_V" --run "$RUN_ID_V1" >/dev/null 2>&1 &
PID_V1=$!

# Wait for background dispatch to enter its run
wait_for '[ -d "$REPO_V/.agy/workers" ] && [ "$(ls -A "$REPO_V/.agy/workers" 2>/dev/null | grep -c .)" -ge 1 ]' || true

OUT_V2="$(run_phase "$REPO_V" "$REPO_V" --run "$RUN_ID_V2" 2>/dev/null)"; RC_V2=$?
check v-default-cap-refused-rc "$RC_V2" 8 "second concurrent dispatch is refused with exit 8"
case "$OUT_V2" in
  *"STATUS: WORKER_CAP_EXCEEDED(running=1, cap=1)"*)
    ok v-default-cap-status "status line reports WORKER_CAP_EXCEEDED with running=1, cap=1"
    ;;
  *)
    bad v-default-cap-status "unexpected output on exceeded cap: $OUT_V2"
    ;;
esac
case "$OUT_V2" in
  *"Note: 1 dispatch is running and the cap is 1"*)
    ok v-default-cap-singular-wording "cap refusal uses singular '1 dispatch is running'"
    ;;
  *)
    bad v-default-cap-singular-wording "expected singular wording in cap note: $OUT_V2"
    ;;
esac

wait "$PID_V1" 2>/dev/null || true

# v2. cap refusal with multiple running workers uses plural wording
REPO_V2="$(new_repo v2-concurrency-plural)"
RUN_ID_V2_1="$(run_dir_new --dir "$REPO_V2" --task "concurrency plural 1")"
RUN_ID_V2_2="$(run_dir_new --dir "$REPO_V2" --task "concurrency plural 2")"
RUN_ID_V2_3="$(run_dir_new --dir "$REPO_V2" --task "concurrency plural 3")"

STUB_SLEEP_SEC=2 run_phase "$REPO_V2" "$REPO_V2" --run "$RUN_ID_V2_1" --max-workers 3 >/dev/null 2>&1 &
PID_V2_1=$!
STUB_SLEEP_SEC=2 run_phase "$REPO_V2" "$REPO_V2" --run "$RUN_ID_V2_2" --max-workers 3 >/dev/null 2>&1 &
PID_V2_2=$!

# Wait for background dispatches to enter their runs
wait_for '[ -d "$REPO_V2/.agy/workers" ] && [ "$(ls -A "$REPO_V2/.agy/workers" 2>/dev/null | grep -c .)" -ge 2 ]' || true

OUT_V2_3="$(run_phase "$REPO_V2" "$REPO_V2" --run "$RUN_ID_V2_3" --max-workers 1 2>/dev/null)"; RC_V2_3=$?
check v2-plural-cap-rc "$RC_V2_3" 8 "third dispatch with max-workers 1 refused with exit 8"
case "$OUT_V2_3" in
  *"STATUS: WORKER_CAP_EXCEEDED(running=2, cap=1)"*)
    ok v2-plural-cap-status "status line reports WORKER_CAP_EXCEEDED with running=2, cap=1"
    ;;
  *)
    bad v2-plural-cap-status "unexpected output on exceeded cap: $OUT_V2_3"
    ;;
esac
case "$OUT_V2_3" in
  *"Note: 2 dispatches are running and the cap is 1"*)
    ok v2-plural-cap-wording "cap refusal uses plural '2 dispatches are running'"
    ;;
  *)
    bad v2-plural-cap-wording "expected plural wording in cap note: $OUT_V2_3"
    ;;
esac

wait "$PID_V2_1" 2>/dev/null || true
wait "$PID_V2_2" 2>/dev/null || true

# w. explicitly raised cap (--max-workers 2) allows concurrent dispatches
REPO_W="$(new_repo w-concurrency-raised)"
RUN_ID_W1="$(run_dir_new --dir "$REPO_W" --task "concurrency raised 1")"
RUN_ID_W2="$(run_dir_new --dir "$REPO_W" --task "concurrency raised 2")"

STUB_SLEEP_SEC=2 run_phase "$REPO_W" "$REPO_W" --run "$RUN_ID_W1" --max-workers 2 >/dev/null 2>&1 &
PID_W1=$!

# Wait for background dispatch to enter its run
wait_for '[ -d "$REPO_W/.agy/workers" ] && [ "$(ls -A "$REPO_W/.agy/workers" 2>/dev/null | grep -c .)" -ge 1 ]' || true

OUT_W2="$(run_phase "$REPO_W" "$REPO_W" --run "$RUN_ID_W2" --max-workers 2 2>/dev/null)"; RC_W2=$?
check w-raised-cap-rc "$RC_W2" 0 "second dispatch with --max-workers 2 succeeds (exit 0)"
case "$OUT_W2" in
  *"STATUS: DONE"*) ok w-raised-cap-status "second dispatch completes with STATUS: DONE" ;;
  *) bad w-raised-cap-status "second dispatch failed: $OUT_W2" ;;
esac

wait "$PID_W1" 2>/dev/null || true

# x. leftover record from dead process is cleared and does not block dispatch.
# Construct a PID that is guaranteed not running: spawn a subshell, wait for it
# to terminate, and confirm via kill -0 that the OS reports no such process.
REPO_X="$(new_repo x-stale-worker-record)"
( : ) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true

# Explicit reasoning: DEAD_PID was reaped by wait and is verified dead by kill -0.
if ! kill -0 "$DEAD_PID" 2>/dev/null; then
  ok x-dead-pid-confirmed "dead pid $DEAD_PID confirmed dead via kill -0"
else
  bad x-dead-pid-confirmed "expected pid $DEAD_PID to be dead"
fi

mkdir -p "$REPO_X/.agy/workers"
STALE_REC="$REPO_X/.agy/workers/stale_${DEAD_PID}.rec"
printf 'pid=%s\nrun=stale-run\nphase=TEST\nstarted=2026-08-25T00:00:00Z\n' "$DEAD_PID" > "$STALE_REC"

run_phase "$REPO_X" "$REPO_X" >/dev/null 2>&1
RC_X=$?
check x-stale-record-rc "$RC_X" 0 "dispatch with stale worker record succeeds (exit 0)"
[ ! -f "$STALE_REC" ] && ok x-stale-record-cleaned "stale worker record was cleaned up" \
  || bad x-stale-record-cleaned "stale worker record was not removed"

# y. worker record is cleaned up when a dispatch finishes and also when it fails
REPO_Y="$(new_repo y-record-cleanup)"
run_phase "$REPO_Y" "$REPO_Y" >/dev/null 2>&1
RUNNING_Y1="$(ls -A "$REPO_Y/.agy/workers" 2>/dev/null || true)"
check y-clean-on-success "${RUNNING_Y1:-empty}" "empty" "workers directory empty after successful dispatch"

# Failing dispatch
STUB_RC=1 run_phase "$REPO_Y" "$REPO_Y" >/dev/null 2>&1 || true
RUNNING_Y2="$(ls -A "$REPO_Y/.agy/workers" 2>/dev/null || true)"
check y-clean-on-failure "${RUNNING_Y2:-empty}" "empty" "workers directory empty after failing dispatch"

# z. progress heartbeat lines on stderr carry the run id
REPO_Z="$(new_repo z-progress-run-id)"
RUN_ID_Z="$(run_dir_new --dir "$REPO_Z" --task "progress run id test")"
STDERR_Z="$ROOT/stderr-progress-z"
VALID_BRIEF_Z="$REPO_Z/valid_brief.md"
cat > "$VALID_BRIEF_Z" <<EOF
# Phase: TEST
Goal: test progress line run id.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID_Z/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

AGY_HEARTBEAT_INTERVAL=1 STUB_SLEEP_SEC=2 AGY_BIN="$STUB" STUB_PHASE=TEST \
  "$PHASE_SH" --phase TEST --brief "$VALID_BRIEF_Z" --dir "$REPO_Z" --run "$RUN_ID_Z" --no-brief-lint --no-preflight >/dev/null 2>"$STDERR_Z"

if grep -q "Run: $RUN_ID_Z" "$STDERR_Z"; then
  ok z-progress-has-run-id "progress lines on stderr carry the run id ($RUN_ID_Z)"
else
  bad z-progress-has-run-id "progress lines missing run id on stderr: $(cat "$STDERR_Z")"
fi

if grep -E -q "phase\.sh: \[[0-9]+s\] Run: $RUN_ID_Z \| Phase: TEST" "$STDERR_Z"; then
  ok z-progress-heartbeat-shape "heartbeat line on stderr matches shape 'phase.sh: [Ns] Run: <id> | Phase: ...'"
else
  bad z-progress-heartbeat-shape "heartbeat line format mismatch on stderr: $(cat "$STDERR_Z")"
fi

# z2. liveness warning line on stderr matches the same leading brackets shape
REPO_Z2="$(new_repo z2-liveness-shape)"
RUN_ID_Z2="$(run_dir_new --dir "$REPO_Z2" --task "liveness shape test")"
STDERR_Z2="$ROOT/stderr-progress-z2"
VALID_BRIEF_Z2="$REPO_Z2/valid_brief.md"
cat > "$VALID_BRIEF_Z2" <<EOF
# Phase: TEST
Goal: test liveness line shape.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID_Z2/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

AGY_HEARTBEAT_INTERVAL=60 AGY_LIVENESS_INTERVAL=1 STUB_SLEEP_SEC=2 AGY_BIN="$STUB" STUB_PHASE=TEST \
  "$PHASE_SH" --phase TEST --brief "$VALID_BRIEF_Z2" --dir "$REPO_Z2" --run "$RUN_ID_Z2" --no-brief-lint --no-preflight >/dev/null 2>"$STDERR_Z2"

if grep -E -q "phase\.sh: \[[0-9]+s\] Run: $RUN_ID_Z2 \| no output for" "$STDERR_Z2"; then
  ok z2-liveness-warning-shape "liveness line on stderr matches shape 'phase.sh: [Ns] Run: <id> | no output for ...'"
else
  bad z2-liveness-warning-shape "liveness line format mismatch on stderr: $(cat "$STDERR_Z2")"
fi

# --- worker liveness & identity checks -------------------------------------

# aa. live process with missing run field does not count as worker and record is cleared
REPO_AA="$(new_repo aa-live-proc-missing-run)"
sleep 10 &
LIVE_PID_AA=$!
if kill -0 "$LIVE_PID_AA" 2>/dev/null; then
  ok aa-live-pid-confirmed "fixture pid $LIVE_PID_AA confirmed alive"
else
  bad aa-live-pid-confirmed "expected fixture pid $LIVE_PID_AA to be alive"
fi

mkdir -p "$REPO_AA/.agy/workers"
REC_AA="$REPO_AA/.agy/workers/missing_run_${LIVE_PID_AA}.rec"
printf 'pid=%s\nphase=TEST\nstarted=2026-08-25T00:00:00Z\n' "$LIVE_PID_AA" > "$REC_AA"

OUT_AA="$(run_phase "$REPO_AA" "$REPO_AA" 2>/dev/null)"; RC_AA=$?
check aa-missing-run-rc "$RC_AA" 0 "dispatch with missing run field record succeeds (exit 0)"
case "$OUT_AA" in
  *"STATUS: DONE"*) ok aa-missing-run-status "dispatch completes with STATUS: DONE" ;;
  *) bad aa-missing-run-status "dispatch failed: $OUT_AA" ;;
esac
[ ! -f "$REC_AA" ] && ok aa-missing-run-cleaned "malformed worker record (missing run) cleared" \
  || bad aa-missing-run-cleaned "worker record was not cleared"

kill "$LIVE_PID_AA" 2>/dev/null || true
wait "$LIVE_PID_AA" 2>/dev/null || true

# ab. live process with missing phase field does not count as worker and record is cleared
REPO_AB="$(new_repo ab-live-proc-missing-phase)"
sleep 10 &
LIVE_PID_AB=$!
if kill -0 "$LIVE_PID_AB" 2>/dev/null; then
  ok ab-live-pid-confirmed "fixture pid $LIVE_PID_AB confirmed alive"
else
  bad ab-live-pid-confirmed "expected fixture pid $LIVE_PID_AB to be alive"
fi

mkdir -p "$REPO_AB/.agy/workers"
REC_AB="$REPO_AB/.agy/workers/missing_phase_${LIVE_PID_AB}.rec"
printf 'pid=%s\nrun=valid-run-id\nstarted=2026-08-25T00:00:00Z\n' "$LIVE_PID_AB" > "$REC_AB"

OUT_AB="$(run_phase "$REPO_AB" "$REPO_AB" 2>/dev/null)"; RC_AB=$?
check ab-missing-phase-rc "$RC_AB" 0 "dispatch with missing phase field record succeeds (exit 0)"
case "$OUT_AB" in
  *"STATUS: DONE"*) ok ab-missing-phase-status "dispatch completes with STATUS: DONE" ;;
  *) bad ab-missing-phase-status "dispatch failed: $OUT_AB" ;;
esac
[ ! -f "$REC_AB" ] && ok ab-missing-phase-cleaned "malformed worker record (missing phase) cleared" \
  || bad ab-missing-phase-cleaned "worker record was not cleared"

kill "$LIVE_PID_AB" 2>/dev/null || true
wait "$LIVE_PID_AB" 2>/dev/null || true

# ac. live process whose command line contains repository path but is not a dispatch
REPO_AC="$(new_repo ac-live-proc-repo-path)"
sh -c 'sleep 10' -- "$REPO_AC" &
LIVE_PID_AC=$!
if kill -0 "$LIVE_PID_AC" 2>/dev/null; then
  ok ac-live-pid-confirmed "fixture pid $LIVE_PID_AC confirmed alive"
else
  bad ac-live-pid-confirmed "expected fixture pid $LIVE_PID_AC to be alive"
fi

mkdir -p "$REPO_AC/.agy/workers"
REC_AC="$REPO_AC/.agy/workers/unrelated_${LIVE_PID_AC}.rec"
printf 'pid=%s\nrun=some-run\nphase=TEST\nstarted=2026-08-25T00:00:00Z\n' "$LIVE_PID_AC" > "$REC_AC"

OUT_AC="$(run_phase "$REPO_AC" "$REPO_AC" 2>/dev/null)"; RC_AC=$?
check ac-unrelated-proc-rc "$RC_AC" 0 "dispatch with unrelated process record succeeds (exit 0)"
case "$OUT_AC" in
  *"STATUS: DONE"*) ok ac-unrelated-proc-status "dispatch completes with STATUS: DONE" ;;
  *) bad ac-unrelated-proc-status "dispatch failed: $OUT_AC" ;;
esac
[ ! -f "$REC_AC" ] && ok ac-unrelated-proc-cleaned "record for unrelated process cleared" \
  || bad ac-unrelated-proc-cleaned "record for unrelated process was not cleared"

kill "$LIVE_PID_AC" 2>/dev/null || true
wait "$LIVE_PID_AC" 2>/dev/null || true

# ad. AGY_MAX_WORKERS environment variable is honoured
REPO_AD="$(new_repo ad-env-max-workers)"
RUN_ID_AD1="$(run_dir_new --dir "$REPO_AD" --task "env max workers 1")"
RUN_ID_AD2="$(run_dir_new --dir "$REPO_AD" --task "env max workers 2")"

STUB_SLEEP_SEC=2 AGY_MAX_WORKERS=2 run_phase "$REPO_AD" "$REPO_AD" --run "$RUN_ID_AD1" >/dev/null 2>&1 &
PID_AD1=$!

# Wait for background dispatch to enter its run
wait_for '[ -d "$REPO_AD/.agy/workers" ] && [ "$(ls -A "$REPO_AD/.agy/workers" 2>/dev/null | grep -c .)" -ge 1 ]' || true

OUT_AD2="$(AGY_MAX_WORKERS=2 run_phase "$REPO_AD" "$REPO_AD" --run "$RUN_ID_AD2" 2>/dev/null)"; RC_AD2=$?
check ad-env-max-workers-rc "$RC_AD2" 0 "second dispatch with AGY_MAX_WORKERS=2 succeeds (exit 0)"
case "$OUT_AD2" in
  *"STATUS: DONE"*) ok ad-env-max-workers-status "second dispatch with AGY_MAX_WORKERS=2 completes with STATUS: DONE" ;;
  *) bad ad-env-max-workers-status "second dispatch failed: $OUT_AD2" ;;
esac

wait "$PID_AD1" 2>/dev/null || true

# --- diff integrity check integration --------------------------------------

# ae. a worker that weakens an assertion fails the phase with status naming it
REPO_AE="$(new_repo ae-weakened-fails)"
mkdir -p "$REPO_AE/tests"
printf 'def test_calc():\n    assert calculate() == 42\n' > "$REPO_AE/tests/test_calc.py"
git -C "$REPO_AE" -c user.email=t@t -c user.name=t add tests/test_calc.py
git -C "$REPO_AE" -c user.email=t@t -c user.name=t commit -q -m "initial tests"
printf 'Update tests in tests/test_calc.py\n' > "$REPO_AE/brief.md"

OUT_AE="$(STUB_ACTION='printf "def test_calc():\n    assert True\n" > tests/test_calc.py' run_phase "$REPO_AE" "$REPO_AE" 2>/dev/null)"; RC_AE=$?
check ae-weakened-fails-rc "$RC_AE" 3 "dispatch with weakened assertion fails with exit 3"
case "$OUT_AE" in
  *"DIFF_TESTS_WEAKENED"*) ok ae-weakened-status "status line names DIFF_TESTS_WEAKENED" ;;
  *) bad ae-weakened-status "DIFF_TESTS_WEAKENED missing from status: $OUT_AE" ;;
esac

# af. a worker that changes nothing surprising passes and line says check ran
REPO_AF="$(new_repo af-clean-passes)"
mkdir -p "$REPO_AF/src" "$REPO_AF/tests"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_AF/src/calc.py"
printf 'def test_add():\n    assert add(1, 2) == 3\n' > "$REPO_AF/tests/test_calc.py"
git -C "$REPO_AF" -c user.email=t@t -c user.name=t add .
git -C "$REPO_AF" -c user.email=t@t -c user.name=t commit -q -m "initial calc"
printf 'Add multiply in src/calc.py and tests in tests/test_calc.py\n' > "$REPO_AF/brief.md"

OUT_AF="$(STUB_ACTION='printf "def multiply(a, b):\n    return a * b\n" >> src/calc.py; printf "def test_multiply():\n    assert multiply(2, 3) == 6\n" >> tests/test_calc.py' run_phase "$REPO_AF" "$REPO_AF" 2>/dev/null)"; RC_AF=$?
check af-clean-passes-rc "$RC_AF" 0 "honest dispatch passes with exit 0"
case "$OUT_AF" in
  *"Integrity: DIFF_CLEAN"*) ok af-clean-status "status line reports Integrity: DIFF_CLEAN" ;;
  *) bad af-clean-status "Integrity: DIFF_CLEAN missing from status: $OUT_AF" ;;
esac

# ag. dirty tree beforehand: attributes only worker's changes, not pre-existing edits
REPO_AG="$(new_repo ag-dirty-tree-no-creep)"
mkdir -p "$REPO_AG/src" "$REPO_AG/tests"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_AG/src/calc.py"
printf 'def test_add():\n    assert add(1, 2) == 3\n' > "$REPO_AG/tests/test_calc.py"
printf 'def unrelated():\n    return "unrelated"\n' > "$REPO_AG/src/unrelated.py"
git -C "$REPO_AG" -c user.email=t@t -c user.name=t add .
git -C "$REPO_AG" -c user.email=t@t -c user.name=t commit -q -m "initial repo"

# Pre-existing uncommitted edits in unrelated files (not in brief)
printf 'def extra_unrelated():\n    pass\n' >> "$REPO_AG/src/unrelated.py"
printf 'notes\n' > "$REPO_AG/untracked_note.txt"

# Brief only mentions src/calc.py and tests/test_calc.py
printf 'Implement multiply in src/calc.py and test in tests/test_calc.py\n' > "$REPO_AG/brief.md"

OUT_AG="$(STUB_ACTION='printf "def multiply(a, b):\n    return a * b\n" >> src/calc.py; printf "def test_multiply():\n    assert multiply(2, 3) == 6\n" >> tests/test_calc.py' run_phase "$REPO_AG" "$REPO_AG" 2>/dev/null)"; RC_AG=$?
check ag-dirty-tree-rc "$RC_AG" 0 "dispatch with pre-existing dirty tree exits 0"
case "$OUT_AG" in
  *"Integrity: DIFF_CLEAN"*) ok ag-dirty-tree-clean "diff check sees only worker changes (DIFF_CLEAN)" ;;
  *) bad ag-dirty-tree-clean "status did not report DIFF_CLEAN on dirty tree: $OUT_AG" ;;
esac
case "$OUT_AG" in
  *scope:*|*unrelated.py*) bad ag-dirty-tree-no-creep "pre-existing edits falsely reported as scope creep: $OUT_AG" ;;
  *) ok ag-dirty-tree-no-creep "pre-existing edits not reported as scope creep" ;;
esac

# ah. pre-existing edits in a file the worker also edits still yield only worker's part
REPO_AH="$(new_repo ah-dirty-same-file)"
mkdir -p "$REPO_AH/src" "$REPO_AH/tests"
printf '# Module header line 1\n# Module header line 2\ndef add(a, b):\n    return a + b\n' > "$REPO_AH/src/calc.py"
printf 'def test_add():\n    assert add(1, 2) == 3\n' > "$REPO_AH/tests/test_calc.py"
git -C "$REPO_AH" -c user.email=t@t -c user.name=t add .
git -C "$REPO_AH" -c user.email=t@t -c user.name=t commit -q -m "initial calc"

# Pre-existing edit to the top of src/calc.py
printf '# Module header line 1 EDITED\n# Module header line 2\ndef add(a, b):\n    return a + b\n' > "$REPO_AH/src/calc.py"

printf 'Add sub function in src/calc.py and test in tests/test_calc.py\n' > "$REPO_AH/brief.md"

OUT_AH="$(STUB_ACTION='printf "def sub(a, b):\n    return a - b\n" >> src/calc.py; printf "def test_sub():\n    assert sub(3, 1) == 2\n" >> tests/test_calc.py' run_phase "$REPO_AH" "$REPO_AH" 2>/dev/null)"; RC_AH=$?
check ah-dirty-same-file-rc "$RC_AH" 0 "dispatch with same-file pre-existing edit exits 0"
case "$OUT_AH" in
  *"Integrity: DIFF_CLEAN"*) ok ah-dirty-same-file-clean "status reports Integrity: DIFF_CLEAN" ;;
  *) bad ah-dirty-same-file-clean "status did not report DIFF_CLEAN: $OUT_AH" ;;
esac

RUN_ID_AH="$(cat "$REPO_AH/.agy/current")"
DISPATCH_PATCH_AH="$REPO_AH/.agy/runs/$RUN_ID_AH/phases/TEST/DISPATCH_DIFF.patch"
if [ -f "$DISPATCH_PATCH_AH" ]; then
  if grep -q "EDITED" "$DISPATCH_PATCH_AH"; then
    bad ah-dirty-same-file-patch "pre-existing edit in same file leaked into dispatch patch"
  else
    ok ah-dirty-same-file-patch "dispatch patch contains only worker edits to the shared file"
  fi
else
  bad ah-dirty-same-file-patch "dispatch patch not found at $DISPATCH_PATCH_AH"
fi

# ai. review diff is not disturbed by dispatch diff capture
REPO_AI="$(new_repo ai-review-diff-untouched)"
RUN_ID_AI="$(run_dir_new --dir "$REPO_AI" --task "review diff preservation")"
mkdir -p "$REPO_AI/.agy/runs/$RUN_ID_AI"
SENTINEL_DIFF="SENTINEL_REVIEW_DIFF_CONTENT_12345"
printf '%s\n' "$SENTINEL_DIFF" > "$REPO_AI/.agy/runs/$RUN_ID_AI/REVIEW_DIFF.patch"

run_phase "$REPO_AI" "$REPO_AI" --run "$RUN_ID_AI" >/dev/null 2>&1
RC_AI=$?
check ai-review-diff-rc "$RC_AI" 0 "dispatch completes with exit 0"
check ai-review-diff-preserved "$(cat "$REPO_AI/.agy/runs/$RUN_ID_AI/REVIEW_DIFF.patch" 2>/dev/null)" \
  "$SENTINEL_DIFF" "REVIEW_DIFF.patch is preserved byte-for-byte and not overwritten"

# aj. opt-out flag (--no-diff-integrity) and env var (AGY_SKIP_DIFF_INTEGRITY) skip check
REPO_AJ="$(new_repo aj-opt-out)"
mkdir -p "$REPO_AJ/tests"
printf 'def test_calc():\n    assert calculate() == 42\n' > "$REPO_AJ/tests/test_calc.py"
git -C "$REPO_AJ" -c user.email=t@t -c user.name=t add tests/test_calc.py
git -C "$REPO_AJ" -c user.email=t@t -c user.name=t commit -q -m "initial test"
printf 'Update tests in tests/test_calc.py\n' > "$REPO_AJ/brief.md"

# 1. With --no-diff-integrity flag
OUT_AJ1="$(STUB_ACTION='printf "def test_calc():\n    assert True\n" > tests/test_calc.py' run_phase "$REPO_AJ" "$REPO_AJ" --no-diff-integrity 2>/dev/null)"; RC_AJ1=$?
check aj-opt-out-flag-rc "$RC_AJ1" 0 "--no-diff-integrity skips check and exits 0"
case "$OUT_AJ1" in
  *"Integrity: skipped"*) ok aj-opt-out-flag-status "status line explicitly says Integrity: skipped" ;;
  *) bad aj-opt-out-flag-status "Integrity: skipped missing from status line: $OUT_AJ1" ;;
esac

# 2. With AGY_SKIP_DIFF_INTEGRITY environment variable
OUT_AJ2="$(AGY_SKIP_DIFF_INTEGRITY=1 STUB_ACTION='printf "def test_calc():\n    assert True\n" > tests/test_calc.py' run_phase "$REPO_AJ" "$REPO_AJ" 2>/dev/null)"; RC_AJ2=$?
check aj-opt-out-env-rc "$RC_AJ2" 0 "AGY_SKIP_DIFF_INTEGRITY=1 skips check and exits 0"
case "$OUT_AJ2" in
  *"Integrity: skipped"*) ok aj-opt-out-env-status "status line explicitly says Integrity: skipped" ;;
  *) bad aj-opt-out-env-status "Integrity: skipped missing from status line: $OUT_AJ2" ;;
esac

# ak. case where check cannot run reports DIFF_UNCHECKED and is not treated as pass
REPO_AK="$(new_repo ak-diff-unchecked)"
printf 'Update ruby script in app.rb\n' > "$REPO_AK/brief.md"

OUT_AK="$(STUB_ACTION='printf "def foo; end\n" > app.rb' run_phase "$REPO_AK" "$REPO_AK" 2>/dev/null)"; RC_AK=$?
check ak-diff-unchecked-rc "$RC_AK" 0 "dispatch on unsupported language exits 0"
case "$OUT_AK" in
  *"DIFF_UNCHECKED"*) ok ak-diff-unchecked-status "status line reports DIFF_UNCHECKED" ;;
  *) bad ak-diff-unchecked-status "DIFF_UNCHECKED missing from status: $OUT_AK" ;;
esac
case "$OUT_AK" in
  *"DIFF_CLEAN"*) bad ak-diff-unchecked-not-pass "DIFF_UNCHECKED must not read as DIFF_CLEAN" ;;
  *) ok ak-diff-unchecked-not-pass "DIFF_UNCHECKED is not treated as clean pass" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1


