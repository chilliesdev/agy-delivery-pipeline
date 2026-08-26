#!/usr/bin/env bash
# Exercise resolve-criteria.sh: which tier wins, and the copy that puts the
# chosen file inside --add-dir where an accept-edits worker can actually read it.
# All three names — code-review, qa and release — plus the legacy release path
# that is deliberately not a source and deliberately not silent about it.
#
#   tests/resolve-criteria.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$HERE/../scripts/resolve-criteria.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
VENDORED="$HERE/../criteria"
[ -f "$RESOLVE" ] || { echo "resolve-criteria-test: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "resolve-criteria-test: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

# Normalised through `cd`, because $TMPDIR carries a trailing slash on macOS and
# the script prints paths that have been through the same normalisation. Without
# this every path comparison below fails on a doubled slash.
ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/resolve-criteria.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q . )
  run_dir_new --dir "$R" --task "criteria test $1" >/dev/null
  printf '%s' "$R"
}

pdir() {
  local repo="$1"
  local id
  id="$(cat "$repo/.agy/current" 2>/dev/null || true)"
  [ -n "$id" ] && printf '%s/.agy/runs/%s' "$repo" "$id"
}

# run <repo> <args...> — path into $OUT, exit code into $CODE.
run() { R="$1"; shift; OUT="$(/bin/bash "$RESOLVE" "$@" --dir "$R" 2>/dev/null)"; CODE=$?; }

# --- the vendored default -------------------------------------------------

# 1. A repo with no criteria of its own still gets a file, and it is the
#    vendored one — this is what "resolution never fails" has to mean.
R="$(new_repo vendored)"
run "$R" code-review
check vendored-rc "$CODE" 0 "exit 0 with only the vendored default"
check vendored-dest "$OUT" "$(pdir "$R")/criteria/code-review.md" "installed under the repo's run criteria"
[ -f "$OUT" ] && ok vendored-exists "the installed file is really there" \
              || bad vendored-exists "nothing at the printed path"
if diff -q "$VENDORED/code-review/base.md" "$OUT" >/dev/null 2>&1; then
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
check qa-dest "$OUT" "$(pdir "$R")/criteria/qa.md" "qa installs alongside it"
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
check tier1-dest "$OUT" "$(pdir "$R")/criteria/code-review.md" "copied like any other tier"

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
if diff -q "$VENDORED/code-review/base.md" "$OUT" >/dev/null 2>&1; then
  ok skill-tier-gone "a user's ~/.claude skill no longer outranks the vendored file"
else
  bad skill-tier-gone "resolution picked something other than the vendored file"
fi

# --- refresh --------------------------------------------------------------

# 7. A stale copy is replaced, not reused: it lives in run criteria, and a left
#    over copy would review this run's diff against a previous run's bar.
R="$(new_repo refresh)"
mkdir -p "$(pdir "$R")/criteria"
printf 'STALE\n' > "$(pdir "$R")/criteria/code-review.md"
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
[ -e "$(pdir "$R")/criteria/code-review.md" ] \
  && bad src-nocopy "--print-source copied anyway" \
  || ok src-nocopy "--print-source copied nothing"

# --- --into ---------------------------------------------------------------

# 9. --into redirects the copy.
R="$(new_repo into)"
run "$R" code-review --into "$R/elsewhere"
check into-dest "$OUT" "$R/elsewhere/code-review.md" "--into moves the copy"
[ -f "$R/elsewhere/code-review.md" ] && ok into-exists "the redirected copy exists" \
                                     || bad into-exists "nothing at the --into path"

# --- the release flow -----------------------------------------------------

# 10. The third name resolves like the other two. Phase 4 is the phase that
#     touches irreversible git state, so "there is always a document to install,
#     and it is always inside --add-dir" matters there more than anywhere.
R="$(new_repo release-vendored)"
run "$R" release
check release-rc "$CODE" 0 "exit 0 with only the vendored default"
check release-dest "$OUT" "$(pdir "$R")/criteria/release.md" "release installs under the repo's run criteria"
if diff -q "$VENDORED/release.md" "$OUT" >/dev/null 2>&1; then
  ok release-content "the copy matches the vendored release flow"
else
  bad release-content "the copy differs from its source"
fi
case "$OUT" in "$R"/*) ok release-inside "the printed path is inside the repo" ;;
  *) bad release-inside "printed a path outside --add-dir: $OUT" ;; esac

# 11. A project can override it, same as the other two.
R="$(new_repo release-override)"
mkdir -p "$R/.claude/criteria"
printf '# Our release flow\nwe tag differently here\n' > "$R/.claude/criteria/release.md"
run "$R" release
if grep -q 'we tag differently here' "$OUT" 2>/dev/null; then
  ok release-tier1 "the project's own release flow won"
else
  bad release-tier1 "the vendored default overrode the project's"
fi

# --- the legacy git-release-flow path -------------------------------------

# 12. `.claude/skills/git-release-flow/SKILL.md` is the path the old Phase 4
#     named — and it is deliberately not a source. It is a Claude Code skill by
#     construction (sub-agents, slash commands, asking the user), nothing ever
#     specified its contents, and this is the one phase where a worker acting on
#     unspecified git instructions is dangerous.
R="$(new_repo legacy-skill)"
mkdir -p "$R/.claude/skills/git-release-flow"
printf '# git-release-flow\nask the user, then push to origin\n' \
  > "$R/.claude/skills/git-release-flow/SKILL.md"
run "$R" release
check legacy-rc "$CODE" 0 "exit 0 with a legacy skill present"
if grep -q 'ask the user' "$OUT" 2>/dev/null; then
  bad legacy-ignored "the legacy skill was installed as the release flow"
else
  ok legacy-ignored "the legacy skill is not read — the vendored flow won"
fi
check legacy-lines "$(printf '%s\n' "$OUT" | grep -c .)" 1 "stdout is still the single path callers parse"

# 13. Not silently, though. Someone who did what the old text told them to do
#     gets a line naming their file and where to move it — on stderr, which is
#     the only place it can go without breaking every caller.
NOTE="$(/bin/bash "$RESOLVE" release --dir "$R" 2>&1 >/dev/null)"
case "$NOTE" in *"git-release-flow/SKILL.md"*) ok legacy-note "stderr names the file that was skipped" ;;
  *) bad legacy-note "the legacy file was dropped without a word: $NOTE" ;; esac
case "$NOTE" in *".claude/criteria/release.md"*) ok legacy-note-where "and says where to move it" ;;
  *) bad legacy-note-where "the note does not say what to do: $NOTE" ;; esac

# 14. The note is scoped: it is about the release name, and about a file that is
#     actually there.
NOTE="$(/bin/bash "$RESOLVE" code-review --dir "$R" 2>&1 >/dev/null)"
check legacy-scoped "$NOTE" "" "no note on code-review, legacy file or not"
R="$(new_repo no-legacy)"
NOTE="$(/bin/bash "$RESOLVE" release --dir "$R" 2>&1 >/dev/null)"
check legacy-quiet "$NOTE" "" "and none at all when there is no legacy file"

# --- argument handling ----------------------------------------------------

R="$(new_repo args)"
run "$R" bogus
check bad-name "$CODE" 2 "exit 2 on an unknown criteria name"
run "$R"
check no-name "$CODE" 2 "exit 2 when no name is given"
OUT="$(/bin/bash "$RESOLVE" code-review --dir "$ROOT/nope" 2>/dev/null)"; CODE=$?
check bad-dir "$CODE" 2 "exit 2 on a missing --dir"

# --- single vendored source per criteria ----------------------------------

# Exactly one vendored source per criteria name: prevents standalone copies
# from reappearing alongside decomposed base files.
for name in code-review qa release; do
  count=0
  [ -e "$VENDORED/$name.md" ] && count=$((count + 1))
  [ -e "$VENDORED/$name/base.md" ] && count=$((count + 1))
  check "single-source-$name" "$count" 1 "exactly one vendored source for $name"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
