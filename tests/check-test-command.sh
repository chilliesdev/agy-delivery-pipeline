#!/usr/bin/env bash
# Exercise check-test-command.sh — above all the distinction it exists to draw,
# between a test command that is wrong and a test command that is right about a
# red suite.
#
#   tests/check-test-command.sh
#
# Every case runs a real command in a throwaway repo under ${TMPDIR:-/tmp}; the
# commands are echo/exit one-liners impersonating the runners, so nothing is
# installed and nothing is written inside this repo. Prints one line per case and
# exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-test-command.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
[ -f "$CHECK" ] || { echo "check-test-command-test: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "check-test-command-test: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-test-command.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

export AGY_FLEET="$ROOT/fleet"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-30s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-30s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# new_repo <name> — a throwaway git directory with run initialized; echoes its path.
new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q . )
  run_dir_new --dir "$R" --task "test-cmd $1" >/dev/null
  printf '%s' "$R"
}

pdir() {
  local repo="$1"
  local id
  id="$(cat "$repo/.agy/current" 2>/dev/null || true)"
  [ -n "$id" ] && printf '%s/.agy/runs/%s' "$repo" "$id"
}

# run <repo> [args...] — stdout into $OUT, stderr into $ERR, exit code into
# $CODE. The two streams are kept apart on purpose: the STATUS line owns stdout.
run() {
  RR="$1"; shift
  /bin/bash "$CHECK" --dir "$RR" "$@" > "$ROOT/out" 2> "$ROOT/err"
  CODE=$?
  OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
}

# The verdict word — second field of the STATUS line, brackets and all.
verdict() { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }

# Canned runner output. The red suite prints what jest prints, because that is
# the case most easily mistaken for a broken command.
RED_SUITE='echo "FAIL src/thing.test.js"; echo "  ● adds two numbers"; echo "Tests:       1 failed, 2 passed, 3 total"; exit 1'
MISSING_SCRIPT='echo "npm ERR! Missing script: \"test\"" >&2; echo "npm ERR! To see a list of scripts, run: npm run" >&2; exit 1'

# 1. a command that works.
R="$(new_repo ok)"
run "$R" --command 'echo running suite; exit 0'
check ok-rc "$CODE" 0 "exit 0 when the command succeeds"
check ok-status "$(verdict "$OUT")" "TEST_COMMAND_OK" "reported as OK"

# 2. a command that does not exist: 127, and it is the command that is wrong.
R="$(new_repo not-found)"
run "$R" --command 'definitely-not-a-real-binary-xyz --ci'
check not-found-rc "$CODE" 3 "exit 3 when the shell cannot find the command"
check not-found-status "$(verdict "$OUT")" "TEST_COMMAND_NOT_RUNNABLE(rc=127)" \
  "127 reported as a wrong command"
case "$OUT" in *"nothing ran"*) ok not-found-why "the line says nothing ran" ;;
  *) bad not-found-why "no reason given: $OUT" ;; esac

# 3. the case this script exists for: the command is right, the suite is red.
R="$(new_repo red-suite)"
run "$R" --command "$RED_SUITE"
check red-rc "$CODE" 4 "exit 4 when the tests fail"
check red-status "$(verdict "$OUT")" "TEST_COMMAND_FAILED(rc=1)" \
  "a red suite is a failure, not a wrong command"
case "$(verdict "$OUT")" in TEST_COMMAND_NOT_RUNNABLE*)
    bad red-not-misfiled "a red suite was blamed on the command" ;;
  *) ok red-not-misfiled "the command is not blamed for failing tests" ;; esac

# 3b. a red suite whose own output contains a phrase the rejection list matches.
# Evidence that a runner ran has to outrank the wording, or every ENOENT
# assertion message would be read as a missing binary.
R="$(new_repo red-suite-noisy)"
run "$R" --command 'echo "Error: ENOENT: no such file or directory, open '\''fixtures/a.json'\''"; echo "Tests:       1 failed, 0 passed, 1 total"; exit 1'
check red-noisy "$(verdict "$OUT")" "TEST_COMMAND_FAILED(rc=1)" \
  "runner evidence outranks a matching rejection phrase"

# 4. a package manager that has no such script — refused before any test ran.
R="$(new_repo missing-script)"
run "$R" --command "$MISSING_SCRIPT"
check missing-script-rc "$CODE" 3 "exit 3 when the runner refuses the command"
check missing-script-status "$(verdict "$OUT")" "TEST_COMMAND_NOT_RUNNABLE(rc=1)" \
  "'Missing script' reported as a wrong command"

# 5. non-zero with nothing recognisable either way: called a failure, but the
# line must admit the evidence was thin rather than claim the command is good.
R="$(new_repo silent-failure)"
run "$R" --command 'exit 1'
check silent-rc "$CODE" 4 "exit 4 when nothing is provable"
case "$OUT" in *"no runner output recognised"*)
    ok silent-honest "the uncertainty is stated in the line" ;;
  *) bad silent-honest "the line overclaimed: $OUT" ;; esac

# 6. the command comes from TEST_COMMAND in the run directory, which is the whole point of
# Phase 0 writing it there.
R="$(new_repo from-file)"
printf 'echo from-the-file; exit 0\n' > "$(pdir "$R")/TEST_COMMAND"
run "$R"
check from-file-rc "$CODE" 0 "exit 0 reading the command from TEST_COMMAND"
case "$OUT" in *"Command: echo from-the-file; exit 0"*)
    ok from-file-echo "the line names the command it read" ;;
  *) bad from-file-echo "command not echoed back: $OUT" ;; esac

# 6b. discovery is a language model, so the file may arrive fenced or in
# backticks. The command still has to come out clean.
R="$(new_repo from-file-fenced)"
printf '```\n  `echo fenced; exit 0`  \n```\n' > "$(pdir "$R")/TEST_COMMAND"
run "$R"
check fenced-rc "$CODE" 0 "a fenced, backticked command still runs"
case "$OUT" in *"Command: echo fenced; exit 0"*)
    ok fenced-clean "fence and backticks stripped" ;;
  *) bad fenced-clean "decoration survived: $OUT" ;; esac

# 7. --command wins over the file — the orchestrator correcting a wrong guess.
R="$(new_repo override)"
printf 'definitely-not-a-real-binary-xyz\n' > "$(pdir "$R")/TEST_COMMAND"
run "$R" --command 'echo corrected; exit 0'
check override-rc "$CODE" 0 "--command overrides the file"
case "$OUT" in *"Command: echo corrected; exit 0"*)
    ok override-used "the flag's command is the one that ran" ;;
  *) bad override-used "the file won: $OUT" ;; esac

# 8. neither present: a usage error, and not a STATUS line pretending to be one.
R="$(new_repo no-command)"
run "$R"
check no-command-rc "$CODE" 2 "exit 2 with no command anywhere"
check no-command-stdout "$OUT" "" "nothing on stdout"
case "$ERR" in *TEST_COMMAND*) ok no-command-msg "the error names TEST_COMMAND" ;;
  *) bad no-command-msg "unhelpful error: $ERR" ;; esac

# 8b. the file is there but empty — same class, its own message.
R="$(new_repo empty-file)"
: > "$(pdir "$R")/TEST_COMMAND"
run "$R"
check empty-file-rc "$CODE" 2 "exit 2 when the file holds no command"

# 9. stdout is exactly one line however loud the command is, and the output
# lands in the log instead. The noise is read from files rather than echoed
# inline, so that finding it on stdout means it leaked out of the command and
# not out of the STATUS line's own `Command:` field.
R="$(new_repo quiet)"
printf 'leakmarker-out\n' > "$R/out.txt"
printf 'leakmarker-err\n' > "$R/err.txt"
run "$R" --command 'cat out.txt; cat err.txt >&2; exit 0'
check stdout-lines "$(printf '%s\n' "$OUT" | grep -c .)" 1 "stdout is one line"
case "$OUT" in *leakmarker*) bad stdout-clean "command output leaked to stdout" ;;
  *) ok stdout-clean "command output stayed out of stdout" ;; esac
case "$(cat "$(pdir "$R")/TEST_COMMAND.log" 2>/dev/null)" in *leakmarker-out*leakmarker-err*)
    ok log-has-both "both streams landed in the log" ;;
  *) bad log-has-both "the log is missing the command's output" ;; esac

# 10. the command runs in --dir, through a shell, so && and pipelines work.
R="$(new_repo shell)"
printf 'marker\n' > "$R/here.txt"
run "$R" --command 'test -f here.txt && grep -q marker here.txt'
check shell-rc "$CODE" 0 "runs in --dir through a shell"

# 11. a command that never returns is killed, and the whole pipeline with it —
# `sleep … | cat` orphans its sleep unless the process group goes.
R="$(new_repo hang)"
run "$R" --command 'sleep 4783 | cat' --timeout 1
check hang-rc "$CODE" 5 "exit 5 when the command hangs"
check hang-status "$(verdict "$OUT")" "TEST_COMMAND_TIMEOUT(1s)" "reported as a timeout"
sleep 1
LEFT="$(pgrep -f 'sleep 4783' 2>/dev/null | grep -c .)"
check hang-no-orphan "${LEFT:-0}" "0" "the whole process group was killed"

# 12. --timeout 0 means no limit at all, and a bad value is a usage error.
R="$(new_repo timeout-args)"
run "$R" --command 'exit 0' --timeout 0
check timeout-zero "$CODE" 0 "--timeout 0 disables the limit"
run "$R" --command 'exit 0' --timeout 2m
check timeout-suffix "$CODE" 0 "--timeout accepts an m suffix"
run "$R" --command 'exit 0' --timeout soon
check timeout-junk "$CODE" 2 "exit 2 on a non-numeric timeout"

# 13. a bad argument is a usage error, as in every other script here.
R="$(new_repo bad-arg)"
run "$R" --bogus
check bad-arg "$CODE" 2 "exit 2 on an unknown argument"

# 14. a refusal reaches the ledger, and a pass does not.
#
# This gate runs in the orchestrator's hands rather than a dispatch's, so
# nothing else records it. Counted at zero, report.sh calls it dead code.

R="$(new_repo ledger-failed)"
run "$R" --command 'echo "1 failing"; exit 1'
LG="$R/.agy/ledger.jsonl"
if [ -f "$LG" ] && grep -q '"status":"TEST_COMMAND_FAILED' "$LG"; then
  ok ledger-failed-recorded "a red suite is recorded in the run ledger"
else
  bad ledger-failed-recorded "no TEST_COMMAND_FAILED record: $(cat "$LG" 2>/dev/null)"
fi
if grep -q '"dispatched":false' "$LG" 2>/dev/null; then
  ok ledger-failed-not-dispatch "the record says no worker ran"
else
  bad ledger-failed-not-dispatch "record missing dispatched=false: $(cat "$LG" 2>/dev/null)"
fi

R="$(new_repo ledger-not-runnable)"
run "$R" --command 'definitely-not-a-real-binary-xyz'
LG="$R/.agy/ledger.jsonl"
if grep -q '"status":"TEST_COMMAND_NOT_RUNNABLE' "$LG" 2>/dev/null; then
  ok ledger-not-runnable-recorded "a wrong command is recorded separately from a red suite"
else
  bad ledger-not-runnable-recorded "no TEST_COMMAND_NOT_RUNNABLE record: $(cat "$LG" 2>/dev/null)"
fi

R="$(new_repo ledger-ok)"
run "$R" --command 'echo "1 passing"; exit 0'
if [ -s "$R/.agy/ledger.jsonl" ]; then
  bad ledger-ok-not-recorded "TEST_COMMAND_OK wrote a record: $(cat "$R/.agy/ledger.jsonl")"
else
  ok ledger-ok-not-recorded "a command that worked writes nothing — the ledger records events, not checks"
fi

R="$(new_repo ledger-skip)"
AGY_SKIP_LEDGER=1 /bin/bash "$CHECK" --dir "$R" --command 'exit 1' >/dev/null 2>&1
if [ -s "$R/.agy/ledger.jsonl" ]; then
  bad ledger-skip "AGY_SKIP_LEDGER=1 still wrote: $(cat "$R/.agy/ledger.jsonl")"
else
  ok ledger-skip "AGY_SKIP_LEDGER=1 keeps the checker read-only"
fi

# Recording must never change the answer.
R="$(new_repo ledger-readonly)"
chmod 500 "$R/.agy"
run "$R" --command 'echo "1 failing"; exit 1'
chmod 700 "$R/.agy"
check ledger-readonly-rc "$CODE" 4 "an unwritable ledger does not change the exit code"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
