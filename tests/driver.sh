#!/usr/bin/env bash
# Exercise worker driver interface: capabilities reporting, agy driver argv construction,
# unknown driver refusal, shell capability propagation to brief lint, and driver models listing.
#
#   tests/driver.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGY_DRIVER="$ROOT/drivers/agy.sh"
AGY_RUN="$ROOT/scripts/agy-run.sh"
PHASE_SH="$ROOT/scripts/phase.sh"
CHECK_BRIEF="$ROOT/scripts/check-brief.sh"
RUN_DIR_SH="$ROOT/scripts/run-dir.sh"

[ -f "$AGY_DRIVER" ] || { echo "driver-test: drivers/agy.sh not found" >&2; exit 2; }
[ -f "$AGY_RUN" ]    || { echo "driver-test: scripts/agy-run.sh not found" >&2; exit 2; }
[ -f "$PHASE_SH" ]   || { echo "driver-test: scripts/phase.sh not found" >&2; exit 2; }
[ -f "$CHECK_BRIEF" ] || { echo "driver-test: scripts/check-brief.sh not found" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "driver-test: scripts/run-dir.sh not found" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/driver-test.XXXXXX")"
SCRATCH="$(cd "$SCRATCH" && pwd)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

export AGY_FLEET="$SCRATCH/fleet"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# Helper to create a throwaway repo
new_repo() {
  local name="$1"
  local r="$SCRATCH/repos/$name"
  mkdir -p "$r"
  r="$(cd "$r" && pwd)"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" \
      && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  local run_id
  run_id="$(run_dir_new --dir "$r" --task "driver test $name")"
  [ -n "$run_id" ] || { echo "driver-test: run_dir_new failed for $name" >&2; exit 2; }
  printf '%s' "$r"
}

# --- 1. agy driver capabilities reporting ------------------------------------

# shellcheck source=../drivers/agy.sh
. "$AGY_DRIVER"

CAPS="$(driver_capabilities)"

get_cap() {
  local key="$1"
  printf '%s\n' "$CAPS" | sed -n "s/^${key}=//p" | head -1
}

check cap-shell "$(get_cap shell)" "no" "shell capability is no"
check cap-sandbox "$(get_cap sandbox)" "yes" "sandbox capability is yes"
check cap-effort "$(get_cap effort)" "yes" "effort capability is yes"
check cap-read-outside-dir "$(get_cap read_outside_dir)" "no" "read_outside_dir capability is no"
check cap-plan-mode-writes "$(get_cap plan_mode_writes)" "no" "plan_mode_writes capability is no"
check cap-usage-reporting "$(get_cap usage_reporting)" "json" "usage_reporting capability is json"
check cap-stdout-pipe "$(get_cap stdout_must_be_pipe)" "yes" "stdout_must_be_pipe capability is yes"
check cap-stdin-devnull "$(get_cap stdin_must_be_devnull)" "yes" "stdin_must_be_devnull capability is yes"

DOCUMENTED_KEYS="shell sandbox effort read_outside_dir plan_mode_writes usage_reporting stdout_must_be_pipe stdin_must_be_devnull"
ALL_KEYS_PRESENT=1
for K in $DOCUMENTED_KEYS; do
  VAL="$(get_cap "$K")"
  if [ -z "$VAL" ]; then
    ALL_KEYS_PRESENT=0
    bad "cap-present-$K" "key $K missing from driver_capabilities"
  fi
done
[ "$ALL_KEYS_PRESENT" -eq 1 ] && ok cap-all-keys-present "all documented capability keys are present"

# --- 2. driver_run builds the exact argv agy-run.sh builds -------------------

# Stub executable to record argv and simulate agy output
STUB_AGY="$SCRATCH/stub_agy"
cat > "$STUB_AGY" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
  exit 0
fi
if [ -n "${STUB_ARGV_FILE:-}" ]; then
  printf '%s\n' "$0" "$@" > "$STUB_ARGV_FILE"
fi
printf '{"response":"STATUS: DONE | File: CHANGES.md","num_turns":1,"usage":{"total_tokens":42}}\n'
exit 0
STUB_EOF
chmod +x "$STUB_AGY"

R_ARGV="$(new_repo argv-test)"
RUN_ID_ARGV="$(cat "$R_ARGV/.agy/current")"
BRIEF_ARGV="$R_ARGV/.agy/runs/$RUN_ID_ARGV/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_ARGV")"
printf 'Test brief content for argv comparison\n' > "$BRIEF_ARGV"
LOG_ARGV="$R_ARGV/.agy/runs/$RUN_ID_ARGV/phases/TEST/log"

# Case 2a: Standard invocation — compare driver_run and agy-run.sh shim
ARGV_DRIVER_STD="$SCRATCH/argv_driver_std"
ARGV_SHIM_STD="$SCRATCH/argv_shim_std"

STUB_ARGV_FILE="$ARGV_DRIVER_STD" AGY_BIN="$STUB_AGY" \
  driver_run --brief "$BRIEF_ARGV" --dir "$R_ARGV" --model "gemini-3.7-flash-medium" \
             --mode "accept-edits" --timeout "30m" --log "$LOG_ARGV" >/dev/null 2>&1
RC_DRIVER_STD=$?

STUB_ARGV_FILE="$ARGV_SHIM_STD" AGY_BIN="$STUB_AGY" \
  "$AGY_RUN" --brief "$BRIEF_ARGV" --dir "$R_ARGV" --model "gemini-3.7-flash-medium" \
             --mode "accept-edits" --timeout "30m" --log "$LOG_ARGV" >/dev/null 2>&1
RC_SHIM_STD=$?

check driver-run-std-rc "$RC_DRIVER_STD" 0 "driver_run exits 0 on standard invocation"
check shim-run-std-rc "$RC_SHIM_STD" 0 "agy-run.sh shim exits 0 on standard invocation"

# Byte-for-byte argv match between driver_run and agy-run.sh
CKSUM_DRIVER="$(cksum < "$ARGV_DRIVER_STD")"
CKSUM_SHIM="$(cksum < "$ARGV_SHIM_STD")"
check argv-driver-shim-match "$CKSUM_DRIVER" "$CKSUM_SHIM" "driver_run and agy-run.sh produce identical argv"

# Verify exact argv contents as a single complete sequence
EXPECTED_ARGV_STD="$(printf '%s\n' "$STUB_AGY" "--output-format" "stream-json" \
  "-p=Test brief content for argv comparison" "--add-dir" "$R_ARGV" \
  "--model" "gemini-3.7-flash-medium" "--print-timeout" "30m" "--mode" "accept-edits")"
check argv-full-match "$(cat "$ARGV_DRIVER_STD")" "$EXPECTED_ARGV_STD" "complete argv matches expected sequence including binary"

# Case 2b: With --effort and --sandbox
ARGV_OPTS="$SCRATCH/argv_opts"
STUB_ARGV_FILE="$ARGV_OPTS" AGY_BIN="$STUB_AGY" \
  driver_run --brief "$BRIEF_ARGV" --dir "$R_ARGV" --model "gemini-3.7-flash-high" \
             --mode "accept-edits" --effort "high" --sandbox --timeout "45m" --log "$LOG_ARGV" >/dev/null 2>&1

EXPECTED_ARGV_OPTS="$(printf '%s\n' "$STUB_AGY" "--output-format" "stream-json" \
  "-p=Test brief content for argv comparison" "--add-dir" "$R_ARGV" \
  "--model" "gemini-3.7-flash-high" "--print-timeout" "45m" "--mode" "accept-edits" \
  "--effort" "high" "--sandbox")"
check argv-opts-full-match "$(cat "$ARGV_OPTS")" "$EXPECTED_ARGV_OPTS" "complete argv matches with --effort and --sandbox"

# Case 2c: Mode full mapping to --dangerously-skip-permissions
ARGV_FULL="$SCRATCH/argv_full"
STUB_ARGV_FILE="$ARGV_FULL" AGY_BIN="$STUB_AGY" \
  driver_run --brief "$BRIEF_ARGV" --dir "$R_ARGV" --model "gemini-3.7-flash-medium" \
             --mode "full" --timeout "30m" --log "$LOG_ARGV" >/dev/null 2>&1

EXPECTED_ARGV_FULL="$(printf '%s\n' "$STUB_AGY" "--output-format" "stream-json" \
  "-p=Test brief content for argv comparison" "--add-dir" "$R_ARGV" \
  "--model" "gemini-3.7-flash-medium" "--print-timeout" "30m" \
  "--dangerously-skip-permissions")"
check argv-mode-full-match "$(cat "$ARGV_FULL")" "$EXPECTED_ARGV_FULL" "complete argv matches with mode full mapping to --dangerously-skip-permissions"

# --- 3. Unknown --driver name is refused with a clear message -----------------

R_UNKNOWN="$(new_repo unknown-driver)"
RUN_ID_UNKNOWN="$(cat "$R_UNKNOWN/.agy/current")"
BRIEF_UNKNOWN="$R_UNKNOWN/.agy/runs/$RUN_ID_UNKNOWN/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_UNKNOWN")"
cat > "$BRIEF_UNKNOWN" <<'EOF'
# Phase: TEST
Goal: test unknown driver refusal.
Rules:
- Do not run shell commands.
- Do not touch git.
- Write nothing outside this repo.
Output Contract:
Write verdict to .agy/runs/RUN_ID/phases/TEST/verdict and print that same line as STATUS: DONE | File: CHANGES.md.
EOF

ERR_UNKNOWN="$SCRATCH/unknown_driver.err"
AGY_BIN="$STUB_AGY" "$PHASE_SH" --phase TEST --brief "$BRIEF_UNKNOWN" --dir "$R_UNKNOWN" \
  --driver nonexistent_driver_xyz --no-preflight >/dev/null 2>"$ERR_UNKNOWN" || RC_UNKNOWN=$?
RC_UNKNOWN="${RC_UNKNOWN:-0}"

check unknown-driver-rc "$RC_UNKNOWN" 2 "unknown --driver exits with code 2"
if grep -q "unknown driver 'nonexistent_driver_xyz'" "$ERR_UNKNOWN"; then
  ok unknown-driver-msg "stderr clearly reports unknown driver name"
else
  bad unknown-driver-msg "stderr missing clear unknown driver message: $(cat "$ERR_UNKNOWN")"
fi

# --- 4. Stub driver shell capability propagation to brief lint ---------------

R_SHELL="$(new_repo shell-prop-test)"
RUN_ID_SHELL="$(cat "$R_SHELL/.agy/current")"
BRIEF_NO_SHELL_RULE="$R_SHELL/.agy/runs/$RUN_ID_SHELL/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_NO_SHELL_RULE")"

# Brief without "do not run shell commands" rule (fails brief lint unless --allow-shell)
cat > "$BRIEF_NO_SHELL_RULE" <<EOF
# Phase: TEST
Goal: do the work.

Rules:
- Do not touch git.
- Write nothing outside this repo.

Output Contract:
Write your one-line verdict to .agy/runs/$RUN_ID_SHELL/phases/TEST/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

# Create stub driver directories
STUB_DRIVERS_DIR="$SCRATCH/drivers"
mkdir -p "$STUB_DRIVERS_DIR"

# Stub driver declaring shell=no
cat > "$STUB_DRIVERS_DIR/stub_shell_no.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
driver_capabilities() {
  cat <<'CAPS_EOF'
shell=no
sandbox=no
effort=no
read_outside_dir=no
plan_mode_writes=no
usage_reporting=none
stdout_must_be_pipe=no
stdin_must_be_devnull=no
CAPS_EOF
}
driver_models() {
  printf 'stub-model\n'
}
driver_run() {
  local log=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --log) log="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$log" ] && printf 'STATUS: DONE | File: CHANGES.md\n' > "$log"
  printf 'STATUS: DONE | File: CHANGES.md\n'
  return 0
}
EOF

# Stub driver declaring shell=yes
cat > "$STUB_DRIVERS_DIR/stub_shell_yes.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
driver_capabilities() {
  cat <<'CAPS_EOF'
shell=yes
sandbox=no
effort=no
read_outside_dir=no
plan_mode_writes=no
usage_reporting=none
stdout_must_be_pipe=no
stdin_must_be_devnull=no
CAPS_EOF
}
driver_models() {
  printf 'stub-model\n'
}
driver_run() {
  local log="" brief=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --log) log="$2"; shift 2 ;;
      --brief) brief="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$log" ]; then
    local phase_dir
    phase_dir="$(dirname "$log")"
    mkdir -p "$phase_dir"
    printf 'STATUS: DONE | File: CHANGES.md\n' > "$phase_dir/verdict"
    printf 'STATUS: DONE | File: CHANGES.md\n' > "$log"
  fi
  printf 'STATUS: DONE | File: CHANGES.md\n'
  return 0
}
EOF

# Case 4a: Driver with shell=no fails brief lint on brief lacking shell prohibition
OUT_SHELL_NO="$(AGY_DRIVERS_DIR="$STUB_DRIVERS_DIR" "$PHASE_SH" --phase TEST --brief "$BRIEF_NO_SHELL_RULE" \
  --dir "$R_SHELL" --driver stub_shell_no --no-preflight 2>/dev/null)" || RC_SHELL_NO=$?
RC_SHELL_NO="${RC_SHELL_NO:-0}"

check shell-no-lint-rc "$RC_SHELL_NO" 3 "driver with shell=no causes brief lint to refuse (exit 3)"
case "$OUT_SHELL_NO" in
  *"STATUS: BRIEF_INVALID(missing_shell_prohibition)"*)
    ok shell-no-lint-status "status reports BRIEF_INVALID(missing_shell_prohibition)" ;;
  *)
    bad shell-no-lint-status "unexpected output with shell=no: $OUT_SHELL_NO" ;;
esac

# Case 4b: Driver with shell=yes passes brief lint on the same brief
OUT_SHELL_YES="$(AGY_DRIVERS_DIR="$STUB_DRIVERS_DIR" "$PHASE_SH" --phase TEST --brief "$BRIEF_NO_SHELL_RULE" \
  --dir "$R_SHELL" --driver stub_shell_yes --no-preflight 2>/dev/null)" || RC_SHELL_YES=$?
RC_SHELL_YES="${RC_SHELL_YES:-0}"

check shell-yes-lint-rc "$RC_SHELL_YES" 0 "driver with shell=yes passes brief lint and executes phase (exit 0)"
case "$OUT_SHELL_YES" in
  *"STATUS: DONE | File: CHANGES.md"*)
    ok shell-yes-lint-status "status reports STATUS: DONE with shell=yes" ;;
  *)
    bad shell-yes-lint-status "unexpected output with shell=yes: $OUT_SHELL_YES" ;;
esac

# --- 5. driver_models returns the model list ---------------------------------

MODELS_LIST="$(AGY_BIN="$STUB_AGY" driver_models)"
RC_MODELS=$?

check driver-models-rc "$RC_MODELS" 0 "driver_models exits 0"
check driver-models-count "$(printf '%s\n' "$MODELS_LIST" | grep -c .)" 3 "driver_models returned 3 models"
check driver-models-first "$(printf '%s\n' "$MODELS_LIST" | sed -n '1p')" "gemini-3.7-flash-low" "first model is gemini-3.7-flash-low"
check driver-models-second "$(printf '%s\n' "$MODELS_LIST" | sed -n '2p')" "gemini-3.7-flash-medium" "second model is gemini-3.7-flash-medium"
check driver-models-third "$(printf '%s\n' "$MODELS_LIST" | sed -n '3p')" "gemini-3.7-flash-high" "third model is gemini-3.7-flash-high"

# --- 6. agy.toml driver configuration and CLI override -----------------------

R_CFG="$(new_repo toml-driver-test)"
RUN_ID_CFG="$(cat "$R_CFG/.agy/current")"
BRIEF_CFG="$R_CFG/.agy/runs/$RUN_ID_CFG/phases/TEST/brief.md"
mkdir -p "$(dirname "$BRIEF_CFG")"
cat > "$BRIEF_CFG" <<EOF
# Phase: TEST
Goal: test toml driver config.

Rules:
- Do not touch git.
- Write nothing outside this repo.

Output Contract:
Write your one-line verdict to .agy/runs/$RUN_ID_CFG/phases/TEST/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

# Case 6a: agy.toml specifying [driver] name = "stub_shell_yes"
cat > "$R_CFG/agy.toml" <<'EOF'
[driver]
name = "stub_shell_yes"
EOF

OUT_TOML_DRIVER="$(AGY_DRIVERS_DIR="$STUB_DRIVERS_DIR" "$PHASE_SH" --phase TEST --brief "$BRIEF_CFG" \
  --dir "$R_CFG" --no-preflight 2>/dev/null)" || RC_TOML_DRIVER=$?
RC_TOML_DRIVER="${RC_TOML_DRIVER:-0}"

check toml-driver-config-rc "$RC_TOML_DRIVER" 0 "phase.sh selects driver configured in agy.toml"
case "$OUT_TOML_DRIVER" in
  *"STATUS: DONE"*) ok toml-driver-config-status "phase completed using agy.toml driver" ;;
  *) bad toml-driver-config-status "unexpected output from agy.toml driver: $OUT_TOML_DRIVER" ;;
esac

# Case 6b: CLI flag --driver overrides agy.toml
OUT_CLI_OVERRIDE="$(AGY_DRIVERS_DIR="$STUB_DRIVERS_DIR" "$PHASE_SH" --phase TEST --brief "$BRIEF_CFG" \
  --dir "$R_CFG" --driver stub_shell_no --no-preflight 2>/dev/null)" || RC_CLI_OVERRIDE=$?
RC_CLI_OVERRIDE="${RC_CLI_OVERRIDE:-0}"

check cli-overrides-toml-driver-rc "$RC_CLI_OVERRIDE" 3 "CLI --driver overrides agy.toml [driver]"
case "$OUT_CLI_OVERRIDE" in
  *"BRIEF_INVALID(missing_shell_prohibition)"*)
    ok cli-overrides-toml-driver-status "CLI driver override enforced" ;;
  *)
    bad cli-overrides-toml-driver-status "unexpected output on CLI driver override: $OUT_CLI_OVERRIDE" ;;
esac

# --- the step stream: what a dispatch actually did ---------------------------
#
# json emits one result object and nothing else, so a worker's steps, their
# timings and their per-step spend were never produced. stream-json produces all
# three and the driver used to overwrite them with the response text. These cases
# pin both halves: the stream survives, and the result is still read from it
# exactly as it was read from the single-object form.
#
# The fixture below is the shape a real agy stream-json dispatch emits, trimmed.

R_STREAM="$(new_repo stream-json)"
RUN_STREAM="$(cat "$R_STREAM/.agy/current")"
PHASE_STREAM="$R_STREAM/.agy/runs/$RUN_STREAM/phases/TEST"
mkdir -p "$PHASE_STREAM"
BRIEF_STREAM="$PHASE_STREAM/brief.md"
printf '# Phase: TEST\nGoal: stream shape.\n' > "$BRIEF_STREAM"

STUB_STREAM="$SCRATCH/stub_stream_agy"
cat > "$STUB_STREAM" <<'STREAM_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-medium\tGemini\n'; exit 0
fi
cat <<'NDJSON'
{"event":"init","conversation_id":"c-1","init":{"model":"gemini-3.7-flash-medium","cwd":"/tmp","permission_mode":"request-review"}}
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":1,"state":"DONE","step_type":"agent_response","duration_seconds":1.77,"usage":{"input_tokens":16847,"output_tokens":69,"thinking_tokens":6,"cache_read_tokens":0,"total_tokens":16916}}}
{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":2,"state":"DONE","step_type":"tool","tool_name":"view_file","duration_seconds":0.1,"tool_info":{"name":"view_file","parameters":{"Path":"a.txt"}}}}
jetski: a human-facing notice that is not JSON at all
{"event":"result","result":{"conversation_id":"c-1","status":"SUCCESS","response":"STATUS: DONE | File: CHANGES.md","duration_seconds":5.7,"num_turns":2,"usage":{"input_tokens":38823,"output_tokens":278,"thinking_tokens":35,"cache_read_tokens":12191,"total_tokens":39101}}}
NDJSON
exit 0
STREAM_EOF
chmod +x "$STUB_STREAM"

LOG_STREAM="$PHASE_STREAM/log"
AGY_BIN="$STUB_STREAM" driver_run --brief "$BRIEF_STREAM" --dir "$R_STREAM" \
  --model gemini-3.7-flash-medium --mode accept-edits --timeout 30m \
  --log "$LOG_STREAM" >/dev/null 2>&1
check stream-run-rc "$?" 0 "a stream-json dispatch exits 0"

if [ -s "$PHASE_STREAM/stream.ndjson" ]; then
  ok stream-kept "the step stream is kept instead of being overwritten"
else
  bad stream-kept "no stream.ndjson at $PHASE_STREAM"
fi

STEP_COUNT="$(grep -c '"event":"step_update"' "$PHASE_STREAM/stream.ndjson" 2>/dev/null | tr -cd '0-9')"
check stream-steps "$STEP_COUNT" "2" "every step line survives, not just the last"

if grep -q '"duration_seconds"' "$PHASE_STREAM/stream.ndjson" 2>/dev/null \
   && grep -q '"thinking_tokens"' "$PHASE_STREAM/stream.ndjson" 2>/dev/null; then
  ok stream-has-trace-data "per-step timings and per-step token spend are both in the stream"
else
  bad stream-has-trace-data "stream is missing the timing or usage fields the trace needs"
fi

# The result object must come out identical to the single-object form, or every
# reader downstream — phase.sh's usage, num_turns and status parsing — breaks.
RES_STREAM="$(cat "$PHASE_STREAM/result.json" 2>/dev/null)"
if printf '%s\n' "$RES_STREAM" | grep -q '^{"conversation_id":"c-1"'; then
  ok stream-result-unwrapped "the result event is unwrapped to the object phase.sh already reads"
else
  bad stream-result-unwrapped "result.json not unwrapped: $RES_STREAM"
fi
if printf '%s\n' "$RES_STREAM" | grep -q '"total_tokens":39101' \
   && printf '%s\n' "$RES_STREAM" | grep -q '"num_turns":2'; then
  ok stream-result-fields "the run total and turn count survive the unwrapping"
else
  bad stream-result-fields "result fields lost: $RES_STREAM"
fi

# A non-JSON notice in the middle of the stream must not be mistaken for the result.
if printf '%s\n' "$RES_STREAM" | grep -q 'jetski'; then
  bad stream-ignores-noise "a human-facing notice was parsed as the result"
else
  ok stream-ignores-noise "non-JSON lines in the stream are stepped over, not parsed"
fi

# The log still holds the response text: the verdict is read from it.
if grep -q 'STATUS: DONE' "$LOG_STREAM" 2>/dev/null; then
  ok stream-log-response "the log still carries the response the verdict is read from"
else
  bad stream-log-response "log lost the response: $(cat "$LOG_STREAM" 2>/dev/null)"
fi

# AGY_OUTPUT_FORMAT=json restores the single-object behaviour for anyone who needs it.
R_JSON="$(new_repo output-format-override)"
RUN_JSON="$(cat "$R_JSON/.agy/current")"
PHASE_JSON="$R_JSON/.agy/runs/$RUN_JSON/phases/TEST"
mkdir -p "$PHASE_JSON"
printf '# Phase: TEST\nGoal: override.\n' > "$PHASE_JSON/brief.md"
ARGV_JSON="$SCRATCH/argv_json"
STUB_ARGV_FILE="$ARGV_JSON" AGY_BIN="$STUB_AGY" AGY_OUTPUT_FORMAT=json \
  driver_run --brief "$PHASE_JSON/brief.md" --dir "$R_JSON" --model gemini-3.7-flash-medium \
  --mode accept-edits --timeout 30m --log "$PHASE_JSON/log" >/dev/null 2>&1
if grep -qx 'json' "$ARGV_JSON" 2>/dev/null; then
  ok stream-format-override "AGY_OUTPUT_FORMAT=json restores the single-object form"
else
  bad stream-format-override "override ignored: $(tr '\n' ' ' < "$ARGV_JSON" 2>/dev/null)"
fi
if [ -f "$PHASE_JSON/stream.ndjson" ]; then
  bad stream-no-file-in-json-mode "a stream file was written in json mode, where there is no stream"
else
  ok stream-no-file-in-json-mode "no stream file is written in json mode — there is no stream to keep"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
