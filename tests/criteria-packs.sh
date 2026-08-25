#!/usr/bin/env bash
# Exercise composable criteria packs in resolve-criteria.sh: language detection
# from REVIEW_DIFF.stat, concern selection from agy.toml, concatenation with
# base.md, capping / truncation reporting, and regression guard on project overrides.
#
#   tests/criteria-packs.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$HERE/../scripts/resolve-criteria.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
VENDORED="$HERE/../criteria"
[ -f "$RESOLVE" ] || { echo "criteria-packs-test: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "criteria-packs-test: run-dir.sh not found next door" >&2; exit 2; }

. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/criteria-packs.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() {
  local r="$ROOT/repos/$1"; mkdir -p "$r"
  ( cd "$r" && git init -q . )
  run_dir_new --dir "$r" --task "criteria pack test $1" >/dev/null
  printf '%s' "$r"
}

pdir() {
  local repo="$1"
  local id
  id="$(cat "$repo/.agy/current" 2>/dev/null || true)"
  [ -n "$id" ] && printf '%s/.agy/runs/%s' "$repo" "$id"
}

set_stat() {
  local repo="$1"
  local rdir
  rdir="$(pdir "$repo")"
  mkdir -p "$rdir"
  cat > "$rdir/REVIEW_DIFF.stat"
}

# run <repo> <args...> -> OUT (stdout), STDERR (stderr), CODE (exit code)
run() {
  local r="$1"; shift
  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/cp-run.XXXXXX")"
  /bin/bash "$RESOLVE" "$@" --dir "$r" >"$work/out" 2>"$work/err"
  CODE=$?
  OUT="$(cat "$work/out")"
  STDERR="$(cat "$work/err")"
  rm -rf "$work"
}

# --- 1. Python diff composes base + lang/python, STATUS names both ---------
R="$(new_repo python-diff)"
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
# This list is complete even when REVIEW_DIFF.patch is truncated.
#
 src/app.py | 12 ++++++------
 1 file changed, 6 insertions(+), 6 deletions(-)
EOF
run "$R" code-review
check py-rc "$CODE" 0 "exit 0 on Python diff"
check py-dest "$OUT" "$(pdir "$R")/criteria/code-review.md" "installed at run criteria path"
[ -f "$OUT" ] && ok py-exists "composed file exists" || bad py-exists "no file at $OUT"
if grep -q "Mutable default arguments" "$OUT" 2>/dev/null; then
  ok py-content "contains python language pack checks"
else
  bad py-content "missing python language checks in composed file"
fi
if grep -q "Axis 1 — Standards" "$OUT" 2>/dev/null; then
  ok py-base "contains base criteria"
else
  bad py-base "missing base criteria in composed file"
fi
case "$STDERR" in
  *"STATUS: CRITERIA_COMPOSED"*|*"CRITERIA_COMPOSED"*)
    ok py-status-type "status reports CRITERIA_COMPOSED" ;;
  *) bad py-status-type "status line missing or wrong: $STDERR" ;;
esac
if printf '%s\n' "$STDERR" | grep -q "base" && printf '%s\n' "$STDERR" | grep -q "lang/python"; then
  ok py-status-packs "STATUS names both base and lang/python"
else
  bad py-status-packs "STATUS did not name base and lang/python: $STDERR"
fi

# --- 2. Python + TypeScript diff composes both lang packs -------------------
R="$(new_repo multi-lang)"
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
# This list is complete even when REVIEW_DIFF.patch is truncated.
#
 backend/api.py   | 10 +++++-----
 frontend/app.tsx | 24 ++++++++++++++++++++++++
 2 files changed, 29 insertions(+), 5 deletions(-)
EOF
run "$R" code-review
check multi-rc "$CODE" 0 "exit 0 on multi-language diff"
if grep -q "Mutable default arguments" "$OUT" 2>/dev/null \
  && grep -q "Type safety escapes" "$OUT" 2>/dev/null; then
  ok multi-content "contains both Python and TypeScript packs"
else
  bad multi-content "missing Python or TypeScript checks in composed file"
fi
if printf '%s\n' "$STDERR" | grep -q "lang/python" && printf '%s\n' "$STDERR" | grep -q "lang/typescript"; then
  ok multi-status "STATUS names both lang/python and lang/typescript"
else
  bad multi-status "STATUS missing python or typescript pack names: $STDERR"
fi

# --- 3. Diff in language with no pack composes base alone and says so -------
R="$(new_repo unknown-lang)"
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
# This list is complete even when REVIEW_DIFF.patch is truncated.
#
 src/Main.kt     | 40 ++++++++++++++++++++++++++++++++++++++++
 docs/README.txt |  5 +++++
 2 files changed, 45 insertions(+)
EOF
run "$R" code-review
check unk-rc "$CODE" 0 "exit 0 on diff with no language pack"
if grep -q "Axis 1 — Standards" "$OUT" 2>/dev/null; then
  ok unk-base "contains base criteria"
else
  bad unk-base "missing base criteria"
fi
if grep -q "Python language checks" "$OUT" 2>/dev/null \
  || grep -q "TypeScript language checks" "$OUT" 2>/dev/null; then
  bad unk-no-langs "composed language packs for unknown language"
else
  ok unk-no-langs "no language packs included for unknown language"
fi
case "$STDERR" in
  *"no language pack applied"*|*"Langs: none"*)
    ok unk-status "STATUS reports no language pack applied" ;;
  *) bad unk-status "STATUS did not report that no language pack applied: $STDERR" ;;
esac

# --- 4. Project naming concern pack in agy.toml gets it included -----------
R="$(new_repo concern-config)"
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
# This list is complete even when REVIEW_DIFF.patch is truncated.
#
 src/server.py | 15 +++++++++++++++
 1 file changed, 15 insertions(+)
EOF
cat > "$R/agy.toml" <<'EOF'
[criteria]
concerns = ["security", "performance"]
EOF
run "$R" code-review
check concern-rc "$CODE" 0 "exit 0 with concerns configured"
if grep -q "Command injection" "$OUT" 2>/dev/null \
  && grep -q "N+1 query patterns" "$OUT" 2>/dev/null; then
  ok concern-content "contains security and performance concern checks"
else
  bad concern-content "missing configured concern packs in composed file"
fi
if printf '%s\n' "$STDERR" | grep -q "concern/security" && printf '%s\n' "$STDERR" | grep -q "concern/performance"; then
  ok concern-status "STATUS names concern/security and concern/performance"
else
  bad concern-status "STATUS missing configured concern pack names: $STDERR"
fi

# --- 5. Project naming nonexistent pack is refused with clear message -------
R="$(new_repo bad-pack)"
cat > "$R/agy.toml" <<'EOF'
[criteria]
concerns = ["security", "nonexistent_pack_xyz"]
EOF
run "$R" code-review
if [ "$CODE" -ne 0 ]; then
  ok bad-pack-rc "refuses with non-zero exit code when pack not found"
else
  bad bad-pack-rc "expected non-zero exit code on nonexistent pack, got 0"
fi
case "$STDERR" in
  *"nonexistent_pack_xyz"*)
    ok bad-pack-msg "stderr mentions the unknown pack name" ;;
  *) bad bad-pack-msg "stderr did not name the missing pack: $STDERR" ;;
esac

# --- 6. Composed file lands at single worker path and is one file ----------
R="$(new_repo single-file)"
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
#
 src/app.go | 10 +++++-----
 1 file changed, 5 insertions(+), 5 deletions(-)
EOF
run "$R" code-review
check single-rc "$CODE" 0 "exit 0"
check single-dest "$OUT" "$(pdir "$R")/criteria/code-review.md" "lands at single worker path"
STDOUT_LINES="$(printf '%s\n' "$OUT" | grep -c .)"
check single-stdout-lines "$STDOUT_LINES" 1 "stdout is exactly one line"
FILE_COUNT="$(find "$(pdir "$R")/criteria" -type f | grep -c .)"
check single-file-count "$FILE_COUNT" 1 "exactly one file in destination criteria dir"

# --- 7. Oversized composition is capped, reported, and names what dropped --
R="$(new_repo capped-composition)"
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
#
 src/app.py   | 10 +++++-----
 src/index.ts | 10 +++++-----
 src/main.go  | 10 +++++-----
 3 files changed, 15 insertions(+), 15 deletions(-)
EOF
cat > "$R/agy.toml" <<'EOF'
[criteria]
concerns = ["security", "performance", "accessibility", "api-compat"]
EOF
# Cap lines to 220 so base fits but remaining packs exceed cap and are dropped
run "$R" code-review --max-lines 220
check capped-rc "$CODE" 0 "exit 0 on capped composition"
case "$STDERR" in
  *"STATUS: CRITERIA_TRUNCATED"*|*"CRITERIA_TRUNCATED"*)
    ok capped-status-type "STATUS reports CRITERIA_TRUNCATED" ;;
  *) bad capped-status-type "STATUS did not report CRITERIA_TRUNCATED: $STDERR" ;;
esac
if printf '%s\n' "$STDERR" | grep -q "Dropped:" && (printf '%s\n' "$STDERR" | grep -q "lang/" || printf '%s\n' "$STDERR" | grep -q "concern/"); then
  ok capped-dropped-named "STATUS names dropped packs"
else
  bad capped-dropped-named "STATUS did not name dropped packs: $STDERR"
fi

# --- 8. Project override still overrides everything and composes nothing ----
R="$(new_repo project-override-regression)"
mkdir -p "$R/.claude/criteria"
cat > "$R/.claude/criteria/code-review.md" <<'EOF'
# Project Custom Bar
This repo enforces strictly custom criteria.
EOF
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
#
 src/app.py | 10 +++++-----
 1 file changed, 5 insertions(+), 5 deletions(-)
EOF
cat > "$R/agy.toml" <<'EOF'
[criteria]
concerns = ["security"]
EOF
run "$R" code-review
check override-rc "$CODE" 0 "exit 0 on project override"
if grep -q "This repo enforces strictly custom criteria" "$OUT" 2>/dev/null; then
  ok override-content "project override document installed"
else
  bad override-content "project override document was not installed"
fi
if grep -q "Mutable default arguments" "$OUT" 2>/dev/null \
  || grep -q "Command injection" "$OUT" 2>/dev/null; then
  bad override-nocompose "override was composed with lang/concern packs"
else
  ok override-nocompose "override was not composed — project bar wins outright"
fi
case "$STDERR" in
  *"CRITERIA_OVERRIDDEN"*|*"project override"*)
    ok override-status "STATUS indicates project override was used" ;;
  *) bad override-status "STATUS did not report project override: $STDERR" ;;
esac

# --- 9. Bash detection: .sh file and shebang-only bash file -----------------
# 9a. .sh extension
R="$(new_repo bash-ext)"
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
#
 scripts/deploy.sh | 10 +++++-----
 1 file changed, 5 insertions(+), 5 deletions(-)
EOF
run "$R" code-review
check bash-ext-rc "$CODE" 0 "exit 0 on .sh diff"
if grep -q "Unquoted variable expansions" "$OUT" 2>/dev/null; then
  ok bash-ext-content "contains bash language checks for .sh file"
else
  bad bash-ext-content "missing bash checks for .sh file"
fi
case "$STDERR" in
  *"lang/bash"*) ok bash-ext-status "STATUS names lang/bash for .sh file" ;;
  *) bad bash-ext-status "STATUS missing lang/bash: $STDERR" ;;
esac

# 9b. Shebang only
R="$(new_repo bash-shebang)"
mkdir -p "$R/bin"
cat > "$R/bin/service-runner" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "starting"
EOF
set_stat "$R" <<'EOF'
# REVIEW_DIFF.stat — every file the change touches, against HEAD
#
 bin/service-runner | 8 ++++++++
 1 file changed, 8 insertions(+)
EOF
run "$R" code-review
check bash-shebang-rc "$CODE" 0 "exit 0 on shebang-only bash file"
if grep -q "Unquoted variable expansions" "$OUT" 2>/dev/null; then
  ok bash-shebang-content "contains bash language checks for shebang-only file"
else
  bad bash-shebang-content "missing bash checks for shebang-only file"
fi
case "$STDERR" in
  *"lang/bash"*) ok bash-shebang-status "STATUS names lang/bash for shebang-only file" ;;
  *) bad bash-shebang-status "STATUS missing lang/bash: $STDERR" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
