#!/usr/bin/env bash
# Say whether the Phase 2 review showed its work, or only its shape.
#
#   check-review.sh [--dir <repo>] [--run <id|current|last>] [--file <path>]
#                   [--diff <path>] [--min-anchors <n>] [--trivial <n>]
#
# Reads:   <run-dir>/REVIEW_FEEDBACK.md   what the reviewer wrote
#          <run-dir>/REVIEW_DIFF.patch    what it was given to review
# Writes:  nothing.
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes, one per outcome:
#     0  REVIEW_EVIDENCED   the review points at something concrete
#     2  bad arguments
#     3  REVIEW_THIN        it does not — read it yourself before advancing
#     4  REVIEW_ABSENT      there is no review, or the file is empty
#
# The failure this exists for. A Phase 2 run came back
# `STATUS: PASSED | File: REVIEW_FEEDBACK.md | Verify: ok` — both mechanical
# gates green — over an artifact that was the criteria document's output shape
# with nothing in it: four zero counts and "No violations found." twice. No file,
# no line, no snippet, no observation. Every gate the pipeline had was structural
# and every one of them passed, because the emptiness was correctly shaped. Only
# reading the file revealed it said nothing, and the whole design of the review
# loop — the retry brief, the --verify override, the retry cap — assumes a review
# that finds things.
#
# What it measures: anchors. An anchor is a `file.ext:123` reference, or a path
# the diff actually touched, cited anywhere in the report. This is deliberately
# not a count of findings — zero findings is a real and defensible outcome, and a
# check that punished it would turn a clean review into an impossible one. It is
# a count of evidence that the reviewer opened the change: even a review with
# nothing to report says *what it looked at*, which is why the criteria now asks
# for an `## Examined` list. A filled-in list clears this check on its own; so
# does a single `cli.py:42` in a finding.
#
# Why it is advisory. A thin review is suspicious, not wrong, and the only thing
# that can settle it is a human reading four hundred words. So this reports a
# suspicion rather than failing the phase: it never touches the verdict, it does
# not feed `phase.sh --verify` (whose exit code *would* override the claim, and
# whose output the orchestrator never sees), and its note says in words that a
# thin review is unevidenced, not failed. The orchestrator decides.
#
# The trivial-diff escape hatch. On a change of a few lines, a review with
# nothing to say and nothing to point at is entirely reasonable, so a diff at or
# under --trivial changed lines (default 10) clears the check by itself and the
# status line says that is why. Above it, showing your work is the bar.
#
# Where this is imprecise, honestly: an anchor is string matching, so a report
# that name-drops `cli.py` without having read it counts the same as one that
# quotes it. This raises the floor on an *empty* review; it cannot detect a
# thorough-looking wrong one. That job is still the orchestrator's, and the diff
# is now on disk at <run-dir>/REVIEW_DIFF.patch for it to read.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"; FEEDBACK=""; PATCH=""; MIN_ANCHORS="1"; TRIVIAL="10"
RUN_TARGET="current"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)         DIR="$2";         shift 2 ;;
    --run)         RUN_TARGET="$2";  shift 2 ;;
    --file)        FEEDBACK="$2";    shift 2 ;;
    --diff)        PATCH="$2";       shift 2 ;;
    --min-anchors) MIN_ANCHORS="$2"; shift 2 ;;
    --trivial)     TRIVIAL="$2";     shift 2 ;;
    -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
    *) echo "check-review: unknown arg $1" >&2; exit 2 ;;
  esac
done

for N in "$MIN_ANCHORS" "$TRIVIAL"; do
  case "$N" in
    ''|*[!0-9]*) echo "check-review: --min-anchors and --trivial want whole numbers, got '$N'" >&2; exit 2 ;;
  esac
done

[ -d "$DIR" ] || { echo "check-review: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

if [ -z "$FEEDBACK" ] || [ -z "$PATCH" ]; then
  R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET")" || exit $?
  FEEDBACK="${FEEDBACK:-$R/REVIEW_FEEDBACK.md}"
  PATCH="${PATCH:-$R/REVIEW_DIFF.patch}"
fi

# Absent is its own answer, and a louder one than thin: a phase that claimed
# PASSED without leaving an artifact has not been reviewed at all.
if [ ! -f "$FEEDBACK" ]; then
  printf '%s\n' "STATUS: REVIEW_ABSENT | File: $FEEDBACK | Note: the reviewer wrote no artifact at this path — the phase's claim rests on nothing; re-dispatch or take the review yourself"
  exit 4
fi
if [ ! -s "$FEEDBACK" ] || [ -z "$(awk 'NF { print "x"; exit }' "$FEEDBACK" 2>/dev/null)" ]; then
  printf '%s\n' "STATUS: REVIEW_ABSENT | File: $FEEDBACK | Note: the artifact exists but is empty — the phase's claim rests on nothing; re-dispatch or take the review yourself"
  exit 4
fi

# The reviewer's own verdict, for the status line only. Never gated on: this
# script has no opinion about PASSED vs FAILED, only about evidence.
#
# Not "the first line": a report that opens with `# Review Feedback` and puts
# the word under a `## Verdict` heading is well within the criteria's shape, and
# reading the title as the verdict prints nonsense. So look for the word itself,
# anywhere in the opening of the file, and only fall back to the first line when
# neither word appears at all.
VERDICT="$(tr -d '\r' < "$FEEDBACK" 2>/dev/null \
  | LC_ALL=C sed -e 's/^[[:space:]*#>_`-]*//' -e 's/[[:space:]*`:.]*$//' \
  | awk '{ w = toupper($1) } w == "PASSED" || w == "FAILED" { print w; exit }')"
if [ -z "$VERDICT" ]; then
  VERDICT="$(awk 'NF { print; exit }' "$FEEDBACK" 2>/dev/null \
    | LC_ALL=C sed -e 's/^[[:space:]*#>_`-]*//' -e 's/[[:space:]*`:.]*$//' \
    | awk '{ print $1 }' | tr '[:lower:]' '[:upper:]')"
fi
VERDICT="${VERDICT:-none}"

# --- what the reviewer was given -----------------------------------------

# Changed lines in the patch, header comments and the ---/+++ file markers
# excluded. This is the size the "did it show its work" bar scales with.
DIFFLINES="unknown"
if [ -f "$PATCH" ]; then
  DIFFLINES="$(grep -a -E '^[+-]' "$PATCH" 2>/dev/null \
    | grep -a -v -E '^(\+\+\+|---)' | grep -c . | tr -cd '0-9')"
  DIFFLINES="${DIFFLINES:-0}"
fi

# Every path the patch touches, from both sides so a deleted file counts too.
PATHS=""
if [ -f "$PATCH" ]; then
  PATHS="$(LC_ALL=C sed -n -e 's|^+++ b/||p' -e 's|^--- a/||p' "$PATCH" 2>/dev/null \
    | LC_ALL=C sed -e 's/[[:space:]].*$//' | grep -v '^/dev/null$' | sort -u)"
fi

# --- what the reviewer produced ------------------------------------------

# A file:line reference. Deliberately loose about the path shape — reviewers
# write `wordstat/cli.py:24`, `cli.py:24`, and `a/wordstat/cli.py:24` — and
# strict about the tail, because the line number is the part that proves
# somebody was looking at a specific place.
FILELINE="$(grep -a -o -E '[A-Za-z0-9_][A-Za-z0-9_./@+-]*\.[A-Za-z0-9_]+:[0-9]+' "$FEEDBACK" 2>/dev/null \
  | sort -u | grep -c . | tr -cd '0-9')"
FILELINE="${FILELINE:-0}"

# A path the diff actually touched, cited anywhere in the report — by full path
# or by basename, since a reviewer that has read the stat often writes either.
CITED=0
if [ -n "$PATHS" ]; then
  while IFS= read -r P; do
    [ -n "$P" ] || continue
    if grep -a -F -q -- "$P" "$FEEDBACK" 2>/dev/null; then
      CITED=$((CITED + 1)); continue
    fi
    B="$(basename "$P")"
    if [ -n "$B" ] && grep -a -F -q -- "$B" "$FEEDBACK" 2>/dev/null; then
      CITED=$((CITED + 1))
    fi
  done <<EOF
$PATHS
EOF
fi

ANCHORS=$((FILELINE + CITED))

# The `## Examined` list the criteria now asks for: a heading, with at least one
# non-blank line under it that is not the next heading. Reported for context —
# a filled-in list is already counted above, through the paths it names.
EXAMINED="none"
if awk '
  BEGIN { seen = 0 }
  {
    line = tolower($0)
    if (line ~ /^#+[[:space:]]*(files[[:space:]]+)?examined/) { seen = 1; next }
    if (seen && $0 ~ /^#+[[:space:]]/) { seen = 0; next }
    if (seen && $0 ~ /[A-Za-z0-9]/) { found = 1; exit }
  }
  END { exit (found ? 0 : 1) }
' "$FEEDBACK" 2>/dev/null; then
  EXAMINED="listed"
fi

# --- the verdict ----------------------------------------------------------

WORDS="$DIFFLINES"
[ "$DIFFLINES" != "unknown" ] && WORDS="$DIFFLINES changed lines"

if [ "$DIFFLINES" = "unknown" ]; then
  DIFF_NOTE=" | Diff: not found at $PATCH — run capture-diff.sh before the review, or pass --diff"
else
  DIFF_NOTE=" | Diff: $WORDS"
fi

if [ "$DIFFLINES" != "unknown" ] && [ "$DIFFLINES" -le "$TRIVIAL" ]; then
  printf '%s\n' "STATUS: REVIEW_EVIDENCED | Verdict: $VERDICT | Anchors: $ANCHORS | Examined: $EXAMINED$DIFF_NOTE | Note: the diff is at or under --trivial ($TRIVIAL) changed lines, where a review with nothing to point at is a reasonable outcome | File: $FEEDBACK"
  exit 0
fi

if [ "$ANCHORS" -ge "$MIN_ANCHORS" ]; then
  printf '%s\n' "STATUS: REVIEW_EVIDENCED | Verdict: $VERDICT | Anchors: $ANCHORS (file:line $FILELINE, changed paths cited $CITED) | Examined: $EXAMINED$DIFF_NOTE | File: $FEEDBACK"
  exit 0
fi

printf '%s\n' "STATUS: REVIEW_THIN(anchors=$ANCHORS, min=$MIN_ANCHORS) | Verdict: $VERDICT | Examined: $EXAMINED$DIFF_NOTE | Note: the report cites no line and no file the diff touched, so nothing in it shows the change was opened — this is an unevidenced review, not a failed one; read $FEEDBACK yourself and decide whether to accept it or re-dispatch | File: $FEEDBACK"
exit 3
