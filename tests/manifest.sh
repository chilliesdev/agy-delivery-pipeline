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

# --- function duplication across sourcing pairs & test shadowing -----------

# Check A: Duplicated function definition across a sourcing pair under scripts/.
# Check B: A test file defining a function that also exists in the script it tests.
#
# Deliberate exemptions in `<file>:<function>` form, one per line with rationale.
FUNCTION_ALLOWLIST="
# <file>:<function>                               # rationale
# tests/manifest.sh:ok                            # test harness helper
"

get_defined_functions() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '/^[a-zA-Z_][a-zA-Z0-9_-]*[ \t]*\([ \t]*\)[ \t]*\{/ { sub(/[ \t]*\(.*/, ""); print }' "$f" 2>/dev/null | sort -u
}

is_fn_exempt() {
  local target_file="$1" target_fn="$2"
  local bn entry line
  bn="$(basename "$target_file")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      \#*|[[:space:]]*\#*) continue ;;
    esac
    entry="$(printf '%s' "$line" | awk '{print $1}')"
    case "$entry" in
      "$target_file:$target_fn" | "$bn:$target_fn" | "scripts/$bn:$target_fn" | "tests/$bn:$target_fn")
        return 0
        ;;
    esac
  done <<EOF
$FUNCTION_ALLOWLIST
EOF
  return 1
}

# --- Check A: no duplicated functions across sourcing pairs ----------------

SOURCED_DUPS=0
SOURCING_PAIRS_CHECKED=0
for S1 in "$ROOT"/scripts/*.sh; do
  [ -f "$S1" ] || continue
  S1_BN="$(basename "$S1")"
  S1_FUNCS="$(get_defined_functions "$S1")"
  [ -n "$S1_FUNCS" ] || continue

  for S2 in "$ROOT"/scripts/*.sh; do
    [ -f "$S2" ] || continue
    [ "$S1" != "$S2" ] || continue
    S2_BN="$(basename "$S2")"

    # Detect if S1 sources S2 (. "$HERE/<file>" or source)
    if grep -E -q '^[[:space:]]*(\.|source)[[:space:]]+.*(^|/|\$HERE/|["'"'"'])'"$S2_BN"'(["'"'"']|[[:space:]]|$)' "$S1" 2>/dev/null; then
      SOURCING_PAIRS_CHECKED=$((SOURCING_PAIRS_CHECKED + 1))
      S2_FUNCS="$(get_defined_functions "$S2")"
      [ -n "$S2_FUNCS" ] || continue

      while IFS= read -r FN; do
        [ -n "$FN" ] || continue
        if printf '%s\n' "$S2_FUNCS" | grep -Fqx "$FN"; then
          if is_fn_exempt "scripts/$S1_BN" "$FN" || is_fn_exempt "scripts/$S2_BN" "$FN"; then
            ok "sourced-dup-exempt-$S1_BN-$S2_BN-$FN" "$FN exempt in scripts/$S1_BN <-> scripts/$S2_BN"
          else
            bad "sourced-dup-$S1_BN-$S2_BN-$FN" "function '$FN' defined in both scripts/$S1_BN and sourced scripts/$S2_BN"
            SOURCED_DUPS=$((SOURCED_DUPS + 1))
          fi
        fi
      done <<EOF
$S1_FUNCS
EOF
    fi
  done
done
check no-duplicate-sourced-functions "$SOURCED_DUPS" "0" "no duplicate function definitions across sourcing pairs in scripts/"

# --- Check B: test file defining a function in the script it tests ----------

TEST_SHADOWS=0
TESTS_CHECKED=0
for T in "$ROOT"/tests/*.sh; do
  [ -f "$T" ] || continue
  T_BN="$(basename "$T")"
  S="$ROOT/scripts/$T_BN"
  [ -f "$S" ] || continue
  TESTS_CHECKED=$((TESTS_CHECKED + 1))

  T_FUNCS="$(get_defined_functions "$T")"
  S_FUNCS="$(get_defined_functions "$S")"
  [ -n "$T_FUNCS" ] && [ -n "$S_FUNCS" ] || continue

  while IFS= read -r FN; do
    [ -n "$FN" ] || continue
    if printf '%s\n' "$S_FUNCS" | grep -Fqx "$FN"; then
      if is_fn_exempt "tests/$T_BN" "$FN" || is_fn_exempt "scripts/$T_BN" "$FN"; then
        ok "test-shadow-exempt-$T_BN-$FN" "$FN exempt in tests/$T_BN <-> scripts/$T_BN"
      else
        bad "test-shadows-script-$T_BN-$FN" "function '$FN' defined in both tests/$T_BN and scripts/$T_BN"
        TEST_SHADOWS=$((TEST_SHADOWS + 1))
      fi
    fi
  done <<EOF
$T_FUNCS
EOF
done
check no-test-script-shadowing "$TEST_SHADOWS" "0" "no test file defines a function that exists in the script it tests"

# --- status table sync between scripts and skills ---------------------------

# Check A (Forward): Every status scripts/phase.sh can print appears in the
# status table of at least one skill file, and every status reachable through
# the single-dispatch path appears in skills/agy-delegate/SKILL.md.
#
# Check B (Backward): Every status named in a skill's table is one the script
# can actually emit.
#
# Deliberate exemptions in `<file>:<status>` or `<status>` form, one per line with rationale.
STATUS_ALLOWLIST="
# <file>:<status>                                 # rationale
# skills/agy-delegate/SKILL.md:DONE               # worker verdict passed through by phase.sh
# skills/agy-delegate/SKILL.md:BLOCKED            # worker verdict passed through by phase.sh
DONE                                              # worker verdict passed through by phase.sh
BLOCKED                                           # worker verdict passed through by phase.sh
"

get_script_statuses() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -n '/^[[:space:]]*#/d; s/.*STATUS:[[:space:]\\]*\([A-Z][A-Z0-9_]*\).*/\1/p; s/.*STATUS="\([A-Z][A-Z0-9_]*\).*/\1/p' "$f" 2>/dev/null | sort -u
}

get_all_emittable_statuses() {
  local dir="$1"
  local s
  for s in "$dir"/*.sh; do
    [ -f "$s" ] || continue
    get_script_statuses "$s"
  done | sort -u
}

get_skill_table_statuses() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -F'|' '
    !/^[[:space:]]*\|/ {
      in_status_table = 0
    }
    NF >= 3 {
      col = $2
      gsub(/[`[:space:]]/, "", col)
      if (tolower(col) == "status") {
        in_status_table = 1
        next
      }
      if (col ~ /^:?-+:?$/) {
        next
      }
      if (in_status_table) {
        sub(/^STATUS:/, "", col)
        if (match(col, /^[A-Z][A-Z0-9_]+/)) {
          val = substr(col, RSTART, RLENGTH)
          if (length(val) >= 2 && val != "STATUS" && val != "GITIGNORE" && val != "STEP") {
            print val
          }
        }
      }
    }
  ' "$f" 2>/dev/null | sort -u
}

is_status_exempt() {
  local target_file="$1" target_status="$2"
  local bn entry line
  bn="$(basename "$target_file")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      \#*|[[:space:]]*\#*) continue ;;
    esac
    entry="$(printf '%s' "$line" | awk '{print $1}')"
    case "$entry" in
      "$target_file:$target_status" | "$bn:$target_status" | "skills/$bn/$target_status" | "$target_status")
        return 0
        ;;
    esac
  done <<EOF
$STATUS_ALLOWLIST
EOF
  return 1
}

# --- Forward check: script statuses appear in skill tables -----------------

PHASE_SCRIPT="$ROOT/scripts/phase.sh"
PHASE_STATUSES="$(get_script_statuses "$PHASE_SCRIPT")"
DELEGATE_SKILL="skills/agy-delegate/SKILL.md"
PIPELINE_SKILL="skills/agy-pipeline/SKILL.md"
DELEGATE_STATUSES="$(get_skill_table_statuses "$ROOT/$DELEGATE_SKILL")"
PIPELINE_STATUSES="$(get_skill_table_statuses "$ROOT/$PIPELINE_SKILL")"
ALL_SKILL_STATUSES="$(printf '%s\n%s\n' "$DELEGATE_STATUSES" "$PIPELINE_STATUSES" | sort -u)"

FORWARD_MISSING=0
FORWARD_CHECKED=0
while IFS= read -r ST; do
  [ -n "$ST" ] || continue
  FORWARD_CHECKED=$((FORWARD_CHECKED + 1))
  if printf '%s\n' "$DELEGATE_STATUSES" | grep -Fqx "$ST" || is_status_exempt "$DELEGATE_SKILL" "$ST"; then
    ok "status-forward-delegate-$ST" "$ST appears in $DELEGATE_SKILL table or is exempt"
  elif printf '%s\n' "$ALL_SKILL_STATUSES" | grep -Fqx "$ST" || is_status_exempt "$PIPELINE_SKILL" "$ST"; then
    ok "status-forward-pipeline-$ST" "$ST appears in $PIPELINE_SKILL table or is exempt"
  else
    bad "status-forward-$ST" "status '$ST' emitted by phase.sh but missing from skill tables"
    FORWARD_MISSING=$((FORWARD_MISSING + 1))
  fi
done <<EOF
$PHASE_STATUSES
EOF

if [ "$FORWARD_CHECKED" -gt 0 ]; then
  ok phase-statuses-nonempty "found $FORWARD_CHECKED statuses in phase.sh"
else
  bad phase-statuses-nonempty "no statuses extracted from phase.sh"
fi
check phase-statuses-in-skills "$FORWARD_MISSING" "0" "all $FORWARD_CHECKED script statuses appear in skill tables"

# --- Backward check: skill table statuses are emittable by script ----------

ALL_EMITTABLE="$(get_all_emittable_statuses "$ROOT/scripts")"
EMITTABLE_COUNT="$(printf '%s\n' "$ALL_EMITTABLE" | grep -c . || true)"
if [ "${EMITTABLE_COUNT:-0}" -gt 0 ]; then
  ok emittable-statuses-nonempty "found $EMITTABLE_COUNT emittable statuses across scripts"
else
  bad emittable-statuses-nonempty "no emittable statuses extracted from scripts"
fi

BACKWARD_EXTRA=0
BACKWARD_CHECKED=0
for SK in "$DELEGATE_SKILL" "$PIPELINE_SKILL"; do
  [ -f "$ROOT/$SK" ] || continue
  SK_STATUSES="$(get_skill_table_statuses "$ROOT/$SK")"
  SK_COUNT="$(printf '%s\n' "$SK_STATUSES" | grep -c . || true)"
  SK_BN="$(basename "$SK" .md)"
  if [ "${SK_COUNT:-0}" -gt 0 ]; then
    ok "skill-statuses-nonempty-$SK_BN" "found $SK_COUNT statuses in $SK"
  else
    bad "skill-statuses-nonempty-$SK_BN" "no statuses extracted from $SK table"
  fi

  while IFS= read -r ST; do
    [ -n "$ST" ] || continue
    BACKWARD_CHECKED=$((BACKWARD_CHECKED + 1))
    if printf '%s\n' "$ALL_EMITTABLE" | grep -Fqx "$ST" || is_status_exempt "$SK" "$ST"; then
      ok "status-backward-$ST" "$ST in $SK is emittable by scripts or exempt"
    else
      bad "status-backward-$ST" "status '$ST' named in $SK table cannot be emitted by scripts"
      BACKWARD_EXTRA=$((BACKWARD_EXTRA + 1))
    fi
  done <<EOF
$SK_STATUSES
EOF
done
check skill-statuses-emittable "$BACKWARD_EXTRA" "0" "all $BACKWARD_CHECKED skill table statuses are emittable by script"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1


