#!/usr/bin/env bash
# Antigravity worker driver for agy-delivery-pipeline.
# Implements the driver interface:
#   driver_run --brief <file> --dir <dir> --model <id> --mode <m> --effort <e> \
#              [--sandbox] --timeout <t> --log <file>     -> rc
#   driver_models                                          -> ids, one per line
#   driver_capabilities                                    -> key=value, one per line
set -uo pipefail

driver_capabilities() {
  cat <<'EOF'
shell=no
sandbox=yes
effort=yes
read_outside_dir=no
plan_mode_writes=no
usage_reporting=json
stdout_must_be_pipe=yes
stdin_must_be_devnull=yes
EOF
}

driver_models() {
  local agy="${AGY_BIN:-agy}"
  if ! command -v "$agy" >/dev/null 2>&1; then
    echo "agy not found on PATH (~/.local/bin/agy)" >&2
    return 127
  fi

  local raw
  raw="$("$agy" models </dev/null 2>/dev/null)"
  local rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  printf '%s\n' "$raw" | awk -F'\t' '
    { id = $1
      sub(/^[[:space:]]+/, "", id)
      sub(/[[:space:]]+$/, "", id)
      if (id ~ /^[A-Za-z0-9][A-Za-z0-9._:-]*$/) print id }
  '
}

driver_run() {
  local agy="${AGY_BIN:-agy}"
  local brief=""
  local dir="$PWD"
  local log=""
  local model="${AGY_MODEL:-gemini-3.7-flash-medium}"
  local mode="${AGY_MODE:-accept-edits}"
  local effort="${AGY_EFFORT:-}"
  local timeout="${AGY_TIMEOUT:-30m}"
  local sandbox=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --brief)   brief="$2";   shift 2 ;;
      --dir)     dir="$2";     shift 2 ;;
      --log)     log="$2";     shift 2 ;;
      --model)   model="$2";   shift 2 ;;
      --mode)    mode="$2";    shift 2 ;;
      --effort)  effort="$2";  shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --sandbox) sandbox=1;    shift ;;
      -h|--help) return 0 ;;
      *) echo "driver_run: unknown arg $1" >&2; return 2 ;;
    esac
  done

  if ! command -v "$agy" >/dev/null 2>&1; then
    echo "agy not found on PATH (~/.local/bin/agy)" >&2
    return 127
  fi
  [ -f "$brief" ] || { echo "driver_run: brief not found: $brief" >&2; return 2; }
  [ -d "$dir" ]   || { echo "driver_run: dir not found: $dir" >&2; return 2; }
  dir="$(cd "$dir" && pwd)"
  log="${log:-${brief%.*}.log}"
  local phase_dir
  phase_dir="$(dirname "$log")"
  mkdir -p "$phase_dir"
  local result_json="$phase_dir/result.json"

  # stream-json, not json. Both end with the same result object, so everything
  # downstream reads exactly what it read before — but json emits that object and
  # nothing else, which meant a dispatch's turns, its per-step timings and its
  # per-step token spend were never produced at all, let alone kept. The stream
  # carries one line per step, each with duration_seconds and its own usage block.
  # That is the whole of the transcript and the trace, and it was being thrown away
  # because nobody asked agy for it.
  #
  # AGY_OUTPUT_FORMAT=json restores the old single-blob behaviour. The parser below
  # reads either shape, so switching back and forth is safe.
  local out_format="${AGY_OUTPUT_FORMAT:-stream-json}"
  local cmd=("$agy" --output-format "$out_format" "-p=$(cat "$brief")" --add-dir "$dir" --model "$model" --print-timeout "$timeout")
  case "$mode" in
    full)             cmd=("${cmd[@]+"${cmd[@]}"}" --dangerously-skip-permissions) ;;
    plan|accept-edits) cmd=("${cmd[@]+"${cmd[@]}"}" --mode "$mode") ;;
    *) echo "driver_run: bad --mode $mode" >&2; return 2 ;;
  esac
  [ -n "$effort" ]  && cmd=("${cmd[@]+"${cmd[@]}"}" --effort "$effort")
  [ -n "$sandbox" ] && cmd=("${cmd[@]+"${cmd[@]}"}" --sandbox)

  local start
  start=$(date +%s)
  local raw_output
  ( cd "$dir" && "${cmd[@]}" </dev/null 2>&1 | cat > "$log"; exit "${PIPESTATUS[0]}" )
  local rc=$?
  raw_output="$(cat "$log" 2>/dev/null || true)"

  rm -f "$result_json"

  # Keep the stream before the log is replaced by the response text.
  #
  # This is the change that makes a dispatch reconstructable. Until now the raw
  # output was overwritten a few lines below and the only surviving trace of a
  # worker's fifteen steps was a paragraph of prose and one total. Everything the
  # transcript and the waterfall need was produced, held in this variable, and
  # dropped.
  local stream_file="$phase_dir/stream.ndjson"
  rm -f "$stream_file"
  if [ "$out_format" = "stream-json" ] && [ -n "$raw_output" ]; then
    printf '%s\n' "$raw_output" > "$stream_file" 2>/dev/null || true
  fi

  # Deliberately narrow parser for agy's known JSON output shapes, not a general
  # JSON parser. Two shapes are accepted:
  #   json         one object:  {"conversation_id":...,"response":...,"usage":{...}}
  #   stream-json  many lines, the last of which wraps that same object:
  #                {"event":"result","result":{ ...the object above... }}
  # The stream also carries non-JSON lines — agy writes human-facing notices into
  # the same channel — so the candidate is selected, never assumed.
  local json_candidate
  json_candidate="$(printf '%s\n' "$raw_output" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -a '^{"event":"result"' | tail -1 || true)"
  if [ -n "$json_candidate" ]; then
    json_candidate="$(printf '%s\n' "$json_candidate" \
      | sed -n 's/^{"event":"result","result":\(.*\)}$/\1/p' || true)"
  fi
  if [ -z "$json_candidate" ]; then
    json_candidate="$(printf '%s\n' "$raw_output" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -a '^{' | grep -a '}$' | head -1 || true)"
  fi

  local extracted_response=""
  if [ -n "$json_candidate" ] && case "$json_candidate" in *'"response":'*) true ;; *) false ;; esac; then
    local resp_escaped
    resp_escaped="$(printf '%s\n' "$json_candidate" | sed -n 's/.*"response":"\(.*\)","duration_seconds":.*/\1/p' 2>/dev/null || true)"
    if [ -z "$resp_escaped" ]; then
      resp_escaped="$(printf '%s\n' "$json_candidate" | sed -n 's/.*"response":"\(.*\)","num_turns":.*/\1/p' 2>/dev/null || true)"
    fi
    if [ -z "$resp_escaped" ]; then
      resp_escaped="$(printf '%s\n' "$json_candidate" | sed -n 's/.*"response":"\(.*\)","usage":.*/\1/p' 2>/dev/null || true)"
    fi
    if [ -z "$resp_escaped" ]; then
      resp_escaped="$(printf '%s\n' "$json_candidate" | sed -n 's/.*"response":"\(.*\)","status":.*/\1/p' 2>/dev/null || true)"
    fi
    if [ -z "$resp_escaped" ]; then
      resp_escaped="$(printf '%s\n' "$json_candidate" | sed -n 's/.*"response":"\(.*\)"[},].*/\1/p' 2>/dev/null || true)"
    fi

    local resp_clean="${resp_escaped//\\\"/\"}"
    extracted_response="$(printf '%b' "$resp_clean")"
    printf '%s\n' "$json_candidate" > "$result_json" 2>/dev/null || true
  else
    extracted_response="$raw_output"
  fi

  printf '%s\n' "$extracted_response" > "$log"
  printf '\n--- agy-run: rc=%s elapsed=%ss brief=%s dir=%s ---\n' \
    "$rc" "$(( $(date +%s) - start ))" "$brief" "$dir" >> "$log"

  printf '%s\n' "$extracted_response"
  printf '\n--- agy-run: rc=%s elapsed=%ss brief=%s dir=%s ---\n' \
    "$rc" "$(( $(date +%s) - start ))" "$brief" "$dir"

  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    driver_run) shift; driver_run "$@" ;;
    driver_models) shift; driver_models "$@" ;;
    driver_capabilities) shift; driver_capabilities "$@" ;;
    *) echo "usage: $0 {driver_run|driver_models|driver_capabilities} [args...]" >&2; exit 2 ;;
  esac
fi
