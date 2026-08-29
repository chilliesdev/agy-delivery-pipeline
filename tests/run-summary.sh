#!/usr/bin/env bash
# Exercise run-summary.sh — composing run summary comments and printing unrun gh commands.
#
#   tests/run-summary.sh
#
# Tests run in a throwaway directory under ${TMPDIR:-/tmp}.
# Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_SH="$HERE/../scripts/run-summary.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
LEDGER_SH="$HERE/../scripts/ledger.sh"

[ -f "$SUMMARY_SH" ] || { echo "run-summary-test: scripts/run-summary.sh not found" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "run-summary-test: scripts/run-dir.sh not found" >&2; exit 2; }
[ -f "$LEDGER_SH" ] || { echo "run-summary-test: scripts/ledger.sh not found" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"
# shellcheck source=../scripts/ledger.sh
. "$LEDGER_SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-summary-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

export AGY_FLEET="$ROOT/fleet"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# Install stub gh binary to verify gh is NEVER invoked
BIN_DIR="$ROOT/bin"
mkdir -p "$BIN_DIR"
STUB_GH="$BIN_DIR/gh"

cat > "$STUB_GH" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'CALLED: %s\n' "$*" >> "${STUB_GH_TRIGGER:-/dev/null}"
exit 1
STUB_EOF
chmod +x "$STUB_GH"

export STUB_GH_TRIGGER="$ROOT/gh_was_executed"
export PATH="$BIN_DIR:$PATH"

new_repo() {
  local r="$ROOT/repos/$1"; mkdir -p "$r"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  git -C "$r" remote add origin "$ROOT/repos/origin-$1.git"
  local task="${2:-test run $1}"
  run_dir_new --dir "$r" --task "$task" >/dev/null
  printf '%s' "$r"
}

pdir() {
  local repo="$1"
  local id
  id="$(cat "$repo/.agy/current" 2>/dev/null || true)"
  [ -n "$id" ] && printf '%s/.agy/runs/%s' "$repo" "$id"
}

run_summary() {
  local target_repo="$1"; shift
  OUT_FILE="$ROOT/out"
  ERR_FILE="$ROOT/err"
  /bin/bash "$SUMMARY_SH" --dir "$target_repo" "$@" > "$OUT_FILE" 2> "$ERR_FILE"
  CODE=$?
  OUT="$(cat "$OUT_FILE" 2>/dev/null || true)"
  ERR="$(cat "$ROOT/err" 2>/dev/null || true)"
}

verdict() { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }

# 1. Complete run — SUMMARY_WRITTEN, exit 0, comment names every phase, unrun gh command printed
R="$(new_repo complete "implement feature X")"
R_DIR="$(pdir "$R")"
RUN_ID="$(basename "$R_DIR")"

# Setup phase artifacts for all 5 phases
mkdir -p "$R_DIR/phases/DISCOVER" "$R_DIR/phases/IMPLEMENT" "$R_DIR/phases/REVIEW" "$R_DIR/phases/QA" "$R_DIR/phases/RELEASE"

printf 'STATUS: DISCOVERY_COMPLETE | Phase: DISCOVER | Run: %s\n' "$RUN_ID" > "$R_DIR/phases/DISCOVER/status"
printf 'STATUS: PASSED | File: DISCOVERY.md\n' > "$R_DIR/phases/DISCOVER/verdict"

printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s | Verify: PASSED\n' "$RUN_ID" > "$R_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: src/main.js\n' > "$R_DIR/phases/IMPLEMENT/verdict"
printf 'test passed\n' > "$R_DIR/phases/IMPLEMENT/verify.log"

printf 'STATUS: PASSED | Phase: REVIEW | Run: %s | Attempt: 2\n' "$RUN_ID" > "$R_DIR/phases/REVIEW/status"
printf 'STATUS: PASSED | File: REVIEW_FEEDBACK.md\n' > "$R_DIR/phases/REVIEW/verdict"

printf 'STATUS: PASSED | Phase: QA | Run: %s | Verify: PASSED\n' "$RUN_ID" > "$R_DIR/phases/QA/status"
printf 'STATUS: PASSED | File: QA_REPORT.md\n' > "$R_DIR/phases/QA/verdict"
printf 'qa tests passed\n' > "$R_DIR/phases/QA/verify.log"

printf 'STATUS: PREPARED | Phase: RELEASE | Run: %s\n' "$RUN_ID" > "$R_DIR/phases/RELEASE/status"
printf 'STATUS: PREPARED | File: RELEASE_PLAN.md\n' > "$R_DIR/phases/RELEASE/verdict"

# Artifacts
printf ' 2 files changed, 10 insertions(+), 2 deletions(-)\n' > "$R_DIR/REVIEW_DIFF.stat"
printf 'All review criteria passed in round 2.\n' > "$R_DIR/REVIEW_FEEDBACK.md"
printf 'Exercised user authentication and edge cases.\n' > "$R_DIR/QA_REPORT.md"

# Ledger with token usage
ledger_append "$R" "run=$RUN_ID" "phase=IMPLEMENT" "status=PASSED" "usage={\"input_tokens\":1000,\"output_tokens\":200,\"thinking_tokens\":50,\"total_tokens\":1250}"

run_summary "$R" --issue 100
check complete-rc "$CODE" 0 "exit 0 on complete run"
check complete-status "$(verdict "$OUT")" "SUMMARY_WRITTEN" "status is SUMMARY_WRITTEN"

COMMENT_FILE="$R_DIR/ISSUE_COMMENT.md"
[ -f "$COMMENT_FILE" ] && ok complete-file "ISSUE_COMMENT.md created" || bad complete-file "ISSUE_COMMENT.md missing"

COMMENT_CONTENT="$(cat "$COMMENT_FILE" 2>/dev/null || true)"
case "$COMMENT_CONTENT" in
  *"DISCOVER"*"IMPLEMENT"*"REVIEW"*"QA"*"RELEASE"*) ok complete-all-phases "comment names every phase" ;;
  *) bad complete-all-phases "missing some phases in comment: $COMMENT_CONTENT" ;;
esac

case "$COMMENT_CONTENT" in
  *"2 files changed"*) ok complete-stat "diff stat included in comment" ;;
  *) bad complete-stat "diff stat missing from comment" ;;
esac

case "$COMMENT_CONTENT" in
  *"Exercised user authentication"*) ok complete-qa "QA report included in comment" ;;
  *) bad complete-qa "QA report missing from comment" ;;
esac

case "$COMMENT_CONTENT" in
  *"Total spend"*"1250 tokens"*) ok complete-tokens "token spend included in comment" ;;
  *) bad complete-tokens "token spend missing from comment: $COMMENT_CONTENT" ;;
esac

case "$OUT" in
  *"gh issue comment 100 --body-file"*) ok complete-gh-comment "printed unrun gh issue comment command" ;;
  *) bad complete-gh-comment "missing gh issue comment in output: $OUT" ;;
esac

case "$OUT" in
  *"gh pr create"*) bad complete-default-no-pr "gh pr create printed on default branch: $OUT" ;;
  *"default branch"*"needs a branch first"*) ok complete-default-pr-note "run on default branch explains PR needs a branch first" ;;
  *) bad complete-default-pr-note "missing explanation about default branch: $OUT" ;;
esac

# 2. A phase that ran without --verify — comment says the claim is unverified and not confirmed
R2="$(new_repo unverified "unverified phase test")"
R2_DIR="$(pdir "$R2")"
RUN2_ID="$(basename "$R2_DIR")"

mkdir -p "$R2_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s\n' "$RUN2_ID" > "$R2_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: code.py\n' > "$R2_DIR/phases/IMPLEMENT/verdict"
# Note: no verify.log

run_summary "$R2"
check unverified-rc "$CODE" 0 "exit 0 on run with unverified phase"
C2_CONTENT="$(cat "$R2_DIR/ISSUE_COMMENT.md" 2>/dev/null || true)"

case "$C2_CONTENT" in
  *"unverified (no --verify ran)"*) ok unverified-marked "unverified phase reported as unverified" ;;
  *) bad unverified-marked "claim not marked unverified: $C2_CONTENT" ;;
esac

# 3. A phase that never ran — comment says did not run and does not report as passed
R3="$(new_repo skipped-phase "skipped phase test")"
R3_DIR="$(pdir "$R3")"
RUN3_ID="$(basename "$R3_DIR")"

mkdir -p "$R3_DIR/phases/DISCOVER"
printf 'STATUS: PASSED | Phase: DISCOVER | Run: %s\n' "$RUN3_ID" > "$R3_DIR/phases/DISCOVER/status"
printf 'STATUS: PASSED | File: DISCOVERY.md\n' > "$R3_DIR/phases/DISCOVER/verdict"

run_summary "$R3"
check skipped-rc "$CODE" 0 "exit 0 with partial phases"
C3_CONTENT="$(cat "$R3_DIR/ISSUE_COMMENT.md" 2>/dev/null || true)"

case "$C3_CONTENT" in
  *"QA"*"did not run"*) ok skipped-not-run "unrun phase reported as 'did not run'" ;;
  *) bad skipped-not-run "unrun phase misreported: $C3_CONTENT" ;;
esac

# 4. A run whose ledger has no token usage — no spend section at all, and no zero
R4="$(new_repo no-tokens "no tokens test")"
R4_DIR="$(pdir "$R4")"
RUN4_ID="$(basename "$R4_DIR")"

mkdir -p "$R4_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s\n' "$RUN4_ID" > "$R4_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: app.js\n' > "$R4_DIR/phases/IMPLEMENT/verdict"
# Ledger without usage
ledger_append "$R4" "run=$RUN4_ID" "phase=IMPLEMENT" "status=PASSED"

run_summary "$R4"
check no-tokens-rc "$CODE" 0 "exit 0 with no token spend"
C4_CONTENT="$(cat "$R4_DIR/ISSUE_COMMENT.md" 2>/dev/null || true)"

case "$C4_CONTENT" in
  *"Token Spend"*) bad no-tokens-omitted "Token Spend section should be omitted" ;;
  *"0 tokens"*) bad no-tokens-zero "should not print 0 tokens" ;;
  *) ok no-tokens-omitted "Token Spend omitted when no usage recorded" ;;
esac

# 5. Missing REVIEW_FEEDBACK.md — reported as not found in those words
R5="$(new_repo missing-feedback "missing feedback test")"
R5_DIR="$(pdir "$R5")"
RUN5_ID="$(basename "$R5_DIR")"

mkdir -p "$R5_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s\n' "$RUN5_ID" > "$R5_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: app.js\n' > "$R5_DIR/phases/IMPLEMENT/verdict"
rm -f "$R5_DIR/REVIEW_FEEDBACK.md"

run_summary "$R5"
check missing-feedback-rc "$CODE" 0 "exit 0 with missing feedback file"
C5_CONTENT="$(cat "$R5_DIR/ISSUE_COMMENT.md" 2>/dev/null || true)"

case "$C5_CONTENT" in
  *"REVIEW_FEEDBACK.md not found"*) ok missing-feedback-text "missing review feedback reported as 'not found'" ;;
  *) bad missing-feedback-text "missing feedback did not say 'not found': $C5_CONTENT" ;;
esac

# 6. Comment body containing a secret — exit 4, no gh command, matched value absent from output
R6="$(new_repo secret-leak "secret leak test")"
R6_DIR="$(pdir "$R6")"
RUN6_ID="$(basename "$R6_DIR")"

mkdir -p "$R6_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s\n' "$RUN6_ID" > "$R6_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: app.js\n' > "$R6_DIR/phases/IMPLEMENT/verdict"

SECRET_VAL="ghp_11112222333344445555666677778888"
printf 'Review noted api token: %s\n' "$SECRET_VAL" > "$R6_DIR/REVIEW_FEEDBACK.md"

run_summary "$R6" --issue 200
check secrets-rc "$CODE" 4 "exit 4 when comment body contains secret"
check secrets-status "$(verdict "$OUT")" "SUMMARY_SECRETS" "status is SUMMARY_SECRETS"

case "$OUT" in
  *"gh issue comment"*|*"gh pr create"*) bad secrets-no-cmd "gh command was printed despite secrets" ;;
  *) ok secrets-no-cmd "no gh command printed when secret flagged" ;;
esac

case "$OUT$ERR" in
  *"$SECRET_VAL"*) bad secrets-value-leaked "secret value was leaked in output" ;;
  *) ok secrets-value-suppressed "secret value stayed out of output" ;;
esac

# 7. Run directory with no phase statuses — SUMMARY_THIN, exit 5
R7="$(new_repo thin-run "thin run test")"
run_summary "$R7"
check thin-rc "$CODE" 5 "exit 5 on run with no phase status"
check thin-status "$(verdict "$OUT")" "SUMMARY_THIN" "status is SUMMARY_THIN"

# 8. Assert gh command was never executed throughout all runs
if [ -f "$ROOT/gh_was_executed" ]; then
  bad gh-never-executed "gh stub was executed ($(cat "$ROOT/gh_was_executed"))"
else
  ok gh-never-executed "gh binary was NEVER executed"
fi

# 9. Issue with bug label — includes regression test note
R9="$(new_repo bug-label "fix login crash")"
R9_DIR="$(pdir "$R9")"
RUN9_ID="$(basename "$R9_DIR")"

mkdir -p "$R9_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s\n' "$RUN9_ID" > "$R9_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: login.js\n' > "$R9_DIR/phases/IMPLEMENT/verdict"

cat > "$R9_DIR/ISSUE.md" <<'EOF'
# Quoted GitHub Issue #42
- **Title**: Login crash
- **Labels**: bug, triage
- **State**: OPEN

## Body
Crash occurs on empty password.
EOF

run_summary "$R9"
check bug-rc "$CODE" 0 "exit 0 on bug issue run"
C9_CONTENT="$(cat "$R9_DIR/ISSUE_COMMENT.md" 2>/dev/null || true)"

case "$C9_CONTENT" in
  *"regression test is expected"*) ok bug-regression-note "regression test expected note present for bug label" ;;
  *) bad bug-regression-note "regression test note missing: $C9_CONTENT" ;;
esac

case "$OUT" in
  *"gh issue comment 42"*) ok bug-issue-cmd "issue number 42 used in gh issue comment command" ;;
  *) bad bug-issue-cmd "wrong issue number in gh command: $OUT" ;;
esac

# 10. --into directory option
R10="$(new_repo into-test "into option test")"
R10_DIR="$(pdir "$R10")"
RUN10_ID="$(basename "$R10_DIR")"

mkdir -p "$R10_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s\n' "$RUN10_ID" > "$R10_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: code.js\n' > "$R10_DIR/phases/IMPLEMENT/verdict"

CUSTOM_INTO="$ROOT/custom_into_dir"
run_summary "$R10" --into "$CUSTOM_INTO"
check into-rc "$CODE" 0 "exit 0 with --into option"
[ -f "$CUSTOM_INTO/ISSUE_COMMENT.md" ] && ok into-file-written "ISSUE_COMMENT.md written to --into directory" || bad into-file-written "ISSUE_COMMENT.md not found in --into directory"

# 11. No run found -> exit 3 (SUMMARY_NO_RUN)
run_summary "$R10" --run "nonexistent-run-id-9999"
check no-run-rc "$CODE" 3 "exit 3 when run is not found"
check no-run-status "$(verdict "$OUT")" "SUMMARY_NO_RUN" "status is SUMMARY_NO_RUN"

# 12. Bad arguments -> exit 2
run_summary "$R10" --invalid-flag
check bad-arg-rc "$CODE" 2 "exit 2 on invalid argument"

run_summary "$R10" --issue "not-a-number"
check bad-issue-rc "$CODE" 2 "exit 2 on non-numeric issue"

# 13. Run on a feature branch — prints gh pr create command
R13="$(new_repo feature-branch "implement widget Y")"
( cd "$R13" && git checkout -q -b feat/widget-y )
run_dir_new --dir "$R13" --task "implement widget Y" >/dev/null
R13_DIR="$(pdir "$R13")"
RUN13_ID="$(basename "$R13_DIR")"

mkdir -p "$R13_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT | Run: %s\n' "$RUN13_ID" > "$R13_DIR/phases/IMPLEMENT/status"
printf 'STATUS: PASSED | File: widget.js\n' > "$R13_DIR/phases/IMPLEMENT/verdict"

run_summary "$R13"
check feat-rc "$CODE" 0 "exit 0 on feature branch run"
case "$OUT" in
  *'gh pr create --draft --head "feat/widget-y"'*) ok feat-gh-pr "printed unrun gh pr create command with feature branch" ;;
  *) bad feat-gh-pr "missing gh pr create for feature branch in output: $OUT" ;;
esac

# 14. Repo with remote HEAD — feature branch prints PR command, default branch does not
R14="$(new_repo remote-default "remote test")"
git -C "$R14" remote set-url origin "$ROOT/repos/origin-remote.git" 2>/dev/null || git -C "$R14" remote add origin "$ROOT/repos/origin-remote.git"
git -C "$R14" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true

mkdir -p "$(pdir "$R14")/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$(pdir "$R14")/phases/IMPLEMENT/status"
run_summary "$R14"
case "$OUT" in
  *"gh pr create"*) bad remote-default-no-pr "gh pr create printed on default branch with remote: $OUT" ;;
  *"default branch"*"needs a branch first"*) ok remote-default-pr-note "explains default branch on repo with remote" ;;
  *) bad remote-default-pr-note "missing explanation about default branch: $OUT" ;;
esac

( cd "$R14" && git checkout -q -b feat/remote-feature )
run_dir_new --dir "$R14" --task "feature on remote repo" >/dev/null
R14_FEAT_DIR="$(pdir "$R14")"
mkdir -p "$R14_FEAT_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$R14_FEAT_DIR/phases/IMPLEMENT/status"
run_summary "$R14"
case "$OUT" in
  *'gh pr create --draft --head "feat/remote-feature"'*) ok remote-feat-pr "printed gh pr create for feature branch with remote" ;;
  *) bad remote-feat-pr "missing gh pr create for feature branch with remote: $OUT" ;;
esac

# 15. Repository where default branch cannot be determined — no PR command and explains why
R15="$ROOT/repos/undet"; mkdir -p "$R15"
( cd "$R15" && git init -q -b custom-branch-only . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
( cd "$R15" && git config init.defaultBranch "" )
git -C "$R15" remote add origin "$ROOT/repos/origin-undet.git"
run_dir_new --dir "$R15" --task "custom branch task" >/dev/null
R15_DIR="$(pdir "$R15")"
mkdir -p "$R15_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$R15_DIR/phases/IMPLEMENT/status"
run_summary "$R15"
check undet-rc "$CODE" 0 "exit 0 when default branch undetermined"
case "$OUT" in
  *"gh pr create"*) bad undet-no-pr "gh pr create printed when default branch undetermined: $OUT" ;;
  *"Default branch could not be determined"*) ok undet-pr-note "explains default branch could not be determined" ;;
  *) bad undet-pr-note "missing explanation that default branch could not be determined: $OUT" ;;
esac

# 16. Repository whose only branch is master while init.defaultBranch is set to main
R16="$ROOT/repos/master-only"; mkdir -p "$R16"
( cd "$R16" && git init -q -b master . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
( cd "$R16" && git config init.defaultBranch "main" )
git -C "$R16" remote add origin "$ROOT/repos/origin-master-only.git"
run_dir_new --dir "$R16" --task "master only task" >/dev/null
R16_DIR="$(pdir "$R16")"
mkdir -p "$R16_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$R16_DIR/phases/IMPLEMENT/status"
run_summary "$R16"
check master-only-rc "$CODE" 0 "exit 0 on master-only branch run"
case "$OUT" in
  *"gh pr create"*) bad master-only-no-pr "gh pr create printed when running on default branch master: $OUT" ;;
  *"default branch (master)"*"needs a branch first"*) ok master-only-pr-note "explains default branch is master despite init.defaultBranch saying main" ;;
  *) bad master-only-pr-note "missing explanation about default branch master: $OUT" ;;
esac

# 17. Repository with no remote configured — prints no gh pr create and explains why
R17="$ROOT/repos/no-remote"; mkdir -p "$R17"
( cd "$R17" && git init -q -b feat/unpushed . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
run_dir_new --dir "$R17" --task "unpushed feature task" >/dev/null
R17_DIR="$(pdir "$R17")"
mkdir -p "$R17_DIR/phases/IMPLEMENT"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$R17_DIR/phases/IMPLEMENT/status"
run_summary "$R17"
check no-remote-rc "$CODE" 0 "exit 0 when repository has no remote"
case "$OUT" in
  *"gh pr create"*) bad no-remote-no-pr "gh pr create printed on repo with no remote: $OUT" ;;
  *"no remote"*"needs a remote first"*) ok no-remote-pr-note "explains repository has no remote configured" ;;
  *) bad no-remote-pr-note "missing explanation that repository has no remote: $OUT" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
