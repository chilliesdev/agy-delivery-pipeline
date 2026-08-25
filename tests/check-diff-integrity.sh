#!/usr/bin/env bash
# Exercise check-diff-integrity.sh: that weakened tests fail, scope creep is
# flagged as suspicious, honest diffs pass with checked rules listed, and
# unsupported languages report DIFF_UNCHECKED.
#
#   tests/check-diff-integrity.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-diff-integrity.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
[ -f "$CHECK" ] || { echo "check-diff-integrity-test: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "check-diff-integrity-test: run-dir.sh not found next door" >&2; exit 2; }

. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-diff-integrity.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# Helper to create a test repo case
new_case() {
  local name="$1"
  local r="$ROOT/cases/$name"; mkdir -p "$r"
  ( cd "$r" && git init -q . )
  local id="$(run_dir_new --dir "$r" --task "diff integrity test $name")"
  local rdir="$r/.agy/runs/$id"
  mkdir -p "$rdir/phases/IMPLEMENT"
  printf '%s' "$r"
}

set_patch() {
  local r="$1"
  local id="$(cat "$r/.agy/current" 2>/dev/null)"
  cat > "$r/.agy/runs/$id/REVIEW_DIFF.patch"
}

set_brief() {
  local r="$1"
  local id="$(cat "$r/.agy/current" 2>/dev/null)"
  cat > "$r/.agy/runs/$id/phases/IMPLEMENT/brief.md"
}

# run <repo> <args...> — STATUS line into $OUT, exit code into $CODE.
run() { local r="$1"; shift; OUT="$(/bin/bash "$CHECK" --dir "$r" "$@" 2>/dev/null)"; CODE=$?; }
word_of() { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }

# --- 1. A deleted test file -> DIFF_TESTS_WEAKENED ------------------------
R="$(new_case deleted-test-file)"
set_brief "$R" <<'EOF'
Add new feature in src/calc.py and tests in tests/test_calc.py
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/test_old.py b/tests/test_old.py
deleted file mode 100644
--- a/tests/test_old.py
+++ /dev/null
@@ -1,5 +0,0 @@
-def test_legacy():
-    assert 1 == 1
EOF
run "$R"
check del-test-rc "$CODE" 3 "exit 3 on deleted test file"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok del-test-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad del-test-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"test_file_deleted"*|*"test_old.py"*) ok del-test-detail "named deleted test file" ;;
  *) bad del-test-detail "deleted file not cited: $OUT" ;; esac

# --- 2. An added @pytest.mark.skip -> DIFF_TESTS_WEAKENED -----------------
R="$(new_case pytest-skip)"
set_brief "$R" <<'EOF'
Fix calculation in src/math.py and tests/test_math.py
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/test_math.py b/tests/test_math.py
--- a/tests/test_math.py
+++ b/tests/test_math.py
@@ -10,3 +10,4 @@
+@pytest.mark.skip(reason="broken")
 def test_division():
     assert divide(4, 2) == 2
EOF
run "$R"
check pytest-skip-rc "$CODE" 3 "exit 3 on added @pytest.mark.skip"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok pytest-skip-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad pytest-skip-status "unexpected status: $OUT" ;; esac

# --- 3. An added it.only -> DIFF_TESTS_WEAKENED ---------------------------
R="$(new_case it-only)"
set_brief "$R" <<'EOF'
Update UI components in src/app.js and tests/app.test.js
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/app.test.js b/tests/app.test.js
--- a/tests/app.test.js
+++ b/tests/app.test.js
@@ -5,3 +5,3 @@
-it("renders header", () => {
+it.only("renders header", () => {
     expect(header).toBeDefined();
 });
EOF
run "$R"
check it-only-rc "$CODE" 3 "exit 3 on added it.only"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok it-only-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad it-only-status "unexpected status: $OUT" ;; esac

# --- 4. assert x == 42 becoming assert True -> DIFF_TESTS_WEAKENED --------
R="$(new_case assert-true)"
set_brief "$R" <<'EOF'
Update math calculations in src/calc.py and tests/test_calc.py
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -5,2 +5,2 @@
-    assert compute_val() == 42
+    assert True
EOF
run "$R"
check assert-true-rc "$CODE" 3 "exit 3 on assertion rewritten to assert True"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok assert-true-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad assert-true-status "unexpected status: $OUT" ;; esac

# --- 5. An expected literal edited with no source change -> DIFF_SUSPICIOUS
R="$(new_case literal-edited)"
set_brief "$R" <<'EOF'
Update tests in tests/test_calc.py
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -5,2 +5,2 @@
-    assert compute_val() == 42
+    assert compute_val() == 99
EOF
run "$R"
check literal-edited-rc "$CODE" 0 "exit 0 on edited literal (suspicious advisory)"
case "$(word_of "$OUT")" in DIFF_SUSPICIOUS*) ok literal-edited-status "reported DIFF_SUSPICIOUS" ;;
  *) bad literal-edited-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"expected_literal_edited"*|*"literal"*) ok literal-edited-note "identified literal edit" ;;
  *) bad literal-edited-note "literal edit not mentioned: $OUT" ;; esac

# --- 6. A file touched that the brief did not name -> DIFF_SUSPICIOUS(scope: …)
R="$(new_case scope-creep)"
set_brief "$R" <<'EOF'
Update calculation in src/calc.py and tests in tests/test_calc.py
EOF
set_patch "$R" <<'EOF'
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
run "$R"
check scope-creep-rc "$CODE" 0 "exit 0 on scope creep (suspicious advisory)"
case "$(word_of "$OUT")" in DIFF_SUSPICIOUS*) ok scope-creep-status "reported DIFF_SUSPICIOUS" ;;
  *) bad scope-creep-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"scope:"*|*"src/unrelated.py"*) ok scope-creep-path "named unexpected file in scope" ;;
  *) bad scope-creep-path "unexpected path not cited: $OUT" ;; esac

# --- 7. An ordinary honest feature diff with tests added -> DIFF_CLEAN ----
R="$(new_case honest-diff)"
set_brief "$R" <<'EOF'
Implement multiply in src/calc.py and tests in tests/test_calc.py
EOF
set_patch "$R" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,3 @@
+def multiply(a, b):
+    return a * b
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,1 +1,3 @@
+def test_multiply():
+    assert multiply(2, 3) == 6
EOF
run "$R"
check honest-rc "$CODE" 0 "exit 0 on honest diff"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok honest-status "reported DIFF_CLEAN" ;;
  *) bad honest-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Checks:"*|*"Checked:"*) ok honest-checked "reported what was checked" ;;
  *) bad honest-checked "what was checked is missing from status: $OUT" ;; esac

# --- 8. A diff in an unsupported language -> DIFF_UNCHECKED ---------------
R="$(new_case unsupported-lang)"
set_brief "$R" <<'EOF'
Update ruby service in lib/service.rb
EOF
set_patch "$R" <<'EOF'
diff --git a/lib/service.rb b/lib/service.rb
--- a/lib/service.rb
+++ b/lib/service.rb
@@ -1,1 +1,2 @@
+def run; end
EOF
run "$R"
check unsup-rc "$CODE" 0 "exit 0 on unsupported language"
case "$(word_of "$OUT")" in DIFF_UNCHECKED*) ok unsup-status "reported DIFF_UNCHECKED" ;;
  *) bad unsup-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"lang=ruby"*) ok unsup-lang "identified language as ruby" ;;
  *) bad unsup-lang "language not identified: $OUT" ;; esac

# --- 9. A diff with no brief supplied -> scope reported as not run --------
R="$(new_case no-brief)"
set_patch "$R" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,3 @@
+def subtract(a, b):
+    return a - b
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,1 +1,3 @@
+def test_subtract():
+    assert subtract(5, 2) == 3
EOF
run "$R"
check nobrief-rc "$CODE" 0 "exit 0 when no brief supplied"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok nobrief-status "reported DIFF_CLEAN" ;;
  *) bad nobrief-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Scope: not run"*|*"no brief"*) ok nobrief-note "scope check reported as not run" ;;
  *) bad nobrief-note "unverified scope was not noted: $OUT" ;; esac

# --- 10. A bash diff from this repo's own history -> analysed, DIFF_CLEAN -
R="$(new_case bash-diff)"
set_brief "$R" <<'EOF'
Update scripts/check-review.sh and tests/check-review.sh
EOF
set_patch "$R" <<'EOF'
diff --git a/scripts/check-review.sh b/scripts/check-review.sh
--- a/scripts/check-review.sh
+++ b/scripts/check-review.sh
@@ -100,2 +100,4 @@
+# Add new check
+echo "checking"
diff --git a/tests/check-review.sh b/tests/check-review.sh
--- a/tests/check-review.sh
+++ b/tests/check-review.sh
@@ -50,2 +50,4 @@
+check new-case "$CODE" 0 "new case passes"
EOF
run "$R"
check bash-rc "$CODE" 0 "exit 0 on bash diff"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok bash-status "reported DIFF_CLEAN for bash diff" ;;
  *) bad bash-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Lang:"*bash*|*"bash"*) ok bash-lang "identified language as bash" ;;
  *) bad bash-lang "language bash not reported: $OUT" ;; esac

# --- 11. Falling assertion count -> DIFF_SUSPICIOUS -----------------------
R="$(new_case falling-asserts)"
set_brief "$R" <<'EOF'
Refactor tests in tests/test_calc.py
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -10,6 +10,2 @@
-    assert a == 1
-    assert b == 2
-    assert c == 3
-    assert d == 4
+    assert a == 1
EOF
run "$R"
check falling-rc "$CODE" 0 "exit 0 on falling assertion count"
case "$(word_of "$OUT")" in DIFF_SUSPICIOUS*) ok falling-status "reported DIFF_SUSPICIOUS" ;;
  *) bad falling-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"assertions_falling"*|*"-3"*) ok falling-detail "identified falling assertions" ;;
  *) bad falling-detail "falling assertions detail missing: $OUT" ;; esac

# --- 12. Go test skip -> DIFF_TESTS_WEAKENED ------------------------------
R="$(new_case go-skip)"
set_brief "$R" <<'EOF'
Update tests in pkg/calc_test.go
EOF
set_patch "$R" <<'EOF'
diff --git a/pkg/calc_test.go b/pkg/calc_test.go
--- a/pkg/calc_test.go
+++ b/pkg/calc_test.go
@@ -5,2 +5,3 @@
 func TestCalc(t *testing.T) {
+    t.Skip("skipping for now")
EOF
run "$R"
check go-skip-rc "$CODE" 3 "exit 3 on Go t.Skip"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok go-skip-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad go-skip-status "unexpected status: $OUT" ;; esac

# --- 12b. Rust #[ignore] -> DIFF_TESTS_WEAKENED ----------------------------
R="$(new_case rust-ignore)"
set_brief "$R" <<'EOF'
Update tests in tests/calc_test.rs
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/calc_test.rs b/tests/calc_test.rs
--- a/tests/calc_test.rs
+++ b/tests/calc_test.rs
@@ -1,3 +1,4 @@
+#[ignore]
 #[test]
 fn test_add() {
     assert_eq!(2 + 2, 4);
EOF
run "$R"
check rust-ignore-rc "$CODE" 3 "exit 3 on Rust #[ignore]"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok rust-ignore-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad rust-ignore-status "unexpected status: $OUT" ;; esac

# --- 12c. Java @Disabled -> DIFF_TESTS_WEAKENED ----------------------------
R="$(new_case java-disabled)"
set_brief "$R" <<'EOF'
Update tests in src/test/java/CalcTest.java
EOF
set_patch "$R" <<'EOF'
diff --git a/src/test/java/CalcTest.java b/src/test/java/CalcTest.java
--- a/src/test/java/CalcTest.java
+++ b/src/test/java/CalcTest.java
@@ -1,3 +1,4 @@
+@Disabled
 @Test
 public void testAdd() {
     assertEquals(4, 2 + 2);
EOF
run "$R"
check java-disabled-rc "$CODE" 3 "exit 3 on Java @Disabled"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok java-disabled-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad java-disabled-status "unexpected status: $OUT" ;; esac

# --- 12d. toBeDefined replacing value comparison -> DIFF_TESTS_WEAKENED ---
R="$(new_case to-be-defined)"
set_brief "$R" <<'EOF'
Update tests in tests/app.test.js
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/app.test.js b/tests/app.test.js
--- a/tests/app.test.js
+++ b/tests/app.test.js
@@ -5,2 +5,2 @@
-    expect(result).toBe(42);
+    expect(result).toBeDefined();
EOF
run "$R"
check to-be-defined-rc "$CODE" 3 "exit 3 on toBeDefined replacing value comparison"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok to-be-defined-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad to-be-defined-status "unexpected status: $OUT" ;; esac

# --- 13. Explicit arguments -----------------------------------------------
R="$(new_case explicit-args)"
mkdir -p "$R/custom"
printf 'Update pkg/calc.py\n' > "$R/custom/task.md"
cat > "$R/custom/diff.patch" <<'EOF'
diff --git a/pkg/calc.py b/pkg/calc.py
--- a/pkg/calc.py
+++ b/pkg/calc.py
@@ -1,1 +1,2 @@
+x = 1
EOF
run "$R" --patch "$R/custom/diff.patch" --brief "$R/custom/task.md"
check explicit-rc "$CODE" 0 "exit 0 with explicit --patch and --brief"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok explicit-status "reported DIFF_CLEAN" ;;
  *) bad explicit-status "unexpected status: $OUT" ;; esac

# --- 14. Output contract and argument handling ---------------------------
check stdout-lines "$(printf '%s\n' "$OUT" | grep -c .)" 1 "stdout is exactly one line"
case "$OUT" in STATUS:*) ok stdout-shape "starts with STATUS:" ;;
  *) bad stdout-shape "not a STATUS line: $OUT" ;; esac

OUT="$(/bin/bash "$CHECK" --dir "$ROOT/cases/honest-diff" --bogus 2>/dev/null)"; CODE=$?
check bad-arg "$CODE" 2 "exit 2 on unknown flag"

OUT="$(/bin/bash "$CHECK" --dir "$ROOT/nonexistent" 2>/dev/null)"; CODE=$?
check bad-dir "$CODE" 2 "exit 2 on missing dir"

# --- 15. Brief naming paths in prose -> scope check runs, DIFF_CLEAN ------
R="$(new_case brief-prose)"
set_brief "$R" <<'EOF'
Please update the calculation routines in src/calc.py and make sure all tests pass in tests/test_calc.py.
EOF
set_patch "$R" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,3 @@
+def divide(a, b):
+    return a / b
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,1 +1,3 @@
+def test_divide():
+    assert divide(4, 2) == 2
EOF
run "$R"
check brief-prose-rc "$CODE" 0 "exit 0 when brief names paths in prose"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok brief-prose-status "reported DIFF_CLEAN" ;;
  *) bad brief-prose-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Scope: clean"*|*"all paths in brief"*) ok brief-prose-scope "scope check ran and found no creep" ;;
  *) bad brief-prose-scope "scope clean was not reported: $OUT" ;; esac

# --- 16. Brief naming paths as a bulleted list -> scope check runs, DIFF_CLEAN
R="$(new_case brief-bullets)"
set_brief "$R" <<'EOF'
Task requirements:
* `src/calc.py`: add square function
* `tests/test_calc.py`: test square function
EOF
set_patch "$R" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,3 @@
+def square(a):
+    return a * a
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,1 +1,3 @@
+def test_square():
+    assert square(3) == 9
EOF
run "$R"
check brief-bullets-rc "$CODE" 0 "exit 0 when brief names paths in bulleted list"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok brief-bullets-status "reported DIFF_CLEAN" ;;
  *) bad brief-bullets-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Scope: clean"*|*"all paths in brief"*) ok brief-bullets-scope "scope check ran and found no creep" ;;
  *) bad brief-bullets-scope "scope clean was not reported: $OUT" ;; esac

# --- 17. Brief with genuine creep -> DIFF_SUSPICIOUS naming only unnamed file
R="$(new_case genuine-creep)"
set_brief "$R" <<'EOF'
Modify src/a.py only.
EOF
set_patch "$R" <<'EOF'
diff --git a/src/a.py b/src/a.py
--- a/src/a.py
+++ b/src/a.py
@@ -1,1 +1,2 @@
+val = 1
diff --git a/src/unrelated.py b/src/unrelated.py
--- a/src/unrelated.py
+++ b/src/unrelated.py
@@ -1,1 +1,2 @@
+val = 2
EOF
run "$R"
check genuine-creep-rc "$CODE" 0 "exit 0 on genuine scope creep"
case "$(word_of "$OUT")" in DIFF_SUSPICIOUS*) ok genuine-creep-status "reported DIFF_SUSPICIOUS" ;;
  *) bad genuine-creep-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"scope: src/unrelated.py"*) ok genuine-creep-file "named only the unexpected file in scope" ;;
  *) bad genuine-creep-file "expected 'scope: src/unrelated.py', got: $OUT" ;; esac
case "$OUT" in *"src/a.py"*) bad genuine-creep-named "incorrectly flagged named file src/a.py as creep: $OUT" ;;
  *) ok genuine-creep-named "did not flag named file as creep" ;; esac

# --- 18. Brief with no path-shaped token -> scope not run, not DIFF_SUSPICIOUS
R="$(new_case brief-no-paths)"
set_brief "$R" <<'EOF'
Refactor arithmetic operations to use faster algorithms.
EOF
set_patch "$R" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,3 @@
+def power(a, b):
+    return a ** b
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,1 +1,3 @@
+def test_power():
+    assert power(2, 3) == 8
EOF
run "$R"
check no-paths-rc "$CODE" 0 "exit 0 when brief has no path tokens"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok no-paths-status "reported DIFF_CLEAN (not DIFF_SUSPICIOUS)" ;;
  *) bad no-paths-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Scope: not run"*|*"no paths in brief"*) ok no-paths-scope "scope reported as not run" ;;
  *) bad no-paths-scope "scope not run was not reported: $OUT" ;; esac

# --- 19. Path named only in a prohibition touched -> DIFF_SUSPICIOUS(prohibited: …)
R="$(new_case scope-prohibited-only)"
set_brief "$R" <<'EOF'
Fix resolve-criteria composition. Do not modify tests/resolve-criteria.sh.
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/resolve-criteria.sh b/tests/resolve-criteria.sh
--- a/tests/resolve-criteria.sh
+++ b/tests/resolve-criteria.sh
@@ -1,1 +1,2 @@
+# modified
EOF
run "$R"
check scope-prohib-rc "$CODE" 0 "exit 0 on touched prohibited file (suspicious advisory)"
case "$(word_of "$OUT")" in DIFF_SUSPICIOUS*) ok scope-prohib-status "reported DIFF_SUSPICIOUS" ;;
  *) bad scope-prohib-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"prohibited: tests/resolve-criteria.sh"*) ok scope-prohib-finding "named prohibited file in finding" ;;
  *) bad scope-prohib-finding "prohibited file not cited: $OUT" ;; esac
case "$OUT" in *"Scope: prohibited (tests/resolve-criteria.sh)"*) ok scope-prohib-scope "scope field reported prohibited" ;;
  *) bad scope-prohib-scope "scope field not reported as prohibited: $OUT" ;; esac

# --- 20. Path named in ordinary instruction touched while other path prohibited -> DIFF_CLEAN
R="$(new_case scope-instruction-permitted)"
set_brief "$R" <<'EOF'
Update src/calc.py and tests/test_calc.py. Do not modify tests/resolve-criteria.sh.
EOF
set_patch "$R" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,2 @@
+def add(a, b): return a + b
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,1 +1,3 @@
+def test_add():
+    assert add(1, 2) == 3
EOF
run "$R"
check scope-perm-rc "$CODE" 0 "exit 0 when touched files are permitted"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok scope-perm-status "reported DIFF_CLEAN" ;;
  *) bad scope-perm-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Scope: clean (all paths in brief)"*) ok scope-perm-scope "scope reported clean" ;;
  *) bad scope-perm-scope "scope clean was not reported: $OUT" ;; esac

# --- 21. Path named both ways treated as denied -> DIFF_SUSPICIOUS(prohibited: …)
R="$(new_case scope-named-both-ways)"
set_brief "$R" <<'EOF'
Work on src/calc.py and tests/test_calc.py.

## Do not
Do not modify tests/test_calc.py.
EOF
set_patch "$R" <<'EOF'
diff --git a/src/calc.py b/src/calc.py
--- a/src/calc.py
+++ b/src/calc.py
@@ -1,1 +1,2 @@
+def add(a, b): return a + b
diff --git a/tests/test_calc.py b/tests/test_calc.py
--- a/tests/test_calc.py
+++ b/tests/test_calc.py
@@ -1,1 +1,3 @@
+def test_add():
+    assert add(1, 2) == 3
EOF
run "$R"
check scope-both-rc "$CODE" 0 "exit 0 on path named both ways (denied advisory)"
case "$(word_of "$OUT")" in DIFF_SUSPICIOUS*) ok scope-both-status "reported DIFF_SUSPICIOUS" ;;
  *) bad scope-both-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"prohibited: tests/test_calc.py"*) ok scope-both-finding "named both-ways path as prohibited" ;;
  *) bad scope-both-finding "prohibited path not cited: $OUT" ;; esac

# --- 22. Exact match replaced by substring match -> DIFF_TESTS_WEAKENED (exit 3)
R="$(new_case assert-substring-match)"
set_brief "$R" <<'EOF'
Fix error formatting in src/parser.py and tests in tests/test_parser.py
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/test_parser.py b/tests/test_parser.py
--- a/tests/test_parser.py
+++ b/tests/test_parser.py
@@ -10,2 +10,2 @@
-    assert parse_error() == "SyntaxError: invalid token at line 42"
+    assert "invalid token" in parse_error()
EOF
run "$R"
check assert-substring-rc "$CODE" 3 "exit 3 on exact equality replaced by substring match"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok assert-substring-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad assert-substring-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"substring match"*|*"comparison_weakened"*) ok assert-substring-detail "detail cited comparison weakening" ;;
  *) bad assert-substring-detail "weakening detail missing: $OUT" ;; esac

# --- 23. JS exact equality replaced by substring match -> DIFF_TESTS_WEAKENED (exit 3)
R="$(new_case js-contain-match)"
set_brief "$R" <<'EOF'
Update response handling in src/app.js and tests/app.test.js
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/app.test.js b/tests/app.test.js
--- a/tests/app.test.js
+++ b/tests/app.test.js
@@ -10,2 +10,2 @@
-    expect(response.body).toBe("exact status message from backend");
+    expect(response.body).toContain("status message");
EOF
run "$R"
check js-contain-rc "$CODE" 3 "exit 3 on expect().toBe() replaced by expect().toContain()"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok js-contain-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad js-contain-status "unexpected status: $OUT" ;; esac

# --- 24. Bash check exact match replaced by single-line case glob -> DIFF_TESTS_WEAKENED (exit 3)
R="$(new_case bash-glob-single-line)"
set_brief "$R" <<'EOF'
Update scripts/cli.sh and tests/cli.sh
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/cli.sh b/tests/cli.sh
--- a/tests/cli.sh
+++ b/tests/cli.sh
@@ -10,2 +10,2 @@
-check legacy-scoped "$NOTE" "exact message" "exact check"
+case "$NOTE" in *"SKILL.md"*) bad legacy-scoped ;; *) ok legacy-scoped ;; esac
EOF
run "$R"
check bash-glob-single-rc "$CODE" 3 "exit 3 on single-line case glob replacing exact check"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok bash-glob-single-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad bash-glob-single-status "unexpected status: $OUT" ;; esac
SINGLE_STATUS="$(word_of "$OUT")"
SINGLE_CODE="$CODE"

# --- 25. Bash check exact match replaced by multi-line case glob -> DIFF_TESTS_WEAKENED (exit 3)
R="$(new_case bash-glob-multi-line)"
set_brief "$R" <<'EOF'
Update scripts/cli.sh and tests/cli.sh
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/cli.sh b/tests/cli.sh
--- a/tests/cli.sh
+++ b/tests/cli.sh
@@ -10,2 +10,4 @@
-check legacy-scoped "$NOTE" "exact message" "exact check"
+case "$NOTE" in
+  *"SKILL.md"*) bad legacy-scoped "leaked" ;;
+  *) ok legacy-scoped "fine" ;;
+esac
EOF
run "$R"
check bash-glob-multi-rc "$CODE" 3 "exit 3 on multi-line case glob replacing exact check"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok bash-glob-multi-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad bash-glob-multi-status "unexpected status: $OUT" ;; esac
check bash-glob-status-match "$(word_of "$OUT")" "$SINGLE_STATUS" "single-line and multi-line produce identical status"
check bash-glob-code-match "$CODE" "$SINGLE_CODE" "single-line and multi-line produce identical exit code"

# --- 26. Case statement added where nothing was removed -> DIFF_CLEAN (exit 0)
R="$(new_case bash-case-added-clean)"
set_brief "$R" <<'EOF'
Update scripts/cli.sh and tests/cli.sh
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/cli.sh b/tests/cli.sh
--- a/tests/cli.sh
+++ b/tests/cli.sh
@@ -10,0 +11,4 @@
+case "$NOTE" in
+  *"SKILL.md"*) bad legacy-scoped "leaked" ;;
+  *) ok legacy-scoped "fine" ;;
+esac
EOF
run "$R"
check bash-case-added-rc "$CODE" 0 "exit 0 on added case statement where nothing removed"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok bash-case-added-status "reported DIFF_CLEAN" ;;
  *) bad bash-case-added-status "unexpected status: $OUT" ;; esac

# --- 27. Case statement in a non-test file -> DIFF_CLEAN (exit 0)
R="$(new_case bash-case-non-test)"
set_brief "$R" <<'EOF'
Update scripts/cli.sh and tests/cli.sh
EOF
set_patch "$R" <<'EOF'
diff --git a/scripts/cli.sh b/scripts/cli.sh
--- a/scripts/cli.sh
+++ b/scripts/cli.sh
@@ -10,2 +10,4 @@
-if [ "$1" = "exact" ]; then
+case "$1" in
+  *"SKILL.md"*) echo "matched" ;;
+  *) echo "other" ;;
+esac
EOF
run "$R"
check bash-case-nontest-rc "$CODE" 0 "exit 0 on case statement in non-test file"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok bash-case-nontest-status "reported DIFF_CLEAN" ;;
  *) bad bash-case-nontest-status "unexpected status: $OUT" ;; esac

# --- 28. Existing case statement merely reindented -> DIFF_CLEAN (exit 0)
R="$(new_case bash-case-reindented)"
set_brief "$R" <<'EOF'
Update scripts/cli.sh and tests/cli.sh
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/cli.sh b/tests/cli.sh
--- a/tests/cli.sh
+++ b/tests/cli.sh
@@ -10,4 +10,4 @@
 case "$NOTE" in
-  *"SKILL.md"*) bad legacy-scoped "leaked" ;;
-  *) ok legacy-scoped "fine" ;;
+    *"SKILL.md"*) bad legacy-scoped "leaked" ;;
+    *) ok legacy-scoped "fine" ;;
 esac
EOF
run "$R"
check bash-case-reindent-rc "$CODE" 0 "exit 0 on reindented case statement arms"
case "$(word_of "$OUT")" in DIFF_CLEAN) ok bash-case-reindent-status "reported DIFF_CLEAN" ;;
  *) bad bash-case-reindent-status "unexpected status: $OUT" ;; esac

# --- 29. Multi-line case statement followed by trailing lines in hunk -> stops at esac
R="$(new_case bash-case-trailing)"
set_brief "$R" <<'EOF'
Update scripts/cli.sh and tests/cli.sh
EOF
set_patch "$R" <<'EOF'
diff --git a/tests/cli.sh b/tests/cli.sh
--- a/tests/cli.sh
+++ b/tests/cli.sh
@@ -10,2 +10,6 @@
-check cli-out "$OUT" "exact CLI response output" "cli outputs exact match"
+case "$OUT" in
+  *"response output"*) ok cli-out "cli outputs match" ;;
+  *) bad cli-out "no match" ;;
+esac
+echo "unrelated * line"
EOF
run "$R"
check bash-case-trailing-rc "$CODE" 3 "exit 3 on multiline case statement with trailing lines"
case "$(word_of "$OUT")" in DIFF_TESTS_WEAKENED*) ok bash-case-trailing-status "reported DIFF_TESTS_WEAKENED" ;;
  *) bad bash-case-trailing-status "unexpected status: $OUT" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
