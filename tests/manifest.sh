#!/usr/bin/env bash
# Check the plugin's own wiring: the two manifests parse, the paths they and the
# command files name exist, and every skill has the frontmatter Claude Code needs
# to load it.
#
#   tests/manifest.sh
#
# Read-only — this suite inspects the repo and writes nothing anywhere.
#
# Worth a suite of its own because none of it fails loudly. A plugin.json with a
# trailing comma, a command citing a script that moved, a skill whose `name` no
# longer matches its directory: each is silent until an install does nothing and
# nobody can say why.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }
exists() { [ -e "$ROOT/$1" ] && echo yes || echo no; }

json_get() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$1" "$2" 2>/dev/null; }

# --- the manifests ----------------------------------------------------------

for M in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  check "present-$(basename "$M")" "$(exists "$M")" "yes" "$M is in the repo"
  if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$ROOT/$M" 2>/dev/null; then
    ok "parses-$(basename "$M")" "$M is valid JSON"
  else
    bad "parses-$(basename "$M")" "$M does not parse"
  fi
done

check plugin-name "$(json_get "$ROOT/.claude-plugin/plugin.json" "d['name']")" "agy" \
  "plugin.json declares the name the commands are namespaced under"

# The two version fields are written by hand in two files and will drift the
# first time one is bumped alone.
check version-agrees \
  "$(json_get "$ROOT/.claude-plugin/plugin.json" "d['version']")" \
  "$(json_get "$ROOT/.claude-plugin/marketplace.json" "d['plugins'][0]['version']")" \
  "plugin.json and marketplace.json agree on the version"

check marketplace-name \
  "$(json_get "$ROOT/.claude-plugin/marketplace.json" "d['plugins'][0]['name']")" \
  "agy" "the marketplace entry names the same plugin"

SRC="$(json_get "$ROOT/.claude-plugin/marketplace.json" "d['plugins'][0]['source']")"
check marketplace-source "$(exists "$SRC")" "yes" \
  "the marketplace source path ('$SRC') exists"

# --- skills -----------------------------------------------------------------

for S in agy-pipeline agy-delegate; do
  F="skills/$S/SKILL.md"
  check "skill-present-$S" "$(exists "$F")" "yes" "$F exists"
  NAME="$(sed -n 's/^name: *//p' "$ROOT/$F" 2>/dev/null | head -1)"
  check "skill-name-$S" "$NAME" "$S" "its frontmatter name matches its directory"
  DESC="$(sed -n 's/^description: *//p' "$ROOT/$F" 2>/dev/null | head -1)"
  if [ -n "$DESC" ]; then ok "skill-desc-$S" "it has a description"
  else bad "skill-desc-$S" "no description — it can never be selected"; fi
  # Frontmatter must be the first thing in the file or it is body text.
  check "skill-fm-$S" "$(sed -n '1p' "$ROOT/$F" 2>/dev/null)" "---" \
    "the frontmatter opens on line 1"
done

# Only the ambient one should read as ambient. agy-pipeline is invoked by
# /agy:pipeline, and a description that still advertises itself competes with
# agy-delegate over the same requests.
if grep -q 'does not trigger on its own' "$ROOT/skills/agy-pipeline/SKILL.md"; then
  ok pipeline-not-ambient "agy-pipeline's description says it is command-invoked"
else
  bad pipeline-not-ambient "agy-pipeline still reads as ambient"
fi

# The QA phase section of agy-pipeline must name --check-git-state.
QA_SECTION="$(sed -n '/^### Phase 3/,/^### Phase 4/p' "$ROOT/skills/agy-pipeline/SKILL.md" 2>/dev/null)"
if printf '%s\n' "$QA_SECTION" | grep -q -- '--check-git-state'; then
  ok pipeline-qa-git-state "QA phase guidance names --check-git-state"
else
  bad pipeline-qa-git-state "QA phase guidance does not name --check-git-state"
fi

# --- commands ---------------------------------------------------------------

for C in pipeline delegate preflight phase; do
  F="commands/$C.md"
  check "cmd-present-$C" "$(exists "$F")" "yes" "$F exists"
  DESC="$(sed -n 's/^description: *//p' "$ROOT/$F" 2>/dev/null | head -1)"
  if [ -n "$DESC" ]; then ok "cmd-desc-$C" "/agy:$C has a description"
  else bad "cmd-desc-$C" "no description"; fi
done

# --- every script anything points at ----------------------------------------

# Pull ${CLAUDE_PLUGIN_ROOT}/scripts/... out of the commands and both skills and
# confirm each one is really there and executable. This is the check that would
# have caught the move of SKILL.md out of the repo root.
MISSING=0; CHECKED=0
while IFS= read -r REF; do
  CHECKED=$((CHECKED + 1))
  [ -x "$ROOT/$REF" ] || { bad "script-$REF" "referenced but not executable"; MISSING=$((MISSING + 1)); }
done <<EOF
$(grep -rhoE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/[a-z-]+\.sh' "$ROOT/commands" "$ROOT/skills" 2>/dev/null \
   | sed 's#^\${CLAUDE_PLUGIN_ROOT}/##' | sort -u)
EOF
check scripts-resolve "$MISSING" "0" "all $CHECKED referenced scripts exist and are executable"

# Nothing may still point at a bare scripts/… path: that resolved when SKILL.md
# sat at the repo root and resolves nowhere now.
STALE="$(grep -rnE '(^|[^/{])scripts/[a-z-]+\.sh' "$ROOT/commands" "$ROOT/skills" 2>/dev/null \
  | grep -v 'CLAUDE_PLUGIN_ROOT' | grep -v '\.\./\.\./scripts/' | grep -c .)"
check no-stale-paths "${STALE:-0}" "0" "no bare scripts/ paths left over from the pre-plugin layout"

# --- every script has a test suite ------------------------------------------

# Every script in scripts/ must have a corresponding test suite named
# tests/<script-name>, unless explicitly listed here with rationale.
#
# Intentional exceptions:
#   agy-run.sh   - thin shim over drivers/agy.sh (tested via tests/driver.sh)
#   phase.sh     - split across tests/phase-{dispatch,exclude,status,verify}.sh
#   run-tests.sh - test runner itself
#   watch-run.sh - tested via tests/progress.sh
SCRIPT_SUITE_EXCEPTIONS=" agy-run.sh phase.sh run-tests.sh watch-run.sh "

MISSING_SUITES=0
SCRIPTS_CHECKED=0
for S in "$ROOT"/scripts/*.sh; do
  [ -f "$S" ] || continue
  SCRIPTS_CHECKED=$((SCRIPTS_CHECKED + 1))
  BN="$(basename "$S")"
  if [ -f "$ROOT/tests/$BN" ]; then
    ok "suite-present-$BN" "tests/$BN exists"
  elif case "$SCRIPT_SUITE_EXCEPTIONS" in *" $BN "*) true ;; *) false ;; esac; then
    ok "suite-exempt-$BN" "tests/$BN explicitly exempted"
  else
    bad "suite-present-$BN" "tests/$BN does not exist"
    MISSING_SUITES=$((MISSING_SUITES + 1))
  fi
done
check scripts-have-suites "$MISSING_SUITES" "0" "all $SCRIPTS_CHECKED scripts have suites or explicit exemptions"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
