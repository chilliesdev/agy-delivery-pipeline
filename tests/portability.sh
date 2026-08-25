#!/usr/bin/env bash
# Assert scripts and tests contain no bash 4+ constructs and no GNU-only flags.
#
#   tests/portability.sh
#
# Scans scripts/*.sh and tests/*.sh for non-portable syntax:
#   - bash 4+: mapfile, readarray, declare -A, ${var^^}/${var,,}, declare -n, &>>
#   - GNU-only: sed -i, grep -P, date -d, readlink -f
#
# Read-only against this repository; synthetic fixtures use ${TMPDIR:-/tmp}.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/portability.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

# Disallowed constructs declared as data: name <TAB> regex pattern <TAB> message
RULES=(
  "mapfile"$'\t'"(^|[^a-zA-Z0-9_])mapfile([^a-zA-Z0-9_]|$)"$'\t'"mapfile (bash 4+)"
  "readarray"$'\t'"(^|[^a-zA-Z0-9_])readarray([^a-zA-Z0-9_]|$)"$'\t'"readarray (bash 4+)"
  "declare_A"$'\t'"(^|[^a-zA-Z0-9_])declare[[:space:]]+-[a-zA-Z]*A"$'\t'"declare -A (bash 4+)"
  "var_upper"$'\t''\$\{[a-zA-Z0-9_]+(\^\^?|,,?)[^}]*\}'$'\t'"\${var^^}/\${var,,} (bash 4+)"
  "declare_n"$'\t'"(^|[^a-zA-Z0-9_])declare[[:space:]]+-[a-zA-Z]*n"$'\t'"declare -n (bash 4.3+)"
  "ampersand_append"$'\t'"&>>"$'\t'"&>> (bash 4+)"
  "sed_i"$'\t'"(^|[^a-zA-Z0-9_])sed[[:space:]]+-[a-zA-Z]*i"$'\t'"sed -i (non-portable)"
  "grep_P"$'\t'"(^|[^a-zA-Z0-9_])grep[[:space:]]+-[a-zA-Z]*P"$'\t'"grep -P (GNU only)"
  "date_d"$'\t'"(^|[^a-zA-Z0-9_])date[[:space:]]+-[a-zA-Z]*d"$'\t'"date -d (GNU only)"
  "readlink_f"$'\t'"(^|[^a-zA-Z0-9_])readlink[[:space:]]+-[a-zA-Z]*f"$'\t'"readlink -f (GNU only)"
)

# Scan a single file for non-portable constructs on non-comment lines.
# Prints one line per violation found.
scan_file() {
  local target="$1"
  local violations=""
  local lnum=0
  local line=""
  local entry=""
  local rest=""
  local rname=""
  local rpat=""
  local rmsg=""

  while IFS= read -r line || [ -n "$line" ]; do
    lnum=$((lnum + 1))

    # Skip whole-line comments
    case "$line" in
      [[:space:]]*\#*|'#'*)
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
          \#*) continue ;;
        esac
        ;;
    esac

    for entry in "${RULES[@]+"${RULES[@]}"}"; do
      rname="${entry%%$'\t'*}"
      rest="${entry#*$'\t'}"
      rpat="${rest%%$'\t'*}"
      rmsg="${rest#*$'\t'}"

      if printf '%s\n' "$line" | grep -q -E "$rpat"; then
        violations="${violations}${target}:${lnum}: ${rmsg}"$'\n'
      fi
    done
  done < "$target"

  printf '%s' "$violations"
}

# --- Synthetic fixture checks: verify scanner detects every prohibited form ---

test_violation() {
  local name="$1"
  local content="$2"
  local expected="$3"
  local fix_file="$SCRATCH/fixture-$name.sh"

  printf '%s\n' "$content" > "$fix_file"
  local out
  out="$(scan_file "$fix_file")"
  case "$out" in
    *"$expected"*)
      ok "detect-$name" "scanner caught $expected"
      ;;
    *)
      bad "detect-$name" "scanner missed $expected (output: '$out')"
      ;;
  esac
}

# Table-driven fixture cases for every disallowed construct
FIXTURES=(
  "mapfile|mapfile lines < input.txt|mapfile (bash 4+)"
  "readarray|readarray arr < input.txt|readarray (bash 4+)"
  "declare-A|declare -A lookup_table|declare -A (bash 4+)"
  "upper-expansion|NAME=\"\${VAL^^}\"|\${var^^}/\${var,,} (bash 4+)"
  "lower-expansion|NAME=\"\${VAL,,}\"|\${var^^}/\${var,,} (bash 4+)"
  "declare-n|declare -n ref=target_var|declare -n (bash 4.3+)"
  "ampersand-append|do_work &>> build.log|&>> (bash 4+)"
  "sed-i|sed -i 's/foo/bar/g' config.txt|sed -i (non-portable)"
  "grep-P|grep -P '^[0-9]+' manifest.txt|grep -P (GNU only)"
  "date-d|EXPIRY=\$(date -d \"+7 days\")|date -d (GNU only)"
  "date-d-at|date -d '@0'|date -d (GNU only)"
  "date-d-yesterday|date -d yesterday|date -d (GNU only)"
  "readlink-f|REAL=\$(readlink -f \"\$PATH_VAR\")|readlink -f (GNU only)"
  "readlink-f-bare|readlink -f \$x|readlink -f (GNU only)"
  "readlink-f-quoted|readlink -f \"\$x\"|readlink -f (GNU only)"
)

COVERED_RULES=""
for entry in "${FIXTURES[@]+"${FIXTURES[@]}"}"; do
  fix_name="${entry%%|*}"
  rest="${entry#*|}"
  fix_content="${rest%%|*}"
  fix_expected="${rest#*|}"
  test_violation "$fix_name" "$fix_content" "$fix_expected"
  COVERED_RULES="${COVERED_RULES}${fix_expected}"$'\n'
done

# Structural check: verify every rule in RULES has at least one test fixture
UNCOVERED=0
for entry in "${RULES[@]+"${RULES[@]}"}"; do
  rname="${entry%%$'\t'*}"
  rest="${entry#*$'\t'}"
  rmsg="${rest#*$'\t'}"
  case "$COVERED_RULES" in
    *"$rmsg"*) ;;
    *)
      bad "rule-coverage-${rname}" "scanner rule '$rname' has no test fixture"
      UNCOVERED=$((UNCOVERED + 1))
      ;;
  esac
done

if [ "$UNCOVERED" -eq 0 ]; then
  ok "rule-coverage" "all scanner rules have corresponding test fixtures"
fi

# Verify clean script produces no violations
CLEAN_FILE="$SCRATCH/clean.sh"
cat > "$CLEAN_FILE" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
START=$(date +%s)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
grep -E '^[0-9]+' "$DIR/file" | sed 's/foo/bar/'
EOF
CLEAN_OUT="$(scan_file "$CLEAN_FILE")"
check clean-fixture "$CLEAN_OUT" "" "clean script has zero violations"

# --- Repository scan: check all scripts/*.sh, tests/*.sh, and drivers/*.sh ---

REPO_VIOLATIONS=""
TOTAL_FILES=0

for SCRIPT in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/drivers/*.sh; do
  [ -f "$SCRIPT" ] || continue
  # Skip tests/portability.sh in the repository-wide scan: a scanner that contains
  # the patterns it searches for will always match itself, and the alternative —
  # obfuscating the patterns so they do not match — makes the rules unreadable,
  # which is worse for a check whose whole value is that a contributor can see
  # what is disallowed.
  [ "$SCRIPT" = "$ROOT/tests/portability.sh" ] && continue

  REL_NAME="${SCRIPT#$ROOT/}"
  V="$(scan_file "$SCRIPT")"
  TOTAL_FILES=$((TOTAL_FILES + 1))
  if [ -n "$V" ]; then
    REPO_VIOLATIONS="${REPO_VIOLATIONS}${V}"
    V_LINES="$(printf '%s' "$V" | tr '\n' '; ' | sed 's/; $//')"
    bad "portable-$REL_NAME" "violations in $REL_NAME: $V_LINES"
  else
    ok "portable-$REL_NAME" "$REL_NAME is bash 3.2 / macOS / Linux portable"
  fi
done

if [ -n "$REPO_VIOLATIONS" ]; then
  printf '\nViolations in repository:\n%s\n' "$REPO_VIOLATIONS"
  V_SUMMARY="$(printf '%s' "$REPO_VIOLATIONS" | tr '\n' '; ' | sed 's/; $//')"
  bad repo-clean "found violations in repository: $V_SUMMARY"
else
  ok repo-clean "all $TOTAL_FILES scripts/tests are free of non-portable constructs"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
