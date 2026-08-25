#!/usr/bin/env bash
# Manage run-scoped pipeline state under <repo>/.agy/runs/<run-id>/.
#
#   run-dir.sh new    [--dir <repo>] [--task <s>] [--base <sha>] [--branch <name>]
#   run-dir.sh path   [--dir <repo>] [--run <id|current|last>]
#   run-dir.sh list   [--dir <repo>]
#   run-dir.sh show   [--dir <repo>] [--run <id|current|last>]
#
# Helper library for run-scoped state. Can be sourced by other scripts:
#   . "$HERE/run-dir.sh"
# or executed directly as a small CLI tool for inspection.
#
# Sourced functions:
#   run_dir_new [--dir <repo>] [--task <string>] [--base <sha>] [--branch <name>]
#   run_dir_resolve [--dir <repo>] [--run <id|current|last>]
#   run_dir_phase_dir <run-dir> <PHASE>
#   run_dir_record_phase <run-dir> <PHASE> <key=value>...
#   run_dir_get <run-dir> <dotted.key>
#   run_dir_phase_status <run-dir> <PHASE>
#   run_dir_finish <run-dir> <outcome>
#
# Layout owned:
#   <repo>/.agy/
#     runs/
#       <run-id>/
#         run.json
#         phases/
#           <PHASE>/
#             brief.md
#             verdict
#             status
#             log
#             verify.log
#             artifacts/
#         criteria/
#         REVIEW_DIFF.patch
#         REVIEW_DIFF.stat
#     current
#     last
#
# Exit codes:
#     0  fine
#     1  key or phase record absent (run_dir_get, run_dir_phase_status)
#     2  bad arguments
#     3  no such run
#     4  --dir is not a git work tree
#
# List ordering:
# `run-dir.sh list` outputs runs by run id descending. This is newest first
# whenever two runs started in different seconds, and is an arbitrary but
# stable order between runs that started in the same one.
#
# Why current and last are plain files:
# current and last are plain files holding the run id, one line, no trailing
# content. Not symlinks. Symlinks are the obvious choice and the wrong one:
# they behave differently on Windows and under Git Bash, and this repo already
# has a portability issue open about exactly that class of thing.
#
# Why run.json matters:
# check-phase-range.sh currently reconstructs what happened by testing whether
# four filenames exist, which is a guess about provenance. It cannot tell
# whether .tmp/DISCOVERY.md belongs to this task or to a run from three days
# ago on a different feature, and a stale discovery report is exactly the
# input that makes a worker improvise confidently. run.json answers the
# question directly: these phases completed, with these verdicts, on this task,
# at this base commit.
set -uo pipefail

# _run_dir_escape and _run_dir_unescape are a matched pair and must be changed together.
_run_dir_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# _run_dir_escape and _run_dir_unescape are a matched pair and must be changed together.
_run_dir_unescape() {
  local str="$1"
  local len=${#str}
  local out=""
  local i=0
  while [ $i -lt $len ]; do
    local c="${str:$i:1}"
    if [ "$c" = "\\" ] && [ $((i + 1)) -lt $len ]; then
      local next="${str:$((i + 1)):1}"
      case "$next" in
        '"') out="${out}\""; i=$((i + 2)) ;;
        \\) out="${out}\\"; i=$((i + 2)) ;; # Must match one backslash (not '\\' which is two)
        *) out="${out}$c"; i=$((i + 1)) ;;
      esac
    else
      out="${out}$c"
      i=$((i + 1))
    fi
  done
  printf '%s\n' "$out"
}

_run_json_serialize() {
  local in_file="$1"
  local out_file="$2"
  local tmp_out="${out_file}.tmp.$$"

  local run_val="" task_val="" backend_val="agy" branch_val="" base_val=""
  local worktree_val="" worktree_set=0
  local started_val="" finished_val="" outcome_val=""

  while IFS= read -r line || [ -n "$line" ]; do
    local k="${line%%=*}"
    local v="${line#*=}"
    case "$k" in
      run) run_val="$v" ;;
      task) task_val="$v" ;;
      backend) backend_val="$v" ;;
      branch) branch_val="$v" ;;
      base) base_val="$v" ;;
      worktree) worktree_val="$v"; worktree_set=1 ;;
      started) started_val="$v" ;;
      finished) finished_val="$v" ;;
      outcome) outcome_val="$v" ;;
    esac
  done < "$in_file"

  {
    printf '{\n'
    printf '  "run": "%s",\n' "$(_run_dir_escape "$run_val")"
    printf '  "task": "%s",\n' "$(_run_dir_escape "$task_val")"
    printf '  "backend": "%s",\n' "$(_run_dir_escape "$backend_val")"
    printf '  "branch": "%s",\n' "$(_run_dir_escape "$branch_val")"
    printf '  "base": "%s",\n' "$(_run_dir_escape "$base_val")"
    if [ $worktree_set -eq 1 ] && [ -n "$worktree_val" ]; then
      printf '  "worktree": "%s",\n' "$(_run_dir_escape "$worktree_val")"
    fi
    printf '  "started": "%s",\n' "$(_run_dir_escape "$started_val")"
    printf '  "finished": "%s",\n' "$(_run_dir_escape "$finished_val")"
    printf '  "outcome": "%s",\n' "$(_run_dir_escape "$outcome_val")"

    local phases
    phases="$(sed -n 's/^phases\.\([^.]*\)\..*/\1/p' "$in_file" 2>/dev/null | sort -u)"

    if [ -z "$phases" ]; then
      printf '  "phases": {}\n'
    else
      printf '  "phases": {\n'
      local phase_count
      phase_count="$(printf '%s\n' "$phases" | grep -c .)"
      local pi=0
      for ph in $phases; do
        pi=$((pi + 1))
        printf '    "%s": {\n' "$ph"
        local phase_lines
        phase_lines="$(sed -n "s/^phases\.$ph\.\(.*\)/\1/p" "$in_file" 2>/dev/null | sort -u)"
        local key_count
        key_count="$(printf '%s\n' "$phase_lines" | grep -c .)"
        local ki=0
        while IFS= read -r pline || [ -n "$pline" ]; do
          [ -z "$pline" ] && continue
          ki=$((ki + 1))
          local pk="${pline%%=*}"
          local pv="${pline#*=}"
          local comma=","
          [ $ki -eq $key_count ] && comma=""
          case "$pv" in
            ''|*[!0-9]*)
              printf '      "%s": "%s"%s\n' "$pk" "$(_run_dir_escape "$pv")" "$comma"
              ;;
            *)
              printf '      "%s": %s%s\n' "$pk" "$pv" "$comma"
              ;;
          esac
        done <<EOF
$phase_lines
EOF
        local pcomma=","
        [ $pi -eq $phase_count ] && pcomma=""
        printf '    }%s\n' "$pcomma"
      done
      printf '  }\n'
    fi
    printf '}\n'
  } > "$tmp_out"

  mv -f "$tmp_out" "$out_file"
}

_run_json_to_flat() {
  local json_file="$1"
  local flat_file="$2"
  local in_phases=0
  local current_phase=""

  > "$flat_file"

  while IFS= read -r line || [ -n "$line" ]; do
    local trimmed="${line#"${line%%[! ]*}"}"
    [ -z "$trimmed" ] && continue

    if [ "$trimmed" = '"phases": {' ] || [ "$trimmed" = '"phases": {}' ]; then
      in_phases=1
      continue
    fi

    if [ $in_phases -eq 0 ]; then
      for top_key in run task backend branch base worktree started finished outcome; do
        local prefix="\"$top_key\":"
        case "$trimmed" in
          "$prefix"*)
            local rest="${trimmed#"$prefix"}"
            rest="${rest#"${rest%%[! ]*}"}"
            rest="${rest%,}"
            if [ "${rest:0:1}" = '"' ] && [ "${rest: -1}" = '"' ]; then
              local raw="${rest:1:${#rest}-2}"
              printf '%s=%s\n' "$top_key" "$(_run_dir_unescape "$raw")" >> "$flat_file"
            else
              printf '%s=%s\n' "$top_key" "$rest" >> "$flat_file"
            fi
            break
            ;;
        esac
      done
    else
      if [ -z "$current_phase" ]; then
        if case "$trimmed" in *": {"*) true ;; *) false ;; esac; then
          current_phase="${trimmed%%\":*}"
          current_phase="${current_phase#\"}"
        elif [ "$trimmed" = '}' ]; then
          in_phases=0
        fi
      else
        if [ "$trimmed" = '}' ] || [ "$trimmed" = '},' ]; then
          current_phase=""
        else
          local pkey="${trimmed%%:*}"
          pkey="${pkey#\"}"
          pkey="${pkey%\"}"
          local rest="${trimmed#*:}"
          rest="${rest#"${rest%%[! ]*}"}"
          rest="${rest%,}"
          if [ "${rest:0:1}" = '"' ] && [ "${rest: -1}" = '"' ]; then
            local raw="${rest:1:${#rest}-2}"
            printf 'phases.%s.%s=%s\n' "$current_phase" "$pkey" "$(_run_dir_unescape "$raw")" >> "$flat_file"
          else
            printf 'phases.%s.%s=%s\n' "$current_phase" "$pkey" "$rest" >> "$flat_file"
          fi
        fi
      fi
    fi
  done < "$json_file"
}

_run_json_get_top() {
  local file="$1"
  local target_key="$2"
  local in_phases=0

  while IFS= read -r line || [ -n "$line" ]; do
    local trimmed="${line#"${line%%[! ]*}"}"
    if [ "$trimmed" = '"phases": {' ] || [ "$trimmed" = '"phases": {}' ]; then
      in_phases=1
      continue
    fi
    if [ $in_phases -eq 0 ]; then
      local prefix="\"$target_key\":"
      case "$trimmed" in
        "$prefix"*)
          local rest="${trimmed#"$prefix"}"
          rest="${rest#"${rest%%[! ]*}"}"
          rest="${rest%,}"
          if [ "${rest:0:1}" = '"' ] && [ "${rest: -1}" = '"' ]; then
            local raw="${rest:1:${#rest}-2}"
            _run_dir_unescape "$raw"
            return 0
          else
            printf '%s\n' "$rest"
            return 0
          fi
          ;;
      esac
    fi
  done < "$file"
  return 1
}

_run_json_get_phase() {
  local file="$1"
  local target_phase="$2"
  local target_field="$3"
  local in_phases=0
  local in_target_phase=0

  while IFS= read -r line || [ -n "$line" ]; do
    local trimmed="${line#"${line%%[! ]*}"}"
    if [ "$trimmed" = '"phases": {' ]; then
      in_phases=1
      continue
    fi
    if [ $in_phases -eq 1 ]; then
      if [ $in_target_phase -eq 0 ]; then
        if [ "$trimmed" = "\"$target_phase\": {" ]; then
          in_target_phase=1
          continue
        fi
        if [ "$trimmed" = '}' ]; then
          in_phases=0
          break
        fi
      else
        if [ "$trimmed" = '}' ] || [ "$trimmed" = '},' ]; then
          break
        fi
        local prefix="\"$target_field\":"
        case "$trimmed" in
          "$prefix"*)
            local rest="${trimmed#"$prefix"}"
            rest="${rest#"${rest%%[! ]*}"}"
            rest="${rest%,}"
            if [ "${rest:0:1}" = '"' ] && [ "${rest: -1}" = '"' ]; then
              local raw="${rest:1:${#rest}-2}"
              _run_dir_unescape "$raw"
              return 0
            else
              printf '%s\n' "$rest"
              return 0
            fi
            ;;
        esac
      fi
    fi
  done < "$file"
  return 1
}

run_dir_new() {
  local dir="$PWD"
  local task=""
  local base=""
  local branch=""
  local base_set=0
  local branch_set=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --base) base="$2"; base_set=1; shift 2 ;;
      --branch) branch="$2"; branch_set=1; shift 2 ;;
      -*) echo "run-dir: unknown arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
      *) echo "run-dir: unexpected arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
  done

  [ -d "$dir" ] || { echo "run-dir: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "run-dir: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }

  case "$task" in
    *$'\n'*)
      echo "run-dir: task string cannot contain newline" >&2
      return 2 2>/dev/null || exit 2
      ;;
  esac

  if [ $base_set -eq 0 ]; then
    base="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [ $branch_set -eq 0 ]; then
    branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  local run_id=""
  local run_dir=""

  while true; do
    local hex
    hex="$(printf '%04x' $(( (RANDOM ^ ($$ * 31 + $(date +%s 2>/dev/null || echo 0))) & 0xffff )) )"
    run_id="${ts}-${hex}"
    run_dir="$dir/.agy/runs/$run_id"
    if [ ! -e "$run_dir" ]; then
      break
    fi
  done

  mkdir -p "$run_dir/phases" "$run_dir/criteria" 2>/dev/null || {
    echo "run-dir: could not create run directory: $run_dir" >&2
    return 2 2>/dev/null || exit 2
  }

  local started
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local flat_tmp="$run_dir/.flat.tmp.$$"
  {
    printf 'run=%s\n' "$run_id"
    printf 'task=%s\n' "$task"
    printf 'backend=%s\n' "agy"
    printf 'branch=%s\n' "$branch"
    printf 'base=%s\n' "$base"
    printf 'started=%s\n' "$started"
    printf 'finished=\n'
    printf 'outcome=\n'
  } > "$flat_tmp"

  _run_json_serialize "$flat_tmp" "$run_dir/run.json"
  rm -f "$flat_tmp"

  mkdir -p "$dir/.agy" 2>/dev/null || true
  printf '%s\n' "$run_id" > "$dir/.agy/current"
  printf '%s\n' "$run_id" > "$dir/.agy/last"

  printf '%s\n' "$run_id"
  return 0
}

run_dir_resolve() {
  local dir="$PWD"
  local run_target="current"

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --run) run_target="$2"; shift 2 ;;
      -*) echo "run-dir: unknown arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
      *) echo "run-dir: unexpected arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
  done

  [ -d "$dir" ] || { echo "run-dir: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "run-dir: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }

  local run_id=""
  case "$run_target" in
    current|last)
      local ptr_file="$dir/.agy/$run_target"
      if [ ! -f "$ptr_file" ]; then
        echo "run-dir: no $run_target run" >&2
        return 3 2>/dev/null || exit 3
      fi
      run_id="$(head -n 1 "$ptr_file" 2>/dev/null | tr -d '\r\n')"
      if [ -z "$run_id" ]; then
        echo "run-dir: empty $run_target pointer" >&2
        return 3 2>/dev/null || exit 3
      fi
      ;;
    *)
      run_id="$run_target"
      ;;
  esac

  local target_dir="$dir/.agy/runs/$run_id"
  if [ -d "$target_dir" ]; then
    printf '%s\n' "$(cd "$target_dir" && pwd)"
    return 0
  else
    echo "run-dir: run not found: $run_id" >&2
    return 3 2>/dev/null || exit 3
  fi
}

run_dir_phase_dir() {
  local run_dir="${1:-}"
  local phase="${2:-}"

  [ -n "$run_dir" ] && [ -n "$phase" ] || {
    echo "run-dir: run_dir and phase required" >&2
    return 2 2>/dev/null || exit 2
  }
  [ -d "$run_dir" ] || {
    echo "run-dir: no such run: $run_dir" >&2
    return 3 2>/dev/null || exit 3
  }

  local pdir="$run_dir/phases/$phase"
  mkdir -p "$pdir" 2>/dev/null || {
    echo "run-dir: could not create phase directory: $pdir" >&2
    return 2 2>/dev/null || exit 2
  }
  printf '%s\n' "$(cd "$pdir" && pwd)"
  return 0
}

run_dir_record_phase() {
  local run_dir="${1:-}"
  local phase="${2:-}"
  shift 2 || true

  [ -n "$run_dir" ] && [ -n "$phase" ] && [ $# -gt 0 ] || {
    echo "run-dir: run_dir, phase, and at least one key=value required" >&2
    return 2 2>/dev/null || exit 2
  }
  [ -d "$run_dir" ] && [ -f "$run_dir/run.json" ] || {
    echo "run-dir: no such run: $run_dir" >&2
    return 3 2>/dev/null || exit 3
  }

  local pair
  for pair in "$@"; do
    case "$pair" in
      *=*) ;;
      *) echo "run-dir: invalid key=value format: $pair" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
    case "$pair" in
      *$'\n'*) echo "run-dir: value cannot contain newline" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
    local pk="${pair%%=*}"
    [ -n "$pk" ] || { echo "run-dir: key cannot be empty" >&2; return 2 2>/dev/null || exit 2; }
  done

  local flat_tmp="${run_dir}/.flat.tmp.$$"
  _run_json_to_flat "$run_dir/run.json" "$flat_tmp"

  for pair in "$@"; do
    local pk="${pair%%=*}"
    local pv="${pair#*=}"
    local target_k="phases.${phase}.${pk}"
    local clean_tmp="${run_dir}/.flat.clean.$$"
    grep -v "^${target_k}=" "$flat_tmp" > "$clean_tmp" 2>/dev/null || true
    mv -f "$clean_tmp" "$flat_tmp"
    printf '%s=%s\n' "$target_k" "$pv" >> "$flat_tmp"
  done

  _run_json_serialize "$flat_tmp" "$run_dir/run.json"
  rm -f "$flat_tmp"
  return 0
}

run_dir_get() {
  local run_dir="${1:-}"
  local key="${2:-}"

  [ -n "$run_dir" ] && [ -n "$key" ] || {
    echo "run-dir: run_dir and key required" >&2
    return 2 2>/dev/null || exit 2
  }
  [ -d "$run_dir" ] && [ -f "$run_dir/run.json" ] || return 1 2>/dev/null || exit 1

  case "$key" in
    phases.*.*)
      local sub="${key#phases.}"
      local phase="${sub%%.*}"
      local field="${sub#*.}"
      _run_json_get_phase "$run_dir/run.json" "$phase" "$field"
      return $?
      ;;
    phases.*)
      return 1 2>/dev/null || exit 1
      ;;
    run|task|backend|branch|base|worktree|started|finished|outcome)
      _run_json_get_top "$run_dir/run.json" "$key"
      return $?
      ;;
    *)
      return 1 2>/dev/null || exit 1
      ;;
  esac
}

run_dir_phase_status() {
  local run_dir="${1:-}"
  local phase="${2:-}"

  [ -n "$run_dir" ] && [ -n "$phase" ] || {
    echo "run-dir: run_dir and phase required" >&2
    return 2 2>/dev/null || exit 2
  }
  run_dir_get "$run_dir" "phases.${phase}.status"
  return $?
}

run_dir_finish() {
  local run_dir="${1:-}"
  local outcome="${2:-}"

  [ -n "$run_dir" ] && [ -n "$outcome" ] || {
    echo "run-dir: run_dir and outcome required" >&2
    return 2 2>/dev/null || exit 2
  }
  [ -d "$run_dir" ] && [ -f "$run_dir/run.json" ] || {
    echo "run-dir: no such run: $run_dir" >&2
    return 3 2>/dev/null || exit 3
  }
  case "$outcome" in
    *$'\n'*) echo "run-dir: outcome cannot contain newline" >&2; return 2 2>/dev/null || exit 2 ;;
  esac

  local finished_ts
  finished_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local flat_tmp="${run_dir}/.flat.tmp.$$"
  _run_json_to_flat "$run_dir/run.json" "$flat_tmp"

  local clean_tmp="${run_dir}/.flat.clean.$$"
  grep -v "^finished=" "$flat_tmp" | grep -v "^outcome=" > "$clean_tmp" 2>/dev/null || true
  mv -f "$clean_tmp" "$flat_tmp"

  printf 'finished=%s\n' "$finished_ts" >> "$flat_tmp"
  printf 'outcome=%s\n' "$outcome" >> "$flat_tmp"

  _run_json_serialize "$flat_tmp" "$run_dir/run.json"
  rm -f "$flat_tmp"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  CMD="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$CMD" in
    new)
      run_dir_new "$@"
      exit $?
      ;;
    path)
      run_dir_resolve "$@"
      exit $?
      ;;
    list)
      DIR="$PWD"
      while [ $# -gt 0 ]; do
        case "$1" in
          --dir) DIR="$2"; shift 2 ;;
          -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
          -*) echo "run-dir: unknown arg $1" >&2; exit 2 ;;
          *) echo "run-dir: unexpected arg $1" >&2; exit 2 ;;
        esac
      done
      [ -d "$DIR" ] || { echo "run-dir: dir not found: $DIR" >&2; exit 2; }
      DIR="$(cd "$DIR" && pwd)"
      git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "run-dir: not a git repository: $DIR" >&2
        exit 4
      }
      if [ -d "$DIR/.agy/runs" ]; then
        for R in $(ls -1r "$DIR/.agy/runs" 2>/dev/null); do
          [ -d "$DIR/.agy/runs/$R" ] && printf '%s\n' "$R"
        done
      fi
      exit 0
      ;;
    show)
      TARGET_RUN_DIR="$(run_dir_resolve "$@")" || exit $?
      if [ -f "$TARGET_RUN_DIR/run.json" ]; then
        cat "$TARGET_RUN_DIR/run.json"
        exit 0
      else
        echo "run-dir: run.json not found in $TARGET_RUN_DIR" >&2
        exit 3
      fi
      ;;
    -h|--help)
      sed -n '2,35p' "$0"
      exit 0
      ;;
    "")
      echo "run-dir: command required (new|path|list|show)" >&2
      exit 2
      ;;
    *)
      echo "run-dir: unknown command $CMD (want new|path|list|show)" >&2
      exit 2
      ;;
  esac
fi
