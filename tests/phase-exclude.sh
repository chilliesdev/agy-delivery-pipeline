#!/usr/bin/env bash
# Exercise phase.sh --ignore-via, the flag that decides *where* .agy/ gets
# ignored: the tracked .gitignore (default, every pipeline phase) or
# .git/info/exclude (the delegate path, which must not touch a tracked file).
#
#   tests/phase-exclude.sh
#
# Same shape as tests/phase-dispatch.sh: a stub `agy` behind AGY_BIN, throwaway
# repos under ${TMPDIR:-/tmp}, nothing written inside this repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE_SH="$HERE/../scripts/phase.sh"
[ -f "$PHASE_SH" ] || { echo "phase-exclude: phase.sh not found next door" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase-exclude.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\n'
  exit 0
fi
if [ -f .agy/current ]; then
  CUR_RUN="$(cat .agy/current 2>/dev/null || true)"
  if [ -n "$CUR_RUN" ]; then
    mkdir -p ".agy/runs/$CUR_RUN/phases/$STUB_PHASE"
    printf 'STATUS: DONE | File: CHANGES.md\n' > ".agy/runs/$CUR_RUN/phases/$STUB_PHASE/verdict"
  fi
fi
printf 'STATUS: DONE | File: CHANGES.md\n'
exit 0
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
count() { C="$(grep -c -- "$2" "$1" 2>/dev/null)"; printf '%s' "${C:-0}"; }

new_repo() {
  R="$ROOT/repos/$1"; mkdir -p "$R"
  printf 'do the thing\n' > "$R/brief.md"
  git -C "$R" init -q >/dev/null 2>&1
  printf '%s\n' "$R"
}

run_phase() {
  RP_REPO="$1"; shift
  STUB_PHASE=DELEGATE AGY_BIN="$STUB" \
    "$PHASE_SH" --phase DELEGATE --brief "$RP_REPO/brief.md" --dir "$RP_REPO" "$@" 2>/dev/null
}

# a. --ignore-via exclude writes .git/info/exclude and leaves .gitignore alone.
# This is the whole point: ambient delegation must not edit a tracked file in a
# repo the user did not ask it to touch.
REPO="$(new_repo a-exclude)"
OUT="$(run_phase "$REPO" --ignore-via exclude)"
check a-exclude-written "$(count "$REPO/.git/info/exclude" '^\.agy/$')" "1" \
  ".git/info/exclude gained one .agy/ entry"
check a-exclude-no-gitignore "$([ -e "$REPO/.gitignore" ] && echo yes || echo no)" "no" \
  "no .gitignore was created"
# The brief itself is untracked in these throwaway repos, so scope the check to
# the two paths this flag is about: the scratch dir must be ignored, and no
# .gitignore must have appeared to be committed by accident.
check a-exclude-clean-tree "$(git -C "$REPO" status --porcelain -- .agy .gitignore 2>/dev/null | grep -c .)" "0" \
  "git sees neither .agy/ nor a new .gitignore"
case "$OUT" in *"| Gitignore: added .agy/ to "*"/info/exclude"*)
    ok a-exclude-reported "the STATUS line names the exclude file" ;;
  *) bad a-exclude-reported "no exclude field: $OUT" ;; esac
check a-exclude-oneline "$(printf '%s\n' "$OUT" | grep -c .)" "1" \
  "stdout is still exactly one line"

# b. the default is unchanged — the pipeline phases still get the tracked file.
REPO="$(new_repo b-default)"
run_phase "$REPO" >/dev/null
check b-default-gitignore "$(count "$REPO/.gitignore" '^\.agy/$')" "1" \
  "without the flag, .gitignore is still what gets written"
check b-default-no-exclude "$(count "$REPO/.git/info/exclude" '^\.agy/$')" "0" \
  ".git/info/exclude was left alone"

# c. --ignore-via gitignore is the default spelled out, not a third behaviour.
REPO="$(new_repo c-explicit)"
run_phase "$REPO" --ignore-via gitignore >/dev/null
check c-explicit "$(count "$REPO/.gitignore" '^\.agy/$')" "1" \
  "the explicit default behaves like the implicit one"

# d. a second dispatch adds nothing: check-ignore already sees the exclude entry,
# so the guard is skipped rather than appending a duplicate.
REPO="$(new_repo d-idempotent)"
run_phase "$REPO" --ignore-via exclude >/dev/null
OUT="$(run_phase "$REPO" --ignore-via exclude)"
check d-idempotent "$(count "$REPO/.git/info/exclude" '^\.agy/$')" "1" \
  "still exactly one entry after a second dispatch"
case "$OUT" in *"| Gitignore: "*) bad d-idempotent-quiet "second run still reported: $OUT" ;;
  *) ok d-idempotent-quiet "the second run says nothing about ignore rules" ;; esac

# e. an exclude file with no trailing newline must not absorb the entry into its
# last line — the same hazard the .gitignore path guards against.
REPO="$(new_repo e-no-newline)"
printf 'build' > "$REPO/.git/info/exclude"
run_phase "$REPO" --ignore-via exclude >/dev/null
check e-no-newline "$(count "$REPO/.git/info/exclude" '^\.agy/$')" "1" \
  ".agy/ landed on its own line"
check e-no-newline-kept "$(count "$REPO/.git/info/exclude" '^build$')" "1" \
  "the existing entry survived intact"

# f. an unknown value is refused up front rather than silently defaulting.
REPO="$(new_repo f-bad-value)"
STUB_PHASE=DELEGATE AGY_BIN="$STUB" \
  "$PHASE_SH" --phase DELEGATE --brief "$REPO/brief.md" --dir "$REPO" \
  --ignore-via sideways >/dev/null 2>&1
check f-bad-value "$?" "2" "a bad --ignore-via exits 2"
check f-bad-value-untouched "$([ -e "$REPO/.gitignore" ] && echo yes || echo no)" "no" \
  "nothing was written before the refusal"

# g. outside a git repo neither file is invented.
REPO="$ROOT/repos/g-not-git"; mkdir -p "$REPO"; printf 'do it\n' > "$REPO/brief.md"
OUT="$(run_phase "$REPO" --ignore-via exclude)"
check g-not-git "$([ -e "$REPO/.gitignore" ] && echo yes || echo no)" "no" \
  "no .gitignore outside a work tree"
case "$OUT" in *"| Gitignore: "*) bad g-not-git-quiet "reported an ignore edit: $OUT" ;;
  *) ok g-not-git-quiet "nothing reported outside a work tree" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
