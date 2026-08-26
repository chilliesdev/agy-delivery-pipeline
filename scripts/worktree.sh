#!/usr/bin/env bash
# Manage run-scoped git worktrees under <repo>/.agy/worktrees/<run-id>.
#
#   worktree.sh add    --run <id> [--dir <repo>] [--branch <name>] [--base <ref>]
#   worktree.sh path   --run <id> [--dir <repo>]
#   worktree.sh list   [--dir <repo>]
#   worktree.sh remove --run <id> [--dir <repo>] [--force]
#
# Sourced functions:
#   worktree_add    --run <id> [--dir <repo>] [--branch <name>] [--base <ref>]
#   worktree_path   --run <id> [--dir <repo>]
#   worktree_list   [--dir <repo>]
#   worktree_remove --run <id> [--dir <repo>] [--force]
#
# Layout owned:
#   <repo>/.agy/
#     worktrees/
#       <run-id>/          isolated git worktree checked out on run branch
#     runs/
#       <run-id>/
#         worktree         path to the run's worktree (sidecar file; run.json is authoritative)
#
# Exit codes:
#     0  fine / success (worktree added, path resolved, list completed, worktree removed)
#     1  worktree absent / not found for run (worktree_path)
#     2  bad arguments (missing required flags, unknown flags, invalid options)
#     3  no such run (run directory does not exist)
#     4  --dir is not a git work tree, or git operation failed
#     5  a worktree already exists for this run
#     6  the branch is already checked out somewhere else
#     7  refusing to remove (unfinished run, failed run without --force, or dirty worktree without --force)
#
# Why one worktree per run:
# Runs were previously serialised only because every run wrote into the same
# working tree and the same state directory, clobbering each other's diffs.
# Run state is run-scoped under .agy/runs/<run-id>/, and giving each run its own
# git worktree allows multiple runs to proceed in parallel without collisions.
#
# Main repository vs worktree separation:
# A worktree holds the working code being changed for that run. Run state
# (briefs, verdicts, logs, diffs, metadata) belongs in the main repository's
# state directory (<repo>/.agy/runs/<run-id>/) and NEVER inside the worktree.
# Worktrees are deleted upon completion or cleanup, while run state is the
# persistent record of the run.
#
# Metadata and authoritative record:
# When a worktree is created, its location is recorded as the "worktree" field in
# run.json alongside "branch", and removed when the worktree is removed. run.json
# is the authoritative source for run metadata (accessed via run_dir_get). The
# sidecar file .agy/runs/<run-id>/worktree is maintained in sync for compatibility.
#
# Branch semantics and ancestry:
# Creating a worktree overwrites the "branch" recorded in run.json at mint time.
# The branch field means the branch the run's work is currently on rather than
# the branch it was started from. The "base" commit SHA recorded in run.json is
# what preserves the ancestry.
#
# What remove refuses:
# 1. Unfinished runs (finished field empty): worker may still be writing.
#    Refused unconditionally (even with --force).
# 2. Failed runs (outcome is not SUCCESS/DONE/PASSED/OK): edits are critical
#    debugging evidence. Refused by default, overridable with --force.
# 3. Dirty worktrees (uncommitted edits or untracked files): prevents silent
#    data loss. Refused by default, overridable with --force.
#
# Branch persistence:
# Removing a worktree never deletes the git branch it was on. The commits made
# during the run remain available in the repository.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

_worktree_record_meta() {
  local run_dir="$1"
  local branch="$2"
  local wt_path="$3"

  printf '%s\n' "$wt_path" > "$run_dir/worktree"

  if [ -f "$run_dir/run.json" ]; then
    local flat_tmp="${run_dir}/.flat.tmp.$$"
    _run_json_to_flat "$run_dir/run.json" "$flat_tmp"
    local clean_tmp="${run_dir}/.flat.clean.$$"
    grep -v "^branch=" "$flat_tmp" | grep -v "^worktree=" > "$clean_tmp" 2>/dev/null || true
    mv -f "$clean_tmp" "$flat_tmp"
    printf 'branch=%s\n' "$branch" >> "$flat_tmp"
    printf 'worktree=%s\n' "$wt_path" >> "$flat_tmp"
    _run_json_serialize "$flat_tmp" "$run_dir/run.json"
    rm -f "$flat_tmp"
  fi
}

_worktree_clear_meta() {
  local run_dir="$1"

  rm -f "$run_dir/worktree"

  if [ -f "$run_dir/run.json" ]; then
    local flat_tmp="${run_dir}/.flat.tmp.$$"
    _run_json_to_flat "$run_dir/run.json" "$flat_tmp"
    local clean_tmp="${run_dir}/.flat.clean.$$"
    grep -v "^worktree=" "$flat_tmp" > "$clean_tmp" 2>/dev/null || true
    mv -f "$clean_tmp" "$flat_tmp"
    _run_json_serialize "$flat_tmp" "$run_dir/run.json"
    rm -f "$flat_tmp"
  fi
}

worktree_add() {
  local dir="$PWD"
  local run_id=""
  local branch=""
  local base=""
  local branch_set=0
  local base_set=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --run) run_id="$2"; shift 2 ;;
      --branch) branch="$2"; branch_set=1; shift 2 ;;
      --base) base="$2"; base_set=1; shift 2 ;;
      -h|--help) sed -n '2,68p' "${BASH_SOURCE[0]}"; return 0 2>/dev/null || exit 0 ;;
      -*) echo "worktree: unknown arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
      *) echo "worktree: unexpected arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
  done

  [ -n "$run_id" ] || {
    echo "worktree: --run is required" >&2
    return 2 2>/dev/null || exit 2
  }

  [ -d "$dir" ] || { echo "worktree: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  local root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  root="$(cd "$root" && pwd)"

  local run_dir="$root/.agy/runs/$run_id"
  [ -d "$run_dir" ] || {
    echo "worktree: no such run: $run_id" >&2
    return 3 2>/dev/null || exit 3
  }

  local wt_path="$root/.agy/worktrees/$run_id"
  local existing_wt
  existing_wt="$(run_dir_get "$run_dir" "worktree" 2>/dev/null || true)"
  if [ -e "$wt_path" ] || [ -f "$run_dir/worktree" ] || [ -n "$existing_wt" ]; then
    echo "STATUS: WORKTREE_EXISTS | Run: $run_id | Path: $wt_path | Note: a worktree already exists for this run" >&2
    return 5 2>/dev/null || exit 5
  fi

  if [ $branch_set -eq 0 ]; then
    branch="agy/$run_id"
  fi

  if [ $base_set -eq 0 ]; then
    base="$(run_dir_get "$run_dir" "base" 2>/dev/null || true)"
    if [ -z "$base" ]; then
      base="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
    fi
  fi

  [ -n "$base" ] || {
    echo "worktree: could not resolve base ref" >&2
    return 2 2>/dev/null || exit 2
  }

  git -C "$root" rev-parse --verify -q "$base" >/dev/null 2>&1 || {
    echo "worktree: base ref not found: $base" >&2
    return 2 2>/dev/null || exit 2
  }

  # Check if branch is already checked out somewhere else
  if git -C "$root" worktree list --porcelain 2>/dev/null | grep -q "^branch refs/heads/$branch\$"; then
    echo "STATUS: BRANCH_CHECKED_OUT | Branch: $branch | Note: the branch is already checked out somewhere else" >&2
    return 6 2>/dev/null || exit 6
  fi

  mkdir -p "$root/.agy/worktrees" 2>/dev/null || {
    echo "worktree: could not create worktrees directory: $root/.agy/worktrees" >&2
    return 2 2>/dev/null || exit 2
  }

  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add -q "$wt_path" "$branch" 2>/dev/null || {
      echo "worktree: git worktree add failed for branch $branch" >&2
      return 4 2>/dev/null || exit 4
    }
  else
    git -C "$root" worktree add -q -b "$branch" "$wt_path" "$base" 2>/dev/null || {
      echo "worktree: git worktree add -b failed for branch $branch at $base" >&2
      return 4 2>/dev/null || exit 4
    }
  fi

  _worktree_record_meta "$run_dir" "$branch" "$wt_path"

  echo "STATUS: WORKTREE_ADDED | Run: $run_id | Branch: $branch | Base: $base | Path: $wt_path | Note: worktree created for run $run_id" >&2
  printf '%s\n' "$wt_path"
  return 0
}

worktree_path() {
  local dir="$PWD"
  local run_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --run) run_id="$2"; shift 2 ;;
      -h|--help) sed -n '2,68p' "${BASH_SOURCE[0]}"; return 0 2>/dev/null || exit 0 ;;
      -*) echo "worktree: unknown arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
      *) echo "worktree: unexpected arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
  done

  [ -n "$run_id" ] || {
    echo "worktree: --run is required" >&2
    return 2 2>/dev/null || exit 2
  }

  [ -d "$dir" ] || { echo "worktree: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  local root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  root="$(cd "$root" && pwd)"

  local run_dir="$root/.agy/runs/$run_id"
  [ -d "$run_dir" ] || {
    echo "worktree: no such run: $run_id" >&2
    return 3 2>/dev/null || exit 3
  }

  local wt_path=""
  wt_path="$(run_dir_get "$run_dir" "worktree" 2>/dev/null || true)"
  if [ -z "$wt_path" ] && [ -f "$run_dir/worktree" ]; then
    wt_path="$(head -n 1 "$run_dir/worktree" 2>/dev/null | tr -d '\r\n')"
  fi
  if [ -z "$wt_path" ]; then
    wt_path="$root/.agy/worktrees/$run_id"
  fi

  if [ -d "$wt_path" ]; then
    printf '%s\n' "$wt_path"
    return 0
  else
    echo "worktree: no worktree found for run: $run_id" >&2
    return 1 2>/dev/null || exit 1
  fi
}

worktree_list() {
  local dir="$PWD"

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      -h|--help) sed -n '2,68p' "${BASH_SOURCE[0]}"; return 0 2>/dev/null || exit 0 ;;
      -*) echo "worktree: unknown arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
      *) echo "worktree: unexpected arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
  done

  [ -d "$dir" ] || { echo "worktree: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  local root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  root="$(cd "$root" && pwd)"

  if [ -d "$root/.agy/runs" ]; then
    # shellcheck disable=SC2045 # ls -1r needed for reverse-chronological ordering of runs
    for r in $(ls -1r "$root/.agy/runs" 2>/dev/null); do
      local rdir="$root/.agy/runs/$r"
      [ -d "$rdir" ] || continue
      local wt_path=""
      wt_path="$(run_dir_get "$rdir" "worktree" 2>/dev/null || true)"
      if [ -z "$wt_path" ] && [ -f "$rdir/worktree" ]; then
        wt_path="$(head -n 1 "$rdir/worktree" 2>/dev/null | tr -d '\r\n')"
      fi
      if [ -z "$wt_path" ]; then
        wt_path="$root/.agy/worktrees/$r"
      fi
      if [ -d "$wt_path" ]; then
        printf '%s\n' "$r"
      fi
    done
  fi
  return 0
}

worktree_remove() {
  local dir="$PWD"
  local run_id=""
  local force=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --run) run_id="$2"; shift 2 ;;
      --force|-f) force=1; shift ;;
      -h|--help) sed -n '2,68p' "${BASH_SOURCE[0]}"; return 0 2>/dev/null || exit 0 ;;
      -*) echo "worktree: unknown arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
      *) echo "worktree: unexpected arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
  done

  [ -n "$run_id" ] || {
    echo "worktree: --run is required" >&2
    return 2 2>/dev/null || exit 2
  }

  [ -d "$dir" ] || { echo "worktree: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  local root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "worktree: not a git repository: $dir" >&2
    return 4 2>/dev/null || exit 4
  }
  root="$(cd "$root" && pwd)"

  local run_dir="$root/.agy/runs/$run_id"
  [ -d "$run_dir" ] || {
    echo "worktree: no such run: $run_id" >&2
    return 3 2>/dev/null || exit 3
  }

  local wt_path=""
  wt_path="$(run_dir_get "$run_dir" "worktree" 2>/dev/null || true)"
  if [ -z "$wt_path" ] && [ -f "$run_dir/worktree" ]; then
    wt_path="$(head -n 1 "$run_dir/worktree" 2>/dev/null | tr -d '\r\n')"
  fi
  if [ -z "$wt_path" ]; then
    wt_path="$root/.agy/worktrees/$run_id"
  fi

  if [ ! -d "$wt_path" ]; then
    echo "worktree: no worktree found for run: $run_id" >&2
    return 1 2>/dev/null || exit 1
  fi

  # Refusal 1: Run has not finished (worker may still be writing)
  local finished
  finished="$(run_dir_get "$run_dir" "finished" 2>/dev/null || true)"
  if [ -z "$finished" ]; then
    echo "STATUS: WORKTREE_REFUSED_UNFINISHED | Run: $run_id | Path: $wt_path | Note: run has not finished; refusing to remove worktree while worker may still be writing" >&2
    return 7 2>/dev/null || exit 7
  fi

  # Refusal 2: Run finished badly (failed run)
  local outcome
  outcome="$(run_dir_get "$run_dir" "outcome" 2>/dev/null || true)"
  local outcome_upper
  outcome_upper="$(printf '%s' "$outcome" | tr '[:lower:]' '[:upper:]')"
  local is_success=0
  case "$outcome_upper" in
    SUCCESS|DONE|PASSED|OK) is_success=1 ;;
  esac

  if [ $is_success -eq 0 ] && [ $force -eq 0 ]; then
    echo "STATUS: WORKTREE_REFUSED_FAILED | Run: $run_id | Outcome: $outcome | Path: $wt_path | Note: run finished badly ($outcome); refusing to remove worktree without --force" >&2
    return 7 2>/dev/null || exit 7
  fi

  # Refusal 3: Worktree has uncommitted changes or untracked files
  local dirty_status
  dirty_status="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty_status" ] && [ $force -eq 0 ]; then
    local lost_summary
    lost_summary="$(printf '%s\n' "$dirty_status" | sed 's/^...//' | tr '\n' ', ' | sed 's/, $//')"
    echo "STATUS: WORKTREE_REFUSED_DIRTY | Run: $run_id | Path: $wt_path | Dirty: $lost_summary | Note: worktree has uncommitted changes or untracked files ($lost_summary); refusing to remove without --force" >&2
    return 7 2>/dev/null || exit 7
  fi

  # Removal
  if [ $force -eq 1 ]; then
    git -C "$root" worktree remove --force "$wt_path" 2>/dev/null || {
      rm -rf "$wt_path"
      git -C "$root" worktree prune 2>/dev/null || true
    }
  else
    git -C "$root" worktree remove "$wt_path" 2>/dev/null || {
      echo "worktree: git worktree remove failed" >&2
      return 4 2>/dev/null || exit 4
    }
  fi

  _worktree_clear_meta "$run_dir"

  echo "STATUS: WORKTREE_REMOVED | Run: $run_id | Path: $wt_path | Note: worktree removed for run $run_id" >&2
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  CMD="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$CMD" in
    add)
      worktree_add "$@"
      exit $?
      ;;
    path)
      worktree_path "$@"
      exit $?
      ;;
    list)
      worktree_list "$@"
      exit $?
      ;;
    remove)
      worktree_remove "$@"
      exit $?
      ;;
    -h|--help)
      sed -n '2,68p' "$0"
      exit 0
      ;;
    "")
      echo "worktree: command required (add|path|list|remove)" >&2
      exit 2
      ;;
    *)
      echo "worktree: unknown command $CMD (want add|path|list|remove)" >&2
      exit 2
      ;;
  esac
fi
