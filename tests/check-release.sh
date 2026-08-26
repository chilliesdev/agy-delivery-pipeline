#!/usr/bin/env bash
# Exercise check-release.sh: that it answers the release phase's questions on one
# machine-readable line — and that asking them changes nothing.
#
#   tests/check-release.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo, and no test repo is ever given a remote that points anywhere real —
# the "has a remote" cases point at a bare repository beside them on disk, which
# is enough for `git remote` and is unreachable by definition.
#
# The case that matters most is `unchanged`: HEAD, `git tag -l` and
# `git for-each-ref` are captured before and after and compared byte for byte.
# This is the one phase where a script that quietly wrote git state would do
# damage nobody could undo, so the invariant is asserted mechanically rather than
# trusted to the reading of the source — though `no-git-writes` reads the source
# too, because the two catch different mistakes.
#
# Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-release.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
[ -f "$CHECK" ] || { echo "check-release-test: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "check-release-test: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

# Normalised through `cd`, because $TMPDIR carries a trailing slash on macOS and
# the script prints paths that have been through the same normalisation.
ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-release.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" "$4" ;; *) bad "$1" "$4 (line: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "$4 (line: $2)" ;; *) ok "$1" "$4" ;; esac; }

# git needs an identity, and the developer running this may have none set
# globally. -c on every commit, never `git config`, so nothing outside $ROOT is
# touched.
commit() { git -C "$1" -c user.email=t@t -c user.name=t commit -q "$2" "$3"; }

# new_repo <name> — a throwaway repo with .agy/ ignored (as phase.sh arranges in
# the real pipeline), initialized run, and one commit; echoes its path. No remote,
# no tags: each case adds what it is about.
new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q -b main . )
  printf '.agy/\n' > "$R/.gitignore"
  printf 'first\n' > "$R/kept.txt"
  ( cd "$R" && git add -A ) >/dev/null 2>&1
  commit "$R" -m init
  run_dir_new --dir "$R" --task "release test $1" >/dev/null
  printf '%s' "$R"
}

# A remote that exists as a name and reaches nothing. `git remote add` never
# contacts anything, and every command this script runs is local, so a bare repo
# on disk beside the test is both sufficient and incapable of touching a network.
add_remote() { git -C "$1" remote add origin "$ROOT/remotes/${2:-bare}.git" >/dev/null 2>&1; }

pdir() {
  local repo="$1"
  local id
  id="$(cat "$repo/.agy/current" 2>/dev/null || true)"
  [ -n "$id" ] && printf '%s/.agy/runs/%s' "$repo" "$id"
}

# run <repo> <args...> — STATUS line into $OUT, exit code into $CODE.
run() { R="$1"; shift; OUT="$(/bin/bash "$CHECK" --dir "$R" "$@" 2>/dev/null)"; CODE=$?; }
word_of()  { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }
facts_of() { printf '%s/RELEASE_FACTS.md' "$(pdir "$R")"; }

# Everything a release could damage, in one string.
snapshot() {
  git -C "$1" rev-parse HEAD 2>/dev/null
  printf -- '--- tags ---\n'
  git -C "$1" tag -l 2>/dev/null
  printf -- '--- refs ---\n'
  git -C "$1" for-each-ref 2>/dev/null
}

# --- the three cases the old Phase 4 had no branch for --------------------

# 1. No remote. A perfectly ordinary local repository, and explicitly not an
#    error: the release simply ends at a local commit and tag.
R="$(new_repo no-remote)"
run "$R"
check noremote-rc "$CODE" 0 "exit 0 with no remote"
check noremote-status "$(word_of "$OUT")" "RELEASE_LOCAL_ONLY" "reported RELEASE_LOCAL_ONLY"
has noremote-field "$OUT" "Remote: none" "the line says there is no remote"
has noremote-note "$OUT" "normal outcome rather than an error" "and says that is normal, not an error"
if grep -q '^can push: *no' "$(facts_of)" 2>/dev/null; then
  ok noremote-facts "the facts file tells the worker it cannot push"
else
  bad noremote-facts "the facts file does not settle the push question"
fi

# 2. A remote exists. Same repository, one line of config apart.
R="$(new_repo with-remote)"; add_remote "$R"
run "$R"
check remote-rc "$CODE" 0 "exit 0 with a remote"
check remote-status "$(word_of "$OUT")" "RELEASE_READY" "reported RELEASE_READY"
has remote-name "$OUT" "Remote: origin" "the remote is named"
hasnt remote-url "$OUT" "$ROOT/remotes" "the remote URL is never printed — it is the field that can carry a credential"

# 3. No tags at all: a first release has no predecessor to increment from.
R="$(new_repo first-release)"
run "$R"
check firsttag-rc "$CODE" 0 "exit 0 with no tags — a first release is not a failure"
has firsttag-count "$OUT" "Tags: 0" "the tag count is zero"
has firsttag-next "$OUT" "Next: v0.1.0 (first release" "v0.1.0 is proposed as a starting point"
run "$R" --first-version 2.0.0
has firsttag-flag "$OUT" "Next: 2.0.0" "--first-version moves it"

# 4. Already on the release branch. Not a blocker — it means the merge step is
#    a no-op, which is a fact about the plan.
R="$(new_repo on-release-branch)"
run "$R"
has onbranch-field "$OUT" "already the release branch" "the branch field says the merge step is a no-op"
if grep -q '^merge step: *none' "$(facts_of)" 2>/dev/null; then
  ok onbranch-facts "and the facts file says so where the worker will read it"
else
  bad onbranch-facts "the facts file still describes a merge"
fi

R="$(new_repo off-release-branch)"
( cd "$R" && git checkout -q -b feature/x )
run "$R"
has offbranch-field "$OUT" "Branch: feature/x" "the working branch is reported"
has offbranch-release "$OUT" "Release branch: main" "and main is identified as the release branch"
if grep -q '^merge step: *feature/x into main' "$(facts_of)" 2>/dev/null; then
  ok offbranch-facts "the facts file names the merge that would be needed"
else
  bad offbranch-facts "the facts file does not name the merge"
fi

# --- versions -------------------------------------------------------------

# 5. Existing semver tags, and the ordering that string sorting gets wrong.
R="$(new_repo semver)"
git -C "$R" tag v1.2.3; git -C "$R" tag v1.9.0; git -C "$R" tag v1.10.0
git -C "$R" tag v1.11.0-rc1
run "$R"
check semver-rc "$CODE" 0 "exit 0 with semver tags"
has semver-latest "$OUT" "latest v1.10.0" "v1.10.0 outranks v1.9.0 — compared as numbers, not strings"
has semver-next "$OUT" "Next: v1.11.0 (minor bump" "the next minor version is computed from it"
has semver-alts "$OUT" "patch v1.10.1 or major v2.0.0" "and the alternatives ride along, because bump size is a judgement"
hasnt semver-rc-tag "$OUT" "v1.11.0-rc1" "a pre-release tag is not read as the last release"

run "$R" --bump patch
has bump-patch "$OUT" "Next: v1.10.1" "--bump patch"
run "$R" --bump major
has bump-major "$OUT" "Next: v2.0.0" "--bump major"

# 6. The repository's own tag format is preserved exactly. Introducing a second
#    convention is worse than any bump size being wrong.
R="$(new_repo no-v-prefix)"
git -C "$R" tag 1.2.3
run "$R"
has prefix-bare "$OUT" "Next: 1.3.0" "a bare 1.2.3 begets 1.3.0, not v1.3.0"
R="$(new_repo odd-prefix)"
git -C "$R" tag release-2.4.1
run "$R"
has prefix-odd "$OUT" "Next: release-2.5.0" "an unusual prefix survives untouched"

# 7. Tags that carry no version at all. Nothing can be derived, and guessing
#    would either restart the scheme at 0.1.0 or invent a second convention.
R="$(new_repo unparseable-tags)"
git -C "$R" tag ship-it; git -C "$R" tag stable
run "$R"
check badtags-rc "$CODE" 3 "exit 3 when no tag carries a version"
check badtags-status "$(word_of "$OUT")" "RELEASE_BLOCKED(tag_format_unknown)" "named the reason in the status"
has badtags-note "$OUT" "name the version yourself" "and said what a person has to supply"

# --- what genuinely needs a person ---------------------------------------

# 8. A dirty tree. Whether uncommitted work belongs in a release is a judgement
#    about intent, and folding it in silently is how unreviewed code ships.
R="$(new_repo dirty)"
printf 'wip\n' > "$R/wip.txt"
run "$R"
check dirty-rc "$CODE" 3 "exit 3 on a dirty tree"
check dirty-status "$(word_of "$OUT")" "RELEASE_BLOCKED(dirty_tree)" "reported RELEASE_BLOCKED(dirty_tree)"
has dirty-paths "$OUT" "wip.txt" "the offending path is named"
run "$R" --allow-dirty
check dirty-override-rc "$CODE" 0 "--allow-dirty exit 0"
has dirty-override "$OUT" "allowed through by --allow-dirty" "and the line says the tree was dirty anyway"

# 9. The facts file this script writes must not itself count as a dirty tree on
#    the next run. Excluded by pathspec, not left to .gitignore.
R="$(new_repo self-dirty)"
rm -f "$R/.gitignore"; ( cd "$R" && git add -A ) >/dev/null 2>&1; commit "$R" -m drop-ignore
run "$R"
check selfdirty-first "$CODE" 0 "exit 0 on the first run, .agy/ not ignored"
run "$R"
check selfdirty-second "$CODE" 0 "exit 0 on the second — a run never reports its own output as blocking work"

# 10. No commits: there is nothing to cut a release from.
R="$ROOT/repos/empty"; mkdir -p "$R"; ( cd "$R" && git init -q -b main . )
run_dir_new --dir "$R" --task "empty" >/dev/null
run "$R"
check nocommits-rc "$CODE" 3 "exit 3 in a repository with no commits"
check nocommits-status "$(word_of "$OUT")" "RELEASE_BLOCKED(no_commits)" "reported RELEASE_BLOCKED(no_commits)"

# 11. Detached HEAD: no branch to merge from, none to tag by name.
R="$(new_repo detached)"
printf 'second\n' >> "$R/kept.txt"; ( cd "$R" && git add -A ) >/dev/null 2>&1; commit "$R" -m second
( cd "$R" && git checkout -q --detach HEAD )
run "$R"
check detached-rc "$CODE" 3 "exit 3 on a detached HEAD"
check detached-status "$(word_of "$OUT")" "RELEASE_BLOCKED(detached_head)" "reported RELEASE_BLOCKED(detached_head)"

# 12. A block still writes the facts file, so whoever reads it afterwards sees
#     what was missing rather than nothing at all.
if grep -q 'blocked because:' "$(facts_of)" 2>/dev/null; then
  ok blocked-facts "a blocked run still leaves the facts on disk"
else
  bad blocked-facts "the facts file says nothing about the block"
fi

# --- the changelog --------------------------------------------------------

R="$(new_repo changelog)"
run "$R"
has changelog-none "$OUT" "Changelog: none" "no changelog is reported as none, not as a problem"
printf '# Changelog\n' > "$R/CHANGELOG.md"
( cd "$R" && git add -A ) >/dev/null 2>&1; commit "$R" -m changelog
run "$R"
has changelog-found "$OUT" "Changelog: CHANGELOG.md" "an existing changelog is found and named"

# --- the facts file the worker actually reads -----------------------------

R="$(new_repo facts)"; add_remote "$R"; git -C "$R" tag v3.1.4
run "$R"
# Taken out of the status line rather than reconstructed, so this asserts the
# path the orchestrator would actually paste into a brief. The script resolves
# through `git rev-parse --show-toplevel`, which returns the physical path, so
# the repo it is compared against is normalised the same way — $TMPDIR on macOS
# is a symlink and the two spellings are not string-equal.
F="$(printf '%s' "$OUT" | sed -e 's/.*| Facts: //' -e 's/ | .*//')"
RP="$(cd "$R" && pwd -P)"
[ -f "$F" ] && ok facts-exists "the status line's Facts path really has a file at it" \
            || bad facts-exists "no facts file at $F"
RUN_ID_FACTS="$(cat "$R/.agy/current")"
check facts-path "$F" "$RP/.agy/runs/$RUN_ID_FACTS/RELEASE_FACTS.md" "under the repo's run directory"
case "$F" in "$RP"/*) ok facts-inside "the path is inside the repo, so inside --add-dir" ;;
  *) bad facts-inside "the worker could not read $F" ;; esac
for KEY in "status:" "current branch:" "release branch:" "remote:" "working tree:" \
           "tags:" "latest version tag:" "tag format:" "proposed version:" "changelog:"; do
  if grep -q "^$KEY" "$F" 2>/dev/null; then
    ok "facts-$(printf '%s' "$KEY" | tr -d ' :')" "the facts file states '$KEY'"
  else
    bad "facts-$(printf '%s' "$KEY" | tr -d ' :')" "the facts file omits '$KEY'"
  fi
done
if grep -q 'a human performs it' "$F" 2>/dev/null; then
  ok facts-prohibition "the facts file tells the worker it prepares and does not perform"
else
  bad facts-prohibition "the facts file does not say who performs the release"
fi

# --into moves the pair; the caller then owns keeping it inside --add-dir.
run "$R" --into "$R/elsewhere"
has into-field "$OUT" "Facts: $R/elsewhere/RELEASE_FACTS.md" "--into moves the facts file"
[ -f "$R/elsewhere/RELEASE_FACTS.md" ] && ok into-exists "the redirected file exists" \
                                       || bad into-exists "nothing at the --into path"

# --- THE INVARIANT: reading the repository changes nothing ----------------

# 13. A repository with everything a release could touch — commits, several
#     branches, several tags, a remote — snapshotted before and after every
#     mode this script runs in.
R="$(new_repo unchanged)"; add_remote "$R"
git -C "$R" tag v1.0.0; git -C "$R" tag v1.1.0; git -C "$R" tag not-a-version
( cd "$R" && git checkout -q -b feature/y )
printf 'more\n' >> "$R/kept.txt"; ( cd "$R" && git add -A ) >/dev/null 2>&1; commit "$R" -m more
( cd "$R" && git checkout -q main )

HEAD_BEFORE="$(git -C "$R" rev-parse HEAD)"
TAGS_BEFORE="$(git -C "$R" tag -l)"
REFS_BEFORE="$(git -C "$R" for-each-ref)"
COMMITS_BEFORE="$(git -C "$R" rev-list --count HEAD)"
SNAP_BEFORE="$(snapshot "$R")"

run "$R"
run "$R" --bump major
run "$R" --allow-dirty
run "$R" --release-branch feature/y
run "$R" --first-version v9.9.9
printf 'dirty now\n' > "$R/scratch.txt"
run "$R"
rm -f "$R/scratch.txt"
run "$R" --into "$R/elsewhere"

check unchanged-head "$(git -C "$R" rev-parse HEAD)" "$HEAD_BEFORE" "HEAD is where it was"
check unchanged-tags "$(git -C "$R" tag -l)" "$TAGS_BEFORE" "not one tag was created, moved or deleted"
check unchanged-refs "$(git -C "$R" for-each-ref)" "$REFS_BEFORE" "every ref points at the same object"
check unchanged-all  "$(snapshot "$R")" "$SNAP_BEFORE" "HEAD, tags and refs together, byte for byte, after seven runs"
check unchanged-log  "$(git -C "$R" rev-list --count HEAD)" "$COMMITS_BEFORE" "no commit was made"
if git -C "$R" status --porcelain | grep -q '^[MARD]'; then
  bad unchanged-index "the script staged something"
else
  ok unchanged-index "nothing was staged — the index is untouched"
fi

# 14. Same again on a repository the script *blocks*: an early exit must not be
#     an exit that skipped a cleanup and left something behind.
R="$(new_repo unchanged-blocked)"
git -C "$R" tag v2.0.0
printf 'wip\n' > "$R/wip.txt"
SNAP_BEFORE="$(snapshot "$R")"
run "$R"
check blocked-rc "$CODE" 3 "the blocked repository still blocks"
check unchanged-blocked "$(snapshot "$R")" "$SNAP_BEFORE" "and a blocked run leaves HEAD, tags and refs identical"

# 15. The source itself. The snapshot above proves this run wrote nothing; this
#     proves no future run can, by asserting the dangerous commands are not in
#     the file at all outside its comments.
CODEONLY="$(sed -e 's/#.*//' "$CHECK")"
DANGEROUS=""
for CMD in "git push" "git merge" "git commit" "git tag -a" "git tag -d" \
           "git reset" "git rebase" "git checkout" "git branch" "git config" \
           "git fetch" "git pull" "gh release"; do
  case "$CODEONLY" in *"$CMD"*) DANGEROUS="$DANGEROUS $CMD" ;; esac
done
check no-git-writes "$(printf '%s' "$DANGEROUS" | sed -e 's/^ //')" "" \
  "no command that writes git state, or reaches a network, appears in the script"

# --- the shape of the answer ---------------------------------------------

R="$(new_repo shape)"
run "$R"
check stdout-lines "$(printf '%s\n' "$OUT" | grep -c .)" 1 "stdout is one line"
has stdout-shape "$OUT" "STATUS: " "and it is a STATUS line"
case "$OUT" in STATUS:*) ok stdout-start "which starts at the first column" ;;
  *) bad stdout-start "stdout does not start with STATUS:" ;; esac

# --- argument handling ----------------------------------------------------

run "$R" --bump sideways
check bad-bump "$CODE" 2 "exit 2 on an unknown --bump"
run "$R" --first-version soon
check bad-first "$CODE" 2 "exit 2 on a --first-version that is not a version"
run "$R" --bogus
check bad-arg "$CODE" 2 "exit 2 on an unknown flag"
OUT="$(/bin/bash "$CHECK" --dir "$ROOT/nope" 2>/dev/null)"; CODE=$?
check bad-dir "$CODE" 2 "exit 2 on a missing --dir"
mkdir -p "$ROOT/plain"
OUT="$(/bin/bash "$CHECK" --dir "$ROOT/plain" 2>/dev/null)"; CODE=$?
check not-a-repo "$CODE" 2 "exit 2 on a directory that is not a git work tree"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
