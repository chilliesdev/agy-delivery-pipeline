#!/usr/bin/env bash
# Say which phases a repository's pipeline declares.
#
#   resolve-phases.sh [--dir <repo>] [--check <PHASE>] [--source]
#
# Reads:   the same agy.toml resolve-model.sh reads, in the same order:
#            1. <repo>/.claude/agy.toml
#            2. <repo>/agy.toml
#            3. <this repo>/agy.toml     the vendored default
# Writes:  nothing.
# Prints:  the declared phases, one per line. With --check, nothing — the exit
#          code carries the answer. With --source, the config file that decided it,
#          on stderr.
#
# Exit codes:
#     0  listed, or --check named a declared phase
#     2  bad arguments, or malformed config
#     3  --check named a phase this repository does not declare
#
# Why this exists. The five phases were a fact about the skill, written down in
# prose and nowhere a script could read. That was fine while every repository ran
# all five. It stops being fine the moment one does not: a repository with no
# release step, or no QA, had no way to say so, and nothing reading a run could
# tell "this phase was skipped" from "this phase does not exist here". Both look
# like an absent artifact.
#
# It is also what makes an *undeclared* phase visible. A run reporting a phase the
# config does not list is not necessarily wrong — but it is unverifiable against
# the config, and a reader deserves to be told that rather than have the phase
# folded silently into the pipeline.
#
# Advisory, deliberately. This does not refuse anything and phase.sh does not gate
# on it. A phase outside the declared set is recorded as undeclared and dispatched
# anyway, in the same spirit as check-review.sh: the finding is a suspicion for a
# person to settle, not a verdict. DELEGATE is the ordinary case of this — one
# bounded worker, deliberately outside the pipeline — and it reads as undeclared
# because that is exactly what it is.
set -uo pipefail

PHASES_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./resolve-model.sh
. "$PHASES_HERE/resolve-model.sh"

# The phases the pipeline has always run, used when no config declares a set.
# Changing this changes what every repository without a [pipeline] section does.
RESOLVE_PHASES_DEFAULT="DISCOVERY IMPLEMENT REVIEW QA RELEASE"

# resolve_phases <repo-dir> -> declared phases, one per line
resolve_phases() {
  local dir="${1:-$PWD}"
  local config parsed declared

  config="$(resolve_config_path "$dir" 2>/dev/null || true)"

  if [ -n "$config" ] && [ -f "$config" ]; then
    parsed="$(_resolve_model_parse_toml "$config")" || return 2
    declared="$(_resolve_model_get_val "pipeline.phases" "$parsed")"
    if [ -n "$declared" ]; then
      printf '%s\n' "$declared" | tr ' ' '\n' | grep -v '^$'
      return 0
    fi
  fi

  printf '%s\n' "$RESOLVE_PHASES_DEFAULT" | tr ' ' '\n' | grep -v '^$'
  return 0
}

# resolve_phases_declared <repo-dir> <phase> -> 0 declared, 3 not
resolve_phases_declared() {
  local dir="${1:-$PWD}"
  local phase="${2:-}"
  [ -n "$phase" ] || return 2

  local list
  list="$(resolve_phases "$dir")" || return 2
  if printf '%s\n' "$list" | grep -Fqx "$phase"; then
    return 0
  fi
  return 3
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  DIR="$PWD"
  CHECK_PHASE=""
  SHOW_SOURCE=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)    DIR="$2";         shift 2 ;;
      --check)  CHECK_PHASE="$2"; shift 2 ;;
      --source) SHOW_SOURCE=1;    shift ;;
      -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
      *) echo "resolve-phases: unknown arg $1" >&2; exit 2 ;;
    esac
  done

  [ -d "$DIR" ] || { echo "resolve-phases: dir not found: $DIR" >&2; exit 2; }

  if [ "$SHOW_SOURCE" -eq 1 ]; then
    SRC="$(resolve_config_path "$DIR" 2>/dev/null || true)"
    if [ -n "$SRC" ]; then
      echo "resolve-phases: reading $SRC" >&2
    else
      echo "resolve-phases: no agy.toml found; using built-in defaults" >&2
    fi
  fi

  if [ -n "$CHECK_PHASE" ]; then
    resolve_phases_declared "$DIR" "$CHECK_PHASE"
    exit $?
  fi

  resolve_phases "$DIR"
  exit $?
fi
