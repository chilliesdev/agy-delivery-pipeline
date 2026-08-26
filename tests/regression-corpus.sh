#!/usr/bin/env bash
# Regression corpus replaying closed repository failures against their gates.
#
#   tests/regression-corpus.sh
#
# Replays historical failure conditions in throwaway fixtures and asserts that
# the corresponding gate fires (detects the condition and exits non-zero or
# with the appropriate status).
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"

CHECK_REVIEW="$ROOT_DIR/scripts/check-review.sh"
CHECK_BRIEF="$ROOT_DIR/scripts/check-brief.sh"
CHECK_DIFF="$ROOT_DIR/scripts/check-diff-integrity.sh"
CHECK_SECRETS="$ROOT_DIR/scripts/check-secrets.sh"
PHASE_SH="$ROOT_DIR/scripts/phase.sh"
RUN_DIR_SH="$ROOT_DIR/scripts/run-dir.sh"
FAKE_LIB="$HERE/lib/fake-agy.sh"

[ -f "$CHECK_REVIEW" ]  || { echo "regression-corpus: scripts/check-review.sh not found" >&2; exit 2; }
[ -f "$CHECK_BRIEF" ]   || { echo "regression-corpus: scripts/check-brief.sh not found" >&2; exit 2; }
[ -f "$CHECK_DIFF" ]    || { echo "regression-corpus: scripts/check-diff-integrity.sh not found" >&2; exit 2; }
[ -f "$CHECK_SECRETS" ] || { echo "regression-corpus: scripts/check-secrets.sh not found" >&2; exit 2; }
[ -f "$PHASE_SH" ]      || { echo "regression-corpus: scripts/phase.sh not found" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ]    || { echo "regression-corpus: scripts/run-dir.sh not found" >&2; exit 2; }
[ -f "$FAKE_LIB" ]      || { echo "regression-corpus: tests/lib/fake-agy.sh not found" >&2; exit 2; }

. "$RUN_DIR_SH"
. "$FAKE_LIB"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/regression-corpus.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf '%-36s ok   %s\n' "$1" "$2"; }
bad()   { FAIL=$((FAIL + 1)); printf '%-36s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
word_of() { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }

# Helper to create a throwaway repo with a run dir
new_repo() {
  local name="$1"
  local r="$ROOT/repos/$name"
  mkdir -p "$r"
  r="$(cd "$r" && pwd)"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" \
      && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  local run_id
  run_id="$(run_dir_new --dir "$r" --task "regression test $name")"
  [ -n "$run_id" ] || { echo "regression-corpus: run_dir_new failed for $name" >&2; exit 2; }
  printf '%s' "$r"
}

# -----------------------------------------------------------------------------
# Case 1: Empty Review (Issue #1)
# Replays an empty review containing only four zero counts and "No violations found."
# Gate (scripts/check-review.sh) must refuse with exit 3 (REVIEW_THIN), not come back clean.
# -----------------------------------------------------------------------------
R1="$(new_repo empty-review)"
RUN_ID1="$(cat "$R1/.agy/current")"
RDIR1="$R1/.agy/runs/$RUN_ID1"
{
  printf '# REVIEW_DIFF.patch\n'
  printf 'diff --git a/wordstat/cli.py b/wordstat/cli.py\n'
  printf 'index 1111111..2222222 100644\n--- a/wordstat/cli.py\n+++ b/wordstat/cli.py\n'
  printf '@@ -1,1 +1,40 @@\n'
  awk 'BEGIN { for (i = 1; i <= 40; i++) print "+    line " i }'
} > "$RDIR1/REVIEW_DIFF.patch"

cat > "$RDIR1/REVIEW_FEEDBACK.md" <<'EOF'
PASSED

- Critical: 0
- Major: 0
- Minor: 0
- Nit: 0

## Standards
No violations found.

## Spec
No violations found. Implementation matches all requirements from task description.
EOF

OUT1="$(/bin/bash "$CHECK_REVIEW" --dir "$R1" 2>/dev/null)"
CODE1=$?
check case1-empty-review-rc "$CODE1" 3 "exit 3 on empty review without anchors"
case "$(word_of "$OUT1")" in
  REVIEW_THIN*) ok case1-empty-review-status "reported REVIEW_THIN" ;;
  *) bad case1-empty-review-status "unexpected status: $OUT1" ;;
esac

# -----------------------------------------------------------------------------
# Case 2: Brief naming a nonexistent input (Issue #48)
# Replays a brief naming an input file that does not exist on disk.
# Gate (scripts/check-brief.sh) must refuse before dispatch with missing_input_file.
# -----------------------------------------------------------------------------
R2="$(new_repo missing-input)"
RUN_ID2="$(cat "$R2/.agy/current")"
BRIEF2="$R2/brief.md"
cat > "$BRIEF2" <<EOF
# Phase 1: Implementation
Read scripts/does-not-exist.sh before starting.

Rules:
- Do not run shell commands.
- Do not touch git. No commits.
- Write nothing outside this repository.

Output Contract:
Write your one-line verdict to .agy/runs/$RUN_ID2/phases/IMPLEMENT/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

OUT2="$(/bin/bash "$CHECK_BRIEF" --phase IMPLEMENT --brief "$BRIEF2" --dir "$R2" --run "$RUN_ID2" 2>/dev/null)"
CODE2=$?
check case2-missing-input-rc "$CODE2" 3 "exit 3 when brief names nonexistent input"
case "$OUT2" in
  *"STATUS: BRIEF_INVALID(missing_input_file:scripts/does-not-exist.sh)"*)
    ok case2-missing-input-status "reported missing_input_file" ;;
  *) bad case2-missing-input-status "unexpected output: $OUT2" ;;
esac

# -----------------------------------------------------------------------------
# Case 3: Gutted test in a diff (deleted test, added skip, tautological assert)
# Replays diffs that weaken tests; Gate (scripts/check-diff-integrity.sh) must
# report DIFF_TESTS_WEAKENED and exit 3 to fail the phase.
# -----------------------------------------------------------------------------

# 3a. Deleted test file
R3A="$(new_repo gutted-deleted-test)"
RUN_ID3A="$(cat "$R3A/.agy/current")"
RDIR3A="$R3A/.agy/runs/$RUN_ID3A"
mkdir -p "$RDIR3A/phases/IMPLEMENT"
cat > "$RDIR3A/phases/IMPLEMENT/brief.md" <<'EOF'
Add new feature in src/calc.py and tests in tests/test_calc.py
EOF
cat > "$RDIR3A/REVIEW_DIFF.patch" <<'EOF'
diff --git a/tests/test_old.py b/tests/test_old.py
deleted file mode 100644
--- a/tests/test_old.py
+++ /dev/null
@@ -1,5 +0,0 @@
-def test_legacy():
-    assert 1 == 1
EOF
OUT3A="$(/bin/bash "$CHECK_DIFF" --dir "$R3A" 2>/dev/null)"
CODE3A=$?
check case3a-del-test-rc "$CODE3A" 3 "exit 3 on deleted test file"
case "$(word_of "$OUT3A")" in
  DIFF_TESTS_WEAKENED*) ok case3a-del-test-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad case3a-del-test-status "unexpected status: $OUT3A" ;;
esac

# 3b. Added skip
R3B="$(new_repo gutted-added-skip)"
RUN_ID3B="$(cat "$R3B/.agy/current")"
RDIR3B="$R3B/.agy/runs/$RUN_ID3B"
mkdir -p "$RDIR3B/phases/IMPLEMENT"
cat > "$RDIR3B/phases/IMPLEMENT/brief.md" <<'EOF'
Fix calculation in src/math.py and tests/test_math.py
EOF
cat > "$RDIR3B/REVIEW_DIFF.patch" <<'EOF'
diff --git a/tests/test_math.py b/tests/test_math.py
--- a/tests/test_math.py
+++ b/tests/test_math.py
@@ -10,3 +10,4 @@
+@pytest.mark.skip(reason="broken")
 def test_division():
     assert divide(4, 2) == 2
EOF
OUT3B="$(/bin/bash "$CHECK_DIFF" --dir "$R3B" 2>/dev/null)"
CODE3B=$?
check case3b-added-skip-rc "$CODE3B" 3 "exit 3 on added test skip"
case "$(word_of "$OUT3B")" in
  DIFF_TESTS_WEAKENED*) ok case3b-added-skip-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad case3b-added-skip-status "unexpected status: $OUT3B" ;;
esac

# 3c. Trivially true assertion (tautology)
R3C="$(new_repo gutted-tautology)"
RUN_ID3C="$(cat "$R3C/.agy/current")"
RDIR3C="$R3C/.agy/runs/$RUN_ID3C"
mkdir -p "$RDIR3C/phases/IMPLEMENT"
cat > "$RDIR3C/phases/IMPLEMENT/brief.md" <<'EOF'
Update math calculations in src/calc.py and tests/test_calc.py
EOF
cat > "$RDIR3C/REVIEW_DIFF.patch" <<'EOF'
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -5,2 +5,2 @@
-    assert compute_val() == 42
+    assert True
EOF
OUT3C="$(/bin/bash "$CHECK_DIFF" --dir "$R3C" 2>/dev/null)"
CODE3C=$?
check case3c-tautology-rc "$CODE3C" 3 "exit 3 on assertion weakened to assert True"
case "$(word_of "$OUT3C")" in
  DIFF_TESTS_WEAKENED*) ok case3c-tautology-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad case3c-tautology-status "unexpected status: $OUT3C" ;;
esac

# -----------------------------------------------------------------------------
# Case 4: Scope creep in a diff
# Replays a diff modifying files outside the brief; Gate (scripts/check-diff-integrity.sh)
# must flag DIFF_SUSPICIOUS with scope finding and exit 0 (advisory, not weakened).
# -----------------------------------------------------------------------------
R4="$(new_repo scope-creep)"
RUN_ID4="$(cat "$R4/.agy/current")"
RDIR4="$R4/.agy/runs/$RUN_ID4"
mkdir -p "$RDIR4/phases/IMPLEMENT"
cat > "$RDIR4/phases/IMPLEMENT/brief.md" <<'EOF'
Update calculation in src/calc.py and tests in tests/test_calc.py
EOF
cat > "$RDIR4/REVIEW_DIFF.patch" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,2 @@
+def add(a, b): return a + b
diff --git a/src/unrelated.py b/src/unrelated.py
--- a/src/unrelated.py
+++ b/src/unrelated.py
@@ -1,1 +1,2 @@
+def backdoor(): pass
EOF
OUT4="$(/bin/bash "$CHECK_DIFF" --dir "$R4" 2>/dev/null)"
CODE4=$?
check case4-scope-creep-rc "$CODE4" 0 "exit 0 on scope creep (advisory)"
case "$(word_of "$OUT4")" in
  DIFF_SUSPICIOUS*) ok case4-scope-creep-status "reported DIFF_SUSPICIOUS" ;;
  *) bad case4-scope-creep-status "unexpected status: $OUT4" ;;
esac
case "$OUT4" in
  *"scope:"*|*"src/unrelated.py"*) ok case4-scope-creep-detail "named unmentioned file in scope" ;;
  *) bad case4-scope-creep-detail "unmentioned path not cited: $OUT4" ;;
esac

# -----------------------------------------------------------------------------
# Case 5: Credential in a diff
# Replays a private key credential leaked in a captured diff.
# Gate (scripts/check-secrets.sh) must refuse dispatch with exit 3 (SECRETS_FOUND).
# -----------------------------------------------------------------------------
R5="$(new_repo secret-in-diff)"
RUN_ID5="$(cat "$R5/.agy/current")"
PATCH5="$R5/.agy/runs/$RUN_ID5/REVIEW_DIFF.patch"
cat > "$PATCH5" <<'EOF'
diff --git a/keys/server.key b/keys/server.key
new file mode 100644
--- /dev/null
+++ b/keys/server.key
@@ -0,0 +1,5 @@
++-----BEGIN RSA PRIVATE KEY-----
++MIIEowIBAAKCAQEA0Y...
++-----END RSA PRIVATE KEY-----
EOF
OUT5="$(/bin/bash "$CHECK_SECRETS" --dir "$R5" --diff "$PATCH5" 2>/dev/null)"
CODE5=$?
check case5-secret-diff-rc "$CODE5" 3 "exit 3 on credential in diff"
case "$OUT5" in
  *"STATUS: SECRETS_FOUND(private_key, "*".agy/runs/$RUN_ID5/REVIEW_DIFF.patch:6)"*)
    ok case5-secret-diff-status "reported SECRETS_FOUND(private_key, ...)" ;;
  *) bad case5-secret-diff-status "unexpected output: $OUT5" ;;
esac

# -----------------------------------------------------------------------------
# Case 6: Worker exits 0 without a verdict
# Replays a worker exiting 0 without producing a verdict file or status marker.
# Gate (scripts/phase.sh) must report NO_STATUS_REPORTED rather than rounding to pass.
# -----------------------------------------------------------------------------
FAKE6="$(fake_agy_new --dir "$ROOT/bin-fake6")"
R6="$(new_repo worker-no-verdict)"
RUN_ID6="$(cat "$R6/.agy/current")"
BRIEF6="$R6/.agy/runs/$RUN_ID6/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF6")"
cat > "$BRIEF6" <<EOF
# Phase: TEST
Goal: test worker exit without verdict.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID6/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

OUT6="$(STUB_ACTION='printf "I did some work but wrote no verdict.\n"; exit 0' \
  AGY_BIN="$FAKE6" /bin/bash "$PHASE_SH" --phase TEST --brief "$BRIEF6" \
  --dir "$R6" --run "$RUN_ID6" --no-preflight --no-brief-lint 2>/dev/null)" || true
case "$OUT6" in
  *"STATUS: NO_STATUS_REPORTED"*) ok case6-no-status "reported NO_STATUS_REPORTED" ;;
  *) bad case6-no-status "unexpected output: $OUT6" ;;
esac
case "$OUT6" in
  *"STATUS: PASSED"*) bad case6-not-passed "verdict rounded to pass" ;;
  *) ok case6-not-passed "verdict was not rounded to pass" ;;
esac

# -----------------------------------------------------------------------------
# Case 7: Worker refused verdict file write and printed verdict instead
# Replays a worker whose file write was rejected (reporting ERROR) but printed the verdict.
# Gate (scripts/phase.sh) status line must carry the note that file route failed.
# -----------------------------------------------------------------------------
FAKE7="$(fake_agy_new --dir "$ROOT/bin-fake7")"
R7="$(new_repo worker-refused-write)"
RUN_ID7="$(cat "$R7/.agy/current")"
BRIEF7="$R7/.agy/runs/$RUN_ID7/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF7")"
cat > "$BRIEF7" <<EOF
# Phase: TEST
Goal: test worker refused verdict file write.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID7/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

OUT7="$(STUB_PHASE=TEST STUB_VERDICT="" \
  STUB_TRANSCRIPT_RAW='{"status":"ERROR","response":"Refused to write verdict file to path outside workspace\nSTATUS: PASSED | File: CHANGES.md\n"}' \
  AGY_BIN="$FAKE7" /bin/bash "$PHASE_SH" --phase TEST --brief "$BRIEF7" \
  --dir "$R7" --run "$RUN_ID7" --no-preflight --no-brief-lint 2>/dev/null)" || true
case "$OUT7" in
  *"Note: file route failed; printed route carried the verdict"*)
    ok case7-file-route-failed-note "status line notes file route failed" ;;
  *) bad case7-file-route-failed-note "missing file route failed note: $OUT7" ;;
esac
case "$OUT7" in
  "STATUS: PASSED | File: CHANGES.md"*)
    ok case7-printed-verdict-carried "printed route verdict carried through" ;;
  *) bad case7-printed-verdict-carried "verdict not carried: $OUT7" ;;
esac
if [ ! -e "$R7/.agy/runs/$RUN_ID7/phases/TEST/retries" ]; then
  ok case7-clean-round "round was clean (no retries spent)"
else
  bad case7-clean-round "retries file exists; round was not clean"
fi

# -----------------------------------------------------------------------------
# Case 8: Worker reported ERROR status but wrote verdict file
# Replays a worker reporting ERROR status whose verdict came from the verdict file.
# Must NOT carry the note that file route failed.
# -----------------------------------------------------------------------------
FAKE8="$(fake_agy_new --dir "$ROOT/bin-fake8")"
R8="$(new_repo worker-error-with-file)"
RUN_ID8="$(cat "$R8/.agy/current")"
BRIEF8="$R8/.agy/runs/$RUN_ID8/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF8")"
cat > "$BRIEF8" <<EOF
# Phase: TEST
Goal: test worker error status with verdict file.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Contract:
Write verdict to .agy/runs/$RUN_ID8/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

OUT8="$(STUB_PHASE=TEST STUB_VERDICT="STATUS: PASSED | File: CHANGES.md" \
  STUB_TRANSCRIPT_RAW='{"status":"ERROR","response":"some error occurred\n"}' \
  AGY_BIN="$FAKE8" /bin/bash "$PHASE_SH" --phase TEST --brief "$BRIEF8" \
  --dir "$R8" --run "$RUN_ID8" --no-preflight --no-brief-lint 2>/dev/null)" || true
case "$OUT8" in
  *"Note: file route failed"*)
    bad case8-no-file-route-note "note must not appear when verdict came from file: $OUT8" ;;
  *)
    ok case8-no-file-route-note "no file route note when verdict came from file" ;;
esac
case "$OUT8" in
  "STATUS: PASSED | File: CHANGES.md"*)
    ok case8-file-verdict-carried "verdict file carried through" ;;
  *) bad case8-file-verdict-carried "verdict not carried: $OUT8" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
