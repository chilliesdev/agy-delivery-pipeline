#!/usr/bin/env bash
# Exercise resolve-model.sh, agy.toml configuration parsing, and preflight fallback chain walking.
#
#   tests/resolve-model.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$HERE/../scripts/resolve-model.sh"
PREFLIGHT="$HERE/../scripts/preflight.sh"
PHASE_SH="$HERE/../scripts/phase.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
VENDORED_CONFIG="$HERE/../agy.toml"
VENDORED_ABS="$(cd "$(dirname "$VENDORED_CONFIG")" && pwd)/$(basename "$VENDORED_CONFIG")"

[ -f "$RESOLVE" ] || { echo "resolve-model-test: resolve-model.sh not found next door" >&2; exit 2; }
[ -f "$PREFLIGHT" ] || { echo "resolve-model-test: preflight.sh not found next door" >&2; exit 2; }
[ -f "$PHASE_SH" ] || { echo "resolve-model-test: phase.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "resolve-model-test: run-dir.sh not found next door" >&2; exit 2; }
[ -f "$VENDORED_CONFIG" ] || { echo "resolve-model-test: agy.toml not found at repo root" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/resolve-model.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

export AGY_FLEET="$ROOT/fleet"

# Stub agy CLI for preflight & phase tests
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  [ -n "${STUB_MODELS:-}" ] && printf '%b' "$STUB_MODELS"
  exit "${STUB_RC:-0}"
fi
if [ -f .agy/current ]; then
  CUR_RUN="$(cat .agy/current 2>/dev/null || true)"
  if [ -n "$CUR_RUN" ]; then
    mkdir -p ".agy/runs/$CUR_RUN/phases/$STUB_PHASE"
    printf '%s\n' "${STUB_VERDICT:-STATUS: DONE | File: CHANGES.md}" > ".agy/runs/$CUR_RUN/phases/$STUB_PHASE/verdict"
  fi
fi
printf '%s\n' "${STUB_VERDICT:-STATUS: DONE | File: CHANGES.md}"
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() {
  local r="$ROOT/repos/$1"; mkdir -p "$r"
  ( cd "$r" && git init -q . )
  printf 'do the thing\n' > "$r/brief.md"
  printf '%s' "$r"
}

# --- 1. Vendored default resolution ---------------------------------------

R1="$(new_repo vendored-defaults)"

# low tier
OUT1="$(/bin/bash "$RESOLVE" --tier low --dir "$R1" 2>/dev/null)"; RC1=$?
check vendored-low-rc "$RC1" 0 "exit 0 resolving low tier"
check vendored-low-model "$OUT1" "gemini-3.7-flash-low" "low tier resolves to gemini-3.7-flash-low"

# medium tier
OUT1_M="$(/bin/bash "$RESOLVE" --tier medium --dir "$R1" 2>/dev/null)"; RC1_M=$?
check vendored-medium-rc "$RC1_M" 0 "exit 0 resolving medium tier"
check vendored-medium-model "$OUT1_M" "gemini-3.7-flash-medium" "medium tier resolves to gemini-3.7-flash-medium"

# high tier
OUT1_H="$(/bin/bash "$RESOLVE" --tier high --dir "$R1" 2>/dev/null)"; RC1_H=$?
check vendored-high-rc "$RC1_H" 0 "exit 0 resolving high tier"
check vendored-high-model "$OUT1_H" "gemini-3.7-flash-high" "high tier resolves to gemini-3.7-flash-high"

# per-phase REVIEW -> high
OUT1_REV="$(/bin/bash "$RESOLVE" --phase REVIEW --dir "$R1" 2>/dev/null)"; RC1_REV=$?
check vendored-review-rc "$RC1_REV" 0 "exit 0 resolving REVIEW phase"
check vendored-review-model "$OUT1_REV" "gemini-3.7-flash-high" "REVIEW phase resolves to gemini-3.7-flash-high"

# per-phase DISCOVERY -> low
OUT1_DISC="$(/bin/bash "$RESOLVE" --phase DISCOVERY --dir "$R1" 2>/dev/null)"; RC1_DISC=$?
check vendored-disc-rc "$RC1_DISC" 0 "exit 0 resolving DISCOVERY phase"
check vendored-disc-model "$OUT1_DISC" "gemini-3.7-flash-low" "DISCOVERY phase resolves to gemini-3.7-flash-low"

# Stderr reporting: stdout has only model id, stderr reports decision and config file
STDERR1="$(/bin/bash "$RESOLVE" --tier high --dir "$R1" 2>&1 >/dev/null)"
case "$STDERR1" in
  *"agy.toml"*"[tiers].high"*) ok vendored-stderr-entry "stderr names config file and [tiers].high entry" ;;
  *) bad vendored-stderr-entry "stderr did not name config and entry: $STDERR1" ;;
esac

# --- 2. Project .claude/agy.toml override ----------------------------------

R2="$(new_repo project-claude-override)"
mkdir -p "$R2/.claude"
cat > "$R2/.claude/agy.toml" <<'EOF'
[tiers]
high = "claude-opus-4-6-thinking"
EOF

OUT2="$(/bin/bash "$RESOLVE" --tier high --dir "$R2" 2>/dev/null)"; RC2=$?
check project-override-rc "$RC2" 0 "exit 0 on project override"
check project-override-model "$OUT2" "claude-opus-4-6-thinking" "project .claude/agy.toml overrides high tier"

STDERR2="$(/bin/bash "$RESOLVE" --tier high --dir "$R2" 2>&1 >/dev/null)"
case "$STDERR2" in
  *".claude/agy.toml"*) ok project-override-stderr "stderr reports project .claude/agy.toml won" ;;
  *) bad project-override-stderr "stderr did not name .claude/agy.toml: $STDERR2" ;;
esac

# Low tier in same project still resolves from vendored default
OUT2_LOW="$(/bin/bash "$RESOLVE" --tier low --dir "$R2" 2>/dev/null)"
check project-unspecified-tier "$OUT2_LOW" "gemini-3.7-flash-low" "unspecified tier still resolves default"

# --- 3. Per-phase tier overriding global/vendored --------------------------

R3="$(new_repo phase-override)"
mkdir -p "$R3/.claude"
cat > "$R3/.claude/agy.toml" <<'EOF'
[phases.REVIEW]
tier = "medium"

[tiers]
low    = "gemini-3.7-flash-low"
medium = "gemini-3.7-flash-medium"
high   = "gemini-3.7-flash-high"
EOF

OUT3="$(/bin/bash "$RESOLVE" --phase REVIEW --dir "$R3" 2>/dev/null)"; RC3=$?
check phase-override-rc "$RC3" 0 "exit 0 on per-phase tier override"
check phase-override-model "$OUT3" "gemini-3.7-flash-medium" "REVIEW phase resolves to configured medium tier"

STDERR3="$(/bin/bash "$RESOLVE" --phase REVIEW --dir "$R3" 2>&1 >/dev/null)"
case "$STDERR3" in
  *"[phases.REVIEW].tier"*) ok phase-override-stderr "stderr reports [phases.REVIEW].tier decided resolution" ;;
  *) bad phase-override-stderr "stderr missing phase tier mention: $STDERR3" ;;
esac

# --- 4. Raw model ID passed to --tier wins over all config -----------------

R4="$(new_repo raw-id-wins)"
OUT4="$(/bin/bash "$RESOLVE" --tier claude-opus-4-6-thinking --phase REVIEW --dir "$R4" 2>/dev/null)"; RC4=$?
check raw-id-rc "$RC4" 0 "exit 0 on raw model id"
check raw-id-model "$OUT4" "claude-opus-4-6-thinking" "raw model id wins over phase config"

STDERR4="$(/bin/bash "$RESOLVE" --tier custom-experimental-model --dir "$R4" 2>&1 >/dev/null)"
case "$STDERR4" in
  *"raw model id"*) ok raw-id-stderr "stderr notes raw model id passed via --tier" ;;
  *) bad raw-id-stderr "stderr missing raw id note: $STDERR4" ;;
esac

# --- 5. Unknown tier refused ----------------------------------------------

R5="$(new_repo unknown-tier)"
/bin/bash "$RESOLVE" --tier bogus --dir "$R5" >/dev/null 2>&1 || RC5=$?
check unknown-tier-rc "$RC5" 2 "exit 2 on unknown tier name"

STDERR5="$(/bin/bash "$RESOLVE" --tier bogus --dir "$R5" 2>&1 >/dev/null)"
case "$STDERR5" in
  *"unknown tier 'bogus'"*) ok unknown-tier-stderr "stderr clearly reports unknown tier 'bogus'" ;;
  *) bad unknown-tier-stderr "stderr missing unknown tier message: $STDERR5" ;;
esac

mkdir -p "$R5/.claude"
cat > "$R5/.claude/agy.toml" <<'EOF'
[phases.REVIEW]
tier = "unregistered"
EOF
/bin/bash "$RESOLVE" --phase REVIEW --dir "$R5" >/dev/null 2>&1 || RC5_PHASE=$?
check unknown-phase-tier-rc "$RC5_PHASE" 2 "exit 2 on unknown tier configured for phase"

# --- 6. Malformed config refused with clear message ------------------------

R6="$(new_repo malformed-config)"

# 6a. Trailing comment after value
cat > "$R6/agy.toml" <<'EOF'
[tiers]
high = "gemini-3.7-flash-high" # inline comment not allowed
EOF
OUT6_A="$(/bin/bash "$RESOLVE" --dir "$R6" --tier high 2>&1)"; RC6_A=$?
check malformed-inline-comment-rc "$RC6_A" 2 "exit 2 on inline comment after value"
case "$OUT6_A" in
  *"malformed config"*) ok malformed-inline-comment-msg "stderr identifies malformed config line" ;;
  *) bad malformed-inline-comment-msg "missing malformed message: $OUT6_A" ;;
esac

# 6b. Nested table beyond one level
cat > "$R6/agy.toml" <<'EOF'
[phases.REVIEW.sub]
tier = "high"
EOF
OUT6_B="$(/bin/bash "$RESOLVE" --dir "$R6" --tier high 2>&1)"; RC6_B=$?
check malformed-nested-table-rc "$RC6_B" 2 "exit 2 on nested table beyond one level"
case "$OUT6_B" in
  *"nested tables beyond one level"*) ok malformed-nested-table-msg "stderr identifies nested table restriction" ;;
  *) bad malformed-nested-table-msg "missing nested table message: $OUT6_B" ;;
esac

# 6c. Multi-line array
cat > "$R6/agy.toml" <<'EOF'
[phases.REVIEW]
fallbacks = [
  "gemini-3.7-flash-high",
  "gemini-3.7-flash-medium"
]
EOF
OUT6_C="$(/bin/bash "$RESOLVE" --dir "$R6" --phase REVIEW 2>&1)"; RC6_C=$?
check malformed-multiline-arr-rc "$RC6_C" 2 "exit 2 on multi-line array"
case "$OUT6_C" in
  *"multi-line array"*|*"malformed"*) ok malformed-multiline-arr-msg "stderr identifies multi-line array error" ;;
  *) bad malformed-multiline-arr-msg "missing array error message: $OUT6_C" ;;
esac

# 6d. Unsupported value type (boolean)
cat > "$R6/agy.toml" <<'EOF'
[tiers]
high = true
EOF
/bin/bash "$RESOLVE" --dir "$R6" --tier high >/dev/null 2>&1 || RC6_D=$?
check malformed-unsupported-type-rc "$RC6_D" 2 "exit 2 on unsupported value type"

# 6e. Key defined outside section
cat > "$R6/agy.toml" <<'EOF'
tier = "high"
[tiers]
high = "gemini-3.7-flash-high"
EOF
/bin/bash "$RESOLVE" --dir "$R6" --tier high >/dev/null 2>&1 || RC6_E=$?
check malformed-outside-section-rc "$RC6_E" 2 "exit 2 on key outside section"

# --- 7. Fallback chain walked when first entry unavailable -----------------

R7="$(new_repo fallback-chain)"
mkdir -p "$R7/.claude"
cat > "$R7/.claude/agy.toml" <<'EOF'
[phases.REVIEW]
tier      = "high"
fallbacks = ["gemini-3.7-flash-high", "gemini-3.7-flash-medium"]

[tiers]
low    = "gemini-3.7-flash-low"
medium = "gemini-3.7-flash-medium"
high   = "gemini-3.7-flash-high"
EOF

# Listing missing gemini-3.7-flash-high, but offering gemini-3.7-flash-medium and low
FALLBACK_LISTING='gemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-low\tGemini 3.7 Flash (Low)\n'

# Preflight walks the chain and succeeds with medium
PREFLIGHT_OUT="$(STUB_MODELS="$FALLBACK_LISTING" STUB_RC=0 AGY_BIN="$STUB" \
  /bin/bash "$PREFLIGHT" --phase REVIEW --dir "$R7" 2>&1)"; PREFLIGHT_RC=$?
check preflight-fallback-rc "$PREFLIGHT_RC" 0 "preflight exits 0 when fallback model is available"
case "$PREFLIGHT_OUT" in
  *"fell back to gemini-3.7-flash-medium"*)
    ok preflight-fallback-msg "preflight reports fallback to gemini-3.7-flash-medium" ;;
  *) bad preflight-fallback-msg "preflight missing fallback report: $PREFLIGHT_OUT" ;;
esac

# Preflight fails with exit 4 when all fallbacks are unavailable
STUB_MODELS='other-model\tOther\n' STUB_RC=0 AGY_BIN="$STUB" \
  /bin/bash "$PREFLIGHT" --phase REVIEW --dir "$R7" >/dev/null 2>&1 || PREFLIGHT_FAIL_RC=$?
check preflight-all-unavailable-rc "$PREFLIGHT_FAIL_RC" 4 "preflight exits 4 when primary and all fallbacks unavailable"

# phase.sh dispatch walks fallback chain and reports fallback on STATUS line
PHASE_OUT="$(STUB_MODELS="$FALLBACK_LISTING" STUB_RC=0 STUB_PHASE=REVIEW AGY_BIN="$STUB" \
  /bin/bash "$PHASE_SH" --phase REVIEW --brief "$R7/brief.md" --dir "$R7" --no-brief-lint 2>/dev/null)"; PHASE_RC=$?
check phase-fallback-rc "$PHASE_RC" 0 "phase.sh exits 0 when fallback succeeds"
case "$PHASE_OUT" in
  *"| Fallback: gemini-3.7-flash-medium"*)
    ok phase-fallback-status-line "STATUS line carries '| Fallback: gemini-3.7-flash-medium'" ;;
  *) bad phase-fallback-status-line "STATUS line missing Fallback field: $PHASE_OUT" ;;
esac

# Verify ledger record reflects the fallback model
LEDGER7="$R7/.agy/ledger.jsonl"
[ -f "$LEDGER7" ] && ok phase-fallback-ledger-exists "ledger record exists" \
                  || bad phase-fallback-ledger-exists "ledger record missing"
LINE7="$(tail -1 "$LEDGER7" 2>/dev/null)"
if printf '%s\n' "$LINE7" | grep -q '"model":"gemini-3.7-flash-medium"'; then
  ok phase-fallback-ledger-model "ledger record has model=gemini-3.7-flash-medium"
else
  bad phase-fallback-ledger-model "ledger record missing fallback model: $LINE7"
fi

# --- 8. Behaviour identical to today's when no config exists anywhere -----

R8="$(new_repo no-config-anywhere)"

# Direct call to resolve_model with empty dir and simulated absent vendored config
# Built-in defaults match hardcoded strings
OUT8_L="$(/bin/bash "$RESOLVE" --tier low --dir "$R8" 2>/dev/null)"
check no-config-low "$OUT8_L" "gemini-3.7-flash-low" "low resolves to gemini-3.7-flash-low without custom config"

OUT8_M="$(/bin/bash "$RESOLVE" --tier medium --dir "$R8" 2>/dev/null)"
check no-config-medium "$OUT8_M" "gemini-3.7-flash-medium" "medium resolves to gemini-3.7-flash-medium without custom config"

OUT8_H="$(/bin/bash "$RESOLVE" --tier high --dir "$R8" 2>/dev/null)"
check no-config-high "$OUT8_H" "gemini-3.7-flash-high" "high resolves to gemini-3.7-flash-high without custom config"

OUT8_RAW="$(/bin/bash "$RESOLVE" --tier claude-opus-4-6-thinking --dir "$R8" 2>/dev/null)"
check no-config-raw "$OUT8_RAW" "claude-opus-4-6-thinking" "raw model id resolves without custom config"

# --- 9. --explain declared vs undeclared/inherited tier -------------------

R9="$(new_repo explain-declared-vs-inherited)"

# 9a. Declared phase REVIEW: declared=true, tier=high, source is agy.toml
OUT9_REV="$(/bin/bash "$RESOLVE" --explain --phase REVIEW --dir "$R9")"; RC9_REV=$?
check explain-review-rc "$RC9_REV" 0 "--explain REVIEW exits 0"
check explain-review-tsv "$OUT9_REV" "REVIEW	high	gemini-3.7-flash-high	true	$VENDORED_ABS	$VENDORED_ABS" "REVIEW row matches declared format"

# 9b. Declared phase DISCOVERY: declared=true, tier=low, source is agy.toml
OUT9_DISC="$(/bin/bash "$RESOLVE" --explain --phase DISCOVERY --dir "$R9")"; RC9_DISC=$?
check explain-disc-rc "$RC9_DISC" 0 "--explain DISCOVERY exits 0"
check explain-disc-tsv "$OUT9_DISC" "DISCOVERY	low	gemini-3.7-flash-low	true	$VENDORED_ABS	$VENDORED_ABS" "DISCOVERY row matches declared format"

# 9c. Undeclared phase IMPLEMENT: declared=false, tier=medium, tier_source=builtin, model_source=agy.toml
OUT9_IMP="$(/bin/bash "$RESOLVE" --explain --phase IMPLEMENT --dir "$R9")"; RC9_IMP=$?
check explain-imp-rc "$RC9_IMP" 0 "--explain IMPLEMENT exits 0"
check explain-imp-tsv "$OUT9_IMP" "IMPLEMENT	medium	gemini-3.7-flash-medium	false	builtin	$VENDORED_ABS" "IMPLEMENT row reflects inherited built-in tier"

# 9d. Undeclared phase QA: declared=false, tier=medium, tier_source=builtin
OUT9_QA="$(/bin/bash "$RESOLVE" --explain --phase QA --dir "$R9")"; RC9_QA=$?
check explain-qa-rc "$RC9_QA" 0 "--explain QA exits 0"
check explain-qa-tsv "$OUT9_QA" "QA	medium	gemini-3.7-flash-medium	false	builtin	$VENDORED_ABS" "QA row reflects inherited built-in tier"

# 9e. Delegation phase DELEGATE: declared=false, tier=medium, tier_source=builtin
OUT9_DEL="$(/bin/bash "$RESOLVE" --explain --phase DELEGATE --dir "$R9")"; RC9_DEL=$?
check explain-del-rc "$RC9_DEL" 0 "--explain DELEGATE exits 0"
check explain-del-tsv "$OUT9_DEL" "DELEGATE	medium	gemini-3.7-flash-medium	false	builtin	$VENDORED_ABS" "DELEGATE row reflects medium default"

# 9f. Field count & stderr suppression on success
FIELD_COUNT9="$(printf '%s\n' "$OUT9_REV" | awk -F'\t' '{print NF}')"
check explain-field-count "$FIELD_COUNT9" 6 "--explain row has exactly 6 tab-separated fields"

STDERR9="$(/bin/bash "$RESOLVE" --explain --phase REVIEW --dir "$R9" 2>&1 >/dev/null)"
check explain-stderr-empty "$STDERR9" "" "--explain produces nothing on stderr on success"

# --- 10. Candidate config resolution order under --explain ----------------

R10="$(new_repo candidate-resolution-order)"
mkdir -p "$R10/.claude"

# Setup both .claude/agy.toml and agy.toml
cat > "$R10/.claude/agy.toml" <<'EOF'
[phases.REVIEW]
tier = "medium"

[tiers]
medium = "custom-claude-medium"
EOF

cat > "$R10/agy.toml" <<'EOF'
[phases.REVIEW]
tier = "low"

[tiers]
low = "custom-root-low"
EOF

R10_CLAUDE_ABS="$(cd "$R10/.claude" && pwd)/agy.toml"
R10_ROOT_ABS="$(cd "$R10" && pwd)/agy.toml"

# 10a. .claude/agy.toml wins over agy.toml and vendored
OUT10_A="$(/bin/bash "$RESOLVE" --explain --phase REVIEW --dir "$R10")"
check explain-cand-claude-wins "$OUT10_A" "REVIEW	medium	custom-claude-medium	true	$R10_CLAUDE_ABS	$R10_CLAUDE_ABS" ".claude/agy.toml wins when present"

# 10b. agy.toml wins when .claude/agy.toml is removed
rm -f "$R10/.claude/agy.toml"
OUT10_B="$(/bin/bash "$RESOLVE" --explain --phase REVIEW --dir "$R10")"
check explain-cand-root-wins "$OUT10_B" "REVIEW	low	custom-root-low	true	$R10_ROOT_ABS	$R10_ROOT_ABS" "repo root agy.toml wins when .claude config absent"

# 10c. Vendored agy.toml wins when repo configs are removed
rm -f "$R10/agy.toml"
OUT10_C="$(/bin/bash "$RESOLVE" --explain --phase REVIEW --dir "$R10")"
check explain-cand-vendored-wins "$OUT10_C" "REVIEW	high	gemini-3.7-flash-high	true	$VENDORED_ABS	$VENDORED_ABS" "vendored agy.toml wins when repo configs absent"

# --- 11. No-phase form emits pipeline phases in order + DELEGATE last -----

R11="$(new_repo custom-pipeline-order)"
cat > "$R11/agy.toml" <<'EOF'
[pipeline]
phases = ["QA", "DISCOVERY", "RELEASE"]

[phases.RELEASE]
tier = "high"
EOF
R11_ABS="$(cd "$R11" && pwd)/agy.toml"

OUT11="$(/bin/bash "$RESOLVE" --explain --dir "$R11")"; RC11=$?
check explain-no-phase-rc "$RC11" 0 "--explain without --phase exits 0"

LINE_COUNT11="$(printf '%s\n' "$OUT11" | grep -c '^' || true)"
check explain-no-phase-line-count "$LINE_COUNT11" 4 "--explain outputs 3 declared phases + 1 DELEGATE row"

LINE11_1="$(printf '%s\n' "$OUT11" | sed -n '1p')"
LINE11_2="$(printf '%s\n' "$OUT11" | sed -n '2p')"
LINE11_3="$(printf '%s\n' "$OUT11" | sed -n '3p')"
LINE11_4="$(printf '%s\n' "$OUT11" | sed -n '4p')"

check explain-no-phase-l1 "$LINE11_1" "QA	medium	gemini-3.7-flash-medium	false	builtin	builtin" "line 1 is QA in declared order"
check explain-no-phase-l2 "$LINE11_2" "DISCOVERY	low	gemini-3.7-flash-low	false	builtin	builtin" "line 2 is DISCOVERY in declared order"
check explain-no-phase-l3 "$LINE11_3" "RELEASE	high	gemini-3.7-flash-high	true	$R11_ABS	builtin" "line 3 is RELEASE with declared tier"
check explain-no-phase-l4 "$LINE11_4" "DELEGATE	medium	gemini-3.7-flash-medium	false	builtin	builtin" "line 4 is DELEGATE bounded worker last"

# Default vendored config no-phase output
OUT11_DEF="$(/bin/bash "$RESOLVE" --explain --dir "$R9")"
LINE_COUNT11_DEF="$(printf '%s\n' "$OUT11_DEF" | grep -c '^' || true)"
check explain-def-line-count "$LINE_COUNT11_DEF" 6 "default config emits 5 pipeline phases + 1 DELEGATE"

# --- 12. Composing --explain with --fallbacks -----------------------------

# 12a. Phase with fallbacks configured (REVIEW in vendored)
OUT12_FB="$(/bin/bash "$RESOLVE" --explain --fallbacks --phase REVIEW --dir "$R9")"; RC12_FB=$?
check explain-fb-rc "$RC12_FB" 0 "--explain --fallbacks exits 0"
check explain-fb-tsv "$OUT12_FB" "REVIEW	high	gemini-3.7-flash-high	true	$VENDORED_ABS	$VENDORED_ABS	gemini-3.7-flash-high,gemini-3.7-flash-medium" "REVIEW row includes 7th comma-joined fallback field"

FIELD_COUNT12="$(printf '%s\n' "$OUT12_FB" | awk -F'\t' '{print NF}')"
check explain-fb-field-count "$FIELD_COUNT12" 7 "--explain --fallbacks row has 7 fields"

# 12b. Phase without fallbacks configured emits '-'
OUT12_NOFB="$(/bin/bash "$RESOLVE" --explain --fallbacks --phase IMPLEMENT --dir "$R9")"
check explain-nofb-tsv "$OUT12_NOFB" "IMPLEMENT	medium	gemini-3.7-flash-medium	false	builtin	$VENDORED_ABS	-" "IMPLEMENT row emits '-' for absent fallbacks"

# --- 13. Repository with no config at all falls through to built-ins ------

# Run a copy of resolve-model in isolated directory where no agy.toml exists next door or above
ISOLATED_DIR="$ROOT/isolated/bin"
mkdir -p "$ISOLATED_DIR"
cp "$RESOLVE" "$ISOLATED_DIR/resolve-model.sh"
R13="$(new_repo isolated-no-config)"

OUT13="$(/bin/bash "$ISOLATED_DIR/resolve-model.sh" --explain --phase REVIEW --dir "$R13")"; RC13=$?
check explain-no-config-rc "$RC13" 0 "isolated resolve-model exits 0"
check explain-no-config-tsv "$OUT13" "REVIEW	high	gemini-3.7-flash-high	false	builtin	builtin" "no config resolves builtin tier and builtin model"

OUT13_ALL="$(/bin/bash "$ISOLATED_DIR/resolve-model.sh" --explain --dir "$R13")"
LINE_COUNT13="$(printf '%s\n' "$OUT13_ALL" | grep -c '^' || true)"
check explain-no-config-line-count "$LINE_COUNT13" 6 "isolated resolve-model emits all default phases + DELEGATE"

# --- 14. Malformed config refused under --explain --------------------------

R14="$(new_repo malformed-explain)"
cat > "$R14/agy.toml" <<'EOF'
[tiers]
high = "gemini-3.7-flash-high" # inline comment
EOF

OUT14="$(/bin/bash "$RESOLVE" --explain --dir "$R14" 2>&1 >/dev/null)"; RC14=$?
check explain-malformed-rc "$RC14" 2 "malformed config exits 2 under --explain"
case "$OUT14" in
  *"malformed config"*) ok explain-malformed-msg "stderr contains malformed config message" ;;
  *) bad explain-malformed-msg "stderr missing malformed message: $OUT14" ;;
esac

STDOUT14="$(/bin/bash "$RESOLVE" --explain --dir "$R14" 2>/dev/null)"
check explain-malformed-stdout-empty "$STDOUT14" "" "no stdout emitted on malformed config"

# --- 15. Unknown tier configured for phase under --explain ----------------

R15="$(new_repo unknown-tier-explain)"
cat > "$R15/agy.toml" <<'EOF'
[phases.REVIEW]
tier = "unregistered_tier"
EOF

OUT15="$(/bin/bash "$RESOLVE" --explain --phase REVIEW --dir "$R15" 2>&1 >/dev/null)"; RC15=$?
check explain-unknown-tier-rc "$RC15" 2 "unknown tier in phase exits 2 under --explain"
case "$OUT15" in
  *"unknown tier 'unregistered_tier'"*) ok explain-unknown-tier-msg "stderr names unknown tier" ;;
  *) bad explain-unknown-tier-msg "stderr missing unknown tier message: $OUT15" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
