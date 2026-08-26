#!/usr/bin/env bash
# Exercise run-dir.sh: run creation, tree layout, run.json serialization and
# retrieval, phase recording and merging, resolution, and CLI operations.
#
#   tests/run-dir.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR_SCRIPT="$HERE/../scripts/run-dir.sh"
[ -f "$RUN_DIR_SCRIPT" ] || { echo "run-dir-test: script not found next door" >&2; exit 2; }

# Source helper for function-level testing
# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SCRIPT"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/run-dir-test.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() {
  local r="$ROOT/repos/$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  printf '%s' "$r"
}

# --- 1. new run creates tree and pointers ----------------------------------

R="$(new_repo new-run)"
RUN_ID="$(run_dir_new --dir "$R" --task "first task")"
RUN_ID_FMT=bad
case "$RUN_ID" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) RUN_ID_FMT=ok ;;
esac
check new-run-id-format "$RUN_ID_FMT" "ok" "run id matches format"

RUN_PATH="$R/.agy/runs/$RUN_ID"
[ -d "$RUN_PATH" ] && ok new-run-dir-exists "run directory exists" || bad new-run-dir-exists "missing run directory"
[ -d "$RUN_PATH/phases" ] && ok new-run-phases-dir "phases directory exists" || bad new-run-phases-dir "missing phases directory"
[ -d "$RUN_PATH/criteria" ] && ok new-run-criteria-dir "criteria directory exists" || bad new-run-criteria-dir "missing criteria directory"
[ -f "$RUN_PATH/run.json" ] && ok new-run-json-exists "run.json exists" || bad new-run-json-exists "missing run.json"

check current-ptr "$(cat "$R/.agy/current" 2>/dev/null)" "$RUN_ID" "current pointer names new run"
check last-ptr "$(cat "$R/.agy/last" 2>/dev/null)" "$RUN_ID" "last pointer names new run"

# --- 2. multiple runs do not collide ---------------------------------------

RUN_ID_2="$(run_dir_new --dir "$R" --task "second task")"
[ "$RUN_ID" != "$RUN_ID_2" ] && ok run-ids-distinct "second run gets distinct id" || bad run-ids-distinct "run ids collided"
[ -d "$R/.agy/runs/$RUN_ID" ] && ok first-run-survives "first run directory survives" || bad first-run-survives "first run directory clobbered"
[ -d "$R/.agy/runs/$RUN_ID_2" ] && ok second-run-exists "second run directory created" || bad second-run-exists "second run missing"
check last-follows-newest "$(cat "$R/.agy/last" 2>/dev/null)" "$RUN_ID_2" "last pointer follows newest run"
check current-follows-newest "$(cat "$R/.agy/current" 2>/dev/null)" "$RUN_ID_2" "current pointer follows newest run"

# --- 3. runs minted in the same second get distinct ids --------------------

R_SAME="$(new_repo same-second)"
ID_A="$(run_dir_new --dir "$R_SAME" --task "run A")"
ID_B="$(run_dir_new --dir "$R_SAME" --task "run B")"
[ "$ID_A" != "$ID_B" ] && ok same-second-distinct "two runs in rapid succession get distinct ids" || bad same-second-distinct "same-second collision"

# --- 4. run_dir_resolve -----------------------------------------------------

RESOLVED_CURRENT="$(run_dir_resolve --dir "$R_SAME" --run current)"
check resolve-current "$RESOLVED_CURRENT" "$R_SAME/.agy/runs/$ID_B" "resolve current returns latest run"

RESOLVED_LAST="$(run_dir_resolve --dir "$R_SAME" --run last)"
check resolve-last "$RESOLVED_LAST" "$R_SAME/.agy/runs/$ID_B" "resolve last returns latest run"

RESOLVED_EXPLICIT="$(run_dir_resolve --dir "$R_SAME" --run "$ID_A")"
check resolve-explicit "$RESOLVED_EXPLICIT" "$R_SAME/.agy/runs/$ID_A" "resolve explicit id returns matching directory"

run_dir_resolve --dir "$R_SAME" --run "nonexistent-id" >/dev/null 2>&1 || CODE=$?
check resolve-nonexistent-rc "$CODE" 3 "resolve nonexistent id exits 3"
[ ! -e "$R_SAME/.agy/runs/nonexistent-id" ] && ok resolve-no-create "resolve does not create anything on failure" || bad resolve-no-create "created missing run"

# --- 5. run_dir_get round-trips all initial fields --------------------------

R_FIELDS="$(new_repo fields)"
GIT_SHA="$(cd "$R_FIELDS" && git rev-parse HEAD)"
GIT_BRANCH="$(cd "$R_FIELDS" && git rev-parse --abbrev-ref HEAD)"
ID_FIELDS="$(run_dir_new --dir "$R_FIELDS" --task "inspect fields" --base "$GIT_SHA" --branch "$GIT_BRANCH")"
DIR_FIELDS="$R_FIELDS/.agy/runs/$ID_FIELDS"

check get-run "$(run_dir_get "$DIR_FIELDS" "run")" "$ID_FIELDS" "round-trip run id"
check get-task "$(run_dir_get "$DIR_FIELDS" "task")" "inspect fields" "round-trip task"
check get-backend "$(run_dir_get "$DIR_FIELDS" "backend")" "agy" "backend is agy"
check get-branch "$(run_dir_get "$DIR_FIELDS" "branch")" "$GIT_BRANCH" "round-trip branch"
check get-base "$(run_dir_get "$DIR_FIELDS" "base")" "$GIT_SHA" "round-trip base sha"
STARTED_VAL="$(run_dir_get "$DIR_FIELDS" "started")"
STARTED_FMT=bad
case "$STARTED_VAL" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) STARTED_FMT=ok ;;
esac
check get-started-format "$STARTED_FMT" "ok" "started is ISO-8601 UTC"
check get-finished-empty "$(run_dir_get "$DIR_FIELDS" "finished")" "" "finished is initially empty"
check get-outcome-empty "$(run_dir_get "$DIR_FIELDS" "outcome")" "" "outcome is initially empty"

# --- 6. special characters in task survive verbatim ------------------------

R_SPEC="$(new_repo special-chars)"
SPECIAL_TASK='task with quotes "and" \backslashes\ and $vars and `backticks`'
ID_SPEC="$(run_dir_new --dir "$R_SPEC" --task "$SPECIAL_TASK")"
DIR_SPEC="$R_SPEC/.agy/runs/$ID_SPEC"
check special-task-get "$(run_dir_get "$DIR_SPEC" "task")" "$SPECIAL_TASK" "special characters survive round-trip verbatim"

# Assert raw run.json contains backslash-escaped quotes for task string
R_QUOTE="$(new_repo quote-task)"
ID_QUOTE="$(run_dir_new --dir "$R_QUOTE" --task 'task with "quotes" here')"
DIR_QUOTE="$R_QUOTE/.agy/runs/$ID_QUOTE"
if grep -Fq '"task": "task with \"quotes\" here"' "$DIR_QUOTE/run.json"; then
  ok quote-escaped-in-json "task double quote is backslash-escaped in raw run.json"
else
  bad quote-escaped-in-json "task double quote not backslash-escaped in raw run.json"
fi

# --- 7. newline in task is refused -----------------------------------------

R_NL="$(new_repo newline-task)"
run_dir_new --dir "$R_NL" --task $'task line 1\ntask line 2' >/dev/null 2>&1 || CODE=$?
check newline-refused-rc "$CODE" 2 "refuses task containing newline with exit 2"

# --- 8. run_dir_record_phase merges without clobbering ---------------------

R_REC="$(new_repo record-phase)"
ID_REC="$(run_dir_new --dir "$R_REC" --task "record test")"
DIR_REC="$R_REC/.agy/runs/$ID_REC"

run_dir_record_phase "$DIR_REC" DISCOVERY status=DONE verdict=DONE attempts=1
check phase-status-1 "$(run_dir_get "$DIR_REC" "phases.DISCOVERY.status")" "DONE" "first record set status"
check phase-attempts-1 "$(run_dir_get "$DIR_REC" "phases.DISCOVERY.attempts")" "1" "first record set attempts"

# Merge additional field into same phase
run_dir_record_phase "$DIR_REC" DISCOVERY finished=2026-08-24T09:52:00Z
check phase-status-merged "$(run_dir_get "$DIR_REC" "phases.DISCOVERY.status")" "DONE" "status preserved after merge"
check phase-verdict-merged "$(run_dir_get "$DIR_REC" "phases.DISCOVERY.verdict")" "DONE" "verdict preserved after merge"
check phase-finished-merged "$(run_dir_get "$DIR_REC" "phases.DISCOVERY.finished")" "2026-08-24T09:52:00Z" "finished field added"

# Record second phase without disturbing first
run_dir_record_phase "$DIR_REC" IMPLEMENTATION status=DONE attempts=2
check phase2-status "$(run_dir_get "$DIR_REC" "phases.IMPLEMENTATION.status")" "DONE" "phase 2 status recorded"
check phase2-attempts "$(run_dir_get "$DIR_REC" "phases.IMPLEMENTATION.attempts")" "2" "phase 2 attempts recorded"
check phase1-undisturbed "$(run_dir_get "$DIR_REC" "phases.DISCOVERY.status")" "DONE" "phase 1 untouched by phase 2 record"

# --- 9. run_dir_phase_status -----------------------------------------------

check phase-status-helper "$(run_dir_phase_status "$DIR_REC" "DISCOVERY")" "DONE" "phase status helper returns recorded status"
STATUS_UNRUN="$(run_dir_phase_status "$DIR_REC" "QA" 2>/dev/null)"; CODE=$?
check phase-status-unrun-rc "$CODE" 1 "phase status helper exits 1 for unrun phase"
check phase-status-unrun-out "$STATUS_UNRUN" "" "phase status output is empty for unrun phase"

# --- 10. run_dir_finish ----------------------------------------------------

run_dir_finish "$DIR_REC" "SUCCESS"
check finish-outcome "$(run_dir_get "$DIR_REC" "outcome")" "SUCCESS" "outcome stamped"
FINISHED_VAL="$(run_dir_get "$DIR_REC" "finished")"
FINISHED_FMT=bad
case "$FINISHED_VAL" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) FINISHED_FMT=ok ;;
esac
check finish-ts-format "$FINISHED_FMT" "ok" "finished timestamp is ISO-8601 UTC"

# --- 11. run_dir_phase_dir -------------------------------------------------

PDIR="$(run_dir_phase_dir "$DIR_REC" "REVIEW")"
check phase-dir-path "$PDIR" "$DIR_REC/phases/REVIEW" "phase directory path matches"
[ -d "$PDIR" ] && ok phase-dir-created "phase directory was created on demand" || bad phase-dir-created "phase directory missing"

# --- 12. --dir non-git directory exits 4 -----------------------------------

NON_GIT="$ROOT/not-a-repo"
mkdir -p "$NON_GIT"
run_dir_new --dir "$NON_GIT" >/dev/null 2>&1 || CODE=$?
check non-git-new-rc "$CODE" 4 "run_dir_new on non-git dir exits 4"

run_dir_resolve --dir "$NON_GIT" >/dev/null 2>&1 || CODE=$?
check non-git-resolve-rc "$CODE" 4 "run_dir_resolve on non-git dir exits 4"

# --- 13. CLI execution mode ------------------------------------------------

R_CLI="$(new_repo cli-test)"
CLI_RUN_ID="$(/bin/bash "$RUN_DIR_SCRIPT" new --dir "$R_CLI" --task "cli run")"; CODE=$?
check cli-new-rc "$CODE" 0 "CLI new exits 0"
CLI_ID_FMT=bad
case "$CLI_RUN_ID" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) CLI_ID_FMT=ok ;;
esac
check cli-new-id-format "$CLI_ID_FMT" "ok" "CLI new output is run id"

CLI_PATH="$(/bin/bash "$RUN_DIR_SCRIPT" path --dir "$R_CLI")"; CODE=$?
check cli-path-rc "$CODE" 0 "CLI path exits 0"
check cli-path-val "$CLI_PATH" "$R_CLI/.agy/runs/$CLI_RUN_ID" "CLI path returns correct directory"

# Add a second run to test list
CLI_RUN_ID_2="$(/bin/bash "$RUN_DIR_SCRIPT" new --dir "$R_CLI" --task "cli run 2")"
CLI_LIST="$(/bin/bash "$RUN_DIR_SCRIPT" list --dir "$R_CLI")"; CODE=$?
check cli-list-rc "$CODE" 0 "CLI list exits 0"
CLI_BOTH=bad
if printf '%s\n' "$CLI_LIST" | grep -q "^$CLI_RUN_ID$" && printf '%s\n' "$CLI_LIST" | grep -q "^$CLI_RUN_ID_2$"; then
  CLI_BOTH=ok
fi
check cli-list-both-runs "$CLI_BOTH" "ok" "CLI list prints both run ids"

# When runs have different timestamps, newer run comes first
CLI_RUN_LATER="2099-01-01T00-00-01Z-0000"
mkdir -p "$R_CLI/.agy/runs/$CLI_RUN_LATER"
CLI_LIST_ORDER="$(/bin/bash "$RUN_DIR_SCRIPT" list --dir "$R_CLI")"
FIRST_LINE="$(printf '%s\n' "$CLI_LIST_ORDER" | head -n 1)"
check cli-list-newest-first "$FIRST_LINE" "$CLI_RUN_LATER" "CLI list shows newest run first when timestamps differ"

CLI_SHOW="$(/bin/bash "$RUN_DIR_SCRIPT" show --dir "$R_CLI" --run "$CLI_RUN_ID")"; CODE=$?
check cli-show-rc "$CODE" 0 "CLI show exits 0"
if printf '%s\n' "$CLI_SHOW" | grep -q "cli run"; then
  ok cli-show-content "CLI show output contains run.json content"
else
  bad cli-show-content "CLI show did not output run.json content"
fi

/bin/bash "$RUN_DIR_SCRIPT" bogus --dir "$R_CLI" >/dev/null 2>&1 || CODE=$?
check cli-bad-cmd-rc "$CODE" 2 "CLI unknown command exits 2"

# --- 14. worktree field readability and unknown key refusal -----------------

R_WT_META="$(new_repo worktree-meta)"
ID_WT_META="$(run_dir_new --dir "$R_WT_META" --task "worktree metadata test")"
DIR_WT_META="$R_WT_META/.agy/runs/$ID_WT_META"

# Initially worktree is absent from metadata
WT_INITIAL="$(run_dir_get "$DIR_WT_META" "worktree" 2>/dev/null)"; CODE=$?
check get-worktree-absent-rc "$CODE" 1 "run_dir_get worktree exits 1 when absent"
check get-worktree-absent-out "$WT_INITIAL" "" "run_dir_get worktree is empty when absent"

# When worktree is recorded in metadata
WT_SAMPLE_PATH="$R_WT_META/.agy/worktrees/$ID_WT_META"
FLAT_TMP="$DIR_WT_META/.flat.test.$$"
_run_json_to_flat "$DIR_WT_META/run.json" "$FLAT_TMP"
printf 'worktree=%s\n' "$WT_SAMPLE_PATH" >> "$FLAT_TMP"
_run_json_serialize "$FLAT_TMP" "$DIR_WT_META/run.json"
rm -f "$FLAT_TMP"

WT_READ="$(run_dir_get "$DIR_WT_META" "worktree")"; CODE=$?
check get-worktree-present-rc "$CODE" 0 "run_dir_get worktree exits 0 when present"
check get-worktree-present-val "$WT_READ" "$WT_SAMPLE_PATH" "run_dir_get worktree returns recorded path"

# Unknown / unrecognized key is refused (exits 1)
UNKNOWN_OUT="$(run_dir_get "$DIR_WT_META" "nonexistent_key" 2>/dev/null)"; CODE=$?
check get-unknown-key-rc "$CODE" 1 "run_dir_get unknown key exits 1"
check get-unknown-key-out "$UNKNOWN_OUT" "" "run_dir_get unknown key produces no output"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
