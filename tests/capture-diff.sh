#!/usr/bin/env bash
# Exercise capture-diff.sh: that the file it hands the Phase 2 reviewer really
# contains the change — including the parts `git diff` alone would drop — and
# that producing it leaves the repository exactly as it found it.
#
#   tests/capture-diff.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE="$HERE/../scripts/capture-diff.sh"
[ -f "$CAPTURE" ] || { echo "capture-diff-test: script not found next door" >&2; exit 2; }

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/capture-diff.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# git needs an identity, and the developer running this may have none set
# globally. -c on every commit, never `git config`, so nothing outside $ROOT is
# touched.
commit() { git -C "$1" -c user.email=t@t -c user.name=t commit -q "$2" "$3"; }

# new_repo <name> — a throwaway repo with .tmp/ ignored (as phase.sh arranges in
# the real pipeline) and one commit to diff against; echoes its path.
new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q . )
  printf '.tmp/\n' > "$R/.gitignore"
  printf 'first\n' > "$R/kept.txt"
  printf 'doomed\n' > "$R/gone.txt"
  ( cd "$R" && git add -A ) >/dev/null 2>&1
  commit "$R" -m init
  printf '%s' "$R"
}

# run <repo> <args...> — STATUS line into $OUT, exit code into $CODE.
run() { R="$1"; shift; OUT="$(/bin/bash "$CAPTURE" --dir "$R" "$@" 2>/dev/null)"; CODE=$?; }
word_of() { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }
patch_of() { printf '%s' "$R/.tmp/REVIEW_DIFF.patch"; }
stat_of()  { printf '%s' "$R/.tmp/REVIEW_DIFF.stat"; }

# --- the three kinds of change ------------------------------------------

# 1. A tracked file that changed. The baseline case, and the only one plain
#    `git diff` would have handled unaided.
R="$(new_repo modified)"
printf 'first\nsecond\n' > "$R/kept.txt"
run "$R"
check mod-rc "$CODE" 0 "exit 0 on a modified tracked file"
case "$(word_of "$OUT")" in DIFF_CAPTURED) ok mod-status "reported DIFF_CAPTURED" ;;
  *) bad mod-status "unexpected status: $OUT" ;; esac
if grep -q '^+second$' "$(patch_of)" 2>/dev/null; then
  ok mod-added "the added line is in the patch"
else
  bad mod-added "the added line is missing from the patch"
fi

# 2. A new file nothing has ever tracked. `git diff` cannot see one at all, so
#    for a task that adds a module this is most of the change.
R="$(new_repo untracked)"
mkdir -p "$R/pkg"
printf 'def hello():\n    return 1\n' > "$R/pkg/new_module.py"
run "$R"
check untracked-rc "$CODE" 0 "exit 0 with only a new file"
if grep -q 'new file mode' "$(patch_of)" 2>/dev/null \
   && grep -q '^+def hello' "$(patch_of)" 2>/dev/null; then
  ok untracked-body "the untracked file appears as an addition, with its content"
else
  bad untracked-body "the untracked file is missing from the patch"
fi
if grep -q 'pkg/new_module.py' "$(stat_of)" 2>/dev/null; then
  ok untracked-stat "and it is listed in the stat"
else
  bad untracked-stat "the stat does not list the new file"
fi

# 3. Intent-to-add is the trick that makes case 2 work, and it writes to the
#    index. This asserts the index it writes to is not the repository's:
#    `git status` must read identically before and after.
R="$(new_repo index-untouched)"
printf 'first\nsecond\n' > "$R/kept.txt"
printf 'brand new\n' > "$R/added.txt"
( cd "$R" && git add kept.txt ) >/dev/null 2>&1     # a half-staged tree, on purpose
BEFORE="$(cd "$R" && git status --porcelain)"
run "$R"
AFTER="$(cd "$R" && git status --porcelain)"
check index-clean "$AFTER" "$BEFORE" "the repository's own index is unchanged"
if grep -q '^+brand new$' "$(patch_of)" 2>/dev/null \
   && grep -q '^+second$' "$(patch_of)" 2>/dev/null; then
  ok index-both "staged and unstaged work land in the same patch"
else
  bad index-both "the half-staged tree did not come through whole"
fi

# 4. A deleted file. Invisible in the post-change tree by definition, which is
#    the whole argument for reviewing a diff rather than file contents.
R="$(new_repo deleted)"
rm "$R/gone.txt"
run "$R"
check del-rc "$CODE" 0 "exit 0 on a deletion"
if grep -q 'deleted file mode' "$(patch_of)" 2>/dev/null \
   && grep -q '^-doomed$' "$(patch_of)" 2>/dev/null; then
  ok del-body "the deletion and the removed line are both in the patch"
else
  bad del-body "the deletion is missing from the patch"
fi

# --- the base ------------------------------------------------------------

# 5. Work that a phase committed. The default base is the working tree, so this
#    is empty — and that must be reported, never quietly captured as nothing.
R="$(new_repo committed)"
printf 'first\nsecond\n' > "$R/kept.txt"
( cd "$R" && git add -A ) >/dev/null 2>&1
commit "$R" -m feat
run "$R"
check base-default-rc "$CODE" 3 "exit 3 when the work is already committed"
case "$(word_of "$OUT")" in DIFF_EMPTY) ok base-default "reported DIFF_EMPTY" ;;
  *) bad base-default "unexpected status: $OUT" ;; esac
case "$OUT" in *"--base HEAD~1"*) ok base-hint "the note names the way out" ;;
  *) bad base-hint "no --base hint in the empty status: $OUT" ;; esac

# 6. …and --base recovers it.
run "$R" --base HEAD~1
check base-explicit-rc "$CODE" 0 "exit 0 against an explicit base"
if grep -q '^+second$' "$(patch_of)" 2>/dev/null; then
  ok base-explicit "the committed change is in the patch"
else
  bad base-explicit "--base did not reach the committed change"
fi
case "$OUT" in *"Base: HEAD~1"*) ok base-reported "the status names the base used" ;;
  *) bad base-reported "the base is not in the status: $OUT" ;; esac

# 7. A base git cannot resolve is an argument error, not an empty diff. Silently
#    capturing nothing here would look exactly like "no changes".
run "$R" --base no-such-ref
check base-bogus "$CODE" 2 "exit 2 on an unresolvable --base"

# --- nothing changed -----------------------------------------------------

# 8. A clean tree still produces both files, valid and self-describing. The
#    brief cites these paths, and a brief naming a file that is not there is the
#    exact hazard this whole design exists to close.
R="$(new_repo clean)"
run "$R"
check clean-rc "$CODE" 3 "exit 3 on a clean tree"
[ -f "$(patch_of)" ] && ok clean-patch "the patch file exists anyway" \
                     || bad clean-patch "no patch file on a clean tree"
[ -f "$(stat_of)" ]  && ok clean-stat  "the stat file exists anyway" \
                     || bad clean-stat  "no stat file on a clean tree"
if grep -q 'no changes against' "$(patch_of)" 2>/dev/null; then
  ok clean-says-so "the patch says in words that it is empty"
else
  bad clean-says-so "an empty patch that does not say it is empty"
fi

# --- truncation ----------------------------------------------------------

# 9. A diff too large for a worker's context is cut — and says so, in the status
#    line and inside the file, so the reviewer knows it is holding a fragment.
R="$(new_repo truncate)"
awk 'BEGIN { for (i = 1; i <= 300; i++) print "line " i }' > "$R/big.txt"
printf 'first\nsecond\n' > "$R/kept.txt"
run "$R" --max-lines 40
check trunc-rc "$CODE" 0 "exit 0 — a truncated diff is still reviewable"
case "$(word_of "$OUT")" in DIFF_TRUNCATED*) ok trunc-status "reported DIFF_TRUNCATED" ;;
  *) bad trunc-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"kept=40/"*) ok trunc-counts "the status says how much was kept" ;;
  *) bad trunc-counts "no kept=n/m in the status: $OUT" ;; esac
if grep -q 'TRUNCATED' "$(patch_of)" 2>/dev/null; then
  ok trunc-in-file "the patch announces its own truncation"
else
  bad trunc-in-file "the patch was cut without saying so"
fi
LINES="$(grep -c '' "$(patch_of)" 2>/dev/null)"
if [ "${LINES:-0}" -lt 100 ]; then
  ok trunc-short "the patch really is shorter than the diff ($LINES lines)"
else
  bad trunc-short "the cap did not shorten the file ($LINES lines)"
fi
# The stat is the reviewer's only way to know what it did not see, so it is
# never truncated — both files must be listed even though one was cut short.
if grep -q 'big.txt' "$(stat_of)" 2>/dev/null && grep -q 'kept.txt' "$(stat_of)" 2>/dev/null; then
  ok trunc-stat-whole "the stat still lists every changed file"
else
  bad trunc-stat-whole "the stat lost a file to the cap"
fi

# 10. --max-lines 0 disables the cap.
run "$R" --max-lines 0
case "$(word_of "$OUT")" in DIFF_CAPTURED) ok trunc-off "--max-lines 0 captures the lot" ;;
  *) bad trunc-off "unexpected status: $OUT" ;; esac

# --- self-exclusion ------------------------------------------------------

# 11. The output lands in the tree being diffed, so a second run must not find
#     the first run's files sitting in the change. Ignored here by .gitignore,
#     and by pathspec in case a caller's repo ignores nothing.
R="$(new_repo self)"
printf 'first\nsecond\n' > "$R/kept.txt"
run "$R"; run "$R"
if grep -q '^+++ b/.tmp/' "$(patch_of)" 2>/dev/null; then
  bad self-exclude "the patch contains its own output"
else
  ok self-exclude "a second run does not review its own first run"
fi
R="$(new_repo self-unignored)"
rm -f "$R/.gitignore"; ( cd "$R" && git rm -q --cached .gitignore ) >/dev/null 2>&1
printf 'first\nsecond\n' > "$R/kept.txt"
run "$R"; run "$R"
if grep -q '^+++ b/.tmp/' "$(patch_of)" 2>/dev/null; then
  bad self-exclude-unignored "the output leaked into the patch with no .gitignore"
else
  ok self-exclude-unignored "excluded by pathspec, not only by .gitignore"
fi

# --- output contract -----------------------------------------------------

# 12. stdout is one STATUS line, like every other script here.
R="$(new_repo stdout)"
printf 'first\nsecond\n' > "$R/kept.txt"
run "$R"
check stdout-lines "$(printf '%s\n' "$OUT" | grep -c .)" 1 "stdout is one line"
case "$OUT" in STATUS:*) ok stdout-shape "and it starts with STATUS:" ;;
  *) bad stdout-shape "stdout is not a STATUS line: $OUT" ;; esac

# 13. The patch opens with a header saying what it is, because the worker reads
#     the file and never sees the status line.
if head -20 "$(patch_of)" | grep -q 'SUBJECT OF THE REVIEW'; then
  ok header-subject "the patch tells the reader it is the review subject"
else
  bad header-subject "the patch has no self-describing header"
fi
if head -20 "$(patch_of)" | grep -q 'base:'; then
  ok header-base "and names the base it was taken against"
else
  bad header-base "the header does not name the base"
fi

# 14. --into moves the pair; --name changes the stem.
run "$R" --into "$R/elsewhere" --name CHANGE
check into-rc "$CODE" 0 "exit 0 with --into and --name"
[ -f "$R/elsewhere/CHANGE.patch" ] && ok into-dest "the patch went where it was sent" \
                                   || bad into-dest "nothing at the --into path"
[ -f "$R/elsewhere/CHANGE.stat" ] && ok into-stat "the stat followed it" \
                                  || bad into-stat "no stat at the --into path"

# --- argument and environment handling -----------------------------------

R="$(new_repo args)"
run "$R" --max-lines nope
check bad-maxlines "$CODE" 2 "exit 2 on a non-numeric --max-lines"
run "$R" --bogus
check bad-arg "$CODE" 2 "exit 2 on an unknown flag"
OUT="$(/bin/bash "$CAPTURE" --dir "$ROOT/nope" 2>/dev/null)"; CODE=$?
check bad-dir "$CODE" 2 "exit 2 on a missing --dir"
NOGIT="$ROOT/notarepo"; mkdir -p "$NOGIT"
OUT="$(/bin/bash "$CAPTURE" --dir "$NOGIT" 2>/dev/null)"; CODE=$?
check not-a-repo "$CODE" 2 "exit 2 outside a git work tree"

# 15. A repository whose first commit has not happened yet. `git diff HEAD`
#     there is a fatal error, so the empty tree stands in for the base.
R="$ROOT/repos/no-commits"; mkdir -p "$R"; ( cd "$R" && git init -q . )
printf '.tmp/\n' > "$R/.gitignore"; printf 'hello\n' > "$R/first.txt"
run "$R"
check no-commits-rc "$CODE" 0 "exit 0 in a repo with no commits"
if grep -q '^+hello$' "$(patch_of)" 2>/dev/null; then
  ok no-commits-body "everything reads as new against the empty tree"
else
  bad no-commits-body "nothing captured in a repo with no commits"
fi

# 16. A subdirectory is still diffed whole: half a change reviewed as if it were
#     all of it is worse than an honest refusal.
R="$(new_repo subdir)"
mkdir -p "$R/deep/er"; printf 'x\n' > "$R/deep/er/file.txt"
printf 'first\nsecond\n' > "$R/kept.txt"
OUT="$(/bin/bash "$CAPTURE" --dir "$R/deep/er" 2>/dev/null)"; CODE=$?
check subdir-rc "$CODE" 0 "exit 0 from a subdirectory"
if grep -q '^+second$' "$R/.tmp/REVIEW_DIFF.patch" 2>/dev/null; then
  ok subdir-whole "the whole work tree was captured, not just the subdirectory"
else
  bad subdir-whole "a change above the given --dir was dropped"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
