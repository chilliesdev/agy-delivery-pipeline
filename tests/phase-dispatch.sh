#!/usr/bin/env bash
# Exercise phase.sh's dispatch side effects: the .gitignore guard it installs
# before running a worker — which it reports on the STATUS line and never
# commits — and the sandbox flag it forwards to agy-run.sh.
#
#   tests/phase-dispatch.sh
#
# Builds a fake `agy` that records the argv it was handed, points agy-run.sh at
# it with AGY_BIN, and runs phase.sh against throwaway repos under
# ${TMPDIR:-/tmp}. Nothing is written inside this repo. Prints one line per case
# and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_SH="$HERE/../scripts/phase.sh"
[ -f "$PHASE_SH" ] || { echo "phase-dispatch: phase.sh not found next door" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase-dispatch.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

# The stub agy: writes the verdict phase.sh expects and dumps its own argv, one
# argument per line, to $STUB_ARGV (absolute — agy-run.sh cd's into the repo).
# `agy models` returns before the argv dump, so preflight.sh's call never
# overwrites the dispatch argv these cases assert on.
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
  exit 0
fi
[ -n "${STUB_ARGV:-}" ] && printf '%s\n' "$@" > "$STUB_ARGV"
mkdir -p .tmp; printf 'STATUS: DONE | File: .tmp/CHANGES.md\n' > ".tmp/$STUB_PHASE.verdict"
exit 0
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
# grep -c both prints 0 and exits 1 on no match, so `|| echo 0` would double up.
count() { C="$(grep -c -- "$2" "$1" 2>/dev/null)"; printf '%s' "${C:-0}"; }

# new_repo <name> — a throwaway git repo with a brief in it; echoes its path.
new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  printf 'do the thing\n' > "$R/brief.md"
  git -C "$R" init -q >/dev/null 2>&1
  printf '%s\n' "$R"
}

# run_phase <repo> <dir> [extra phase.sh args...] — dispatch, capture stdout.
run_phase() {
  RP_REPO="$1"; RP_DIR="$2"; shift 2
  STUB_PHASE=TEST STUB_ARGV="${STUB_ARGV_FILE:-}" AGY_BIN="$STUB" \
    "$PHASE_SH" --phase TEST --brief "$RP_REPO/brief.md" --dir "$RP_DIR" "$@" 2>/dev/null
}

# --- .gitignore guard -------------------------------------------------------

# a. a fresh git repo gains .tmp/ on the first run
REPO="$(new_repo a-fresh-repo)"
OUT="$(run_phase "$REPO" "$REPO")"
check a-fresh-repo "$(count "$REPO/.gitignore" '^\.tmp/$')" "1" \
  ".gitignore gained one .tmp/ entry"
case "$OUT" in
  "STATUS: DONE | File: .tmp/CHANGES.md | Phase: TEST | Log: "*) ok a-fresh-repo-stdout "stdout is still one STATUS line" ;;
  *) bad a-fresh-repo-stdout "stdout was: $OUT" ;;
esac
check a-fresh-repo-oneline "$(printf '%s\n' "$OUT" | grep -c .)" "1" \
  "the report did not cost a second line"

# a2. the file the tooling just authored is reported, because it is untracked
# and one `git add -A` from the task's own commit. The path in the line comes
# from `git rev-parse --show-toplevel`, which is physical — $TMPDIR on macOS is
# /var/folders/…, a symlink to /private/var/folders/… — so compare against the
# resolved path, not the one mktemp handed back.
REPO_REAL="$(cd "$REPO" && pwd -P)"
case "$OUT" in *"| Gitignore: created $REPO_REAL/.gitignore holding .tmp/"*)
    ok a-fresh-repo-reported "the STATUS line names the file it created" ;;
  *) bad a-fresh-repo-reported "no Gitignore field: $OUT" ;; esac
check a-fresh-repo-status-file "$(sed -n '1p' "$REPO/.tmp/TEST.status")" "$OUT" \
  ".tmp/TEST.status carries the same line"

# a3. reported, not committed: phase.sh writes nothing to the user's history.
check a-fresh-repo-no-commit "$(git -C "$REPO" rev-list --count --all 2>/dev/null)" "0" \
  "no commit was made on the user's behalf"
check a-fresh-repo-untracked "$(git -C "$REPO" status --porcelain -- .gitignore 2>/dev/null)" \
  "?? .gitignore" "the file is left untracked for the orchestrator to deal with"

# b. running twice must not duplicate the entry, and must not repeat the report
run_phase "$REPO" "$REPO" >/dev/null
check b-run-twice "$(count "$REPO/.gitignore" '^\.tmp/$')" "1" \
  "still exactly one .tmp/ entry after a second run"
OUT="$(run_phase "$REPO" "$REPO")"
case "$OUT" in *Gitignore:*) bad b-run-twice-quiet "the second run reported an edit it did not make" ;;
  *) ok b-run-twice-quiet "only the dispatch that wrote it says so" ;; esac

# c. a repo that already ignores .tmp is left byte-identical. `.tmp/` is
# directory-only, so this also pins phase.sh's mkdir-before-check ordering:
# check-ignore cannot match it until .tmp exists as a directory.
REPO="$(new_repo c-already-ignored)"
printf 'node_modules/\n.tmp/\ndist/\n' > "$REPO/.gitignore"
BEFORE="$(cksum < "$REPO/.gitignore")"
OUT="$(run_phase "$REPO" "$REPO")"
check c-already-ignored "$(cksum < "$REPO/.gitignore")" "$BEFORE" \
  "existing .gitignore untouched"
case "$OUT" in *Gitignore:*) bad c-already-ignored-quiet "reported an edit that never happened" ;;
  *) ok c-already-ignored-quiet "nothing edited, nothing reported" ;; esac

# c2. same, via a differently-spelled rule that git still honours
REPO="$(new_repo c2-ignored-other-spelling)"
printf '/.tmp\n' > "$REPO/.gitignore"
BEFORE="$(cksum < "$REPO/.gitignore")"
run_phase "$REPO" "$REPO" >/dev/null
check c2-ignored-other-spelling "$(cksum < "$REPO/.gitignore")" "$BEFORE" \
  "'/.tmp' recognised as already ignoring"

# d. a .gitignore with no trailing newline must not have its last line corrupted
REPO="$(new_repo d-no-trailing-newline)"
printf 'node_modules/' > "$REPO/.gitignore"
OUT="$(run_phase "$REPO" "$REPO")"
check d-no-trailing-newline "$(printf '%s' "$(cat "$REPO/.gitignore")" | tr '\n' '|')" \
  "node_modules/|.tmp/" "last line intact, .tmp/ on its own line"

# d2. an edit to a file that was already there is still an edit the task did not
# ask for, and is reported as one — in the other wording, since nothing was
# created here.
REPO_REAL="$(cd "$REPO" && pwd -P)"
case "$OUT" in *"| Gitignore: added .tmp/ to $REPO_REAL/.gitignore"*)
    ok d-existing-reported "an edit to an existing .gitignore is reported too" ;;
  *) bad d-existing-reported "no Gitignore field: $OUT" ;; esac
check d-existing-no-commit "$(git -C "$REPO" rev-list --count --all 2>/dev/null)" "0" \
  "still nothing committed"

# e. a plain directory that is not a git repo: no error, no .gitignore invented
REPO="$ROOT/repos/e-not-a-repo"; mkdir -p "$REPO"
printf 'do the thing\n' > "$REPO/brief.md"
OUT="$(run_phase "$REPO" "$REPO")"; RC=$?
check e-not-a-repo "$RC" "0" "phase.sh exited 0 outside a git repo"
check e-not-a-repo-clean "$([ -e "$REPO/.gitignore" ] && echo present || echo absent)" "absent" \
  "no .gitignore created"

# f. --dir is a subdirectory: the work tree root's .gitignore is the one written
REPO="$(new_repo f-subdir)"
mkdir -p "$REPO/packages/app"
run_phase "$REPO" "$REPO/packages/app" >/dev/null
check f-subdir-root "$(count "$REPO/.gitignore" '^\.tmp/$')" "1" \
  "root .gitignore got the entry"
check f-subdir-leaf "$([ -e "$REPO/packages/app/.gitignore" ] && echo present || echo absent)" \
  "absent" "subdirectory .gitignore not created"

# --- sandbox flag forwarding ------------------------------------------------

# g. without --sandbox the flag must not reach agy at all
REPO="$(new_repo g-no-sandbox)"
STUB_ARGV_FILE="$ROOT/argv-no-sandbox"
run_phase "$REPO" "$REPO" >/dev/null
check g-no-sandbox-recorded "$(count "$STUB_ARGV_FILE" '^--add-dir$')" "1" \
  "the stub really recorded an argv"
check g-no-sandbox "$(count "$STUB_ARGV_FILE" '^--sandbox$')" "0" \
  "agy invoked without --sandbox"
check g-no-sandbox-empty "$(count "$STUB_ARGV_FILE" '^$')" "0" \
  "no stray empty argument from the expansion"

# h. with --sandbox the flag reaches agy exactly once
REPO="$(new_repo h-sandbox)"
STUB_ARGV_FILE="$ROOT/argv-sandbox"
run_phase "$REPO" "$REPO" --sandbox >/dev/null
check h-sandbox "$(count "$STUB_ARGV_FILE" '^--sandbox$')" "1" \
  "agy invoked with --sandbox once"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
