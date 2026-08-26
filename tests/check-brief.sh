#!/usr/bin/env bash
# Exercise check-brief.sh: that well-formed briefs pass, that stale or broken
# contracts are refused before dispatch, and that phase.sh enforces the lint
# without invoking the worker.
#
#   tests/check-brief.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-brief.sh"
PHASE_SH="$HERE/../scripts/phase.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"

[ -f "$CHECK" ] || { echo "check-brief-test: check-brief.sh not found next door" >&2; exit 2; }
[ -f "$PHASE_SH" ] || { echo "check-brief-test: phase.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "check-brief-test: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-brief.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# Helper to create a throwaway repo with a run dir
new_repo() {
  local name="$1"
  local r="$ROOT/repos/$name"
  mkdir -p "$r"
  ( cd "$r" && git init -q . )
  run_dir_new --dir "$r" --task "brief test $name" >/dev/null
  printf '%s' "$r"
}

# run_check <repo> <phase> <brief_file> [extra args...]
run_check() {
  local repo="$1"
  local phase="$2"
  local brief="$3"
  shift 3
  OUT="$(/bin/bash "$CHECK" --dir "$repo" --phase "$phase" --brief "$brief" "$@" 2>/dev/null)"
  CODE=$?
}

# --- Check 1: Wrong phase verdict path ---------------------------------------
REPO="$(new_repo wrong-phase)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Goal: do the work

Invariant Rules:
- Do not run shell commands.
- Do not touch git. No commits.
- Write nothing outside this repo.

Output Contract:
Write your one-line verdict to .agy/runs/$RUN_ID/phases/REVIEW/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF"
check wrong-phase-rc "$CODE" 3 "exit 3 on wrong phase verdict path"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(wrong_phase_verdict_path:phases/REVIEW/verdict)"*)
    ok wrong-phase-status "reported wrong_phase_verdict_path" ;;
  *) bad wrong-phase-status "unexpected output: $OUT" ;;
esac

# --- Check 1: Stale .tmp/ verdict path (Issue #44) ---------------------------
REPO="$(new_repo stale-tmp)"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Delegate task
Implement feature.

Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repository.

When you are done, write one line to .tmp/DELEGATE.verdict, and print that same line as the last line of your output, in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "DELEGATE" "$BRIEF"
check stale-tmp-rc "$CODE" 3 "exit 3 on stale .tmp/ verdict path"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(stale_verdict_path:.tmp/DELEGATE.verdict)"*)
    ok stale-tmp-status "reported stale_verdict_path (.tmp/DELEGATE.verdict)" ;;
  *) bad stale-tmp-status "unexpected output: $OUT" ;;
esac

# --- Check 2: Prints verdict but never writes file ---------------------------
REPO="$(new_repo print-only)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Implementation
Goal: do the work

Rules:
- Do not run shell commands.
- Do not touch git.

When you are done, print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF"
check print-only-rc "$CODE" 3 "exit 3 when verdict file route is missing"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_verdict_path)"*|*"STATUS: BRIEF_INVALID(missing_verdict_file_route)"*)
    ok print-only-status "reported missing verdict file route" ;;
  *) bad print-only-status "unexpected output: $OUT" ;;
esac

# --- Check 2b: Writes file but never prints line -----------------------------
REPO="$(new_repo write-only)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Implementation
Goal: do the work

Rules:
- Do not run shell commands.
- Do not touch git.

When you are done, write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF"
check write-only-rc "$CODE" 3 "exit 3 when print line route is missing"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_verdict_print_route)"*)
    ok write-only-status "reported missing verdict print route" ;;
  *) bad write-only-status "unexpected output: $OUT" ;;
esac

# --- Check 4: Input file that does not exist ---------------------------------
REPO="$(new_repo missing-input)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 2: Review
Read and follow .agy/runs/$RUN_ID/criteria/code-review.md.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/REVIEW/verdict and print that same line as STATUS: PASSED | File: REVIEW_FEEDBACK.md.
EOF

run_check "$REPO" "REVIEW" "$BRIEF"
check missing-input-rc "$CODE" 3 "exit 3 when input file is missing"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_input_file:.agy/runs/$RUN_ID/criteria/code-review.md)"*)
    ok missing-input-status "reported missing criteria input file" ;;
  *) bad missing-input-status "unexpected output: $OUT" ;;
esac

# --- Check 4b: Bare filenames in backticks are not input paths (Issue #48) ---
REPO="$(new_repo bare-filenames)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Read \`SKILL.md\` and \`package.json\` first.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check bare-filenames-rc "$CODE" 0 "exit 0 when brief mentions bare filenames in backticks"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok bare-filenames-status "reported BRIEF_VALID for bare filenames in prose" ;;
  *) bad bare-filenames-status "unexpected output: $OUT" ;;
esac

# --- Check 4c: Mentioning DISCOVERY.md in prose (Issue #48) -------------------
REPO="$(new_repo prose-mention)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
The orchestrator reads DISCOVERY.md in full by design.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check prose-mention-rc "$CODE" 0 "exit 0 when brief mentions DISCOVERY.md in prose"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok prose-mention-status "reported BRIEF_VALID for DISCOVERY.md prose mention" ;;
  *) bad prose-mention-status "unexpected output: $OUT" ;;
esac

# --- Check 4d: Nonexistent path with directory is refused --------------------
REPO="$(new_repo missing-path-with-slash)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Read scripts/does-not-exist.sh before starting.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check missing-path-slash-rc "$CODE" 3 "exit 3 when path with directory does not exist"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_input_file:scripts/does-not-exist.sh)"*)
    ok missing-path-slash-status "reported missing_input_file for nonexistent script path" ;;
  *) bad missing-path-slash-status "unexpected output: $OUT" ;;
esac

# --- Check 4e: Existing path with directory is accepted ----------------------
REPO="$(new_repo existing-path-with-slash)"
RUN_ID="$(cat "$REPO/.agy/current")"
mkdir -p "$REPO/briefs"
touch "$REPO/briefs/DELEGATE.md"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Follow instructions in briefs/DELEGATE.md.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check existing-path-slash-rc "$CODE" 0 "exit 0 when path with directory exists"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok existing-path-slash-status "reported BRIEF_VALID for existing path with slash" ;;
  *) bad existing-path-slash-status "unexpected output: $OUT" ;;
esac

# --- Check 4f: Brief writing a nonexistent file is accepted (Issue #48) -------
REPO="$(new_repo create-nonexistent-file)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Write \`docs/new-thing.md\` with initial architecture documentation.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check create-nonexistent-rc "$CODE" 0 "exit 0 when brief writes a file to create"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*"input_paths (0 checked, 1 output skipped)"*)
    ok create-nonexistent-status "reported BRIEF_VALID and 1 output skipped for created file" ;;
  *) bad create-nonexistent-status "unexpected output: $OUT" ;;
esac

# --- Check 4g: Nonexistent path under Output Contract is accepted (Issue #48) -
REPO="$(new_repo output-contract-nonexistent)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Implement the requested feature.

Rules:
- Do not run shell commands.
- Do not touch git.

## Output Contract
1. Write output report to \`docs/generated-report.md\`.
2. Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check output-contract-nonexistent-rc "$CODE" 0 "exit 0 when nonexistent path is in Output Contract"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*"input_paths (0 checked, 1 output skipped)"*)
    ok output-contract-nonexistent-status "reported BRIEF_VALID for Output Contract path" ;;
  *) bad output-contract-nonexistent-status "unexpected output: $OUT" ;;
esac

# --- Check 4h: Reading and creating same nonexistent path is refused ---------
REPO="$(new_repo read-and-create-same)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Read \`docs/scratch.md\` and then write \`docs/scratch.md\`.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check read-and-create-same-rc "$CODE" 3 "exit 3 when reading and creating same nonexistent path"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_input_file:docs/scratch.md)"*)
    ok read-and-create-same-status "reported missing_input_file when path is both read and written" ;;
  *) bad read-and-create-same-status "unexpected output: $OUT" ;;
esac

# --- Check 4i: Reports both inputs checked and outputs skipped counts --------
REPO="$(new_repo input-and-output-counts)"
RUN_ID="$(cat "$REPO/.agy/current")"
mkdir -p "$REPO/briefs"
touch "$REPO/briefs/DELEGATE.md"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Read \`briefs/DELEGATE.md\` and write \`docs/new-module.md\`.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check input-and-output-counts-rc "$CODE" 0 "exit 0 for brief with input and output paths"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*"input_paths (1 checked, 1 output skipped)"*)
    ok input-and-output-counts-status "reported BRIEF_VALID with 1 checked, 1 output skipped" ;;
  *) bad input-and-output-counts-status "unexpected output: $OUT" ;;
esac

# --- Check 4j: Bare filenames in prose without backticks (Issue #48) ---------
REPO="$(new_repo bare-filenames-prose)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Examine README.md and Makefile for general patterns and structure.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check bare-filenames-prose-rc "$CODE" 0 "exit 0 when brief names bare filenames in prose"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok bare-filenames-prose-status "reported BRIEF_VALID for bare filenames in prose" ;;
  *) bad bare-filenames-prose-status "unexpected output: $OUT" ;;
esac

# --- Check 4k: Existing path under docs directory is accepted ----------------
REPO="$(new_repo existing-docs-path)"
RUN_ID="$(cat "$REPO/.agy/current")"
mkdir -p "$REPO/docs"
touch "$REPO/docs/architecture.md"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Follow design in docs/architecture.md.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check existing-docs-path-rc "$CODE" 0 "exit 0 when path under docs directory exists"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok existing-docs-path-status "reported BRIEF_VALID for existing path under docs" ;;
  *) bad existing-docs-path-status "unexpected output: $OUT" ;;
esac

# --- Check 4l: Nonexistent root-level path in ./ form is refused --------------
REPO="$(new_repo missing-dot-slash-path)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Read ./nonexistent-root-file.md before proceeding.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check missing-dot-slash-rc "$CODE" 3 "exit 3 when nonexistent root file uses ./ form"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_input_file:./nonexistent-root-file.md)"*)
    ok missing-dot-slash-status "reported missing_input_file for nonexistent ./ root file" ;;
  *) bad missing-dot-slash-status "unexpected output: $OUT" ;;
esac

# --- Check 4m: Slash-joined backticked words in prose are accepted (Issue #73) -
REPO="$(new_repo slash-joined-backticks)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Use \`helper_a\`/\`helper_b\`/\`helper_c\` to coordinate the pipeline.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check slash-joined-backticks-rc "$CODE" 0 "exit 0 when prose joins three backticked words with slashes"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok slash-joined-backticks-status "reported BRIEF_VALID for slash-joined backticked words" ;;
  *) bad slash-joined-backticks-status "unexpected output: $OUT" ;;
esac

# --- Check 4n: Diagnostic line for existing file with line:column suffix (Issue #73) -
REPO="$(new_repo diagnostic-existing)"
RUN_ID="$(cat "$REPO/.agy/current")"
mkdir -p "$REPO/src"
touch "$REPO/src/parser.sh"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Fix the issue reported by the linter:
src/parser.sh:42:15: error: unquoted expansion

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check diagnostic-existing-rc "$CODE" 0 "exit 0 when diagnostic names existing file with line:column"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok diagnostic-existing-status "reported BRIEF_VALID for existing file diagnostic line" ;;
  *) bad diagnostic-existing-status "unexpected output: $OUT" ;;
esac

# --- Check 4o: Diagnostic line for nonexistent file with line:column suffix (Issue #73) -
REPO="$(new_repo diagnostic-nonexistent)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Fix the issue reported by the linter:
src/nonexistent.sh:10:5: error: syntax error

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check diagnostic-nonexistent-rc "$CODE" 3 "exit 3 when diagnostic names nonexistent file"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_input_file:src/nonexistent.sh)"*)
    ok diagnostic-nonexistent-status "reported missing_input_file with stripped suffix for nonexistent file" ;;
  *) bad diagnostic-nonexistent-status "unexpected output: $OUT" ;;
esac

# --- Check 4p: Nonexistent path with no suffix is refused (Issue #73) ---------
REPO="$(new_repo missing-path-no-suffix)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Read src/missing-module.sh before starting.

Rules:
- Do not run shell commands.
- Do not touch git.

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check missing-path-no-suffix-rc "$CODE" 3 "exit 3 when nonexistent path has no suffix"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_input_file:src/missing-module.sh)"*)
    ok missing-path-no-suffix-status "reported missing_input_file for nonexistent path with no suffix" ;;
  *) bad missing-path-no-suffix-status "unexpected output: $OUT" ;;
esac

# --- Check 5: Path outside repository (~/.claude/something) -----------------
REPO="$(new_repo outside-tilde)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Read ~/.claude/something for extra config.

Rules:
- Do not run shell commands.
- Do not touch git.

Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF"
check outside-tilde-rc "$CODE" 3 "exit 3 on path outside repo (~/...)"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(outside_path:~/.claude/something)"*)
    ok outside-tilde-status "reported outside_path (~/.claude/something)" ;;
  *) bad outside-tilde-status "unexpected output: $OUT" ;;
esac

# --- Check 5b: Absolute path outside repo (/etc/passwd) ----------------------
REPO="$(new_repo outside-abs)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Check /etc/passwd for format.

Rules:
- Do not run shell commands.
- Do not touch git.

Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF"
check outside-abs-rc "$CODE" 3 "exit 3 on absolute path outside repo"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(outside_path:/etc/passwd)"*)
    ok outside-abs-status "reported outside_path (/etc/passwd)" ;;
  *) bad outside-abs-status "unexpected output: $OUT" ;;
esac

# --- Check 5c: Tilde in table or ellipsis is not treated as outside path -----
REPO="$(new_repo tilde-example)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repository (~/ or ~/... are examples of outside paths).

Output Contract:
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check tilde-example-rc "$CODE" 0 "exit 0 when brief mentions ~/ or ~/... as examples"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok tilde-example-status "reported BRIEF_VALID for tilde example mentions" ;;
  *) bad tilde-example-status "unexpected output: $OUT" ;;
esac

# --- Check 3: Missing shell prohibition & --allow-shell override ------------
REPO="$(new_repo shell-prohibition)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Goal: add feature.

Rules:
- Do not touch git.

Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF"
check shell-prohib-rc "$CODE" 3 "exit 3 when shell prohibition is missing"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_shell_prohibition)"*)
    ok shell-prohib-status "reported missing_shell_prohibition" ;;
  *) bad shell-prohib-status "unexpected output: $OUT" ;;
esac

run_check "$REPO" "IMPLEMENT" "$BRIEF" --allow-shell
check shell-allow-rc "$CODE" 0 "exit 0 when --allow-shell is passed"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*|*"shell_prohibition (skipped: --allow-shell)"*)
    ok shell-allow-status "brief valid under --allow-shell" ;;
  *) bad shell-allow-status "unexpected output: $OUT" ;;
esac

# --- Check 6: Missing git prohibition ----------------------------------------
REPO="$(new_repo git-prohibition)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Goal: add feature.

Rules:
- Do not run shell commands.

Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF"
check git-prohib-rc "$CODE" 3 "exit 3 when git prohibition is missing"
case "$OUT" in
  *"STATUS: BRIEF_INVALID(missing_git_prohibition)"*)
    ok git-prohib-status "reported missing_git_prohibition" ;;
  *) bad git-prohib-status "unexpected output: $OUT" ;;
esac

# --- Check 7: Well-formed brief from template --------------------------------
REPO="$(new_repo valid-template)"
RUN_ID="$(cat "$REPO/.agy/current")"
mkdir -p "$REPO/.agy/runs/$RUN_ID/criteria"
printf '# Code Review Criteria\n' > "$REPO/.agy/runs/$RUN_ID/criteria/code-review.md"
printf '# Diff\n' > "$REPO/.agy/runs/$RUN_ID/REVIEW_DIFF.patch"
printf '# Stat\n' > "$REPO/.agy/runs/$RUN_ID/REVIEW_DIFF.stat"

BRIEF="$REPO/.agy/runs/$RUN_ID/phases/REVIEW/brief.md"
mkdir -p "$(dirname "$BRIEF")"
cat > "$BRIEF" <<EOF
# Phase 2: Code Review

Review the captured diff against project coding standards and task specification.

## Criteria
Read and follow .agy/runs/$RUN_ID/criteria/code-review.md.

## Subject of Review
The change under review is in .agy/runs/$RUN_ID/REVIEW_DIFF.patch, with a per-file summary in .agy/runs/$RUN_ID/REVIEW_DIFF.stat.

## Invariant Rules
1. **Do not run shell commands.** You cannot run git diff; the patch and stat files are your only account of the change.
2. **Do not touch git.** Do not commit.
3. **Do not modify source code or fix anything.**
4. **Write nothing outside this repository.**

## Output Contract
1. Write findings to .agy/runs/$RUN_ID/REVIEW_FEEDBACK.md.
2. Write your one-line verdict — STATUS: PASSED | File: .agy/runs/$RUN_ID/REVIEW_FEEDBACK.md or STATUS: FAILED | File: .agy/runs/$RUN_ID/REVIEW_FEEDBACK.md — to .agy/runs/$RUN_ID/phases/REVIEW/verdict, and print that same line as the last line of your output in the form STATUS: <verdict> | File: <path>. Do not write .agy/runs/$RUN_ID/phases/REVIEW/status.
EOF

run_check "$REPO" "REVIEW" "$BRIEF" --run "$RUN_ID"
check valid-brief-rc "$CODE" 0 "exit 0 on well-formed brief"
case "$OUT" in
  *"STATUS: BRIEF_VALID | Checks: "*|*"verdict_path, verdict_routes, shell_prohibition, input_paths"*)
    ok valid-brief-status "reported BRIEF_VALID and named checks" ;;
  *) bad valid-brief-status "unexpected output: $OUT" ;;
esac

# --- Check 10: Multi-line / hard-wrapped brief (Issue #27 regression) --------
REPO="$(new_repo hard-wrapped)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Delegate Task: hard-wrapped test
Implement feature.

## Invariant Rules
1. **Do not run
   shell commands.** In accept-edits mode a denied command aborts the entire run.
2. **Do not
   touch git.** No staging, no commits, no branches.
3. **Write nothing outside this repository**, and nothing in .agy/ except your verdict file.

## Output Contract
When done, write one line to .agy/runs/$RUN_ID/phases/DELEGATE/verdict and print
that same line as the last line of your output.
EOF

run_check "$REPO" "DELEGATE" "$BRIEF" --run "$RUN_ID"
check hard-wrapped-rc "$CODE" 0 "exit 0 on hard-wrapped brief with phrases split across line breaks"
case "$OUT" in
  *"STATUS: BRIEF_VALID"*)
    ok hard-wrapped-status "reported BRIEF_VALID for hard-wrapped brief" ;;
  *) bad hard-wrapped-status "unexpected output: $OUT" ;;
esac

# --- Check 10b: Split file route across line break ---------------------------
REPO="$(new_repo split-file-route)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Rules:
- Do not run shell commands.
- Do not touch git.
When done, write one line to
.agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check split-file-route-rc "$CODE" 0 "exit 0 when file route is split across line break"

# --- Check 10c: Split shell prohibition across line break --------------------
REPO="$(new_repo split-shell-prohib)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Rules:
- Do not
  run shell commands.
- Do not touch git.
When done, write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check split-shell-prohib-rc "$CODE" 0 "exit 0 when shell prohibition is split across line break"

# --- Check 10d: Split git prohibition across line break ----------------------
REPO="$(new_repo split-git-prohib)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Rules:
- Do not run shell commands.
- Do not touch
  git.
When done, write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print that same line as the last line of your output.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check split-git-prohib-rc "$CODE" 0 "exit 0 when git prohibition is split across line break"

# --- Check 11: Widened print route phrasings ---------------------------------
# 11a: "print it as the final line"
REPO="$(new_repo print-route-widen-a)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Rules:
- Do not run shell commands.
- Do not touch git.
Write your verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and print it as the final line in the form STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check print-widen-a-rc "$CODE" 0 "exit 0 for 'print it as the final line'"

# 11b: "echo the same line"
REPO="$(new_repo print-route-widen-b)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Rules:
- Do not run shell commands.
- Do not touch git.
Write verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict and echo the same line to stdout.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check print-widen-b-rc "$CODE" 0 "exit 0 for 'echo the same line'"

# 11c: "the last line of your output must be"
REPO="$(new_repo print-route-widen-c)"
RUN_ID="$(cat "$REPO/.agy/current")"
BRIEF="$REPO/brief.md"
cat > "$BRIEF" <<EOF
# Phase 1: Implementation
Rules:
- Do not run shell commands.
- Do not touch git.
Write verdict to .agy/runs/$RUN_ID/phases/IMPLEMENT/verdict. The last line of your output must be STATUS: DONE | File: CHANGES.md.
EOF

run_check "$REPO" "IMPLEMENT" "$BRIEF" --run "$RUN_ID"
check print-widen-c-rc "$CODE" 0 "exit 0 for 'the last line of your output must be'"

# --- Check 8: All 6 shipped templates exist in briefs/ ----------------------
for T in DISCOVERY IMPLEMENT REVIEW QA RELEASE DELEGATE; do
  TEMPLATE_FILE="$HERE/../briefs/$T.md"
  if [ -f "$TEMPLATE_FILE" ]; then
    ok "template-exists-$T" "briefs/$T.md is present"
  else
    bad "template-exists-$T" "briefs/$T.md is missing"
  fi
done

# --- Check 9: Arguments handling --------------------------------------------
run_check "$REPO" "" "$BRIEF"
check bad-args-no-phase "$CODE" 2 "exit 2 when --phase is missing"
run_check "$REPO" "TEST" ""
check bad-args-no-brief "$CODE" 2 "exit 2 when --brief is missing"
/bin/bash "$CHECK" --dir "$REPO" --phase TEST --brief "$REPO/nonexistent.md" 2>/dev/null
check bad-args-missing-brief "$?" 2 "exit 2 when brief file does not exist"
/bin/bash "$CHECK" --dir "$ROOT/nonexistent-dir" --phase TEST --brief "$BRIEF" 2>/dev/null
check bad-args-missing-dir "$?" 2 "exit 2 when dir does not exist"

# =============================================================================
# phase.sh integration tests
# =============================================================================

# Setup stub agy binary
STUB="$ROOT/stub-agy"
INVOKED_FILE="$ROOT/worker-invoked"
cat > "$STUB" <<STUB_EOF
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
  exit 0
fi
printf 'invoked\n' >> "$INVOKED_FILE"
if [ -f .agy/current ]; then
  CUR_RUN="\$(cat .agy/current 2>/dev/null || true)"
  if [ -n "\$CUR_RUN" ]; then
    mkdir -p ".agy/runs/\$CUR_RUN/phases/\$STUB_PHASE"
    printf 'STATUS: DONE | File: CHANGES.md\n' > ".agy/runs/\$CUR_RUN/phases/\$STUB_PHASE/verdict"
  fi
fi
printf 'STATUS: DONE | File: CHANGES.md\n'
exit 0
STUB_EOF
chmod +x "$STUB"

# 1. phase.sh refuses to dispatch on an invalid brief (worker never invoked)
REPO_P1="$(new_repo phase-refusal)"
RUN_ID_P1="$(cat "$REPO_P1/.agy/current")"
INVALID_BRIEF="$REPO_P1/invalid_brief.md"
cat > "$INVALID_BRIEF" <<EOF
# Implementation without shell prohibition
Rules:
- Do not touch git.
Write verdict to .agy/runs/$RUN_ID_P1/phases/IMPLEMENT/verdict and print STATUS: DONE | File: CHANGES.md.
EOF

rm -f "$INVOKED_FILE"
PHASE_OUT="$(STUB_PHASE=IMPLEMENT AGY_BIN="$STUB" "$PHASE_SH" --phase IMPLEMENT --brief "$INVALID_BRIEF" --dir "$REPO_P1" --run "$RUN_ID_P1" 2>/dev/null)"
PHASE_RC=$?

check phase-refusal-rc "$PHASE_RC" 3 "phase.sh exits non-zero on invalid brief"
case "$PHASE_OUT" in
  *"STATUS: BRIEF_INVALID(missing_shell_prohibition)"*)
    ok phase-refusal-status "phase.sh reports BRIEF_INVALID" ;;
  *) bad phase-refusal-status "unexpected output: $PHASE_OUT" ;;
esac
[ ! -f "$INVOKED_FILE" ] && ok phase-worker-never-invoked "worker was never invoked" \
  || bad phase-worker-never-invoked "worker was invoked despite invalid brief"

# 2. phase.sh dispatches anyway under --no-brief-lint
rm -f "$INVOKED_FILE"
STUB_PHASE=IMPLEMENT AGY_BIN="$STUB" "$PHASE_SH" --phase IMPLEMENT --brief "$INVALID_BRIEF" --dir "$REPO_P1" --run "$RUN_ID_P1" --no-brief-lint >/dev/null 2>&1
PHASE_RC_BYPASS=$?

check phase-bypass-rc "$PHASE_RC_BYPASS" 0 "phase.sh exits 0 under --no-brief-lint"
[ -f "$INVOKED_FILE" ] && ok phase-bypass-worker-invoked "worker was invoked under --no-brief-lint" \
  || bad phase-bypass-worker-invoked "worker was not invoked under --no-brief-lint"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
