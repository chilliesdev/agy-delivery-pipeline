#!/usr/bin/env bash
# Fixture library for generating configurable fake agy worker binaries.
#
# Reproduces observed quirks of the real Antigravity worker on demand:
#
#   hang-on-file-stdout:
#     Reproduces: worker hangs when its standard output is a plain file rather than a pipe.
#     Observation: stdout_must_be_pipe=yes in driver capabilities.
#
#   abort-on-shell-command:
#     Reproduces: a denied permission aborts the whole headless run, so work survives and status is lost.
#     Observation: shell=no in driver capabilities.
#
#   scratch-write-without-add-dir:
#     Reproduces: the add-dir flag is mandatory or worker writes into its own scratch directory instead of repo.
#     Observation: read_outside_dir=no in driver capabilities.
#
#   deny-write-in-plan-mode:
#     Reproduces: plan mode denies the worker writing its own report/verdict to the repository.
#     Observation: plan_mode_writes=no in driver capabilities.
#
#   drain-stdin-forever:
#     Reproduces: worker drains standard input before it answers, hanging on unclosed inherited stdin.
#     Observation: stdin_must_be_devnull=yes in driver capabilities.
#
# Usage:
#   . "$HERE/lib/fake-agy.sh"
#   BIN="$(fake_agy_new [--dir <dir>] [--behaviour <name>] [--verdict <v>] [--sleep <n>] [--rc <rc>])"
set -uo pipefail

fake_agy_new() {
  local target_dir=""
  local verdict="STATUS: DONE | File: CHANGES.md"
  local sleep_sec=""
  local rc="0"
  local name="agy"
  local b_hang_stdout=0
  local b_abort_shell=0
  local b_scratch_no_add_dir=0
  local b_deny_plan=0
  local b_drain_stdin=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)       target_dir="$2"; shift 2 ;;
      --name)      name="$2"; shift 2 ;;
      --verdict)   verdict="$2"; shift 2 ;;
      --sleep|--delay) sleep_sec="$2"; shift 2 ;;
      --rc)        rc="$2"; shift 2 ;;
      --behaviour|--behavior)
        case "$2" in
          hang-on-file-stdout)           b_hang_stdout=1 ;;
          abort-on-shell-command)        b_abort_shell=1 ;;
          scratch-write-without-add-dir)  b_scratch_no_add_dir=1 ;;
          deny-write-in-plan-mode)       b_deny_plan=1 ;;
          drain-stdin-forever)           b_drain_stdin=1 ;;
          *) echo "fake_agy_new: unknown behaviour '$2'" >&2; return 2 ;;
        esac
        shift 2
        ;;
      *)
        echo "fake_agy_new: unknown arg '$1'" >&2; return 2 ;;
    esac
  done

  if [ -z "$target_dir" ]; then
    target_dir="$(mktemp -d "${TMPDIR:-/tmp}/fake-agy.XXXXXX")"
  fi
  mkdir -p "$target_dir"
  local bin_path="$target_dir/$name"

  cat > "$bin_path" <<FAKE_AGY_EOF
#!/usr/bin/env bash
set -uo pipefail

B_HANG_STDOUT=$b_hang_stdout
B_ABORT_SHELL=$b_abort_shell
B_SCRATCH_NO_ADD_DIR=$b_scratch_no_add_dir
B_DENY_PLAN=$b_deny_plan
B_DRAIN_STDIN=$b_drain_stdin

DEFAULT_VERDICT=\$(cat <<'__VERDICT_EOF__'
$verdict
__VERDICT_EOF__
)
DEFAULT_SLEEP="$sleep_sec"
DEFAULT_RC="$rc"

# 1. Drain stdin if behaviour active or STUB_READS_STDIN set
if [ "\$B_DRAIN_STDIN" -eq 1 ] || [ -n "\${STUB_READS_STDIN:-}" ]; then
  cat >/dev/null
fi

# 2. Artificial delay if requested
SLEEP_TIME="\${STUB_SLEEP:-\${STUB_SLEEP_SEC:-\$DEFAULT_SLEEP}}"
if [ -n "\$SLEEP_TIME" ] && [ "\$SLEEP_TIME" -gt 0 ] 2>/dev/null; then
  sleep "\$SLEEP_TIME" | cat
fi

# 3. Subcommand: models
if [ "\${1:-}" = "models" ]; then
  printf 'Fetching available models...\n' >&2
  if [ -n "\${STUB_MODELS+x}" ]; then
    printf '%b' "\$STUB_MODELS"
  else
    printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\nclaude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)\n'
  fi
  exit "\${STUB_RC:-\$DEFAULT_RC}"
fi

# 4. Hang if stdout is a plain file rather than a pipe
if [ "\$B_HANG_STDOUT" -eq 1 ]; then
  if [ -f /dev/fd/1 ] || [ -f /dev/stdout ] 2>/dev/null || ( [ ! -p /dev/fd/1 ] && [ ! -p /dev/stdout ] && [ ! -t 1 ] ); then
    sleep 3600 | cat
  fi
fi

# 5. Parse argv
ADD_DIR=""
MODE_ARG="accept-edits"
OUTPUT_FORMAT=""
PROMPT=""

[ -n "\${STUB_ARGV:-}" ] && printf '%s\n' "\$@" > "\$STUB_ARGV"
[ -n "\${STUB_ARGV_FILE:-}" ] && printf '%s\n' "\$0" "\$@" > "\$STUB_ARGV_FILE"

while [ \$# -gt 0 ]; do
  case "\$1" in
    --add-dir) ADD_DIR="\$2"; shift 2 ;;
    --mode)    MODE_ARG="\$2"; shift 2 ;;
    --output-format) OUTPUT_FORMAT="\$2"; shift 2 ;;
    -p=*)      PROMPT="\${1#-p=}"; shift ;;
    -p)        PROMPT="\$2"; shift 2 ;;
    --dangerously-skip-permissions) MODE_ARG="full"; shift ;;
    *) shift ;;
  esac
done

if [ -n "\${STUB_MUTATE_SCRIPT:-}" ] && [ -f "\$STUB_MUTATE_SCRIPT" ]; then
  printf '\nthis is a syntax error that would kill bash if executed mid-run: (\n' >> "\$STUB_MUTATE_SCRIPT"
fi

if [ -n "\${STUB_ACTION:-}" ]; then
  eval "\$STUB_ACTION"
fi

# 6. Abort on shell command behaviour
if [ "\$B_ABORT_SHELL" -eq 1 ] && [ "\$MODE_ARG" != "full" ]; then
  printf 'Permission denied: shell command execution rejected in accept-edits mode\n' >&2
  exit "\${STUB_RC:-1}"
fi

# 7. Target directory resolution
TARGET_DIR="\${ADD_DIR:-}"
if [ "\$B_SCRATCH_NO_ADD_DIR" -eq 1 ] && [ -z "\$ADD_DIR" ]; then
  TARGET_DIR="\$(mktemp -d "\${TMPDIR:-/tmp}/fake-agy-scratch.XXXXXX" 2>/dev/null || true)"
elif [ -z "\$TARGET_DIR" ]; then
  TARGET_DIR="\$PWD"
fi

# 8. Verdict formatting
V_TEXT="\${STUB_VERDICT:-\$DEFAULT_VERDICT}"
case "\$V_TEXT" in
  STATUS:*) ;;
  *) V_TEXT="STATUS: \$V_TEXT" ;;
esac

# 9. Write verdict file
CAN_WRITE=1
if [ "\$B_DENY_PLAN" -eq 1 ] && [ "\$MODE_ARG" = "plan" ]; then
  CAN_WRITE=0
fi

if [ "\$CAN_WRITE" -eq 1 ] && [ -n "\$TARGET_DIR" ] && [ -d "\$TARGET_DIR" ]; then
  if [ -f "\$TARGET_DIR/.agy/current" ]; then
    CUR_RUN="\$(cat "\$TARGET_DIR/.agy/current" 2>/dev/null || true)"
    if [ -n "\$CUR_RUN" ]; then
      PHASE_NAME="\${STUB_PHASE:-}"
      if [ -z "\$PHASE_NAME" ] && [ -d "\$TARGET_DIR/.agy/runs/\$CUR_RUN/phases" ]; then
        for P in "\$TARGET_DIR/.agy/runs/\$CUR_RUN/phases"/*; do
          [ -d "\$P" ] && PHASE_NAME="\$(basename "\$P")"
        done
      fi
      if [ -n "\$PHASE_NAME" ]; then
        mkdir -p "\$TARGET_DIR/.agy/runs/\$CUR_RUN/phases/\$PHASE_NAME"
        printf '%s\n' "\$V_TEXT" > "\$TARGET_DIR/.agy/runs/\$CUR_RUN/phases/\$PHASE_NAME/verdict"
      fi
    fi
  fi
fi

# 10. Worker output
if [ "\$OUTPUT_FORMAT" = "json" ]; then
  JSON_ESCAPED="\$(printf '%s' "\$V_TEXT" | sed 's/"/\\\\"/g')"
  printf '{"response":"%s","num_turns":1,"usage":{"total_tokens":42}}\n' "\$JSON_ESCAPED"
else
  printf '%s\n' "\$V_TEXT"
fi

exit "\${STUB_RC:-\$DEFAULT_RC}"
FAKE_AGY_EOF

  chmod +x "$bin_path"
  printf '%s\n' "$bin_path"
}
