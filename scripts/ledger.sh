#!/usr/bin/env bash
# Manage the run ledger across dispatches under <repo>/.agy/ledger.jsonl.
#
#   ledger.sh append [--dir <repo>] <key=value>...
#   ledger.sh path   [--dir <repo>]
#
# Sourced functions:
#   ledger_append <repo> <key=value>...
#   ledger_path   <repo>
#
# Exit codes:
#     0  fine
#     2  bad arguments
#     4  --dir is not a git work tree
#
# Schema notes:
# One JSON object per line, one line per dispatch in <repo>/.agy/ledger.jsonl.
# Append-only. Never rewritten, never truncated, never sorted.
# Values containing newlines are flattened to preserve the single-line invariant.
# Task strings are hashed by default as task_id (first 12 chars of git hash-object)
# for privacy; set AGY_LEDGER_TASK=plain to record literal task strings.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

ledger_path() {
  local dir="${1:-$PWD}"
  [ -d "$dir" ] || { echo "ledger: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ledger: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  printf '%s/.agy/ledger.jsonl\n' "$dir"
  return 0
}

_ledger_spent_tokens() {
  local dir="${1:-$PWD}"
  local run_id="${2:-}"
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  dir="$(cd "$dir" 2>/dev/null && pwd || echo "$dir")"
  local ledger="$dir/.agy/ledger.jsonl"
  [ -f "$ledger" ] || { printf '0\n'; return 0; }
  [ -n "$run_id" ] || { printf '0\n'; return 0; }

  local sum=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"\"run\":\"$run_id\""*)
        local tt
        tt="$(printf '%s\n' "$line" | sed -n 's/.*"total_tokens":\([0-9][0-9]*\).*/\1/p' 2>/dev/null || true)"
        if [ -n "$tt" ]; then
          sum=$((sum + tt))
        fi
        ;;
    esac
  done < "$ledger"
  printf '%s\n' "$sum"
  return 0
}

_ledger_extract_diff() {
  local dir="${1:-}"
  local run_target="${2:-}"
  local run_dir=""

  if [ -n "$run_target" ]; then
    if [ -d "$run_target" ]; then
      run_dir="$(cd "$run_target" && pwd)"
    else
      run_dir="$(run_dir_resolve --dir "$dir" --run "$run_target" 2>/dev/null || true)"
    fi
  elif [ -n "$dir" ]; then
    if [ -d "$dir" ] && { [ -f "$dir/run.json" ] || [ -d "$dir/phases" ]; }; then
      run_dir="$(cd "$dir" && pwd)"
    elif [ -d "$dir" ]; then
      run_dir="$(run_dir_resolve --dir "$dir" --run current 2>/dev/null || true)"
    else
      run_dir="$(run_dir_resolve --run "$dir" 2>/dev/null || true)"
    fi
  fi

  [ -n "$run_dir" ] && [ -d "$run_dir" ] || return 1

  if [ ! -f "$run_dir/REVIEW_DIFF.stat" ] && [ ! -f "$run_dir/REVIEW_DIFF.patch" ]; then
    return 1
  fi

  local files=0 insertions=0 deletions=0 truncated="false"

  if [ -f "$run_dir/REVIEW_DIFF.patch" ]; then
    local f_line i_line
    f_line="$(sed -n 's/^# files changed: *\([0-9]*\).*/\1/p' "$run_dir/REVIEW_DIFF.patch" 2>/dev/null | head -1)"
    [ -n "$f_line" ] && files="$f_line"
    i_line="$(sed -n 's/^# changed lines:.*(+\([0-9]*\) \/ -\([0-9]*\)).*/\1 \2/p' "$run_dir/REVIEW_DIFF.patch" 2>/dev/null | head -1)"
    if [ -n "$i_line" ]; then
      insertions="$(printf '%s' "$i_line" | awk '{print $1}')"
      deletions="$(printf '%s' "$i_line" | awk '{print $2}')"
    fi
    if grep -q -E '^#[[:space:]]*TRUNCATED:' "$run_dir/REVIEW_DIFF.patch" 2>/dev/null; then
      truncated="true"
    fi
  fi

  files="${files:-0}"; insertions="${insertions:-0}"; deletions="${deletions:-0}"
  printf '{"files":%s,"insertions":%s,"deletions":%s,"truncated":%s}\n' "$files" "$insertions" "$deletions" "$truncated"
  return 0
}

_ledger_extract_review() {
  local dir="${1:-}"
  local run_target="${2:-}"
  local run_dir=""
  local run_id=""

  if [ -n "$run_target" ]; then
    if [ -d "$run_target" ]; then
      run_dir="$(cd "$run_target" && pwd)"
      if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        dir="$(cd "$run_dir/../../.." && pwd 2>/dev/null || true)"
      else
        dir="$(cd "$dir" && pwd)"
      fi
      run_id="$(run_dir_get "$run_dir" "run" 2>/dev/null || basename "$run_dir")"
    else
      [ -d "$dir" ] || return 1
      dir="$(cd "$dir" && pwd)"
      run_id="$run_target"
      run_dir="$(run_dir_resolve --dir "$dir" --run "$run_id" 2>/dev/null || true)"
    fi
  elif [ -n "$dir" ]; then
    if [ -d "$dir" ] && { [ -f "$dir/run.json" ] || [ -d "$dir/phases" ]; }; then
      run_dir="$(cd "$dir" && pwd)"
      dir="$(cd "$run_dir/../../.." && pwd 2>/dev/null || true)"
      run_id="$(run_dir_get "$run_dir" "run" 2>/dev/null || basename "$run_dir")"
    elif [ -d "$dir" ]; then
      dir="$(cd "$dir" && pwd)"
      run_dir="$(run_dir_resolve --dir "$dir" --run current 2>/dev/null || true)"
      [ -n "$run_dir" ] && run_id="$(run_dir_get "$run_dir" "run" 2>/dev/null || basename "$run_dir")"
    else
      run_id="$dir"
      run_dir="$(run_dir_resolve --run "$run_id" 2>/dev/null || true)"
      [ -n "$run_dir" ] && dir="$(cd "$run_dir/../../.." && pwd 2>/dev/null || true)"
    fi
  fi

  [ -n "$run_dir" ] && [ -d "$run_dir" ] || return 1
  [ -n "$run_id" ] || return 1
  [ -d "$dir" ] || return 1

  if [ ! -f "$run_dir/REVIEW_FEEDBACK.md" ]; then
    return 1
  fi

  local check_sh="$HERE/check-review.sh"
  if [ ! -f "$check_sh" ]; then
    return 1
  fi

  # The run id is the identifier and paths are never rebuilt beside it, so this does not regrow.
  local out
  out="$("$check_sh" --dir "$dir" --run "$run_id" 2>/dev/null || true)"
  local rev_status
  rev_status="$(printf '%s' "${out#STATUS: }" | awk '{print $1}')"
  rev_status="${rev_status%%(*}"
  [ -n "$rev_status" ] || return 1

  local anchors=""
  local anch_line
  anch_line="$(printf '%s\n' "$out" | tr '|' '\n' | grep -E '^[[:space:]]*Anchors:[[:space:]]*[0-9]+' 2>/dev/null | head -1)"
  if [ -n "$anch_line" ]; then
    anchors="$(printf '%s\n' "$anch_line" | sed -e 's/^[[:space:]]*Anchors:[[:space:]]*//' | awk '{print $1}')"
  else
    local thin_match
    thin_match="$(printf '%s\n' "$out" | sed -n 's/.*anchors=\([0-9][0-9]*\).*/\1/p' 2>/dev/null | head -1)"
    if [ -n "$thin_match" ]; then
      anchors="$(printf '%s\n' "$thin_match" | sed 's/[^0-9].*//')"
    fi
  fi

  if [ -n "$anchors" ]; then
    printf '{"anchors":%s,"status":"%s"}\n' "$anchors" "$(_run_dir_escape "$rev_status")"
  else
    printf '{"status":"%s"}\n' "$(_run_dir_escape "$rev_status")"
  fi
  return 0
}

# Append a single-line JSON record to <repo>/.agy/ledger.jsonl.
# A ledger record is a side effect of a dispatch that already happened.
# Refusing to record it does not undo the dispatch — it loses the evidence of it,
# which is the one thing the ledger exists to keep. A run.json value may be refused,
# because that refusal happens before a run is minted and the caller can fix the input.
# A ledger append has no such moment. So: replace every newline (and carriage return)
# in a value with a single space before escaping, collapse runs of resulting whitespace,
# and write the record.
ledger_append() {
  local dir="${1:-}"
  shift || true

  [ -n "$dir" ] && [ $# -gt 0 ] || {
    echo "ledger: repo directory and at least one key=value required" >&2
    return 2 2>/dev/null || exit 2
  }

  [ -d "$dir" ] || { echo "ledger: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ledger: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }

  local run_val="" phase_val="" attempt_val="" tier_val="" model_val=""
  local backend_val="agy" started_val="" elapsed_s_val="" worker_rc_val=""
  local verdict_val="" verify_ran_val="" verify_rc_val="" status_val=""
  local retries_spent_val="" retries_refunded_val="" task_val="" task_id_val=""
  local diff_val="" review_val=""
  local usage_val="" num_turns_val="" agy_status_val=""

  local has_elapsed=0 has_worker_rc=0 has_verdict=0 has_verify_rc=0
  local has_diff=0 has_review=0 has_attempt=0 has_retries_spent=0 has_retries_refunded=0
  local has_verify_ran=0 has_usage=0 has_num_turns=0 has_agy_status=0

  for pair in "$@"; do
    case "$pair" in
      *=*) ;;
      *) echo "ledger: invalid key=value format: $pair" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
    local k="${pair%%=*}"
    local v="${pair#*=}"
    [ -n "$k" ] || { echo "ledger: key cannot be empty" >&2; return 2 2>/dev/null || exit 2; }

    # Replace newlines and carriage returns with a space and collapse runs of spaces.
    v="${v//$'\r'/ }"
    v="${v//$'\n'/ }"
    while case "$v" in *"  "*) true ;; *) false ;; esac; do
      v="${v//  / }"
    done

    case "$k" in
      run) run_val="$v" ;;
      phase) phase_val="$v" ;;
      attempt) attempt_val="$v"; has_attempt=1 ;;
      tier) tier_val="$v" ;;
      model) model_val="$v" ;;
      backend) backend_val="$v" ;;
      started) started_val="$v" ;;
      elapsed_s) elapsed_s_val="$v"; has_elapsed=1 ;;
      worker_rc) worker_rc_val="$v"; has_worker_rc=1 ;;
      verdict) verdict_val="$v"; has_verdict=1 ;;
      verify_ran) verify_ran_val="$v"; has_verify_ran=1 ;;
      verify_rc) verify_rc_val="$v"; has_verify_rc=1 ;;
      status) status_val="$v" ;;
      retries_spent) retries_spent_val="$v"; has_retries_spent=1 ;;
      retries_refunded) retries_refunded_val="$v"; has_retries_refunded=1 ;;
      task) task_val="$v" ;;
      task_id) task_id_val="$v" ;;
      diff) diff_val="$v"; has_diff=1 ;;
      review) review_val="$v"; has_review=1 ;;
      usage) usage_val="$v"; has_usage=1 ;;
      num_turns) num_turns_val="$v"; has_num_turns=1 ;;
      agy_status) agy_status_val="$v"; has_agy_status=1 ;;
    esac
  done

  local privacy_opt="${AGY_LEDGER_TASK:-hash}"
  local task_field=""
  if [ "$privacy_opt" = "plain" ]; then
    if [ -n "$task_val" ]; then
      task_field="\"task\":\"$(_run_dir_escape "$task_val")\""
    elif [ -n "$task_id_val" ]; then
      task_field="\"task\":\"$(_run_dir_escape "$task_id_val")\""
    fi
  else
    if [ -n "$task_id_val" ]; then
      task_field="\"task_id\":\"$(_run_dir_escape "$task_id_val")\""
    elif [ -n "$task_val" ]; then
      local tid
      tid="$(printf '%s' "$task_val" | git -C "$dir" hash-object --stdin 2>/dev/null | cut -c 1-12)"
      task_field="\"task_id\":\"$tid\""
    fi
  fi

  local fields=()

  [ -n "$run_val" ] && fields[${#fields[@]}]="\"run\":\"$(_run_dir_escape "$run_val")\""
  [ -n "$phase_val" ] && fields[${#fields[@]}]="\"phase\":\"$(_run_dir_escape "$phase_val")\""
  if [ $has_attempt -eq 1 ]; then
    fields[${#fields[@]}]="\"attempt\":${attempt_val:-1}"
  fi
  [ -n "$tier_val" ] && fields[${#fields[@]}]="\"tier\":\"$(_run_dir_escape "$tier_val")\""
  [ -n "$model_val" ] && fields[${#fields[@]}]="\"model\":\"$(_run_dir_escape "$model_val")\""
  [ -n "$backend_val" ] && fields[${#fields[@]}]="\"backend\":\"$(_run_dir_escape "$backend_val")\""
  [ -n "$started_val" ] && fields[${#fields[@]}]="\"started\":\"$(_run_dir_escape "$started_val")\""

  if [ $has_elapsed -eq 1 ] && [ -n "$elapsed_s_val" ]; then
    fields[${#fields[@]}]="\"elapsed_s\":$elapsed_s_val"
  fi
  if [ $has_worker_rc -eq 1 ] && [ -n "$worker_rc_val" ]; then
    fields[${#fields[@]}]="\"worker_rc\":$worker_rc_val"
  fi
  if [ $has_verdict -eq 1 ] && [ -n "$verdict_val" ]; then
    fields[${#fields[@]}]="\"verdict\":\"$(_run_dir_escape "$verdict_val")\""
  fi
  if [ $has_verify_ran -eq 1 ]; then
    case "$verify_ran_val" in
      true|TRUE|1) fields[${#fields[@]}]="\"verify_ran\":true" ;;
      *) fields[${#fields[@]}]="\"verify_ran\":false" ;;
    esac
  fi
  if [ $has_verify_rc -eq 1 ] && [ -n "$verify_rc_val" ]; then
    fields[${#fields[@]}]="\"verify_rc\":$verify_rc_val"
  fi
  [ -n "$status_val" ] && fields[${#fields[@]}]="\"status\":\"$(_run_dir_escape "$status_val")\""
  if [ $has_retries_spent -eq 1 ]; then
    fields[${#fields[@]}]="\"retries_spent\":${retries_spent_val:-0}"
  fi
  if [ $has_retries_refunded -eq 1 ]; then
    fields[${#fields[@]}]="\"retries_refunded\":${retries_refunded_val:-0}"
  fi
  [ -n "$task_field" ] && fields[${#fields[@]}]="$task_field"

  if [ $has_usage -eq 1 ] && [ -n "$usage_val" ]; then
    fields[${#fields[@]}]="\"usage\":$usage_val"
  fi
  if [ $has_num_turns -eq 1 ] && [ -n "$num_turns_val" ]; then
    fields[${#fields[@]}]="\"num_turns\":$num_turns_val"
  fi
  if [ $has_agy_status -eq 1 ] && [ -n "$agy_status_val" ]; then
    fields[${#fields[@]}]="\"agy_status\":\"$(_run_dir_escape "$agy_status_val")\""
  fi

  if [ $has_diff -eq 1 ] && [ -n "$diff_val" ]; then
    fields[${#fields[@]}]="\"diff\":$diff_val"
  fi
  if [ $has_review -eq 1 ] && [ -n "$review_val" ]; then
    fields[${#fields[@]}]="\"review\":$review_val"
  fi

  local json_line="{"
  local first=1
  for f in "${fields[@]+"${fields[@]}"}"; do
    if [ $first -eq 1 ]; then
      json_line="${json_line}${f}"
      first=0
    else
      json_line="${json_line},${f}"
    fi
  done
  json_line="${json_line}}"

  mkdir -p "$dir/.agy" 2>/dev/null || {
    echo "ledger: could not create .agy directory in $dir" >&2
    return 2 2>/dev/null || exit 2
  }

  printf '%s\n' "$json_line" >> "$dir/.agy/ledger.jsonl" 2>/dev/null || {
    echo "ledger: could not write to $dir/.agy/ledger.jsonl" >&2
    return 2 2>/dev/null || exit 2
  }

  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  CMD="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$CMD" in
    append)
      DIR="$PWD"
      KEY_VALUES=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --dir) DIR="$2"; shift 2 ;;
          -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
          -*) echo "ledger: unknown arg $1" >&2; exit 2 ;;
          *=*) KEY_VALUES[${#KEY_VALUES[@]}]="$1"; shift ;;
          *)
            if [ -d "$1" ]; then
              DIR="$1"; shift
            else
              echo "ledger: unexpected arg $1" >&2; exit 2
            fi
            ;;
        esac
      done
      ledger_append "$DIR" "${KEY_VALUES[@]+"${KEY_VALUES[@]}"}"
      exit $?
      ;;
    path)
      DIR="$PWD"
      while [ $# -gt 0 ]; do
        case "$1" in
          --dir) DIR="$2"; shift 2 ;;
          -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
          -*) echo "ledger: unknown arg $1" >&2; exit 2 ;;
          *) DIR="$1"; shift ;;
        esac
      done
      ledger_path "$DIR"
      exit $?
      ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    "")
      echo "ledger: command required (append|path)" >&2
      exit 2
      ;;
    *)
      echo "ledger: unknown command $CMD (want append|path)" >&2
      exit 2
      ;;
  esac
fi
