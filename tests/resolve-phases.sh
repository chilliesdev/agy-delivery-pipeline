#!/usr/bin/env bash
# Exercise resolve-phases.sh: which phases a repository declares, what happens when
# it declares none, and how an undeclared phase is reported.
#
#   tests/resolve-phases.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_PHASES="$HERE/../scripts/resolve-phases.sh"
VENDORED_CONFIG="$HERE/../agy.toml"

[ -f "$RESOLVE_PHASES" ] || { echo "resolve-phases-test: resolve-phases.sh not found next door" >&2; exit 2; }
[ -f "$VENDORED_CONFIG" ] || { echo "resolve-phases-test: agy.toml not found at repo root" >&2; exit 2; }

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/resolve-phases.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# new_repo <name> [config-body] — a repo, optionally with its own agy.toml
new_repo() {
  local r="$ROOT/$1"; mkdir -p "$r"
  if [ $# -gt 1 ]; then
    printf '%s\n' "$2" > "$r/agy.toml"
  fi
  printf '%s' "$r"
}

run_phases() { OUT="$(/bin/bash "$RESOLVE_PHASES" --dir "$1" 2>/dev/null)"; CODE=$?; }
check_phase() { /bin/bash "$RESOLVE_PHASES" --dir "$1" --check "$2" >/dev/null 2>&1; printf '%s' "$?"; }

# --- the vendored default ---------------------------------------------------

R_DEF="$(new_repo default-config)"
run_phases "$R_DEF"
check default-rc "$CODE" 0 "a repo with no agy.toml resolves without error"
check default-list "$(printf '%s' "$OUT" | tr '\n' ' ')" "DISCOVERY IMPLEMENT REVIEW QA RELEASE" \
  "falls back to the five phases the pipeline has always run"

# --- a repository that declares its own, shorter, pipeline ------------------
#
# This is the case the whole thing exists for: a repo with no release step could
# not say so, and a missing RELEASE_PLAN.md read as a failure rather than as a
# phase that was never part of this pipeline.

R_SHORT="$(new_repo no-release '[pipeline]
phases = ["DISCOVERY", "IMPLEMENT", "REVIEW"]')"
run_phases "$R_SHORT"
check short-rc "$CODE" 0 "a declared subset resolves without error"
check short-list "$(printf '%s' "$OUT" | tr '\n' ' ')" "DISCOVERY IMPLEMENT REVIEW" \
  "the declared list wins over the default"
check short-declared "$(check_phase "$R_SHORT" REVIEW)" "0" "a declared phase checks clean"
check short-undeclared "$(check_phase "$R_SHORT" RELEASE)" "3" \
  "a phase this repo does not declare exits 3, distinct from an error"

# --- order is meaning, not a set --------------------------------------------

R_ORDER="$(new_repo reordered '[pipeline]
phases = ["DISCOVERY", "REVIEW", "IMPLEMENT"]')"
run_phases "$R_ORDER"
check order-preserved "$(printf '%s' "$OUT" | tr '\n' ' ')" "DISCOVERY REVIEW IMPLEMENT" \
  "declared order is preserved, not sorted"

# --- DELEGATE is undeclared, and that is the correct answer -----------------
#
# One bounded worker outside the pipeline is not a phase of it. Reporting it as
# undeclared is what lets a reader tell a delegation from a pipeline run.

check delegate-undeclared "$(check_phase "$R_DEF" DELEGATE)" "3" \
  "DELEGATE reads as undeclared against the default pipeline"

# --- a repo config outranks the vendored default ----------------------------

R_CLAUDE="$(new_repo dot-claude)"
mkdir -p "$R_CLAUDE/.claude"
printf '[pipeline]\nphases = ["IMPLEMENT"]\n' > "$R_CLAUDE/.claude/agy.toml"
printf '[pipeline]\nphases = ["DISCOVERY", "IMPLEMENT"]\n' > "$R_CLAUDE/agy.toml"
run_phases "$R_CLAUDE"
check claude-config-wins "$(printf '%s' "$OUT" | tr '\n' ' ')" "IMPLEMENT" \
  ".claude/agy.toml is read before the project root, as resolve-model.sh does"

# --- a config with no [pipeline] section still resolves ---------------------
#
# Every agy.toml written before this feature existed is this case. It must keep
# working, and it must not report an empty pipeline.

R_NOSEC="$(new_repo no-pipeline-section '[tiers]
low = "gemini-3.7-flash-low"')"
run_phases "$R_NOSEC"
check nosection-rc "$CODE" 0 "a config with no [pipeline] section is not an error"
check nosection-list "$(printf '%s' "$OUT" | tr '\n' ' ')" "DISCOVERY IMPLEMENT REVIEW QA RELEASE" \
  "an older config falls back to the default rather than declaring nothing"

# --- the vendored config declares the five it documents ---------------------

run_phases "$HERE/.."
check vendored-list "$(printf '%s' "$OUT" | tr '\n' ' ')" "DISCOVERY IMPLEMENT REVIEW QA RELEASE" \
  "this repo's own agy.toml declares the five phases the README documents"

# --- argument handling ------------------------------------------------------

/bin/bash "$RESOLVE_PHASES" --bogus >/dev/null 2>&1; check bad-arg "$?" 2 "exit 2 on an unknown flag"
/bin/bash "$RESOLVE_PHASES" --dir "$ROOT/nope" >/dev/null 2>&1; check bad-dir "$?" 2 "exit 2 on a missing --dir"

# --- read-only --------------------------------------------------------------

BEFORE="$(find "$R_SHORT" -type f | sort)"
run_phases "$R_SHORT"
check_phase "$R_SHORT" REVIEW >/dev/null
AFTER="$(find "$R_SHORT" -type f | sort)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok read-only "resolving phases writes nothing"
else
  bad read-only "resolve-phases.sh wrote files"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
