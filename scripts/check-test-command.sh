#!/usr/bin/env bash
# Run the test command Phase 0 reported, and say whether it actually works.
#
#   check-test-command.sh [--dir <repo>] [--run <id|current|last>]
#                         [--command '<cmd>'] [--timeout <n>]
#
# Reads:   <run-dir>/TEST_COMMAND       the bare command discovery wrote, one line
# Writes:  <run-dir>/TEST_COMMAND.log   the command's own output
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes, one per outcome:
#     0  TEST_COMMAND_OK            it ran and exited zero
#     2  bad arguments, or no command to check
#     3  TEST_COMMAND_NOT_RUNNABLE  the command is wrong — discovery guessed
#     4  TEST_COMMAND_FAILED        the command is right and the suite is red
#     5  TEST_COMMAND_TIMEOUT       it never finished (usually a watch mode)
#
# Discovery reports the test command by *reading* package.json or a CI config,
# because a worker in accept-edits that tries to run it dies on the denial. So
# the command reaching Phase 1 is unverified prose until something runs it. This
# is that something, and it deliberately mirrors phase.sh's --verify: the command
# runs in <repo> through a shell so `&&` and pipelines work, its output goes to a
# log, and the result comes back as one STATUS line. The command this blesses is
# the one later phases hand to `phase.sh --verify`.
#
# 3 vs 4 — the distinction this whole script exists for. "npm test is not the
# command" and "npm test is the command and the tests are red" are different
# problems with different fixes, and only the first is discovery's mistake. The
# classifier, in order:
#
#   1. rc 127 or 126 is conclusive: the shell could not find the command, or
#      found it and could not execute it. Nothing ran.
#   2. Otherwise, positive evidence that a test runner produced results —
#      "Tests: 1 failed", "test result:", "collected 7 items", a TAP or go-test
#      line — settles it as a red suite. Evidence that something ran outranks
#      any wording below, because runners print all sorts of things.
#   3. Otherwise, a runner-rejection marker near the top of the output —
#      "Missing script:", "Unknown command", "command not found", a usage line —
#      means the command was refused before any test ran.
#   4. Otherwise: nothing proved either way. Reported as FAILED, since a
#      non-zero exit from a command that produced no recognisable complaint is
#      more often a red suite, but the STATUS line says the evidence was thin
#      instead of pretending otherwise.
#
# Where that is uncertain, honestly: step 3 is string matching against other
# people's error prose, so a test whose *own* output contains "no such file or
# directory" or prints a usage banner can be misread as a bad command — step 2
# is what usually saves it, and it only saves it if the runner printed something
# recognisable first. A runner not in the pattern list that fails cleanly lands
# in step 4. Both mistakes are visible: the log is right there, and the STATUS
# line names what matched.
#
# .agy/ is not added to .gitignore here — phase.sh does that on its first
# dispatch, which is Phase 0, which is always before this runs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"; COMMAND=""; COMMAND_GIVEN=""; TIMEOUT="600"
RUN_TARGET="current"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="$2";     shift 2 ;;
    --run)     RUN_TARGET="$2"; shift 2 ;;
    --command) COMMAND="$2"; COMMAND_GIVEN=1; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
    *) echo "check-test-command: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -d "$DIR" ] || { echo "check-test-command: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

# --timeout takes seconds, or the same number with an s or m suffix. 0 disables
# the limit entirely, for a suite that is genuinely slower than any default.
case "$TIMEOUT" in
  *m) LIMIT="${TIMEOUT%m}"; MULT=60 ;;
  *s) LIMIT="${TIMEOUT%s}"; MULT=1 ;;
  *)  LIMIT="$TIMEOUT";     MULT=1 ;;
esac
case "$LIMIT" in
  ''|*[!0-9]*) echo "check-test-command: --timeout wants seconds (or 30s / 5m), got '$TIMEOUT'" >&2; exit 2 ;;
esac
LIMIT=$((LIMIT * MULT))

R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET")" || exit $?

CMD_FILE="$R/TEST_COMMAND"

# Default to what Phase 0 wrote. The file is meant to hold the bare command and
# nothing else, but discovery is a language model: take the first line with
# anything on it, skip a markdown fence if it wrapped one round the command, and
# strip surrounding whitespace and backticks.
if [ -z "$COMMAND_GIVEN" ] && [ -f "$CMD_FILE" ]; then
  COMMAND="$(awk '
    /^[[:space:]]*```/ { next }
    NF { print; exit }
  ' "$CMD_FILE" 2>/dev/null | sed -e 's/^[[:space:]`]*//' -e 's/[[:space:]`]*$//')"
fi

if [ -z "$COMMAND" ]; then
  if [ -n "$COMMAND_GIVEN" ]; then
    echo "check-test-command: --command was empty" >&2
  elif [ -f "$CMD_FILE" ]; then
    echo "check-test-command: $CMD_FILE holds no command" >&2
  else
    echo "check-test-command: no command to check." >&2
    echo "check-test-command: pass --command '<cmd>', or have Phase 0's brief write the" >&2
    echo "check-test-command: bare test command, one line, to $CMD_FILE" >&2
  fi
  exit 2
fi

LOG="$R/TEST_COMMAND.log"

# Same header shape phase.sh writes for --verify, so the two logs read alike.
# Exactly two lines: the classifier reads from line 3 on, and must not scan the
# command text back in as if the command had printed it.
printf -- '--- check-test-command: %s ---\n$ %s\n' "$DIR" "$COMMAND" > "$LOG" 2>/dev/null

# A hung suite is a real outcome, not a hypothetical: `npm test` wired to a
# watch mode never returns, and blocking the orchestrator on it forever is worse
# than any of the failures above.
#
# The watchdog is hand-rolled here and in preflight.sh rather than using
# timeout(1). macOS ships no timeout(1) and no gtimeout(1), so a timeout-based
# path could only ever be the second implementation, never the only one. Two
# implementations of a timeout means the platform that runs in CI most often
# is not the platform most users are on, and the less-travelled branch is the
# one that breaks. This repo has already been bitten by a rarely-taken branch —
# the release phase's first-version path — and by a workaround that existed
# only in prose. Furthermore, the hand-rolled watchdog does something timeout(1)
# does not: `set -m` gives the job its own process group, which is what makes a
# pipeline killable as a whole rather than leaving `sleep 30 | cat` orphaned.
# The watchdog TERMs that whole group, then KILLs it, and marks that it fired.
# The cost is that process-group semantics differ across platforms — which is
# precisely why it now runs on both in CI on every push.
MARKER="$R/TEST_COMMAND.timeout"
rm -f "$MARKER"
START=$(date +%s)

set -m
( cd "$DIR" && exec /bin/bash -c "$COMMAND" ) >> "$LOG" 2>&1 &
CMD_PID=$!
set +m

WATCH_PID=""
if [ "$LIMIT" -gt 0 ]; then
  ( sleep "$LIMIT"
    printf 'fired\n' > "$MARKER" 2>/dev/null
    kill -TERM -"$CMD_PID" 2>/dev/null || kill -TERM "$CMD_PID" 2>/dev/null
    sleep 2
    kill -KILL -"$CMD_PID" 2>/dev/null ) >/dev/null 2>&1 &
  WATCH_PID=$!
fi

# Braced so the shell's own "Terminated: 15" job notice — job control is on for
# the command above — cannot reach stderr and be mistaken for the command's.
{ wait "$CMD_PID"; RC=$?; } 2>/dev/null
if [ -n "$WATCH_PID" ]; then
  kill "$WATCH_PID" 2>/dev/null
  { wait "$WATCH_PID"; } 2>/dev/null
fi
ELAPSED=$(( $(date +%s) - START ))

TIMED_OUT=0
[ -f "$MARKER" ] && TIMED_OUT=1
rm -f "$MARKER"

# Output a test runner produces when it has actually run something. Deliberately
# broad — jest/vitest tallies, cargo, go test, TAP, pytest, unittest, rspec,
# mocha, JUnit — because this is the pattern that rescues a red suite from being
# misfiled as a bad command.
RAN_EVIDENCE="[0-9]+ (test|tests|spec|specs|example|examples|assertion|assertions|passed|failed|passing|failing|pending|skipped|error|errors|failure|failures)\
|(tests|specs|suites|failures|assertions|examples)[[:space:]]*[:=][[:space:]]*[0-9]\
|test result:|collected [0-9]+ item|ran [0-9]+ test|OK \\([0-9]|FAILED \\((failures|errors)=\
|^(FAIL|PASS|ok|not ok|--- FAIL|--- PASS|=== RUN)[[:space:]]\
|assertionerror|assertion failed|expected .* (to|but) |^[[:space:]]*[0-9]+\\) "

# What a runner says when it never got as far as running anything: the shell
# could not resolve the command, the package manager has no such script, or the
# tool printed its usage and gave up.
REJECT_MARKER="command not found|: not found|no such file or directory\
|missing script|err_pnpm_no_script|command \".*\" not found\
|unknown command|unrecognized command|no such command|is not a .* command\
|no rule to make target|task '.*' not found\
|no module named|can't open file|couldn't find|could not find or load main class\
|unrecognized (option|argument)|unknown (option|argument)|invalid (choice|option)\
|executable file not found|^[[:space:]]*usage:"

# How much the command printed, header excluded and footer not yet appended.
BODY_LINES="$(tail -n +3 "$LOG" 2>/dev/null | wc -l | tr -cd '0-9')"
BODY_LINES="${BODY_LINES:-0}"

# A refusal is short and arrives at once, so the top of the output is where it
# lives; a red suite is long, and scanning all of it would invite every false
# positive its failure text can offer. Short outputs are scanned whole.
if [ "$BODY_LINES" -le 40 ]; then SCAN=$BODY_LINES; else SCAN=10; fi
[ "$SCAN" -lt 1 ] && SCAN=1

matched() { tail -n +3 "$LOG" 2>/dev/null | head -n "$SCAN" | grep -a -E -i -q -- "$1"; }
ran_anything() { tail -n +3 "$LOG" 2>/dev/null | grep -a -E -i -q -- "$RAN_EVIDENCE"; }

if [ "$TIMED_OUT" -eq 1 ]; then
  LINE="STATUS: TEST_COMMAND_TIMEOUT(${LIMIT}s) | Command: $COMMAND | Note: it never returned — a test command wired to a watch mode is the usual cause; correct it to the one-shot form | Log: $LOG"
  CODE=5
elif [ "$RC" -eq 0 ]; then
  LINE="STATUS: TEST_COMMAND_OK | Command: $COMMAND | Elapsed: ${ELAPSED}s | Log: $LOG"
  CODE=0
elif [ "$RC" -eq 127 ] || [ "$RC" -eq 126 ]; then
  case "$RC" in
    127) WHY="the shell could not find it" ;;
    126) WHY="found but not executable" ;;
  esac
  LINE="STATUS: TEST_COMMAND_NOT_RUNNABLE(rc=$RC) | Command: $COMMAND | Reason: $WHY — nothing ran, so this is the command, not the tests | Log: $LOG"
  CODE=3
elif ran_anything; then
  LINE="STATUS: TEST_COMMAND_FAILED(rc=$RC) | Command: $COMMAND | Tests: the runner ran and reported results — the command is right and the suite is red | Log: $LOG"
  CODE=4
elif matched "$REJECT_MARKER"; then
  LINE="STATUS: TEST_COMMAND_NOT_RUNNABLE(rc=$RC) | Command: $COMMAND | Reason: the runner refused the command before any test ran — see the first lines of the log | Log: $LOG"
  CODE=3
else
  LINE="STATUS: TEST_COMMAND_FAILED(rc=$RC) | Command: $COMMAND | Tests: no runner output recognised, so read the log — probably a red suite, but nothing proves the command itself is right | Log: $LOG"
  CODE=4
fi

# Appended only now: the classifier reads the log, and the footer is not
# something the command said.
printf -- '--- check-test-command: rc=%s elapsed=%ss verdict=%s ---\n' \
  "$RC" "$ELAPSED" "$CODE" >> "$LOG" 2>/dev/null

printf '%s\n' "$LINE"
exit "$CODE"
