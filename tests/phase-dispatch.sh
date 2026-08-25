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

. "$RUN_DIR_SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase-dispatch.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

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
[ -n "${STUB_ARGV:-}" ] && printf '%s\n' "$@" > "$STUB_ARGV"
if [ -n "${STUB_MUTATE_SCRIPT:-}" ] && [ -f "$STUB_MUTATE_SCRIPT" ]; then
  printf '\nthis is a syntax error that would kill bash if executed mid-run: (\n' >> "$STUB_MUTATE_SCRIPT"
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
  STUB_PHASE=TEST STUB_ARGV="${STUB_ARGV_FILE:-}" AGY_BIN="$STUB" \
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
RUN2_DIR="$REPO/.agy/runs/$RUN2_ID/phases/TEST"

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

case "$(cat "$STDERR_T" 2>/dev/null)" in
  *"phase.sh: re-executing from snapshot"*) ok t-self-snapshot-stderr "re-execution diagnostic printed on stderr" ;;
  *) bad t-self-snapshot-stderr "re-execution diagnostic missing from stderr" ;;
esac

# Check that the script file was indeed mutated
case "$(tail -1 "$REPO_T/scripts/phase.sh" 2>/dev/null)" in
  *"syntax error"*) ok t-self-snapshot-mutated "target script was mutated by worker mid-run" ;;
  *) bad t-self-snapshot-mutated "target script was not mutated" ;;
esac

# Check that the temporary snapshot directory was removed on exit
SNAP_DIR_T="$(sed -n 's/.*phase\.sh: re-executing from snapshot \([^[:space:]]*\).*/\1/p' "$STDERR_T" 2>/dev/null)"
if [ -n "$SNAP_DIR_T" ] && [ ! -d "$SNAP_DIR_T" ]; then
  ok t-self-snapshot-cleanup "snapshot directory cleaned up on exit"
else
  bad t-self-snapshot-cleanup "snapshot directory still exists: $SNAP_DIR_T"
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

