#!/usr/bin/env bash
# Exercise worktree.sh: worktree creation, metadata recording, branch isolation,
# refusal conditions, force overrides, CLI operations, and cleanup.
#
#   tests/worktree.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="$HERE/../scripts/worktree.sh"
RUN_DIR_SCRIPT="$HERE/../scripts/run-dir.sh"
[ -f "$WORKTREE_SCRIPT" ] || { echo "worktree-test: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SCRIPT" ] || { echo "worktree-test: run-dir script not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SCRIPT"
# shellcheck source=../scripts/worktree.sh
. "$WORKTREE_SCRIPT"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/worktree-test.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

export AGY_FLEET="$ROOT/fleet"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() {
  local r="$ROOT/repos/$1"
  mkdir -p "$r"
  (
    cd "$r" && \
    git init -q . && \
    git config user.email "test@example.com" && \
    git config user.name "Tester" && \
    echo "hello from repo" > hello.txt && \
    echo "int main() { return 0; }" > main.c && \
    git add . && \
    git commit -q -m "initial commit"
  )
  printf '%s' "$r"
}

# --- 1. add worktree and find real files in it ------------------------------

R="$(new_repo basic-add)"
ID1="$(run_dir_new --dir "$R" --task "first task")"
WT1="$(worktree_add --dir "$R" --run "$ID1")"; CODE=$?
check add-worktree-rc "$CODE" 0 "worktree_add exits 0"
[ -d "$WT1" ] && ok add-worktree-dir-exists "worktree directory created" || bad add-worktree-dir-exists "missing worktree directory"
[ -f "$WT1/hello.txt" ] && ok add-worktree-file-hello "real file hello.txt found in worktree" || bad add-worktree-file-hello "missing hello.txt"
[ -f "$WT1/main.c" ] && ok add-worktree-file-main "real file main.c found in worktree" || bad add-worktree-file-main "missing main.c"
check add-worktree-file-content "$(cat "$WT1/hello.txt")" "hello from repo" "worktree file matches base commit content"

# --- 2. run's metadata knows where its worktree is -------------------------

check metadata-worktree-file "$(cat "$R/.agy/runs/$ID1/worktree" 2>/dev/null)" "$WT1" "run worktree file contains worktree path"
RESOLVED_WT="$(worktree_path --dir "$R" --run "$ID1")"; CODE=$?
check metadata-worktree-path-rc "$CODE" 0 "worktree_path exits 0"
check metadata-worktree-path "$RESOLVED_WT" "$WT1" "worktree_path returns expected worktree path"
BRANCH1="$(run_dir_get "$R/.agy/runs/$ID1" "branch")"
check metadata-run-branch "$BRANCH1" "agy/$ID1" "run.json branch updated with worktree branch"
WT_META="$(run_dir_get "$R/.agy/runs/$ID1" "worktree")"; CODE=$?
check metadata-run-worktree-rc "$CODE" 0 "run_dir_get worktree exits 0"
check metadata-run-worktree "$WT_META" "$WT1" "run.json worktree field matches worktree path"
[ -d "$WT_META" ] && ok metadata-worktree-dir-exists "worktree field names existing directory" || bad metadata-worktree-dir-exists "worktree field directory does not exist"
check metadata-sidecar-agrees "$(cat "$R/.agy/runs/$ID1/worktree" 2>/dev/null)" "$WT_META" "sidecar file and run.json worktree field agree"

# --- 3. run directory stays in main repository, not in worktree ------------

[ -d "$R/.agy/runs/$ID1" ] && ok run-dir-in-main "run directory exists in main repository" || bad run-dir-in-main "missing run directory in main"
[ ! -d "$WT1/.agy/runs" ] && ok run-dir-not-in-worktree "run directory does not appear inside worktree" || bad run-dir-not-in-worktree "run directory leaked into worktree"

# --- 4. two runs get two different worktrees on different branches --------

ID2="$(run_dir_new --dir "$R" --task "second task")"
WT2="$(worktree_add --dir "$R" --run "$ID2")"; CODE=$?
check add-second-worktree-rc "$CODE" 0 "second worktree_add exits 0"
[ "$WT1" != "$WT2" ] && ok worktree-paths-distinct "two runs get distinct worktree paths" || bad worktree-paths-distinct "worktree paths collided"
[ -d "$WT2" ] && ok second-worktree-dir-exists "second worktree directory exists" || bad second-worktree-dir-exists "missing second worktree dir"

BRANCH_WT1="$(git -C "$WT1" rev-parse --abbrev-ref HEAD)"
BRANCH_WT2="$(git -C "$WT2" rev-parse --abbrev-ref HEAD)"
[ "$BRANCH_WT1" != "$BRANCH_WT2" ] && ok worktree-branches-distinct "worktrees are on distinct branches" || bad worktree-branches-distinct "branches collided"

# Independent edits do not bleed across worktrees
echo "edit in wt1" > "$WT1/change1.txt"
( cd "$WT1" && git add change1.txt && git commit -q -m "wt1 commit" )
[ -f "$WT1/change1.txt" ] && ok wt1-has-commit "wt1 has committed file" || bad wt1-has-commit "wt1 missing file"
[ ! -f "$WT2/change1.txt" ] && ok wt2-isolated-from-wt1 "wt2 does not see wt1 file" || bad wt2-isolated-from-wt1 "wt2 saw wt1 unmerged change"

# --- 5. worktree already exists for run (exit code 5) ----------------------

CODE=0
worktree_add --dir "$R" --run "$ID1" >/dev/null 2>&1 || CODE=$?
check worktree-exists-rc "$CODE" 5 "adding existing worktree exits 5"

# --- 6. branch already checked out elsewhere (exit code 6) -----------------

ID_BRANCH_CONFLICT="$(run_dir_new --dir "$R" --task "branch conflict task")"
# Try checking out the main branch (already checked out in main repo)
MAIN_BR="$(git -C "$R" rev-parse --abbrev-ref HEAD)"
CODE=0
worktree_add --dir "$R" --run "$ID_BRANCH_CONFLICT" --branch "$MAIN_BR" >/dev/null 2>&1 || CODE=$?
check branch-checked-out-main-rc "$CODE" 6 "adding worktree with main branch exits 6"

# Try checking out the branch currently checked out in WT1
CODE=0
worktree_add --dir "$R" --run "$ID_BRANCH_CONFLICT" --branch "$BRANCH_WT1" >/dev/null 2>&1 || CODE=$?
check branch-checked-out-other-wt-rc "$CODE" 6 "adding worktree with another worktree branch exits 6"

# --- 7. refusal 1: unfinished run (exit code 7, refuses even with force) ---

R_UNF="$(new_repo unfin-test)"
ID_UNF="$(run_dir_new --dir "$R_UNF" --task "unfinished task")"
WT_UNF="$(worktree_add --dir "$R_UNF" --run "$ID_UNF")"

CODE=0
worktree_remove --dir "$R_UNF" --run "$ID_UNF" >/dev/null 2>&1 || CODE=$?
check remove-unfinished-rc "$CODE" 7 "removing unfinished run exits 7"
[ -d "$WT_UNF" ] && ok remove-unfinished-survives "unfinished worktree survives removal attempt" || bad remove-unfinished-survives "unfinished worktree removed"

# Unfinished runs cannot be removed even with --force
CODE=0
worktree_remove --dir "$R_UNF" --run "$ID_UNF" --force >/dev/null 2>&1 || CODE=$?
check remove-unfinished-force-rc "$CODE" 7 "removing unfinished run with --force still exits 7"
[ -d "$WT_UNF" ] && ok remove-unfinished-force-survives "unfinished worktree still survives with --force" || bad remove-unfinished-force-survives "unfinished worktree removed with force"

# --- 8. refusal 2: failed run (exit code 7, --force overrides) -------------

R_FAIL="$(new_repo fail-test)"
ID_FAIL="$(run_dir_new --dir "$R_FAIL" --task "failed task")"
WT_FAIL="$(worktree_add --dir "$R_FAIL" --run "$ID_FAIL")"
run_dir_finish "$R_FAIL/.agy/runs/$ID_FAIL" "FAILED"

CODE=0
worktree_remove --dir "$R_FAIL" --run "$ID_FAIL" >/dev/null 2>&1 || CODE=$?
check remove-failed-rc "$CODE" 7 "removing failed run without --force exits 7"
[ -d "$WT_FAIL" ] && ok remove-failed-survives "failed run worktree preserved as evidence" || bad remove-failed-survives "failed worktree removed without force"

CODE=0
worktree_remove --dir "$R_FAIL" --run "$ID_FAIL" --force >/dev/null 2>&1 || CODE=$?
check remove-failed-force-rc "$CODE" 0 "removing failed run with --force exits 0"
[ ! -d "$WT_FAIL" ] && ok remove-failed-force-removed "failed run worktree removed after --force" || bad remove-failed-force-removed "failed worktree still present"

# --- 9. refusal 3: dirty worktree (exit code 7, --force overrides) ---------

# 9a: Uncommitted modification to existing file
R_DIRTY1="$(new_repo dirty1-test)"
ID_DIRTY1="$(run_dir_new --dir "$R_DIRTY1" --task "dirty mod task")"
WT_DIRTY1="$(worktree_add --dir "$R_DIRTY1" --run "$ID_DIRTY1")"
run_dir_finish "$R_DIRTY1/.agy/runs/$ID_DIRTY1" "SUCCESS"

echo "uncommitted edit" >> "$WT_DIRTY1/hello.txt"
CODE=0
worktree_remove --dir "$R_DIRTY1" --run "$ID_DIRTY1" >/dev/null 2>&1 || CODE=$?
check remove-dirty-mod-rc "$CODE" 7 "removing worktree with modified file exits 7"
[ -d "$WT_DIRTY1" ] && ok remove-dirty-mod-survives "dirty modified worktree preserved" || bad remove-dirty-mod-survives "dirty worktree removed without force"

CODE=0
worktree_remove --dir "$R_DIRTY1" --run "$ID_DIRTY1" --force >/dev/null 2>&1 || CODE=$?
check remove-dirty-mod-force-rc "$CODE" 0 "removing dirty modified worktree with --force exits 0"
[ ! -d "$WT_DIRTY1" ] && ok remove-dirty-mod-force-removed "dirty modified worktree removed with force" || bad remove-dirty-mod-force-removed "dirty worktree still present"

# 9b: Untracked file
R_DIRTY2="$(new_repo dirty2-test)"
ID_DIRTY2="$(run_dir_new --dir "$R_DIRTY2" --task "dirty untracked task")"
WT_DIRTY2="$(worktree_add --dir "$R_DIRTY2" --run "$ID_DIRTY2")"
run_dir_finish "$R_DIRTY2/.agy/runs/$ID_DIRTY2" "SUCCESS"

echo "untracked content" > "$WT_DIRTY2/untracked.txt"
CODE=0
worktree_remove --dir "$R_DIRTY2" --run "$ID_DIRTY2" >/dev/null 2>&1 || CODE=$?
check remove-dirty-untracked-rc "$CODE" 7 "removing worktree with untracked file exits 7"
[ -d "$WT_DIRTY2" ] && ok remove-dirty-untracked-survives "dirty untracked worktree preserved" || bad remove-dirty-untracked-survives "dirty worktree removed without force"

CODE=0
worktree_remove --dir "$R_DIRTY2" --run "$ID_DIRTY2" --force >/dev/null 2>&1 || CODE=$?
check remove-dirty-untracked-force-rc "$CODE" 0 "removing dirty untracked worktree with --force exits 0"
[ ! -d "$WT_DIRTY2" ] && ok remove-dirty-untracked-force-removed "dirty untracked worktree removed with force" || bad remove-dirty-untracked-force-removed "dirty worktree still present"

# --- 10. branch survives removal -------------------------------------------

R_SURV="$(new_repo survive-test)"
ID_SURV="$(run_dir_new --dir "$R_SURV" --task "survive task")"
WT_SURV="$(worktree_add --dir "$R_SURV" --run "$ID_SURV")"
BRANCH_SURV="$(git -C "$WT_SURV" rev-parse --abbrev-ref HEAD)"

echo "branch feature commit" > "$WT_SURV/feature.txt"
( cd "$WT_SURV" && git add feature.txt && git commit -q -m "add feature" )
COMMIT_SHA="$(git -C "$WT_SURV" rev-parse HEAD)"

run_dir_finish "$R_SURV/.agy/runs/$ID_SURV" "SUCCESS"
worktree_remove --dir "$R_SURV" --run "$ID_SURV" 2>/dev/null; CODE=$?
check remove-clean-rc "$CODE" 0 "clean worktree remove exits 0"
[ ! -d "$WT_SURV" ] && ok worktree-dir-removed "worktree directory removed" || bad worktree-dir-removed "worktree dir still exists"

BRANCH_REF_SHA="$(git -C "$R_SURV" rev-parse --verify "refs/heads/$BRANCH_SURV" 2>/dev/null || true)"
check branch-survives-sha "$BRANCH_REF_SHA" "$COMMIT_SHA" "branch survives removal and retains commit"

WT_GONE="$(run_dir_get "$R_SURV/.agy/runs/$ID_SURV" "worktree" 2>/dev/null)"; CODE=$?
check remove-worktree-metadata-absent "$CODE" 1 "worktree field absent from run.json after remove"
check remove-worktree-metadata-empty "$WT_GONE" "" "worktree metadata accessor returns empty"
[ ! -f "$R_SURV/.agy/runs/$ID_SURV/worktree" ] && ok remove-sidecar-absent "sidecar file removed after worktree removal" || bad remove-sidecar-absent "sidecar file still present after remove"

# --- 11. path command prints clean path for command substitution -----------

R_PATH_TEST="$(new_repo path-test)"
ID_PATH_TEST="$(run_dir_new --dir "$R_PATH_TEST" --task "path test")"
WT_PATH_TEST="$(worktree_add --dir "$R_PATH_TEST" --run "$ID_PATH_TEST")"

CLI_PATH_OUT="$(/bin/bash "$WORKTREE_SCRIPT" path --dir "$R_PATH_TEST" --run "$ID_PATH_TEST")"; CODE=$?
check cli-path-cmd-rc "$CODE" 0 "CLI path command exits 0"
check cli-path-clean "$CLI_PATH_OUT" "$WT_PATH_TEST" "CLI path stdout contains only path (usable in command substitution)"

# --- 12. list command shows all runs with worktrees ------------------------

R_LIST="$(new_repo list-test)"
ID_L1="$(run_dir_new --dir "$R_LIST" --task "list run 1")"
ID_L2="$(run_dir_new --dir "$R_LIST" --task "list run 2")"
ID_L3="$(run_dir_new --dir "$R_LIST" --task "list run 3")"

worktree_add --dir "$R_LIST" --run "$ID_L1" >/dev/null
worktree_add --dir "$R_LIST" --run "$ID_L3" >/dev/null

LIST_OUT="$(/bin/bash "$WORKTREE_SCRIPT" list --dir "$R_LIST")"
case "$LIST_OUT" in
  *"$ID_L1"*) ok list-has-id1 "list includes run 1 with worktree" ;;
  *) bad list-has-id1 "list missing run 1" ;;
esac
case "$LIST_OUT" in
  *"$ID_L3"*) ok list-has-id3 "list includes run 3 with worktree" ;;
  *) bad list-has-id3 "list missing run 3" ;;
esac
case "$LIST_OUT" in
  *"$ID_L2"*) bad list-excludes-id2 "list included run 2 which has no worktree" ;;
  *) ok list-excludes-id2 "list correctly excludes run without worktree" ;;
esac

# --- 13. standard error exit codes -----------------------------------------

# Bad args (exit 2)
CODE=0
/bin/bash "$WORKTREE_SCRIPT" add --bogus-arg >/dev/null 2>&1 || CODE=$?
check exit-code-bad-arg "$CODE" 2 "bad argument exits 2"

# Missing required --run (exit 2)
CODE=0
/bin/bash "$WORKTREE_SCRIPT" add --dir "$R" >/dev/null 2>&1 || CODE=$?
check exit-code-missing-run "$CODE" 2 "missing --run flag exits 2"

# Non-existent run (exit 3)
CODE=0
/bin/bash "$WORKTREE_SCRIPT" add --dir "$R" --run "nonexistent-run" >/dev/null 2>&1 || CODE=$?
check exit-code-nonexistent-run "$CODE" 3 "nonexistent run exits 3"

# Non-git directory (exit 4)
NON_GIT_DIR="$ROOT/not-a-repo"
mkdir -p "$NON_GIT_DIR"
CODE=0
/bin/bash "$WORKTREE_SCRIPT" add --dir "$NON_GIT_DIR" --run "some-run" >/dev/null 2>&1 || CODE=$?
check exit-code-non-git-dir "$CODE" 4 "non-git directory exits 4"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
