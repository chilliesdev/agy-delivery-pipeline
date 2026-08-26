#!/usr/bin/env bash
# Say what a release can and cannot do in this repository — without doing any
# of it.
#
#   check-release.sh [--dir <repo>] [--run <id|current|last>] [--into <dir>]
#                    [--release-branch <name>] [--bump patch|minor|major]
#                    [--first-version <v>] [--allow-dirty]
#
# Writes:  <run-dir>/RELEASE_FACTS.md   the same facts, for the worker to read
#          a refusal record in the run ledger on RELEASE_BLOCKED and
#          RELEASE_FAILED, so a gate that fires outside a dispatch is not
#          reported as never firing (AGY_SKIP_LEDGER=1 suppresses it)
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes, one per outcome:
#     0  RELEASE_READY        a release can be prepared, and pushed afterwards
#     0  RELEASE_LOCAL_ONLY   the same, but there is no remote — nothing to push
#     2  bad arguments, or --dir is not a git work tree
#     3  RELEASE_BLOCKED(<reason>)  a person has to decide something first
#     4  RELEASE_FAILED       git refused — the message is in the STATUS line
#
# ---------------------------------------------------------------------------
# THIS SCRIPT NEVER WRITES GIT STATE. Not a tag, not a commit, not a merge, not
# a push, not a config entry, not a branch, not the index. Every git command
# below reads, and each is passed --no-optional-locks where git supports it so
# that even the index stat-cache refresh `git status` would normally perform is
# suppressed. tests/check-release.sh asserts the whole of that mechanically:
# HEAD, `git tag -l` and `git for-each-ref` are captured before and after and
# compared. If you add a git call here, it reads or it does not belong.
# ---------------------------------------------------------------------------
#
# Why it exists. Phase 4's release step used to say: follow the project's
# git-release-flow skill if it has one, and otherwise *ask the user* for their
# branch strategy, tag format, changelog and build triggers. Every other phase
# in this pipeline is mechanized down to an exit code; that one dropped to a
# blocking human question with no defined behaviour for an unattended run —
# which is the mode the pipeline is built for. There was no refusal status, no
# state file and no script, so a run that reached the terminal phase simply
# stopped. This is the missing answer: the repository is inspected, the findings
# come back on one machine-readable line, and the cases that genuinely need a
# person come back named rather than as a prompt nobody is there to read.
#
# The three cases the issue called out, and what each does here:
#
#   no remote          Not an error. A local repository is a perfectly ordinary
#                      one; it is simply a release that ends at a commit and a
#                      tag. It gets its own exit-0 status so the difference is
#                      legible on the line rather than buried in a field, and
#                      the release document drops the push commands instead of
#                      leaving them commented out for someone to uncomment.
#   no tags            Not an error either. A first release has no predecessor
#                      to increment from, so --first-version is proposed as a
#                      starting point rather than a bump.
#   already on the     Not an error. It means the merge step is a no-op, which
#   release branch     is a fact about the plan, not a blocker, so it is
#                      reported in the Branch field and the plan drops the
#                      checkout and merge lines.
#
# What does block, and why each needs a person rather than a default:
#
#   no_commits         Nothing has ever been committed; there is nothing to cut.
#   detached_head      There is no branch to merge from or tag by name.
#   dirty_tree         Uncommitted work exists. Whether it belongs in this
#                      release is a judgement about intent, and folding it in
#                      silently is how unreviewed code ships. --allow-dirty
#                      overrides deliberately.
#   tag_format_unknown Tags exist, but not one of them ends in a M.N.P version,
#                      so no next version can be derived from them. Guessing
#                      here would either restart a versioning scheme at 0.1.0 or
#                      invent a second convention alongside the existing one.
#
# The facts file. The release worker cannot run shell commands — the brief
# forbids it and in accept-edits the denial aborts the run — so it cannot look
# at git at all. The same rule that put the Phase 2 diff on disk applies: if a
# brief names a thing to read, something must first have put that thing inside
# --add-dir. So every fact on the STATUS line is also written to
# <run-dir>/RELEASE_FACTS.md, which the release criteria treats as its only
# account of the repository's state. It is written on a block too, so a person
# reading afterwards sees what was missing.
#
# The proposed version is a proposal. Bump size is a judgement about what the
# change means, which the script cannot make, so it prints the alternatives
# alongside its default and the criteria tells the worker to disagree in writing
# when the change warrants it. The tag's existing prefix is preserved exactly —
# `v1.2.3` begets `v1.3.0`, `1.2.3` begets `1.3.0` — because introducing a
# second convention into a repository that already has one is worse than any
# bump size being wrong.
#
# --into moves the facts file; the caller then owns keeping it inside --add-dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"
. "$HERE/ledger.sh"

DIR="$PWD"; INTO=""; RELEASE_BRANCH=""; BUMP="minor"
FIRST_VERSION="v0.1.0"; ALLOW_DIRTY=""
RUN_TARGET="current"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)            DIR="$2";            shift 2 ;;
    --run)            RUN_TARGET="$2";     shift 2 ;;
    --into)           INTO="$2";           shift 2 ;;
    --release-branch) RELEASE_BRANCH="$2"; shift 2 ;;
    --bump)           BUMP="$2";           shift 2 ;;
    --first-version)  FIRST_VERSION="$2";  shift 2 ;;
    --allow-dirty)    ALLOW_DIRTY=1;       shift ;;
    -h|--help) sed -n '2,86p' "$0"; exit 0 ;;
    *) echo "check-release: unknown arg $1" >&2; exit 2 ;;
  esac
done

case "$BUMP" in
  patch|minor|major) ;;
  *) echo "check-release: --bump wants patch, minor or major, got '$BUMP'" >&2; exit 2 ;;
esac
case "$FIRST_VERSION" in
  *[0-9].[0-9]*) ;;
  *) echo "check-release: --first-version wants a version like v0.1.0, got '$FIRST_VERSION'" >&2; exit 2 ;;
esac

[ -d "$DIR" ] || { echo "check-release: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

if ! ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "check-release: not a git work tree: $DIR" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

# --no-optional-locks keeps `git status` from refreshing — and therefore
# writing — the index. Probed rather than assumed: it is a modern flag, and a
# git that rejects it would fail every call below with an unknown-option error.
NOLOCK=""
git -C "$ROOT" --no-optional-locks rev-parse --git-dir >/dev/null 2>&1 && NOLOCK="--no-optional-locks"

# Every git call in this script goes through here, and every one of them reads.
GIT_ERR="$(mktemp "${TMPDIR:-/tmp}/check-release.XXXXXX")" \
  || { echo "check-release: could not create a scratch file" >&2; exit 2; }
trap 'rm -f "$GIT_ERR"' EXIT INT TERM
git_ro() { git -C "$ROOT" ${NOLOCK:+$NOLOCK} "$@" 2>"$GIT_ERR"; }

# The run directory is resolved further down, so a refusal reached before that
# records without a run rather than not at all.
_release_run_id() {
  [ -n "${R:-}" ] && [ -d "${R:-}" ] || return 0
  run_dir_get "$R" "run" 2>/dev/null || basename "$R"
}

fail() {
  printf '%s\n' "STATUS: RELEASE_FAILED | Reason: ${1:-git refused} | Next: check git repository permissions and status | Dir: $ROOT"
  ledger_record_refusal "$ROOT" "$(_release_run_id)" "RELEASE" "RELEASE_FAILED"
  exit 4
}

# --- what git says --------------------------------------------------------

HEAD_SHA=""
HAS_COMMITS=no
if git_ro rev-parse --verify -q HEAD >/dev/null 2>&1; then
  HAS_COMMITS=yes
  HEAD_SHA="$(git_ro rev-parse --short HEAD)"
fi

# An unborn branch still reports its name through --symbolic-full-name, which is
# what a repository with no commits has; a detached HEAD reports nothing at all.
BRANCH="$(git_ro symbolic-ref --quiet --short HEAD)"
DETACHED=no
[ -n "$BRANCH" ] || DETACHED=yes

REMOTES="$(git_ro remote | grep -c . | tr -cd '0-9')"; REMOTES="${REMOTES:-0}"
REMOTE=""
if [ "$REMOTES" -gt 0 ]; then
  # origin if it exists, otherwise whichever is first — the name only. The URL
  # is never printed: it is the one field here that can carry a credential.
  REMOTE="$(git_ro remote | awk '$0 == "origin" { print; found = 1; exit }
                                { if (!first) first = $0 }
                                END { if (!found) print first }')"
fi

if [ -n "$INTO" ]; then
  OUT_DIR="$INTO"
else
  R="$(run_dir_resolve --dir "$ROOT" --run "$RUN_TARGET")" || exit $?
  OUT_DIR="$R"
fi

# The output directory is excluded from the dirty check by pathspec rather than
# left to .gitignore: this script writes into it, and a second run must not
# report its own first run as uncommitted work standing in the way of a release.
SPEC=(. )
case "$OUT_DIR" in
  "$ROOT"/*) SPEC=(. ":(exclude)${OUT_DIR#$ROOT/}") ;;
esac

DIRTY=0
if [ "$HAS_COMMITS" = yes ]; then
  PORCELAIN="$(git_ro status --porcelain -- ${SPEC[@]+"${SPEC[@]}"})" \
    || fail "$(head -1 "$GIT_ERR" 2>/dev/null | tr -d '|')"
  DIRTY="$(printf '%s' "$PORCELAIN" | grep -c . | tr -cd '0-9')"; DIRTY="${DIRTY:-0}"
  DIRTY_PATHS="$(printf '%s' "$PORCELAIN" | awk '{ $1 = ""; sub(/^ /, ""); print }' \
    | head -5 | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
else
  DIRTY_PATHS=""
fi

TAGS="$(git_ro tag -l | grep -c . | tr -cd '0-9')"; TAGS="${TAGS:-0}"

# --- the version to propose ----------------------------------------------

# Highest M.N.P tag, compared numerically rather than as strings, so v1.10.0
# outranks v1.9.0. Only tags whose numeric core *ends* the name are candidates,
# which keeps v1.3.0-rc1 from being read as the last release. Whatever precedes
# that core is the repository's prefix, and it is carried through untouched.
#
# awk, not `sort -V` and not `git tag --sort=v:refname`: this has to behave the
# same on a macOS bash 3.2 box as anywhere else, and the prefix has to survive
# the comparison, which a sort discards.
LATEST_TAG=""; PREFIX=""; MAJOR=0; MINOR=0; PATCH=0
if [ "$TAGS" -gt 0 ]; then
  PICKED="$(git_ro tag -l | awk '
    {
      t = $0
      if (match(t, /[0-9]+\.[0-9]+\.[0-9]+$/)) {
        core = substr(t, RSTART, RLENGTH)
        pre  = substr(t, 1, RSTART - 1)
        n = split(core, v, ".")
        if (n != 3) next
        m = v[1] + 0; k = v[2] + 0; p = v[3] + 0
        if (!seen || m > bm || (m == bm && k > bn) || (m == bm && k == bn && p > bp)) {
          seen = 1; bm = m; bn = k; bp = p
          bpre = pre; btag = t
        }
      }
    }
    END { if (seen) printf "%s\t%s\t%s\t%s\t%s\n", bpre, bm, bn, bp, btag }
  ')"
  if [ -n "$PICKED" ]; then
    PREFIX="$(printf '%s' "$PICKED" | cut -f1)"
    MAJOR="$(printf '%s' "$PICKED" | cut -f2)"
    MINOR="$(printf '%s' "$PICKED" | cut -f3)"
    PATCH="$(printf '%s' "$PICKED" | cut -f4)"
    LATEST_TAG="$(printf '%s' "$PICKED" | cut -f5)"
  fi
fi

next_version() {
  case "$1" in
    major) printf '%s%s.0.0\n' "$PREFIX" "$((MAJOR + 1))" ;;
    minor) printf '%s%s.%s.0\n' "$PREFIX" "$MAJOR" "$((MINOR + 1))" ;;
    patch) printf '%s%s.%s.%s\n' "$PREFIX" "$MAJOR" "$MINOR" "$((PATCH + 1))" ;;
  esac
}

FIRST_RELEASE=no
TAG_FORMAT="none"
if [ -n "$LATEST_TAG" ]; then
  TAG_FORMAT="${PREFIX}<major>.<minor>.<patch>"
  NEXT="$(next_version "$BUMP")"
  ALT_ONE=""; ALT_TWO=""
  case "$BUMP" in
    patch) ALT_ONE="minor $(next_version minor)"; ALT_TWO="major $(next_version major)" ;;
    minor) ALT_ONE="patch $(next_version patch)"; ALT_TWO="major $(next_version major)" ;;
    major) ALT_ONE="patch $(next_version patch)"; ALT_TWO="minor $(next_version minor)" ;;
  esac
elif [ "$TAGS" -eq 0 ]; then
  FIRST_RELEASE=yes
  NEXT="$FIRST_VERSION"
  ALT_ONE=""; ALT_TWO=""
else
  NEXT=""
  ALT_ONE=""; ALT_TWO=""
fi

# --- the release branch ---------------------------------------------------

# Asked for, else what the remote calls its default, else the first conventional
# name that exists locally, else wherever we already are. The last of those is
# reported as a guess rather than a finding, because a repository with one
# oddly-named branch is not a repository in trouble.
RELEASE_BRANCH_SOURCE="--release-branch"
if [ -z "$RELEASE_BRANCH" ] && [ -n "$REMOTE" ]; then
  HEADREF="$(git_ro symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD")"
  if [ -n "$HEADREF" ]; then
    RELEASE_BRANCH="${HEADREF#$REMOTE/}"
    RELEASE_BRANCH_SOURCE="$REMOTE/HEAD"
  fi
fi
if [ -z "$RELEASE_BRANCH" ]; then
  for CANDIDATE in main master trunk release; do
    if git_ro rev-parse --verify -q "refs/heads/$CANDIDATE" >/dev/null 2>&1; then
      RELEASE_BRANCH="$CANDIDATE"; RELEASE_BRANCH_SOURCE="convention"; break
    fi
  done
fi
if [ -z "$RELEASE_BRANCH" ]; then
  RELEASE_BRANCH="${BRANCH:-unknown}"
  RELEASE_BRANCH_SOURCE="assumed — no main, master, trunk or release branch exists"
fi

ON_RELEASE_BRANCH=no
[ -n "$BRANCH" ] && [ "$BRANCH" = "$RELEASE_BRANCH" ] && ON_RELEASE_BRANCH=yes

# --- the changelog --------------------------------------------------------

CHANGELOG="none"
for CANDIDATE in CHANGELOG.md CHANGELOG CHANGELOG.rst CHANGES.md CHANGES \
                 HISTORY.md NEWS.md docs/CHANGELOG.md; do
  if [ -f "$ROOT/$CANDIDATE" ]; then CHANGELOG="$CANDIDATE"; break; fi
done

# --- the verdict ----------------------------------------------------------

BLOCKED=""
BLOCK_NOTE=""
if [ "$HAS_COMMITS" != yes ]; then
  BLOCKED="no_commits"
  BLOCK_NOTE="this repository has no commits, so there is nothing to release — commit the work first"
elif [ "$DETACHED" = yes ]; then
  BLOCKED="detached_head"
  BLOCK_NOTE="HEAD is detached at $HEAD_SHA, so there is no branch to merge from or tag by name — check out a branch first"
elif [ "$DIRTY" -gt 0 ] && [ -z "$ALLOW_DIRTY" ]; then
  BLOCKED="dirty_tree"
  BLOCK_NOTE="$DIRTY uncommitted path(s) — whether they belong in this release is a decision only you can make; commit or stash them, or re-run with --allow-dirty${DIRTY_PATHS:+ (first few: $DIRTY_PATHS)}"
elif [ -z "$NEXT" ]; then
  BLOCKED="tag_format_unknown"
  BLOCKED_SAMPLE="$(git_ro tag -l | head -3 | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
  BLOCK_NOTE="$TAGS tag(s) exist but none ends in a <major>.<minor>.<patch> version (e.g. $BLOCKED_SAMPLE), so no next version can be derived — name the version yourself and pass it on to the release phase"
fi

if [ -n "$BLOCKED" ]; then
  STATUS="RELEASE_BLOCKED($BLOCKED)"
elif [ "$REMOTES" -eq 0 ]; then
  STATUS="RELEASE_LOCAL_ONLY"
else
  STATUS="RELEASE_READY"
fi

# --- the facts file -------------------------------------------------------

mkdir -p "$OUT_DIR" 2>/dev/null \
  || { echo "check-release: could not create $OUT_DIR" >&2; exit 2; }
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
FACTS="$OUT_DIR/RELEASE_FACTS.md"

{
  printf '# RELEASE_FACTS.md — what a release can and cannot do in this repository\n#\n'
  printf '# Written by check-release.sh immediately before the release phase was\n'
  printf '# dispatched. You cannot run shell commands, so this is your only account of\n'
  printf '# the git state. Everything below was read; nothing was changed. No tag, no\n'
  printf '# commit, no merge and no push has happened, and nothing in this file\n'
  printf '# authorises you to make one — you prepare a release, a human performs it.\n#\n'
  printf 'status:             %s\n' "$STATUS"
  [ -n "$BLOCKED" ] && printf 'blocked because:    %s\n' "$BLOCK_NOTE"
  printf 'repository:         %s\n' "$ROOT"
  printf 'head:               %s\n' "${HEAD_SHA:-none (no commits)}"
  printf 'current branch:     %s\n' "${BRANCH:-none (detached HEAD)}"
  printf 'release branch:     %s (%s)\n' "$RELEASE_BRANCH" "$RELEASE_BRANCH_SOURCE"
  printf 'on release branch:  %s\n' "$ON_RELEASE_BRANCH"
  if [ "$ON_RELEASE_BRANCH" = yes ]; then
    printf 'merge step:         none — the work is already on the release branch\n'
  else
    printf 'merge step:         %s into %s\n' "${BRANCH:-none}" "$RELEASE_BRANCH"
  fi
  if [ -n "$REMOTE" ]; then
    printf 'remote:             %s\n' "$REMOTE"
    printf 'can push:           yes — but only a human runs the push\n'
  else
    printf 'remote:             none\n'
    printf 'can push:           no — this repository has no remote. That is normal, not\n'
    printf '                    an error: the release ends at a local commit and tag.\n'
    printf '                    Leave every push command out of the plan entirely.\n'
  fi
  printf 'working tree:       %s\n' "$([ "$DIRTY" -eq 0 ] && printf 'clean' || printf '%s uncommitted path(s)' "$DIRTY")"
  printf 'tags:               %s\n' "$TAGS"
  printf 'latest version tag: %s\n' "${LATEST_TAG:-none}"
  printf 'tag format:         %s\n' "$TAG_FORMAT"
  if [ "$FIRST_RELEASE" = yes ]; then
    printf 'first release:      yes — no predecessor to increment from\n'
  else
    printf 'first release:      no\n'
  fi
  printf 'proposed version:   %s\n' "${NEXT:-none — name it yourself}"
  printf 'bump:               %s\n' "$BUMP"
  if [ -n "$ALT_ONE" ]; then
    printf 'alternatives:       %s, %s\n' "$ALT_ONE" "$ALT_TWO"
    printf 'note:               the bump size is a judgement about what the change means.\n'
    printf '                    Take the proposal unless the change says otherwise, and\n'
    printf '                    say which you took and why.\n'
  fi
  printf 'changelog:          %s\n' "$CHANGELOG"
} > "$FACTS" 2>/dev/null || { echo "check-release: could not write $FACTS" >&2; exit 2; }

# --- the status line ------------------------------------------------------

BRANCH_FIELD="${BRANCH:-detached}"
[ "$ON_RELEASE_BRANCH" = yes ] && BRANCH_FIELD="$BRANCH (already the release branch — no merge step)"

if [ -n "$BLOCKED" ]; then
  printf '%s\n' "STATUS: $STATUS | Branch: $BRANCH_FIELD | Note: $BLOCK_NOTE | Next: resolve the blocking git condition named here, or pass --allow-dirty if uncommitted changes are intended | Facts: $FACTS"
  ledger_record_refusal "$ROOT" "$(_release_run_id)" "RELEASE" "$STATUS"
  exit 3
fi

TAGS_FIELD="$TAGS"
[ -n "$LATEST_TAG" ] && TAGS_FIELD="$TAGS (latest $LATEST_TAG, format $TAG_FORMAT)"
NEXT_FIELD="$NEXT ($BUMP bump)"
[ "$FIRST_RELEASE" = yes ] && NEXT_FIELD="$NEXT (first release — no predecessor to increment from)"
[ -n "$ALT_ONE" ] && NEXT_FIELD="$NEXT ($BUMP bump; --bump gives $ALT_ONE or $ALT_TWO)"

TREE_FIELD="clean"
[ "$DIRTY" -gt 0 ] && TREE_FIELD="$DIRTY uncommitted path(s), allowed through by --allow-dirty"

COMMON="Branch: $BRANCH_FIELD | Release branch: $RELEASE_BRANCH | Tree: $TREE_FIELD | Tags: $TAGS_FIELD | Next: $NEXT_FIELD | Changelog: $CHANGELOG | Facts: $FACTS"

if [ "$STATUS" = "RELEASE_LOCAL_ONLY" ]; then
  printf '%s\n' "STATUS: RELEASE_LOCAL_ONLY | Remote: none | $COMMON | Note: there is no remote, so this release ends at a local commit and tag — nothing is pushed, and that is a normal outcome rather than an error"
  exit 0
fi

printf '%s\n' "STATUS: RELEASE_READY | Remote: $REMOTE | $COMMON | Note: nothing here has been tagged, merged or pushed — this script only reads; the release phase prepares, and you run the commands it proposes"
exit 0
