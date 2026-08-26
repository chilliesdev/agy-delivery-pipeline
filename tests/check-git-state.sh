#!/usr/bin/env bash
# Exercise check-git-state.sh: snapshotting and comparing git repository state.
#
#   tests/check-git-state.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-git-state.sh"
[ -f "$CHECK" ] || { echo "check-git-state-test: script not found next door" >&2; exit 2; }

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-git-state.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" "$4" ;; *) bad "$1" "$4 (line: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "$4 (line: $2)" ;; *) ok "$1" "$4" ;; esac; }

commit() { git -C "$1" -c user.email=t@t -c user.name=t commit -q "$2" "$3"; }

new_repo() {
  local r="$ROOT/repos/$1"; mkdir -p "$r"
  ( cd "$r" && git init -q -b main . )
  printf '.agy/\n' > "$r/.gitignore"
  printf 'initial\n' > "$r/file.txt"
  ( cd "$r" && git add -A ) >/dev/null 2>&1
  commit "$r" -m "initial commit"
  git -C "$r" tag v1.0.0
  printf '%s' "$r"
}

run_check() {
  OUT="$(/bin/bash "$CHECK" "$@" 2>/dev/null)"
  CODE=$?
}

# 1. An untouched repository compares as unchanged, exit 0
R1="$(new_repo untouched)"
SNAP1="$ROOT/snap1.txt"
run_check snapshot --dir "$R1" --out "$SNAP1"
check untouched-snap-rc "$CODE" 0 "snapshot exits 0"
[ -f "$SNAP1" ] && ok untouched-snap-file "snapshot file written" || bad untouched-snap-file "snapshot file missing"

run_check compare --dir "$R1" --before "$SNAP1"
check untouched-cmp-rc "$CODE" 0 "untouched repo compares as unchanged, exit 0"
has untouched-status "$OUT" "STATUS: GIT_STATE_UNCHANGED" "status is GIT_STATE_UNCHANGED"
has untouched-checks "$OUT" "Checks: head, tags, refs" "names compared checks"

# 2. A new commit is reported as changed, with the head named, on non-zero exit
R2="$(new_repo commit-change)"
SNAP2="$ROOT/snap2.txt"
run_check snapshot --dir "$R2" --out "$SNAP2"

printf 'more data\n' >> "$R2/file.txt"
( cd "$R2" && git add -A ) >/dev/null 2>&1
commit "$R2" -m "second commit"
NEW_HEAD2="$(git -C "$R2" rev-parse HEAD)"

run_check compare --dir "$R2" --before "$SNAP2"
check commit-cmp-rc "$CODE" 3 "new commit exits 3 (non-zero)"
has commit-status "$OUT" "STATUS: GIT_STATE_CHANGED" "status is GIT_STATE_CHANGED"
has commit-head-named "$OUT" "$NEW_HEAD2" "new head commit is named in output"
has commit-head-changed "$OUT" "head" "names head as changed"

# 3. A new tag is reported as changed
R3="$(new_repo tag-change)"
SNAP3="$ROOT/snap3.txt"
run_check snapshot --dir "$R3" --out "$SNAP3"

git -C "$R3" tag v2.0.0
run_check compare --dir "$R3" --before "$SNAP3"
check tag-cmp-rc "$CODE" 3 "new tag exits 3 (non-zero)"
has tag-status "$OUT" "STATUS: GIT_STATE_CHANGED" "status is GIT_STATE_CHANGED"
has tag-item-named "$OUT" "tags" "names tags as changed"

# 4. A moved branch ref is reported as changed
R4="$(new_repo ref-change)"
printf 'second\n' >> "$R4/file.txt"
( cd "$R4" && git add -A ) >/dev/null 2>&1
commit "$R4" -m "second commit"
( cd "$R4" && git branch feature-branch main )

SNAP4="$ROOT/snap4.txt"
run_check snapshot --dir "$R4" --out "$SNAP4"

git -C "$R4" branch -f feature-branch HEAD~1
run_check compare --dir "$R4" --before "$SNAP4"
check ref-cmp-rc "$CODE" 3 "moved branch ref exits 3 (non-zero)"
has ref-status "$OUT" "STATUS: GIT_STATE_CHANGED" "status is GIT_STATE_CHANGED"
has ref-item-named "$OUT" "refs" "names refs as changed"

# 5. Bad arguments exit 2
run_check
check badarg-no-cmd "$CODE" 2 "exit 2 with no command"
run_check unknown_subcommand
check badarg-unknown-cmd "$CODE" 2 "exit 2 on unknown subcommand"
run_check snapshot --dir "$R1"
check badarg-snap-no-out "$CODE" 2 "exit 2 on snapshot missing --out"
run_check compare --dir "$R1"
check badarg-cmp-no-before "$CODE" 2 "exit 2 on compare missing --before"
run_check compare --dir "$R1" --before "$ROOT/nonexistent.txt"
check badarg-cmp-missing-file "$CODE" 2 "exit 2 on compare with missing file"
run_check snapshot --dir "$ROOT/not-a-dir" --out "$SNAP1"
check badarg-missing-dir "$CODE" 2 "exit 2 on non-existent dir"
mkdir -p "$ROOT/plain-dir"
run_check snapshot --dir "$ROOT/plain-dir" --out "$SNAP1"
check badarg-not-git "$CODE" 2 "exit 2 on non-git directory"
run_check snapshot --dir "$R1" --out "$SNAP1" --invalid-flag
check badarg-invalid-flag "$CODE" 2 "exit 2 on invalid flag"

# 6. Source contains no git mutations
CODEONLY="$(sed -e 's/#.*//' "$CHECK")"
DANGEROUS=""
for CMD in "git push" "git merge" "git commit" "git tag -a" "git tag -d" \
           "git reset" "git rebase" "git checkout" "git branch" "git config" \
           "git fetch" "git pull"; do
  case "$CODEONLY" in *"$CMD"*) DANGEROUS="$DANGEROUS $CMD" ;; esac
done
check no-git-writes "$(printf '%s' "$DANGEROUS" | sed -e 's/^ //')" "" \
  "no command that writes git state appears in check-git-state.sh"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
