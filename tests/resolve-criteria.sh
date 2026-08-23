#!/usr/bin/env bash
# Exercise resolve-criteria.sh: which tier wins, and the copy that puts the
# chosen file inside --add-dir where an accept-edits worker can actually read it.
#
#   tests/resolve-criteria.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$HERE/../scripts/resolve-criteria.sh"
VENDORED="$HERE/../criteria"
[ -f "$RESOLVE" ] || { echo "resolve-criteria-test: script not found next door" >&2; exit 2; }

# Normalised through `cd`, because $TMPDIR carries a trailing slash on macOS and
# the script prints paths that have been through the same normalisation. Without
# this every path comparison below fails on a doubled slash.
ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/resolve-criteria.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() { R="$ROOT/repos/$1"; mkdir -p "$R"; ( cd "$R" && git init -q . ); printf '%s' "$R"; }

# run <repo> <args...> — path into $OUT, exit code into $CODE.
run() { R="$1"; shift; OUT="$(/bin/bash "$RESOLVE" "$@" --dir "$R" 2>/dev/null)"; CODE=$?; }

# --- the vendored default -------------------------------------------------

# 1. A repo with no criteria of its own still gets a file, and it is the
#    vendored one — this is what "resolution never fails" has to mean.
R="$(new_repo vendored)"
run "$R" code-review
check vendored-rc "$CODE" 0 "exit 0 with only the vendored default"
check vendored-dest "$OUT" "$R/.tmp/criteria/code-review.md" "installed under the repo's .tmp/"
[ -f "$OUT" ] && ok vendored-exists "the installed file is really there" \
              || bad vendored-exists "nothing at the printed path"
if diff -q "$VENDORED/code-review.md" "$OUT" >/dev/null 2>&1; then
  ok vendored-content "the copy matches the vendored source"
else
  bad vendored-content "the copy differs from its source"
fi

# 2. The whole point: the path handed to the brief is inside the repo, so it is
#    inside --add-dir. A path outside aborts an accept-edits run outright.
case "$OUT" in "$R"/*) ok vendored-inside "the printed path is inside the repo" ;;
  *) bad vendored-inside "printed a path outside --add-dir: $OUT" ;; esac

# 3. qa resolves independently of code-review.
run "$R" qa
check qa-dest "$OUT" "$R/.tmp/criteria/qa.md" "qa installs alongside it"
if diff -q "$VENDORED/qa.md" "$OUT" >/dev/null 2>&1; then
  ok qa-content "the qa copy matches its source"
else
  bad qa-content "the qa copy differs from its source"
fi

# --- the project's own bar ------------------------------------------------

# 4. Tier 1 outranks the vendored default.
R="$(new_repo project-bar)"
mkdir -p "$R/.claude/criteria"
printf '# Project bar\nonly this project says so\n' > "$R/.claude/criteria/code-review.md"
run "$R" code-review
check tier1-rc "$CODE" 0 "exit 0 on a project override"
if grep -q 'only this project says so' "$OUT" 2>/dev/null; then
  ok tier1-wins "the project's own file won"
else
  bad tier1-wins "the vendored default overrode the project's"
fi
check tier1-dest "$OUT" "$R/.tmp/criteria/code-review.md" "copied like any other tier"

# 5. An override for one name does not capture the other.
run "$R" qa
if grep -q 'only this project says so' "$OUT" 2>/dev/null; then
  bad tier1-scoped "the code-review override leaked into qa"
else
  ok tier1-scoped "qa still falls back to the vendored default"
fi

# --- the Claude-skill tier is gone ----------------------------------------

# 6. A file at the old tier-2 location must not be picked up. It cannot be
#    created under $HOME from a test, so this asserts the weaker but sufficient
#    thing: the vendored default wins in a repo with no override, whatever the
#    developer happens to have installed in ~/.claude/skills.
R="$(new_repo no-skill-tier)"
run "$R" code-review
if diff -q "$VENDORED/code-review.md" "$OUT" >/dev/null 2>&1; then
  ok skill-tier-gone "a user's ~/.claude skill no longer outranks the vendored file"
else
  bad skill-tier-gone "resolution picked something other than the vendored file"
fi

# --- refresh --------------------------------------------------------------

# 7. A stale copy is replaced, not reused: it lives in .tmp/ scratch, and a left
#    over copy would review this run's diff against a previous run's bar.
R="$(new_repo refresh)"
mkdir -p "$R/.tmp/criteria"
printf 'STALE\n' > "$R/.tmp/criteria/code-review.md"
run "$R" code-review
if grep -q 'STALE' "$OUT" 2>/dev/null; then
  bad refresh "the stale copy survived"
else
  ok refresh "the stale copy was overwritten"
fi

# --- inspection path ------------------------------------------------------

# 8. --print-source still names the tier that won, without copying.
R="$(new_repo print-source)"
run "$R" code-review --print-source
check src-rc "$CODE" 0 "exit 0 with --print-source"
case "$OUT" in "$R"/*) bad src-path "printed the copy, not the source" ;;
  *) ok src-path "printed the source path outside the repo" ;; esac
[ -e "$R/.tmp/criteria/code-review.md" ] \
  && bad src-nocopy "--print-source copied anyway" \
  || ok src-nocopy "--print-source copied nothing"

# --- --into ---------------------------------------------------------------

# 9. --into redirects the copy.
R="$(new_repo into)"
run "$R" code-review --into "$R/elsewhere"
check into-dest "$OUT" "$R/elsewhere/code-review.md" "--into moves the copy"
[ -f "$R/elsewhere/code-review.md" ] && ok into-exists "the redirected copy exists" \
                                     || bad into-exists "nothing at the --into path"

# --- argument handling ----------------------------------------------------

R="$(new_repo args)"
run "$R" bogus
check bad-name "$CODE" 2 "exit 2 on an unknown criteria name"
run "$R"
check no-name "$CODE" 2 "exit 2 when no name is given"
OUT="$(/bin/bash "$RESOLVE" code-review --dir "$ROOT/nope" 2>/dev/null)"; CODE=$?
check bad-dir "$CODE" 2 "exit 2 on a missing --dir"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
