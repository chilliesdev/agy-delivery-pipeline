#!/usr/bin/env bash
# Install the criteria file a review/QA/release brief should cite *inside* the
# target repo, and print the path the brief must carry.
#
#   resolve-criteria.sh <code-review|qa|release> [--dir <repo>] [--into <dir>]
#                       [--print-source]
#
# Precedence (first hit wins):
#   1. <repo>/.claude/criteria/<name>.md     the project's own bar
#   2. <this repo>/criteria/<name>.md        vendored default, always present
#
# Writes:  <repo>/.tmp/criteria/<name>.md    the copy the worker actually reads
# Prints:  that copy's absolute path — one line, nothing else.
#
# Exit codes:
#     0  installed (or, with --print-source, resolved)
#     1  no criteria file found for that name
#     2  bad arguments
#     3  resolved, but the copy could not be made
#
# Why a copy. In accept-edits agy denies reading any path outside --add-dir, and
# the denial does not degrade — it aborts the run with rc=1 and no artifacts. The
# vendored default lives in this skill repo, which is not the repo under review,
# so a brief citing the resolved *source* is a brief the Phase 2 worker is
# forbidden to follow. Copying into <repo>/.tmp/ puts the file inside --add-dir,
# where it is readable in every mode. Phase 3 survives the same brief only
# because --mode full turns the permission check off; it gets the copy too, so
# the two phases are briefed the same way.
#
# A tier 1 hit is copied as well, though it is already inside the repo. Uniform
# beats clever: every brief then cites one path shape, and the script never has
# to decide whether some path is "inside" a repo — a question symlinks, `..` and
# a case-insensitive filesystem all make harder than it looks.
#
# The copy is overwritten on every run rather than reused. It lives in .tmp/,
# which is worker scratch that phase.sh already keeps out of git, and a stale
# copy would review this run's diff against a previous run's bar.
#
# `release` rides the same mechanism as the other two rather than getting one of
# its own. It is a procedure where they are bars, but the machinery a phase
# needs is identical — a vendored default that is always there, a per-project
# override, and an installed copy inside --add-dir — and the failure that
# mechanism exists to prevent is the same failure. A second resolution path
# would be a second thing to get wrong on the one phase that touches
# irreversible git state. What it does *not* read is
# <repo>/.claude/skills/git-release-flow/SKILL.md, the path the old Phase 4
# named; see the note further down, which says so out loud on stderr.
#
# --dir defaults to $PWD and is the repo being worked on, not this one. --into
# moves the copy elsewhere; the caller then owns keeping it inside --add-dir.
# --print-source resolves and prints without copying — for inspecting which tier
# won. A brief built from that path is exactly the bug the default prevents.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=""; DIR="$PWD"; INTO=""; PRINT_SOURCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)          DIR="$2";  shift 2 ;;
    --into)         INTO="$2"; shift 2 ;;
    --print-source) PRINT_SOURCE=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) echo "resolve-criteria: unknown arg $1" >&2; exit 2 ;;
    *) [ -z "$NAME" ] || { echo "resolve-criteria: unexpected arg $1" >&2; exit 2; }
       NAME="$1"; shift ;;
  esac
done

case "$NAME" in
  code-review|qa|release) ;;
  "") echo "resolve-criteria: name required (code-review|qa|release)" >&2; exit 2 ;;
  *)  echo "resolve-criteria: unknown criteria $NAME (want code-review|qa|release)" >&2; exit 2 ;;
esac

[ -d "$DIR" ] || { echo "resolve-criteria: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

# The user's own ~/.claude/skills/{code-review,e2e-qa-tester}/SKILL.md used to
# rank here, above the vendored files. It is gone rather than demoted: those
# documents are written for a Claude Code session — parallel sub-agents, git
# commands, slash commands, asking the user — none of which a headless agy
# worker has, and the QA one directs its report to QA_REPORT.md at the repo
# root, against this skill's own .tmp/QA_REPORT.md contract. Demoting it below
# the vendored file would have been the same thing more quietly: the vendored
# file ships here and is always present, so a lower tier could never fire. A
# project that wants its own bar has tier 1, which is better placed anyway —
# per-project, and already inside --add-dir.
SOURCE=""
for CANDIDATE in "$DIR/.claude/criteria/$NAME.md" "$HERE/../criteria/$NAME.md"; do
  if [ -f "$CANDIDATE" ]; then
    SOURCE="$(cd "$(dirname "$CANDIDATE")" && pwd)/$(basename "$CANDIDATE")"
    break
  fi
done
[ -n "$SOURCE" ] || { echo "resolve-criteria: no criteria file found for $NAME" >&2; exit 1; }

# The legacy release path is not a source, and is not silently ignored either.
#
# SKILL.md's old Phase 4 told the orchestrator to look for — and, failing that,
# to *write* — <repo>/.claude/skills/git-release-flow/SKILL.md. So a project may
# have one, and dropping it without a word would be taking work away from
# someone who did what they were told. It is still not read, for the reason the
# ~/.claude/skills tier above was deleted, which applies harder here than it did
# there: a SKILL.md is a Claude Code document by construction — sub-agents,
# slash commands, asking the user — and release is the one phase where "ask the
# user" is precisely the dead end being removed and where a worker acting on
# git instructions is precisely the danger. Its being inside the repo answers
# the --add-dir objection and none of that one. And nothing ever specified the
# file's contents, so a document at that path was written against no shape at
# all; treating it as authoritative for the irreversible phase would be trusting
# an unspecified file to drive `git push`.
#
# So: a line on stderr, naming the file and where to move it. stdout stays the
# single path every caller parses.
if [ "$NAME" = "release" ] && [ -f "$DIR/.claude/skills/git-release-flow/SKILL.md" ]; then
  echo "resolve-criteria: note — $DIR/.claude/skills/git-release-flow/SKILL.md exists but is not used." >&2
  echo "resolve-criteria:        That path is from the old Phase 4 text and is a Claude Code skill, not" >&2
  echo "resolve-criteria:        a headless worker document. To override the vendored release flow, put" >&2
  echo "resolve-criteria:        your version at $DIR/.claude/criteria/release.md." >&2
fi

if [ -n "$PRINT_SOURCE" ]; then
  printf '%s\n' "$SOURCE"
  exit 0
fi

DEST_DIR="${INTO:-$DIR/.tmp/criteria}"
mkdir -p "$DEST_DIR" 2>/dev/null \
  || { echo "resolve-criteria: could not create $DEST_DIR" >&2; exit 3; }
DEST_DIR="$(cd "$DEST_DIR" && pwd)"
DEST="$DEST_DIR/$NAME.md"

# `cp a a` truncates on some platforms and errors on others; neither is what an
# --into pointing at the source's own directory should mean. It is already the
# installed file, so say so and stop.
if [ "$DEST" != "$SOURCE" ]; then
  cp -f "$SOURCE" "$DEST" 2>/dev/null \
    || { echo "resolve-criteria: could not copy $SOURCE to $DEST" >&2; exit 3; }
fi

printf '%s\n' "$DEST"
exit 0
