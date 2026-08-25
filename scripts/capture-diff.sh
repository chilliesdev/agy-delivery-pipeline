#!/usr/bin/env bash
# Write the change under review to a file the Phase 2 worker is allowed to read.
#
#   capture-diff.sh [--dir <repo>] [--run <id|current|last>] [--base <ref>]
#                   [--into <dir>] [--max-lines <n>] [--name <stem>]
#
# Writes:  <run-dir>/REVIEW_DIFF.patch  the unified diff — the review subject
#          <run-dir>/REVIEW_DIFF.stat   the per-file summary, never truncated
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes, one per outcome:
#     0  DIFF_CAPTURED       there is a change, and both files describe it
#     0  DIFF_TRUNCATED      same, but the patch was cut at --max-lines
#     2  bad arguments, or --dir is not a git work tree
#     3  DIFF_EMPTY          nothing changed against <base>; both files written
#     4  DIFF_FAILED         git refused — the message is in the STATUS line
#
# Why this exists. The Phase 2 brief forbids shell commands, so the worker
# cannot run `git diff`, and in accept-edits agy reads nothing outside
# --add-dir. Until this script ran, nothing in the pipeline ever put the diff
# anywhere the reviewer could open it: the criteria said "review the
# working-tree diff", the worker found no diff, and — being a language model
# with the files right there — silently reviewed the post-change file contents
# instead. That substitution is not a weaker review, it is a different one. A
# test that was weakened, a line that was deleted, behaviour that changed: none
# of it is visible in the end state, and those are the failures SKILL.md most
# wants caught.
#
# Two files, not one. The patch can be cut to fit a worker's context; the stat
# never is. So a truncated review still knows the full list of files it did not
# get to, and can say so rather than reporting on a fragment as if it were the
# change.
#
# --base, and its failure mode. The default is HEAD, i.e. the working tree,
# which is what Phase 1 leaves behind — its brief says "do not commit". If a
# phase committed anyway, HEAD moves with it and the working tree diff is
# empty. That is not silently absorbed: an empty capture is its own status and
# its own exit code, and the note tells the caller to re-run against the ref the
# work started from (`--base HEAD~1`, a branch point, a tag). Guessing a
# fallback here would be worse than reporting nothing — a clean tree whose last
# commit is unrelated would get that unrelated commit reviewed as if it were the
# task.
#
# Untracked files. `git diff` does not see them at all, so a task that adds a
# module would hand the reviewer everything except the module. `git add -N`
# fixes that, but it writes to the index, and this script must not disturb a
# tree the user is about to inspect. So the intent-to-add goes into a *copy* of
# the index under $TMPDIR, pointed at by GIT_INDEX_FILE; the repository's own
# index is never opened for writing, and `git status` reads the same before and
# after. Anything git ignores stays out, and so does the .agy/ tree (or an
# explicit --into directory) — excluded by pathspec rather than left to .gitignore,
# so run N never finds run N-1's output sitting in the change.
#
# --into moves the pair elsewhere; the caller then owns keeping it inside
# --add-dir, and a brief citing a path outside it is the bug this whole design
# exists to prevent. --name changes the stem for both files.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"; BASE=""; INTO=""; MAX_LINES="4000"; NAME="REVIEW_DIFF"
RUN_TARGET="current"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       DIR="$2";       shift 2 ;;
    --run)       RUN_TARGET="$2"; shift 2 ;;
    --base)      BASE="$2";      shift 2 ;;
    --into)      INTO="$2";      shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    --name)      NAME="$2";      shift 2 ;;
    -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
    *) echo "capture-diff: unknown arg $1" >&2; exit 2 ;;
  esac
done

case "$MAX_LINES" in
  ''|*[!0-9]*) echo "capture-diff: --max-lines wants a whole number, got '$MAX_LINES'" >&2; exit 2 ;;
esac
case "$NAME" in
  ''|*/*) echo "capture-diff: --name wants a bare file stem, got '$NAME'" >&2; exit 2 ;;
esac

[ -d "$DIR" ] || { echo "capture-diff: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

# The whole work tree, not the subdirectory the caller happened to be in: a
# review of half a change is worse than a review that says it saw nothing.
if ! ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "capture-diff: not a git work tree: $DIR" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

# The empty tree, for a repository whose first commit has not happened yet.
# `git diff HEAD` there is a fatal error, not an empty diff.
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
if [ -z "$BASE" ]; then
  if git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    BASE="HEAD"
  else
    BASE="$EMPTY_TREE"
  fi
elif ! git -C "$ROOT" rev-parse --verify -q "$BASE^{tree}" >/dev/null 2>&1; then
  echo "capture-diff: --base does not name anything git can resolve: $BASE" >&2
  exit 2
fi
# What to print, so a status line naming HEAD is still pinned to a commit.
BASE_SHOWN="$BASE"
if [ "$BASE" = "$EMPTY_TREE" ]; then
  BASE_SHOWN="the empty tree (this repository has no commits yet)"
else
  BASE_SHA="$(git -C "$ROOT" rev-parse --short "$BASE" 2>/dev/null)"
  if [ -n "$BASE_SHA" ] && [ "$BASE_SHA" != "$BASE" ]; then
    BASE_SHOWN="$BASE ($BASE_SHA)"
  fi
fi

if [ -n "$INTO" ]; then
  OUT_DIR="$INTO"
else
  OUT_DIR="$(run_dir_resolve --dir "$ROOT" --run "$RUN_TARGET")" || exit $?
fi

mkdir -p "$OUT_DIR" 2>/dev/null \
  || { echo "capture-diff: could not create $OUT_DIR" >&2; exit 2; }
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
PATCH="$OUT_DIR/$NAME.patch"
STAT="$OUT_DIR/$NAME.stat"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/capture-diff.XXXXXX")" \
  || { echo "capture-diff: could not create a scratch directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# The throwaway index. Copied rather than created, so tracked files keep their
# staged state and a change that is half-staged still reads as one change.
# Absent on a repository nothing has ever been added to; git makes it for us.
IDX="$WORK/index"
REAL_IDX="$(git -C "$ROOT" rev-parse --git-path index 2>/dev/null)"
if [ -n "$REAL_IDX" ] && [ -f "$ROOT/$REAL_IDX" ]; then
  cp -f "$ROOT/$REAL_IDX" "$IDX" 2>/dev/null
elif [ -n "$REAL_IDX" ] && [ -f "$REAL_IDX" ]; then
  cp -f "$REAL_IDX" "$IDX" 2>/dev/null
fi

# The output directory is excluded by pathspec, not left to .gitignore. In the
# pipeline phase.sh has already ignored .agy/, but this script also runs on its
# own, and a patch whose second run contains its own first run is the kind of
# thing a reviewer reports findings about.
#
# When OUT_DIR is inside .agy/, exclude the whole .agy/ tree rather than just the
# current run directory: with run-scoped state, run N must exclude run N-1's
# output as well as its own, and an exclusion scoped to the current run
# silently stops working the second time anyone uses the same repo. An explicit
# --into pointing elsewhere inside the repo keeps its targeted exclusion.
SPEC=(. )
case "$OUT_DIR" in
  "$ROOT/.agy"|"$ROOT/.agy"/*) SPEC=(. ":(exclude).agy/") ;;
  "$ROOT"/*) SPEC=(. ":(exclude)${OUT_DIR#$ROOT/}") ;;
esac

# Intent-to-add every untracked, non-ignored path. Plain `.` on purpose, without
# the exclusion above: `git add` reads a `:(exclude)<dir>` spec as *naming* that
# directory and errors out when the directory is ignored, which is exactly the
# case the pipeline always runs in. Nothing is lost — an ignored path is skipped
# by `add` anyway, and the diffs below still carry the exclusion.
# Failure is not fatal: a tracked-only diff is a worse review subject than a
# complete one, but a far better one than none, so carry on and say what is
# missing.
UNTRACKED_NOTE=""
if ! ( cd "$ROOT" && GIT_INDEX_FILE="$IDX" git add -N -- . ) >/dev/null 2>&1; then
  UNTRACKED_NOTE="new files could not be staged for the diff — they may be missing below"
fi

git_d() { ( cd "$ROOT" && GIT_INDEX_FILE="$IDX" git diff "$@" ) 2>"$WORK/err"; }

git_d --numstat "$BASE" -- ${SPEC[@]+"${SPEC[@]}"} > "$WORK/numstat"
if [ "$?" -ne 0 ]; then
  WHY="$(head -1 "$WORK/err" 2>/dev/null | tr -d '|')"
  printf '%s\n' "STATUS: DIFF_FAILED | Base: $BASE_SHOWN | Reason: ${WHY:-git diff failed} | Dir: $ROOT"
  exit 4
fi

git_d --stat "$BASE" -- ${SPEC[@]+"${SPEC[@]}"} > "$WORK/stat"
git_d          "$BASE" -- ${SPEC[@]+"${SPEC[@]}"} > "$WORK/patch"

FILES="$(grep -c . "$WORK/numstat" 2>/dev/null | tr -cd '0-9')"; FILES="${FILES:-0}"
# Binary files report "-" for both counts; they contribute a file, not lines.
ADDED="$(awk '$1 ~ /^[0-9]+$/ { n += $1 } END { print n + 0 }' "$WORK/numstat" 2>/dev/null)"
REMOVED="$(awk '$2 ~ /^[0-9]+$/ { n += $2 } END { print n + 0 }' "$WORK/numstat" 2>/dev/null)"
ADDED="${ADDED:-0}"; REMOVED="${REMOVED:-0}"
CHANGED=$((ADDED + REMOVED))
BODY_LINES="$(grep -c '' "$WORK/patch" 2>/dev/null | tr -cd '0-9')"; BODY_LINES="${BODY_LINES:-0}"

TRUNCATED=0
KEPT="$BODY_LINES"
if [ "$MAX_LINES" -gt 0 ] && [ "$BODY_LINES" -gt "$MAX_LINES" ]; then
  TRUNCATED=1
  KEPT="$MAX_LINES"
fi

# The stat file first: it is the one that always describes the whole change,
# and the patch header points at it when the patch itself is short of the truth.
{
  printf '# %s.stat — every file the change touches, against %s\n' "$NAME" "$BASE_SHOWN"
  printf '# This list is complete even when %s.patch is truncated.\n#\n' "$NAME"
  if [ "$FILES" -eq 0 ]; then
    printf '(no files changed against %s)\n' "$BASE_SHOWN"
  else
    cat "$WORK/stat"
  fi
} > "$STAT" 2>/dev/null || { echo "capture-diff: could not write $STAT" >&2; exit 2; }

{
  printf '# %s.patch — the change under review\n#\n' "$NAME"
  printf '# base:          %s\n' "$BASE_SHOWN"
  printf '# files changed: %s\n' "$FILES"
  printf '# changed lines: %s (+%s / -%s)\n' "$CHANGED" "$ADDED" "$REMOVED"
  printf '# patch lines:   %s\n#\n' "$BODY_LINES"
  printf '# THIS PATCH IS THE SUBJECT OF THE REVIEW. The current contents of the\n'
  printf '# files are context for reading a hunk — they are not the thing being\n'
  printf '# reviewed. A line removed or a test weakened is visible here and nowhere\n'
  printf '# else. Every finding must trace to a hunk below.\n'
  printf '#\n# New files appear as additions against /dev/null. Anything git ignores is\n'
  printf '# excluded, as is the .agy/ tree (or the explicit --into directory), so this\n'
  printf '# patch never contains previous runs or itself.\n'
  [ -n "$UNTRACKED_NOTE" ] && printf '#\n# WARNING: %s\n' "$UNTRACKED_NOTE"
  if [ "$TRUNCATED" -eq 1 ]; then
    printf '#\n# TRUNCATED: only the first %s of %s patch lines are below. You are\n' "$KEPT" "$BODY_LINES"
    printf '# seeing part of this change, not all of it. %s.stat lists every file,\n' "$NAME"
    printf '# including the ones whose hunks were cut. Say so in your report rather\n'
    printf '# than reporting on the fragment as if it were the whole change.\n'
  fi
  printf '#\n'
  if [ "$FILES" -eq 0 ]; then
    printf '# (no changes against %s)\n' "$BASE_SHOWN"
    printf '#\n# If work was expected here, it was probably committed: re-run with the ref\n'
    printf '# the work started from, e.g. --base HEAD~1.\n'
  elif [ "$TRUNCATED" -eq 1 ]; then
    head -n "$KEPT" "$WORK/patch"
    printf '\n# --- TRUNCATED HERE: %s further patch lines omitted ---\n' "$((BODY_LINES - KEPT))"
  else
    cat "$WORK/patch"
  fi
} > "$PATCH" 2>/dev/null || { echo "capture-diff: could not write $PATCH" >&2; exit 2; }

if [ "$FILES" -eq 0 ]; then
  printf '%s\n' "STATUS: DIFF_EMPTY | Base: $BASE_SHOWN | Note: nothing changed against this base — if a phase committed its work, re-capture against the ref it started from (--base HEAD~1) before briefing the reviewer | Patch: $PATCH | Stat: $STAT"
  exit 3
fi

SUFFIX=""
[ -n "$UNTRACKED_NOTE" ] && SUFFIX=" | Warning: $UNTRACKED_NOTE"
if [ "$TRUNCATED" -eq 1 ]; then
  printf '%s\n' "STATUS: DIFF_TRUNCATED(kept=$KEPT/$BODY_LINES) | Base: $BASE_SHOWN | Files: $FILES | Changed: $CHANGED (+$ADDED / -$REMOVED) | Note: the patch is capped at --max-lines and says so in its own header; the stat still lists every file | Patch: $PATCH | Stat: $STAT$SUFFIX"
  exit 0
fi
printf '%s\n' "STATUS: DIFF_CAPTURED | Base: $BASE_SHOWN | Files: $FILES | Changed: $CHANGED (+$ADDED / -$REMOVED) | Patch: $PATCH | Stat: $STAT$SUFFIX"
exit 0
