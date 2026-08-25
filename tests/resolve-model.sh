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

[ -f "$RESOLVE" ] || { echo "resolve-model-test: resolve-model.sh not found next door" >&2; exit 2; }
[ -f "$PREFLIGHT" ] || { echo "resolve-model-test: preflight.sh not found next door" >&2; exit 2; }
[ -f "$PHASE_SH" ] || { echo "resolve-model-test: phase.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "resolve-model-test: run-dir.sh not found next door" >&2; exit 2; }
[ -f "$VENDORED_CONFIG" ] || { echo "resolve-model-test: agy.toml not found at repo root" >&2; exit 2; }

. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/resolve-model.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

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
OUT5="$(/bin/bash "$RESOLVE" --tier bogus --dir "$R5" 2>/dev/null)"; RC5=$?
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
OUT5_PHASE="$(/bin/bash "$RESOLVE" --phase REVIEW --dir "$R5" 2>/dev/null)"; RC5_PHASE=$?
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
OUT6_D="$(/bin/bash "$RESOLVE" --dir "$R6" --tier high 2>&1)"; RC6_D=$?
check malformed-unsupported-type-rc "$RC6_D" 2 "exit 2 on unsupported value type"

# 6e. Key defined outside section
cat > "$R6/agy.toml" <<'EOF'
tier = "high"
[tiers]
high = "gemini-3.7-flash-high"
EOF
OUT6_E="$(/bin/bash "$RESOLVE" --dir "$R6" --tier high 2>&1)"; RC6_E=$?
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
PREFLIGHT_FAIL_OUT="$(STUB_MODELS='other-model\tOther\n' STUB_RC=0 AGY_BIN="$STUB" \
  /bin/bash "$PREFLIGHT" --phase REVIEW --dir "$R7" 2>&1)"; PREFLIGHT_FAIL_RC=$?
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
