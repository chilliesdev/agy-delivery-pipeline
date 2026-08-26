#!/usr/bin/env bash
# Run one pipeline phase as an agy delegation.
#
#   phase.sh --phase <NAME> --brief <file> [--tier low|medium|high]
#            [--dir <repo>] [--run <id|current|new>] [--task <string>]
#            [--mode accept-edits|plan|full] [--timeout 30m]
#            [--sandbox] [--no-preflight] [--no-brief-lint] [--no-secret-scan]
#            [--no-diff-integrity] [--check-git-state]
#            [--allow-shell] [--verify '<command>'] [--retry-cap <n>]
#            [--budget-tokens <n>] [--repo-budget-tokens <n>] [--max-workers <n>]
#            [--reset-retries] [--ignore-via gitignore|exclude]
#
# Reads:   R/phases/<PHASE>/verdict      the verdict the worker wrote itself
#          R/phases/<PHASE>/retries      retries this phase's cycle has spent
# Writes:  R/phases/<PHASE>/log          full worker transcript (never read whole)
#          R/phases/<PHASE>/verify.log   --verify output, never stdout
#          R/phases/<PHASE>/status       one STATUS line for the orchestrator
#          R/phases/<PHASE>/brief.md     copy of the brief dispatched with
# Prints:  the STATUS line only — keeps the orchestrator context lean.
#
# --verify runs the given check in <repo> after the worker returns and folds the
# result into that one line. It overrides the worker: a PASSED claim whose check
# exits non-zero comes back as STATUS: VERIFY_FAILED(rc=N), exit 5 — distinct
# from WORKER_FAILED, which is the worker itself dying.
#
# --check-git-state snapshots git state (HEAD, tags, refs) before dispatch and
# compares after return via check-git-state.sh, failing the phase on any changes.
# The flag is a request, and an unfulfilled request is not a pass.
#
# The retry counter is mechanical: each dispatch beyond the first bumps
# R/phases/<PHASE>/retries, and past --retry-cap (default 2, matching SKILL.md)
# phase.sh refuses to dispatch at all, returning STATUS: RETRY_CAP_REACHED(n=N),
# exit 6. A clean round clears the counter, as does --reset-retries. A round
# that ends WORKER_FAILED or PREFLIGHT_FAILED is refunded: neither is a worker
# failing to converge, which is the only thing the cap is there to catch.
#
# --budget-tokens <n> enforces a spend ceiling: before dispatching, sum
# total_tokens across every ledger record for this run. If already at or past
# the budget, phase.sh refuses to dispatch, returning STATUS: BUDGET_EXCEEDED(spent=N, budget=M),
# exit 7. Budget in tokens, not dollars — do not hardcode a price per token anywhere.
# Prices change, differ per model and account, and a stale number presented as a cost
# is worse than no number.
#
# --repo-budget-tokens <n> enforces a spend ceiling across all runs: before
# dispatching, sum total_tokens across every ledger record in the repository. If
# already at or past the ceiling, phase.sh refuses to dispatch, returning
# STATUS: REPO_BUDGET_EXCEEDED(spent=N, budget=M), exit 9.
#
# --max-workers <n> enforces a concurrency cap on in-flight dispatches for this
# repository (default 1, matching AGY_MAX_WORKERS). Before dispatching, count
# actively running worker processes. If already at or past the cap, phase.sh
# refuses to dispatch, returning STATUS: WORKER_CAP_EXCEEDED(running=N, cap=M),
# exit 8.
#
# check-diff-integrity.sh checks worker changes for weakened tests and scope creep.
# --no-diff-integrity bypasses.
#
# check-secrets.sh scans the brief and diff for secrets before dispatch,
# refusing on SECRETS_FOUND without invoking the worker. --no-secret-scan bypasses.
#
# check-brief.sh lints the brief before dispatch, refusing on BRIEF_INVALID
# without invoking the worker. --no-brief-lint bypasses the check.
#
# preflight.sh runs first unless --no-preflight or AGY_SKIP_PREFLIGHT=1.
#
# If this dispatch had to tell git to ignore .agy/, the STATUS line carries a
# trailing `| Gitignore: …` field saying so — a file the tooling authored is one
# wholesale `git add` from the task's own commit. It is never committed here.
#
# --ignore-via chooses where that rule goes. `gitignore` (the default, and what
# every pipeline phase uses) appends to the work tree's tracked .gitignore and
# reports it. `exclude` writes .git/info/exclude instead: same effect on git,
# but the entry is local and untracked, so nothing enters the diff and there is
# nothing to keep out of a commit. The delegate path uses `exclude`, because
# ambient delegation would otherwise edit a tracked file in every repo it ever
# touches, unasked, for a one-line change.
set -uo pipefail

# -----------------------------------------------------------------------------
# Self-snapshot execution for in-repo self-modification safety
# -----------------------------------------------------------------------------
# Why this exists:
# When phase.sh is executed from within the target repository, a worker modifying
# files in the repository (e.g. during self-hosting development or refactoring)
# could edit or overwrite phase.sh or its helpers while they are executing.
# Bash reads scripts line-by-line from disk as they run, so mutating a running
# script causes syntax errors or process aborts mid-flight.
#
# What it copies:
# If the executing script resides inside the target repository root, it creates a
# temporary directory under TMPDIR, copies the entire scripts/ directory and the
# drivers/ directory into it, sets AGY_PHASE_SNAPSHOT, and re-executes the
# snapshot script with the original arguments.
#
# Critical rule for dependencies:
# Anything that phase.sh or its helper scripts source, execute, or reference
# MUST reside inside the directories copied here (scripts/ and drivers/). If a
# new dependency is introduced in a sibling directory (e.g., helpers/, lib/),
# it MUST be added to the snapshot copy logic below; otherwise, it will be
# missing in the snapshot environment and cause subtle runtime failures.
# -----------------------------------------------------------------------------

_cleanup_worker_record() {
  if [ -n "${WORKER_RECORD_FILE:-}" ]; then
    rm -f "$WORKER_RECORD_FILE" 2>/dev/null || true
  fi
  if [ -n "${AGY_PHASE_SNAPSHOT:-}" ]; then
    rm -rf "$AGY_PHASE_SNAPSHOT" 2>/dev/null || true
  fi
}

trap '_cleanup_worker_record' EXIT INT TERM

if [ -n "${AGY_PHASE_SNAPSHOT:-}" ]; then
  :
else
  _TARGET_DIR="$PWD"
  _PREV=""
  for _ARG in "$@"; do
    if [ "$_PREV" = "--dir" ]; then
      _TARGET_DIR="$_ARG"
    fi
    _PREV="$_ARG"
  done

  _SCRIPT_PATH="${BASH_SOURCE[0]}"
  while [ -L "$_SCRIPT_PATH" ]; do
    _LINK="$(readlink "$_SCRIPT_PATH" 2>/dev/null || true)"
    [ -n "$_LINK" ] || break
    case "$_LINK" in
      /*) _SCRIPT_PATH="$_LINK" ;;
      *)  _SCRIPT_PATH="$(dirname "$_SCRIPT_PATH")/$_LINK" ;;
    esac
  done
  _SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" 2>/dev/null && pwd -P || true)"
  _RESOLVED_TARGET="$(cd "$_TARGET_DIR" 2>/dev/null && pwd -P || true)"

  _INSIDE=""
  if [ -n "$_RESOLVED_TARGET" ] && [ -n "$_SCRIPT_DIR" ]; then
    if [ "$_RESOLVED_TARGET" = "/" ]; then
      _INSIDE=1
    elif [ "$_SCRIPT_DIR" = "$_RESOLVED_TARGET" ] || [ "${_SCRIPT_DIR#$_RESOLVED_TARGET/}" != "$_SCRIPT_DIR" ]; then
      _INSIDE=1
    fi
  fi

  if [ -n "$_INSIDE" ]; then
    _SNAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-phase.XXXXXX")"
    mkdir -p "$_SNAP_DIR/scripts"
    cp -R "$_SCRIPT_DIR/." "$_SNAP_DIR/scripts/"
    if [ -d "$_SCRIPT_DIR/../drivers" ]; then
      mkdir -p "$_SNAP_DIR/drivers"
      cp -R "$_SCRIPT_DIR/../drivers/." "$_SNAP_DIR/drivers/"
    fi
    _SCRIPT_NAME="$(basename "$_SCRIPT_PATH")"
    chmod +x "$_SNAP_DIR/scripts/$_SCRIPT_NAME" 2>/dev/null || true
    echo "phase.sh: re-executing from snapshot $_SNAP_DIR" >&2
    export AGY_PHASE_SNAPSHOT="$_SNAP_DIR"
    exec "$_SNAP_DIR/scripts/$_SCRIPT_NAME" "$@"
  fi
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"
. "$HERE/ledger.sh"
. "$HERE/resolve-model.sh"

STARTED_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PHASE=""; BRIEF=""; TIER=""; DIR="$PWD"; MODE="accept-edits"; TIMEOUT="30m"
QUIET=0
DRIVER="${AGY_DRIVER:-}"
SKIP_PREFLIGHT="${AGY_SKIP_PREFLIGHT:-}"
SKIP_BRIEF_LINT="${AGY_SKIP_BRIEF_LINT:-}"
SKIP_SECRET_SCAN="${AGY_SKIP_SECRET_SCAN:-}"
SKIP_DIFF_INTEGRITY="${AGY_SKIP_DIFF_INTEGRITY:-}"
CHECK_GIT_STATE="${AGY_CHECK_GIT_STATE:-}"
ALLOW_SHELL="${AGY_ALLOW_SHELL:-}"
VERIFY=""; RESET_RETRIES=""; IGNORE_VIA="gitignore"
RETRY_CAP="${AGY_RETRY_CAP:-2}"
BUDGET_TOKENS="${AGY_BUDGET_TOKENS:-}"
REPO_BUDGET_TOKENS="${AGY_REPO_BUDGET_TOKENS:-}"
MAX_WORKERS="${AGY_MAX_WORKERS:-1}"
RUN_TARGET=""
TASK=""
SANDBOX_ARGS=()   # array, so the flag is never word-split out of an unquoted scalar

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)   PHASE="$2";   shift 2 ;;
    --brief)   BRIEF="$2";   shift 2 ;;
    --tier)    TIER="$2";    shift 2 ;;
    --driver)  DRIVER="$2";  shift 2 ;;
    --dir)     DIR="$2";     shift 2 ;;
    --run)     RUN_TARGET="$2"; shift 2 ;;
    --task)    TASK="$2";    shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --verify)  VERIFY="$2";  shift 2 ;;
    --retry-cap) RETRY_CAP="$2"; shift 2 ;;
    --budget-tokens) BUDGET_TOKENS="$2"; shift 2 ;;
    --repo-budget-tokens) REPO_BUDGET_TOKENS="$2"; shift 2 ;;
    --max-workers) MAX_WORKERS="$2"; shift 2 ;;
    --reset-retries) RESET_RETRIES=1; shift ;;
    --ignore-via) IGNORE_VIA="$2"; shift 2 ;;
    --sandbox) SANDBOX_ARGS=("${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"}" --sandbox); shift ;;
    --no-preflight) SKIP_PREFLIGHT=1; shift ;;
    --no-brief-lint) SKIP_BRIEF_LINT=1; shift ;;
    --no-secret-scan) SKIP_SECRET_SCAN=1; shift ;;
    --no-diff-integrity) SKIP_DIFF_INTEGRITY=1; shift ;;
    --check-git-state) CHECK_GIT_STATE=1; shift ;;
    --allow-shell) ALLOW_SHELL=1; shift ;;
    --quiet|-q)    QUIET=1; shift ;;
    -h|--help)     sed -n '2,68p' "$0"; exit 0 ;;
    *) echo "phase.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$PHASE" ] || { echo "phase.sh: --phase required" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "phase.sh: brief not found: $BRIEF" >&2; exit 2; }
case "$RETRY_CAP" in
  ''|*[!0-9]*) echo "phase.sh: --retry-cap wants a whole number, got '$RETRY_CAP'" >&2; exit 2 ;;
esac
case "$BUDGET_TOKENS" in
  ""|*[!0-9]*)
    if [ -n "$BUDGET_TOKENS" ]; then
      echo "phase.sh: --budget-tokens wants a whole number, got '$BUDGET_TOKENS'" >&2
      exit 2
    fi
    ;;
esac
case "$REPO_BUDGET_TOKENS" in
  ""|*[!0-9]*)
    if [ -n "$REPO_BUDGET_TOKENS" ]; then
      echo "phase.sh: --repo-budget-tokens wants a whole number, got '$REPO_BUDGET_TOKENS'" >&2
      exit 2
    fi
    ;;
esac
case "$MAX_WORKERS" in
  ''|*[!0-9]*) echo "phase.sh: --max-workers wants a whole number, got '$MAX_WORKERS'" >&2; exit 2 ;;
esac
case "$IGNORE_VIA" in
  gitignore|exclude) ;;
  *) echo "phase.sh: --ignore-via wants gitignore or exclude, got '$IGNORE_VIA'" >&2; exit 2 ;;
esac

_is_worker_alive() {
  local pid="$1"
  local expected_run="${2:-}"
  local expected_phase="${3:-}"

  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac

  # If the record lacks required identity fields (run or phase), it cannot be
  # confirmed as a worker process. An incomplete record must never match
  # arbitrary processes.
  if [ -z "$expected_run" ] || [ -z "$expected_phase" ]; then
    return 1
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  local proc_args
  proc_args="$(ps -p "$pid" -o args= 2>/dev/null || ps -p "$pid" -o command= 2>/dev/null || true)"
  if [ -z "$proc_args" ]; then
    proc_args="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  fi

  # If process arguments cannot be retrieved, fail open (return 1):
  # an unverified process must not block future dispatches permanently,
  # while an occasional extra worker only costs visible spend.
  if [ -z "$proc_args" ]; then
    return 1
  fi

  # Match specific dispatch arguments rather than broad substrings like 'agy' or 'phase'
  # which match unrelated processes running inside this repo.
  case "$proc_args" in
    *phase.sh*--phase*"$expected_phase"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_count_running_workers() {
  local workers_dir="$1"
  local count=0

  if [ ! -d "$workers_dir" ]; then
    printf '0'
    return 0
  fi

  for rec in "$workers_dir"/*; do
    [ -f "$rec" ] || continue

    local w_pid="" w_run="" w_phase=""
    w_pid="$(sed -n 's/^pid=//p' "$rec" 2>/dev/null | head -1)"
    w_run="$(sed -n 's/^run=//p' "$rec" 2>/dev/null | head -1)"
    w_phase="$(sed -n 's/^phase=//p' "$rec" 2>/dev/null | head -1)"

    if [ "$w_pid" = "$$" ]; then
      continue
    fi

    if _is_worker_alive "$w_pid" "$w_run" "$w_phase"; then
      count=$((count + 1))
    else
      rm -f "$rec" 2>/dev/null || true
    fi
  done

  printf '%s' "$count"
}

DIR="$(cd "$DIR" && pwd)"

# Resolve driver from agy.toml if not passed on CLI
if [ -z "$DRIVER" ]; then
  if CONFIG_FILE="$(resolve_config_path "$DIR" 2>/dev/null)"; then
    PARSED_CONFIG="$(_resolve_model_parse_toml "$CONFIG_FILE" 2>/dev/null || true)"
    if [ -n "$PARSED_CONFIG" ]; then
      CFG_DRIVER="$(_resolve_model_get_val "driver.name" "$PARSED_CONFIG")"
      [ -z "$CFG_DRIVER" ] && CFG_DRIVER="$(_resolve_model_get_val "driver.default" "$PARSED_CONFIG")"
      [ -z "$CFG_DRIVER" ] && CFG_DRIVER="$(_resolve_model_get_val "driver.driver" "$PARSED_CONFIG")"
      [ -n "$CFG_DRIVER" ] && DRIVER="$CFG_DRIVER"
    fi
  fi
fi
DRIVER="${DRIVER:-agy}"

_list_available_drivers() {
  local dirs=()
  [ -n "${AGY_DRIVERS_DIR:-}" ] && [ -d "${AGY_DRIVERS_DIR:-}" ] && dirs=("${dirs[@]+"${dirs[@]}"}" "$AGY_DRIVERS_DIR")
  [ -d "$HERE/../drivers" ] && dirs=("${dirs[@]+"${dirs[@]}"}" "$HERE/../drivers")
  [ -d "$DIR/drivers" ] && dirs=("${dirs[@]+"${dirs[@]}"}" "$DIR/drivers")

  local names=""
  for d in "${dirs[@]+"${dirs[@]}"}"; do
    for f in "$d"/*.sh; do
      [ -f "$f" ] || continue
      local base
      base="$(basename "$f" .sh)"
      if [ -z "$names" ]; then
        names="$base"
      else
        local match=0
        for existing in $(printf '%s' "$names" | tr '|' ' '); do
          if [ "$existing" = "$base" ]; then
            match=1
            break
          fi
        done
        if [ "$match" -eq 0 ]; then
          names="$names|$base"
        fi
      fi
    done
  done
  printf '%s' "${names:-agy}"
}

DRIVER_PATH=""
if [ -n "${AGY_DRIVERS_DIR:-}" ] && [ -f "$AGY_DRIVERS_DIR/$DRIVER.sh" ]; then
  DRIVER_PATH="$AGY_DRIVERS_DIR/$DRIVER.sh"
elif [ -f "$HERE/../drivers/$DRIVER.sh" ]; then
  DRIVER_PATH="$HERE/../drivers/$DRIVER.sh"
elif [ -f "$DIR/drivers/$DRIVER.sh" ]; then
  DRIVER_PATH="$DIR/drivers/$DRIVER.sh"
elif [ -f "$DRIVER" ]; then
  DRIVER_PATH="$DRIVER"
elif [ -f "$DRIVER.sh" ]; then
  DRIVER_PATH="$DRIVER.sh"
fi

if [ -z "$DRIVER_PATH" ] || [ ! -f "$DRIVER_PATH" ]; then
  echo "phase.sh: unknown driver '$DRIVER' (want $(_list_available_drivers))" >&2
  exit 2
fi

. "$DRIVER_PATH"

if ! command -v driver_run >/dev/null 2>&1 || ! command -v driver_capabilities >/dev/null 2>&1; then
  echo "phase.sh: driver '$DRIVER' does not implement driver interface" >&2
  exit 2
fi

DRIVER_CAPS="$(driver_capabilities 2>/dev/null || true)"
DRIVER_SHELL="$(printf '%s\n' "$DRIVER_CAPS" | sed -n 's/^shell=//p' | head -1)"
if [ "$DRIVER_SHELL" = "yes" ]; then
  ALLOW_SHELL=1
fi

RESOLVE_ARGS=()
if [ -n "$TIER" ]; then
  RESOLVE_ARGS=("${RESOLVE_ARGS[@]+"${RESOLVE_ARGS[@]}"}" --tier "$TIER")
fi
if [ -n "$PHASE" ]; then
  RESOLVE_ARGS=("${RESOLVE_ARGS[@]+"${RESOLVE_ARGS[@]}"}" --phase "$PHASE")
fi
RESOLVE_ARGS=("${RESOLVE_ARGS[@]+"${RESOLVE_ARGS[@]}"}" --dir "$DIR")

MODEL="$("$HERE/resolve-model.sh" "${RESOLVE_ARGS[@]}")" || exit $?
if [ -z "$TIER" ]; then
  case "$MODEL" in
    gemini-3.7-flash-low)    TIER="low" ;;
    gemini-3.7-flash-medium) TIER="medium" ;;
    gemini-3.7-flash-high)   TIER="high" ;;
    *)                       TIER="$MODEL" ;;
  esac
fi

# Resolve the run directory R and RUN_ID.
if [ -z "$RUN_TARGET" ]; then
  if R="$(run_dir_resolve --dir "$DIR" --run current 2>/dev/null)"; then
    RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
  else
    RUN_TASK="${TASK:-"$PHASE (no task supplied)"}"
    RUN_ID="$(run_dir_new --dir "$DIR" --task "$RUN_TASK")" || exit $?
    R="$DIR/.agy/runs/$RUN_ID"
  fi
elif [ "$RUN_TARGET" = "new" ]; then
  RUN_TASK="${TASK:-"$PHASE (no task supplied)"}"
  RUN_ID="$(run_dir_new --dir "$DIR" --task "$RUN_TASK")" || exit $?
  R="$DIR/.agy/runs/$RUN_ID"
else
  R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET")" || exit $?
  RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
fi

if [ -n "$TASK" ]; then
  EXISTING_TASK="$(run_dir_get "$R" "task" 2>/dev/null || true)"
  if [ -n "$EXISTING_TASK" ] && [ "$TASK" != "$EXISTING_TASK" ]; then
    echo "phase.sh: run $RUN_ID already has task '$EXISTING_TASK' (ignoring passed task '$TASK')" >&2
  fi
fi

PHASE_DIR="$(run_dir_phase_dir "$R" "$PHASE")" || exit $?

# .agy/ is worker state and must never reach the user's history — one `git add
# -A` in a later phase is all it would take. Add the ignore once, where
# --ignore-via says, and only if git does not already ignore .agy (which also
# covers a global or parent-level rule, and either of the two files below that a
# previous dispatch may have written). Must stay *after* the run dir creation
# above: a directory-only rule like `.agy/` only matches a path git can see is a
# directory, so checking first would re-add an entry that is already there.
#
# The edit is not silent, because in the default `gitignore` mode it is the
# tooling authoring a *tracked* file in someone else's repo: a .gitignore this
# created is itself untracked, and the wholesale
# `git add -A` a release phase reaches for would sweep it into the task's commit
# — which is how it turned up in a delivered diffstat as a change nobody asked
# for. It is reported rather than committed: committing writes to the user's
# history as a side effect of a dispatch, which nothing here is licensed to do,
# and would need a clean index, an identity, and no hooks to be safe. The report
# rides the STATUS line, appended as a field so the head of the line never
# shifts, because the orchestrator reads that line and nothing else — stderr
# carries the same sentence for whoever is running phase.sh by hand.
GITIGNORE_FIELD=""
if GITROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" \
   && [ "$(git -C "$DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
   && [ -n "$GITROOT" ] \
   && ! git -C "$DIR" check-ignore -q .agy 2>/dev/null; then
  # check-ignore above sees both files, so whichever one a previous dispatch
  # wrote, this is skipped on the next.
  if [ "$IGNORE_VIA" = "exclude" ]; then
    GITDIR="$(git -C "$DIR" rev-parse --git-dir 2>/dev/null)"
    case "$GITDIR" in /*) ;; *) GITDIR="$GITROOT/$GITDIR" ;; esac
    IGNORE_TARGET="$GITDIR/info/exclude"
    mkdir -p "$GITDIR/info" 2>/dev/null
    WROTE_NOTE="Gitignore: added .agy/ to $IGNORE_TARGET — local to this clone, untracked, nothing to keep out of the commit"
    CREATED_NOTE="$WROTE_NOTE"
  else
    IGNORE_TARGET="$GITROOT/.gitignore"
    WROTE_NOTE="Gitignore: added .agy/ to $IGNORE_TARGET — the tooling's edit, not the task's; keep it out of the task's commit"
    CREATED_NOTE="Gitignore: created $IGNORE_TARGET holding .agy/ — untracked and not the task's; keep it out of the task's commit"
  fi
  [ -e "$IGNORE_TARGET" ] && GI_EXISTED=1 || GI_EXISTED=""
  # An existing file that lacks a trailing newline would otherwise absorb the
  # new entry into its last line.
  if [ -s "$IGNORE_TARGET" ] && [ -n "$(tail -c 1 "$IGNORE_TARGET" 2>/dev/null)" ]; then
    printf '\n' >> "$IGNORE_TARGET" 2>/dev/null
  fi
  if printf '.agy/\n' >> "$IGNORE_TARGET" 2>/dev/null; then
    if [ -n "$GI_EXISTED" ]; then
      GITIGNORE_NOTE="$WROTE_NOTE"
    else
      GITIGNORE_NOTE="$CREATED_NOTE"
    fi
    GITIGNORE_FIELD=" | $GITIGNORE_NOTE"
    echo "phase.sh: $GITIGNORE_NOTE" >&2
  else
    echo "phase.sh: could not add .agy/ to $IGNORE_TARGET" >&2
  fi
fi

LOG="$PHASE_DIR/log"
VERIFY_LOG="$PHASE_DIR/verify.log"
STATUS_FILE="$PHASE_DIR/status"
VERDICT_FILE="$PHASE_DIR/verdict"
RETRY_FILE="$PHASE_DIR/retries"

ESC="$(printf '\033')"
CR="$(printf '\r')"

# Drop ANSI escape sequences and carriage returns from stdin. Worker transcripts
# are coloured, so the STATUS: marker is rarely the first byte of its own line.
strip_ansi() { LC_ALL=C sed -e "s/${ESC}\[[0-9;?]*[a-zA-Z]//g" -e "s/${CR}//g"; }

# Trim markdown decoration and surrounding whitespace from one claim line. Never
# stops at a quote — a verdict naming "src/my file.ts" must survive whole.
trim_claim() { LC_ALL=C sed -e 's/^[[:space:]*#>_`-]*//' -e 's/[[:space:]*`]*$//'; }

# Copy the brief into R/phases/<PHASE>/brief.md before dispatch.
# Skip the copy when the source is already that file (the normal case for a
# brief written in place): cp would fail copying a file onto itself.
# When the copy genuinely fails for another reason — an unwritable directory,
# a missing source — refuse, because a run directory that does not contain the
# brief it ran with cannot be diagnosed later.
BRIEF_ABS="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
DEST_ABS="$(cd "$PHASE_DIR" && pwd)/brief.md"
if [ "$BRIEF_ABS" != "$DEST_ABS" ]; then
  cp -f "$BRIEF" "$PHASE_DIR/brief.md" 2>/dev/null || {
    echo "phase.sh: could not copy brief to $PHASE_DIR/brief.md" >&2
    exit 2
  }
fi


# The retry cap SKILL.md asks for, made mechanical. R/phases/<PHASE>/retries holds
# how many *retries* — dispatches beyond the first — this cycle has spent; the
# file being absent means the cycle has not dispatched at all yet. Unlike the
# verdict file below it is deliberately *not* cleared before each dispatch, or
# it could never accumulate; it is cleared by a clean round or --reset-retries.
[ -n "$RESET_RETRIES" ] && rm -f "$RETRY_FILE"
if [ -f "$RETRY_FILE" ]; then
  # tr -cd is the sanitiser: a hand-edited or truncated counter reads as 0
  # rather than aborting the dispatch on a string comparison.
  SPENT="$(tr -cd '0-9' < "$RETRY_FILE" 2>/dev/null)"; SPENT="${SPENT:-0}"
  NEXT=$((SPENT + 1))
  HAD_COUNTER=1
else
  SPENT=0; NEXT=0
  # No file at all is its own state — "this cycle has not dispatched yet" — and
  # a refund below has to be able to put it back, not settle for writing 0.
  HAD_COUNTER=""
fi

# At the cap, refuse before anything is spent — no preflight fetch, no worker,
# no cleared verdict, so REVIEW_FEEDBACK.md and the last verdict survive for
# the orchestrator, which SKILL.md tells to take the work over itself from here.
if [ "$SPENT" -ge "$RETRY_CAP" ]; then
  printf '%s\n' "STATUS: RETRY_CAP_REACHED(n=$SPENT, cap=$RETRY_CAP) | Phase: $PHASE | Run: $RUN_ID | Note: the retry budget for this phase is spent — take the work over yourself, or pass --reset-retries to start a fresh cycle | Next: re-brief with what the last review asked for, or take it over; a third round rarely converges | Log: $LOG$GITIGNORE_FIELD" \
    | tee "$STATUS_FILE"
  TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
  [ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"
  ledger_append "$DIR" \
    "run=$RUN_ID" \
    "phase=$PHASE" \
    "attempt=$((SPENT + 1))" \
    "tier=$TIER" \
    "model=$MODEL" \
    "backend=$DRIVER" \
    "started=$STARTED_TS" \
    "status=RETRY_CAP_REACHED(n=$SPENT, cap=$RETRY_CAP)" \
    "retries_spent=$SPENT" \
    "retries_refunded=0" \
    "verify_ran=false" \
    ${TASK_TO_RECORD:+"task=$TASK_TO_RECORD"} 2>/dev/null || echo "phase.sh: could not record to ledger" >&2
  exit 6
fi

# At the budget ceiling, refuse before anything is spent — no preflight fetch,
# no worker, no cleared verdict.
if [ -n "$BUDGET_TOKENS" ]; then
  SPENT_TOKENS="$(_ledger_spent_tokens "$DIR" "$RUN_ID")"
  if [ "$SPENT_TOKENS" -ge "$BUDGET_TOKENS" ]; then
    printf '%s\n' "STATUS: BUDGET_EXCEEDED(spent=$SPENT_TOKENS, budget=$BUDGET_TOKENS) | Phase: $PHASE | Run: $RUN_ID | Note: the token budget for this run is spent — increase --budget-tokens to continue | Next: increase --budget-tokens to continue, or inspect spend with report.sh | Log: $LOG$GITIGNORE_FIELD" \
      | tee "$STATUS_FILE"
    TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
    [ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"
    ledger_append "$DIR" \
      "run=$RUN_ID" \
      "phase=$PHASE" \
      "attempt=$((SPENT + 1))" \
      "tier=$TIER" \
      "model=$MODEL" \
      "backend=$DRIVER" \
      "started=$STARTED_TS" \
      "status=BUDGET_EXCEEDED(spent=$SPENT_TOKENS, budget=$BUDGET_TOKENS)" \
      "retries_spent=$SPENT" \
      "retries_refunded=0" \
      "verify_ran=false" \
      ${TASK_TO_RECORD:+"task=$TASK_TO_RECORD"} 2>/dev/null || echo "phase.sh: could not record to ledger" >&2
    exit 7
  fi
fi

# At the repository budget ceiling, refuse before anything is spent — no preflight fetch,
# no worker, no cleared verdict.
if [ -n "$REPO_BUDGET_TOKENS" ]; then
  REPO_SPENT_TOKENS="$(_ledger_repo_spent_tokens "$DIR")"
  if [ "$REPO_SPENT_TOKENS" -ge "$REPO_BUDGET_TOKENS" ]; then
    printf '%s\n' "STATUS: REPO_BUDGET_EXCEEDED(spent=$REPO_SPENT_TOKENS, budget=$REPO_BUDGET_TOKENS) | Phase: $PHASE | Run: $RUN_ID | Note: the repository token budget is spent — increase --repo-budget-tokens to continue | Next: increase --repo-budget-tokens to continue, or inspect spend with report.sh | Log: $LOG$GITIGNORE_FIELD" \
      | tee "$STATUS_FILE"
    TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
    [ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"
    ledger_append "$DIR" \
      "run=$RUN_ID" \
      "phase=$PHASE" \
      "attempt=$((SPENT + 1))" \
      "tier=$TIER" \
      "model=$MODEL" \
      "backend=$DRIVER" \
      "started=$STARTED_TS" \
      "status=REPO_BUDGET_EXCEEDED(spent=$REPO_SPENT_TOKENS, budget=$REPO_BUDGET_TOKENS)" \
      "retries_spent=$SPENT" \
      "retries_refunded=0" \
      "verify_ran=false" \
      ${TASK_TO_RECORD:+"task=$TASK_TO_RECORD"} 2>/dev/null || echo "phase.sh: could not record to ledger" >&2
    exit 9
  fi
fi

# At the worker concurrency cap, refuse before anything is spent — no preflight fetch,
# no worker, no cleared verdict.
WORKERS_DIR="$DIR/.agy/workers"
WORKER_RECORD_FILE="$WORKERS_DIR/${RUN_ID}_${PHASE}_$$.rec"
RUNNING_WORKERS="$(_count_running_workers "$WORKERS_DIR")"
if [ "$RUNNING_WORKERS" -ge "$MAX_WORKERS" ]; then
  W_NOUN="dispatches"
  W_VERB="are"
  if [ "$RUNNING_WORKERS" -eq 1 ]; then
    W_NOUN="dispatch"
    W_VERB="is"
  fi
  printf '%s\n' "STATUS: WORKER_CAP_EXCEEDED(running=$RUNNING_WORKERS, cap=$MAX_WORKERS) | Phase: $PHASE | Run: $RUN_ID | Note: $RUNNING_WORKERS $W_NOUN $W_VERB running and the cap is $MAX_WORKERS — raising the cap is the caller's decision | Next: wait for a running dispatch to finish, or increase --max-workers to continue | Log: $LOG$GITIGNORE_FIELD" \
    | tee "$STATUS_FILE"
  TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
  [ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"
  ledger_append "$DIR" \
    "run=$RUN_ID" \
    "phase=$PHASE" \
    "attempt=$((SPENT + 1))" \
    "tier=$TIER" \
    "model=$MODEL" \
    "backend=$DRIVER" \
    "started=$STARTED_TS" \
    "status=WORKER_CAP_EXCEEDED(running=$RUNNING_WORKERS, cap=$MAX_WORKERS)" \
    "retries_spent=$SPENT" \
    "retries_refunded=0" \
    "verify_ran=false" \
    ${TASK_TO_RECORD:+"task=$TASK_TO_RECORD"} 2>/dev/null || echo "phase.sh: could not record to ledger" >&2
  exit 8
fi

mkdir -p "$WORKERS_DIR" 2>/dev/null || true
{
  printf 'pid=%s\n' "$$"
  printf 'run=%s\n' "$RUN_ID"
  printf 'phase=%s\n' "$PHASE"
  printf 'started=%s\n' "$STARTED_TS"
} > "$WORKER_RECORD_FILE" 2>/dev/null || true

# Scan brief and diff for secrets before dispatch unless --no-secret-scan or AGY_SKIP_SECRET_SCAN=1.
# Secret scan runs before brief lint: a malformed brief costs a wasted dispatch,
# and a brief carrying a credential is a disclosure. When both are true the
# disclosure is the one the person needs to be told about, because it is the one
# with consequences outside this machine — and a credential does not stop
# needing rotation because the brief that carried it also had the wrong verdict
# path.
SECRETS_FIELD=""
if [ -z "$SKIP_SECRET_SCAN" ]; then
  SECRETS_ARGS=(--brief "$BRIEF" --dir "$DIR" --run "$RUN_ID" --phase "$PHASE")
  if [ -f "$R/REVIEW_DIFF.patch" ]; then
    SECRETS_ARGS=("${SECRETS_ARGS[@]+"${SECRETS_ARGS[@]}"}" --diff "$R/REVIEW_DIFF.patch")
  fi
  SECRETS_OUT="$("$HERE/check-secrets.sh" "${SECRETS_ARGS[@]}" 2>/dev/null)"
  SECRETS_RC=$?
  if [ "$SECRETS_RC" -ne 0 ]; then
    printf '%s\n' "$SECRETS_OUT$GITIGNORE_FIELD" | tee "$STATUS_FILE"
    TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
    [ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"
    SECRETS_STATUS="$(printf '%s' "${SECRETS_OUT#STATUS: }" | awk '{print $1}')"
    ledger_append "$DIR" \
      "run=$RUN_ID" \
      "phase=$PHASE" \
      "attempt=$((SPENT + 1))" \
      "tier=$TIER" \
      "model=$MODEL" \
      "backend=$DRIVER" \
      "started=$STARTED_TS" \
      "status=$SECRETS_STATUS" \
      "retries_spent=$SPENT" \
      "retries_refunded=0" \
      "verify_ran=false" \
      ${TASK_TO_RECORD:+"task=$TASK_TO_RECORD"} 2>/dev/null || echo "phase.sh: could not record to ledger" >&2
    exit "$SECRETS_RC"
  fi
  case "$SECRETS_OUT" in
    *"SECRETS_UNCHECKED"*)
      SECRETS_STATUS="$(printf '%s' "${SECRETS_OUT#STATUS: }" | awk '{print $1}')"
      SECRETS_FIELD=" | Secrets: $SECRETS_STATUS"
      ;;
  esac
fi

# Lint brief before dispatch unless --no-brief-lint or AGY_SKIP_BRIEF_LINT=1.
if [ -z "$SKIP_BRIEF_LINT" ]; then
  LINT_SHELL_ARGS=()
  if [ -n "$ALLOW_SHELL" ] || [ "$MODE" = "full" ] || [ "$PHASE" = "QA" ]; then
    LINT_SHELL_ARGS=(--allow-shell)
  fi
  LINT_OUT="$("$HERE/check-brief.sh" --phase "$PHASE" --brief "$BRIEF" --dir "$DIR" --run "$RUN_ID" ${LINT_SHELL_ARGS[@]+"${LINT_SHELL_ARGS[@]}"} 2>/dev/null)"
  LINT_RC=$?
  if [ "$LINT_RC" -ne 0 ]; then
    printf '%s\n' "$LINT_OUT$GITIGNORE_FIELD" | tee "$STATUS_FILE"
    TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
    [ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"
    LINT_STATUS="$(printf '%s' "${LINT_OUT#STATUS: }" | awk '{print $1}')"
    ledger_append "$DIR" \
      "run=$RUN_ID" \
      "phase=$PHASE" \
      "attempt=$((SPENT + 1))" \
      "tier=$TIER" \
      "model=$MODEL" \
      "backend=$DRIVER" \
      "started=$STARTED_TS" \
      "status=$LINT_STATUS" \
      "retries_spent=$SPENT" \
      "retries_refunded=0" \
      "verify_ran=false" \
      ${TASK_TO_RECORD:+"task=$TASK_TO_RECORD"} 2>/dev/null || echo "phase.sh: could not record to ledger" >&2
    exit "$LINT_RC"
  fi
fi

# The same phase name is re-run by the Phase 2 review loop, so a verdict left by
# the previous round would otherwise be read as this round's answer.
rm -f "$VERDICT_FILE"

# Missing CLI, expired sign-in or a model id this account cannot use otherwise
# surface deep inside the phase, after the brief is written and the time is
# spent. Check first — one live `agy models` fetch, a few seconds against a
# phase measured in minutes — and report the refusal as a STATUS line, because
# the orchestrator never reads stderr. On by default: a sign-in can lapse and a
# model id can be withdrawn mid-pipeline, so Phase 0 alone is not enough.
# AGY_SKIP_PREFLIGHT=1 or --no-preflight drops it for a tight retry loop.
FALLBACK_FIELD=""
if [ -z "$SKIP_PREFLIGHT" ]; then
  PREFLIGHT_LOG="$PHASE_DIR/preflight.log"
  PREFLIGHT_MODEL_FILE="$PHASE_DIR/model"
  rm -f "$PREFLIGHT_MODEL_FILE"
  PREFLIGHT_ARGS=(--model "$MODEL" --phase "$PHASE" --dir "$DIR" --output-model "$PREFLIGHT_MODEL_FILE" --quiet)
  "$HERE/preflight.sh" "${PREFLIGHT_ARGS[@]}" >/dev/null 2>"$PREFLIGHT_LOG"
  PRC=$?
  if [ "$PRC" -ne 0 ]; then
    case "$PRC" in
      127) REASON="agy_not_found" ;;
      3)   REASON="not_signed_in" ;;
      4)   REASON="model_unavailable:$MODEL" ;;
      7)   REASON="timeout" ;;
      *)   REASON="rc=$PRC" ;;
    esac
    printf '%s\n' "STATUS: PREFLIGHT_FAILED($REASON) | Phase: $PHASE | Run: $RUN_ID | Next: report the cause, do the work yourself | Log: $PREFLIGHT_LOG$GITIGNORE_FIELD" \
      | tee "$STATUS_FILE"
    TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
    [ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"
    ledger_append "$DIR" \
      "run=$RUN_ID" \
      "phase=$PHASE" \
      "attempt=$((SPENT + 1))" \
      "tier=$TIER" \
      "model=$MODEL" \
      "backend=$DRIVER" \
      "started=$STARTED_TS" \
      "status=PREFLIGHT_FAILED($REASON)" \
      "retries_spent=$SPENT" \
      "retries_refunded=0" \
      "verify_ran=false" \
      ${TASK_TO_RECORD:+"task=$TASK_TO_RECORD"} 2>/dev/null || echo "phase.sh: could not record to ledger" >&2
    exit "$PRC"
  fi
  if [ -f "$PREFLIGHT_MODEL_FILE" ]; then
    RESOLVED_MODEL="$(cat "$PREFLIGHT_MODEL_FILE" 2>/dev/null || true)"
    rm -f "$PREFLIGHT_MODEL_FILE"
    if [ -n "$RESOLVED_MODEL" ] && [ "$RESOLVED_MODEL" != "$MODEL" ]; then
      FALLBACK_FIELD=" | Fallback: $RESOLVED_MODEL"
      MODEL="$RESOLVED_MODEL"
    fi
  fi
fi

# Count the dispatch the moment it is committed to, not once it comes back: a
# round killed halfway still spent a retry, and only a counter written up front
# survives to say so.
printf '%s\n' "$NEXT" > "$RETRY_FILE" 2>/dev/null

# Take a snapshot of the working tree before dispatch to isolate what the worker changed,
# even if the working tree was already dirty before dispatch.
TREE_BEFORE=""
if [ -z "$SKIP_DIFF_INTEGRITY" ]; then
  if GITROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" \
     && [ "$(git -C "$DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
     && [ -n "$GITROOT" ]; then
    _TREE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/phase-tree.XXXXXX" 2>/dev/null || true)"
    if [ -n "$_TREE_WORK" ] && [ -d "$_TREE_WORK" ]; then
      _TREE_IDX="$_TREE_WORK/index"
      _REAL_IDX="$(git -C "$GITROOT" rev-parse --git-path index 2>/dev/null)"
      if [ -n "$_REAL_IDX" ] && [ -f "$GITROOT/$_REAL_IDX" ]; then
        cp -f "$GITROOT/$_REAL_IDX" "$_TREE_IDX" 2>/dev/null || true
      elif [ -n "$_REAL_IDX" ] && [ -f "$_REAL_IDX" ]; then
        cp -f "$_REAL_IDX" "$_TREE_IDX" 2>/dev/null || true
      fi
      ( cd "$GITROOT" && GIT_INDEX_FILE="$_TREE_IDX" git add -A -- . ) >/dev/null 2>&1 || true
      TREE_BEFORE="$(cd "$GITROOT" && GIT_INDEX_FILE="$_TREE_IDX" git write-tree 2>/dev/null || true)"
      rm -rf "$_TREE_WORK" 2>/dev/null || true
    fi
  fi
fi

GIT_STATE_BEFORE=""
GIT_STATE_SNAP_RC=0
if [ -n "$CHECK_GIT_STATE" ]; then
  GIT_STATE_BEFORE="$PHASE_DIR/git_state_before.txt"
  /bin/bash "$HERE/check-git-state.sh" snapshot --dir "$DIR" --out "$GIT_STATE_BEFORE" >/dev/null 2>&1
  GIT_STATE_SNAP_RC=$?
fi

START_EPOCH=$(date +%s)

MONITOR_PID=""
if [ -z "${AGY_NO_PROGRESS:-}" ] && [ "$QUIET" -eq 0 ]; then
  HB_INTERVAL="${AGY_HEARTBEAT_INTERVAL:-30}"
  LIVENESS_INTERVAL="${AGY_LIVENESS_INTERVAL:-300}"
  case "$LIVENESS_INTERVAL" in
    *m) L_SEC="${LIVENESS_INTERVAL%m}"; L_MULT=60 ;;
    *s) L_SEC="${LIVENESS_INTERVAL%s}"; L_MULT=1 ;;
    *)  L_SEC="$LIVENESS_INTERVAL";     L_MULT=1 ;;
  esac
  case "$L_SEC" in
    ''|*[!0-9]*) L_LIMIT=300 ;;
    *) L_LIMIT=$((L_SEC * L_MULT)) ;;
  esac

  (
    LAST_LOG_SIZE=0
    LAST_LOG_CHANGE=$START_EPOCH
    WARNED_LIVENESS=0
    NEXT_HB=$((START_EPOCH + HB_INTERVAL))

    while :; do
      sleep 1
      NOW=$(date +%s)

      CUR_SIZE=0
      if [ -f "$LOG" ]; then
        CUR_SIZE="$(wc -c < "$LOG" 2>/dev/null | tr -cd '0-9')"
        CUR_SIZE="${CUR_SIZE:-0}"
      fi

      if [ "$CUR_SIZE" -gt "$LAST_LOG_SIZE" ]; then
        LAST_LOG_SIZE="$CUR_SIZE"
        LAST_LOG_CHANGE="$NOW"
        WARNED_LIVENESS=0
      fi

      IDLE_TIME=$((NOW - LAST_LOG_CHANGE))
      if [ "$L_LIMIT" -gt 0 ] && [ "$IDLE_TIME" -ge "$L_LIMIT" ] && [ "$WARNED_LIVENESS" -eq 0 ]; then
        if [ $((L_LIMIT % 60)) -eq 0 ]; then
          L_DISP="$((L_LIMIT / 60))m"
        else
          L_DISP="${L_LIMIT}s"
        fi
        ELAPSED=$((NOW - START_EPOCH))
        printf 'phase.sh: [%ds] Run: %s | no output for %s — the worker may be hung; the timeout is at %s\n' "$ELAPSED" "$RUN_ID" "$L_DISP" "$TIMEOUT" >&2
        WARNED_LIVENESS=1
      fi

      if [ "$NOW" -ge "$NEXT_HB" ]; then
        ELAPSED=$((NOW - START_EPOCH))
        LAST_FILE=""
        if [ -f "$LOG" ] && [ -s "$LOG" ]; then
          LAST_FILE="$(tail -n 50 "$LOG" 2>/dev/null | LC_ALL=C sed -n \
            -e 's/.*"TargetFile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            -e 's/.*TargetFile:[[:space:]]*\([^,[:space:]]*\).*/\1/p' \
            -e 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            -e 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            -e 's/.*File:[[:space:]]*\([^|[:space:]]*\).*/\1/p' \
            -e 's/.*file:[[:space:]]*\([^|[:space:]]*\).*/\1/p' | tail -1)"
          if [ -n "$LAST_FILE" ]; then
            case "$LAST_FILE" in
              "$DIR"/*) LAST_FILE="${LAST_FILE#$DIR/}" ;;
            esac
          fi
        fi

        FILE_FIELD=""
        if [ -n "$LAST_FILE" ]; then
          FILE_FIELD=" | File: $LAST_FILE"
        fi

        printf 'phase.sh: [%ds] Run: %s | Phase: %s | Tier: %s | Model: %s%s\n' "$ELAPSED" "$RUN_ID" "$PHASE" "$TIER" "$MODEL" "$FILE_FIELD" >&2
        NEXT_HB=$((NOW + HB_INTERVAL))
      fi
    done
  ) &
  MONITOR_PID=$!
fi

driver_run --brief "$BRIEF" --dir "$DIR" --log "$LOG" \
  --model "$MODEL" --mode "$MODE" --timeout "$TIMEOUT" \
  ${SANDBOX_ARGS[@]+"${SANDBOX_ARGS[@]}"} >/dev/null 2>&1
RC=$?
ELAPSED_S=$(( $(date +%s) - START_EPOCH ))

if [ -n "$MONITOR_PID" ]; then
  kill "$MONITOR_PID" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true
fi

if [ "$RC" -ne 0 ] && [ "$QUIET" -eq 0 ] && [ -f "$LOG" ] && [ -s "$LOG" ]; then
  printf -- '--- phase.sh: log tail (%s) ---\n' "$LOG" >&2
  tail -n 20 "$LOG" >&2
  printf -- '--- phase.sh: end log tail ---\n' >&2
fi

RESULT_JSON="$PHASE_DIR/result.json"
JSON_FALLBACK_FIELD=""
USAGE_OBJ=""
NUM_TURNS_VAL=""
AGY_STATUS_VAL=""

if [ -f "$RESULT_JSON" ] && [ -s "$RESULT_JSON" ]; then
  RES_LINE="$(cat "$RESULT_JSON" 2>/dev/null || true)"
  USAGE_OBJ="$(printf '%s\n' "$RES_LINE" | sed -n 's/.*"usage":\({[^}]*}\).*/\1/p' 2>/dev/null || true)"
  NUM_TURNS_VAL="$(printf '%s\n' "$RES_LINE" | sed -n 's/.*"num_turns":\([0-9][0-9]*\).*/\1/p' 2>/dev/null || true)"
  AGY_STATUS_VAL="$(printf '%s\n' "$RES_LINE" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' 2>/dev/null || true)"
elif [ "$RC" -eq 0 ]; then
  JSON_FALLBACK_FIELD=" | Note: worker output was not valid JSON; fell back to raw text"
fi

# Primary: the verdict the worker wrote to R/phases/<PHASE>/verdict — first non-empty
# line, no transcript involved. Fallback: the last transcript line that *starts*
# with STATUS:, so prose like "I will end with STATUS: PASSED" cannot match.
CLAIM=""
if [ -s "$VERDICT_FILE" ]; then
  CLAIM="$(strip_ansi < "$VERDICT_FILE" 2>/dev/null | awk 'NF { print; exit }' | trim_claim)"
fi
if [ -z "$CLAIM" ] && [ -f "$LOG" ]; then
  CLAIM="$(strip_ansi < "$LOG" 2>/dev/null \
    | grep -a -E '^[[:space:]*#>_`-]*STATUS:' | tail -1 | trim_claim)"
fi
case "$CLAIM" in
  ""|STATUS:*) ;;
  *) CLAIM="STATUS: $CLAIM" ;;   # a verdict file that omitted the marker
esac

# The gate SKILL.md asks the orchestrator to run by hand, run here instead. It
# is a claim the worker cannot make good on by asserting it: the check runs in
# $DIR, through a shell so `&&` and pipelines work, and its own exit code — not
# the verdict — decides. Skipped when the worker itself failed or preflight
# refused: there is no work to check. Output goes to its own log and never to
# stdout, which belongs to the STATUS line alone.
VRC=0
if [ -n "$VERIFY" ] && [ "$RC" -eq 0 ]; then
  printf -- '--- phase.sh: verify %s ---\n$ %s\n' "$PHASE" "$VERIFY" > "$VERIFY_LOG" 2>/dev/null
  # No pipe here on purpose: $? is the check's own code, not a tee's.
  ( cd "$DIR" && /bin/bash -c "$VERIFY" ) >> "$VERIFY_LOG" 2>&1
  VRC=$?
  printf -- '--- phase.sh: verify rc=%s ---\n' "$VRC" >> "$VERIFY_LOG" 2>/dev/null
fi

# Run git state check if requested
GIT_STATE_FIELD=""
GIT_STATE_RC=0
GIT_STATE_STATUS=""

if [ -n "$CHECK_GIT_STATE" ]; then
  if [ -n "$GIT_STATE_BEFORE" ] && [ -f "$GIT_STATE_BEFORE" ] && [ "$GIT_STATE_SNAP_RC" -eq 0 ]; then
    GIT_STATE_OUT="$(/bin/bash "$HERE/check-git-state.sh" compare --dir "$DIR" --before "$GIT_STATE_BEFORE" 2>/dev/null)"
    GIT_STATE_RC=$?
    GIT_STATE_STATUS="$(printf '%s\n' "$GIT_STATE_OUT" | sed -e 's/^STATUS:[[:space:]]*//' -e 's/[[:space:]]*|.*//')"
    if [ -z "$GIT_STATE_STATUS" ]; then
      GIT_STATE_STATUS="GIT_STATE_UNCHECKED(empty_output)"
      [ "$GIT_STATE_RC" -eq 0 ] && GIT_STATE_RC=2
    elif [ "$GIT_STATE_RC" -ne 0 ] && [ "$GIT_STATE_STATUS" = "GIT_STATE_UNCHANGED" ]; then
      GIT_STATE_STATUS="GIT_STATE_UNCHECKED(rc=$GIT_STATE_RC)"
    fi
    GIT_STATE_FIELD=" | GitState: $GIT_STATE_STATUS"
  else
    GIT_STATE_STATUS="GIT_STATE_UNCHECKED(no_snapshot)"
    GIT_STATE_RC=2
    GIT_STATE_FIELD=" | GitState: $GIT_STATE_STATUS"
  fi
fi

# Run diff integrity check over the changes the worker made
INTEGRITY_FIELD=""
INTEGRITY_RC=0

if [ -n "$SKIP_DIFF_INTEGRITY" ]; then
  INTEGRITY_FIELD=" | Integrity: skipped"
elif [ "$RC" -eq 0 ]; then
  if [ -n "$TREE_BEFORE" ]; then
    DISPATCH_PATCH="$PHASE_DIR/DISPATCH_DIFF.patch"
    DISPATCH_STAT="$PHASE_DIR/DISPATCH_DIFF.stat"
    CAPTURE_OUT="$("$HERE/capture-diff.sh" --dir "$DIR" --base "$TREE_BEFORE" --into "$PHASE_DIR" --name "DISPATCH_DIFF" 2>/dev/null)"
    CAPTURE_RC=$?
    if [ "$CAPTURE_RC" -eq 0 ] || [ "$CAPTURE_RC" -eq 3 ]; then
      INTEGRITY_OUT="$("$HERE/check-diff-integrity.sh" --dir "$DIR" --patch "$DISPATCH_PATCH" --stat "$DISPATCH_STAT" --brief "$PHASE_DIR/brief.md" 2>/dev/null)"
      INTEGRITY_RC=$?
      INTEGRITY_STATUS="$(printf '%s\n' "$INTEGRITY_OUT" | sed -e 's/^STATUS:[[:space:]]*//' -e 's/[[:space:]]*|.*//')"
      [ -z "$INTEGRITY_STATUS" ] && INTEGRITY_STATUS="DIFF_UNCHECKED(empty_output)"
      INTEGRITY_FIELD=" | Integrity: $INTEGRITY_STATUS"
    else
      INTEGRITY_STATUS="DIFF_UNCHECKED(capture_failed)"
      INTEGRITY_FIELD=" | Integrity: $INTEGRITY_STATUS"
    fi
  else
    INTEGRITY_STATUS="DIFF_UNCHECKED(no_tree_snapshot)"
    INTEGRITY_FIELD=" | Integrity: $INTEGRITY_STATUS"
  fi
fi

# Trust the claim only as a claim — the orchestrator still verifies the artifacts
# on disk. rc=0 with no claim at all is not a failure and not a pass; say so.
if [ "$RC" -ne 0 ]; then
  LINE="STATUS: WORKER_FAILED(rc=$RC) | Phase: $PHASE | Run: $RUN_ID | Next: check the brief path and the criteria, then retry once | Log: $LOG"
elif [ -n "$VERIFY" ] && [ "$VRC" -ne 0 ]; then
  LINE="STATUS: VERIFY_FAILED(rc=$VRC) | Phase: $PHASE | Run: $RUN_ID | Claimed: ${CLAIM:-none} | Next: read the verify log named on this line, then fix or re-brief once | Log: $LOG | VerifyLog: $VERIFY_LOG"
elif [ -n "$CHECK_GIT_STATE" ] && [ "$GIT_STATE_RC" -ne 0 ]; then
  LINE="STATUS: $GIT_STATE_STATUS | Phase: $PHASE | Run: $RUN_ID | Claimed: ${CLAIM:-none} | Next: git state changed during phase execution — inspect git status | Log: $LOG"
elif [ -n "$CLAIM" ]; then
  LINE="$CLAIM | Phase: $PHASE | Run: $RUN_ID | Log: $LOG"
else
  LINE="STATUS: NO_STATUS_REPORTED | Phase: $PHASE | Run: $RUN_ID | Note: worker exited 0 without a verdict — the phase may have succeeded anyway; verify the artifact on disk before advancing or retrying | Next: check the diff, it may well have worked; neither pass nor fail | Log: $LOG"
fi
# Appended, never spliced: every existing caller matches on the head of this
# line, so a passing check adds to it and shifts nothing.
if [ -n "$VERIFY" ] && [ "$VRC" -eq 0 ] && [ "$RC" -eq 0 ]; then
  LINE="$LINE | Verify: ok | VerifyLog: $VERIFY_LOG"
fi
LINE="$LINE$GIT_STATE_FIELD$INTEGRITY_FIELD$FALLBACK_FIELD$JSON_FALLBACK_FIELD$SECRETS_FIELD$GITIGNORE_FIELD"

# Record the phase outcome in run.json
FINAL_STATUS="$(printf '%s' "${LINE#STATUS: }" | awk '{print $1}')"
FINAL_VERDICT="$(printf '%s' "${CLAIM#STATUS: }" | awk '{print $1}')"
run_dir_record_phase "$R" "$PHASE" "status=$FINAL_STATUS" "verdict=${FINAL_VERDICT:-$FINAL_STATUS}" "attempts=$((SPENT + 1))"

# A round that ends clean ends the cycle, so the next one starts from zero
# without anybody having to remember --reset-retries. Clean means the worker
# returned, the check (if any) held, and the verdict is not one of the phrasings
# every phase uses for "I could not". NO_STATUS_REPORTED is not clean: it is
# unresolved, and an unresolved round is exactly what the cap is counting.
CLEAN=0
if [ "$RC" -eq 0 ] && [ "$VRC" -eq 0 ] && [ "$GIT_STATE_RC" -eq 0 ] && [ "$INTEGRITY_RC" -eq 0 ] && [ -n "$CLAIM" ]; then
  WORD="$(printf '%s' "${CLAIM#STATUS: }" | awk '{print $1}' \
    | tr -d '|' | tr '[:lower:]' '[:upper:]')"
  case "$WORD" in
    FAILED|BLOCKED|ERROR|REJECTED) ;;
    *) CLEAN=1 ;;
  esac
fi
[ "$CLEAN" -eq 1 ] && rm -f "$RETRY_FILE"

# The refund. The cap exists to stop a review-fix loop that is not converging,
# so it should only be spent by a worker that tried and did not converge. A
# WORKER_FAILED round is not that: agy died on its own configuration — an
# unreadable criteria path, a brief it could not open — in seconds, before any
# reasoning happened, and it leaves no feedback file for the next round to work
# from either. Two of those in a row would have retired a review phase that had
# never reviewed anything. So the counter goes back exactly as it was, an absent
# file included. FAILED, VERIFY_FAILED and NO_STATUS_REPORTED all keep spending:
# each of them is a worker that ran and left the round unresolved.
#
# This deliberately does not run from a trap, and that is the whole answer to
# the case writing the counter up front protects — a round killed halfway. A
# user's ^C reaches phase.sh with the worker, phase.sh dies here and never
# reaches this line, so the retry it wrote before dispatching stands. Only a
# worker that returned a non-zero code to a phase.sh still running is refunded.
if [ "$RC" -ne 0 ]; then
  if [ -n "$HAD_COUNTER" ]; then
    printf '%s\n' "$SPENT" > "$RETRY_FILE" 2>/dev/null
  else
    rm -f "$RETRY_FILE"
  fi
fi

# Record dispatch outcome to ledger
TASK_TO_RECORD="${EXISTING_TASK:-${TASK:-}}"
[ -z "$TASK_TO_RECORD" ] && TASK_TO_RECORD="$(run_dir_get "$R" "task" 2>/dev/null || true)"

LEDGER_ARGS=(
  "run=$RUN_ID"
  "phase=$PHASE"
  "attempt=$((SPENT + 1))"
  "tier=$TIER"
  "model=$MODEL"
  "backend=$DRIVER"
  "started=$STARTED_TS"
  "elapsed_s=$ELAPSED_S"
  "worker_rc=$RC"
  "status=$FINAL_STATUS"
  "retries_spent=$SPENT"
)

if [ -n "$FINAL_VERDICT" ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "verdict=$FINAL_VERDICT")
fi

if [ -n "$VERIFY" ] && [ "$RC" -eq 0 ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "verify_ran=true" "verify_rc=$VRC")
else
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "verify_ran=false")
fi

if [ -n "$CHECK_GIT_STATE" ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "git_state_ran=true" "git_state_rc=$GIT_STATE_RC")
fi

if [ "$RC" -ne 0 ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "retries_refunded=1")
else
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "retries_refunded=0")
fi

if [ -n "$TASK_TO_RECORD" ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "task=$TASK_TO_RECORD")
fi

if [ -n "$USAGE_OBJ" ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "usage=$USAGE_OBJ")
fi

if [ -n "$NUM_TURNS_VAL" ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "num_turns=$NUM_TURNS_VAL")
fi

if [ -n "$AGY_STATUS_VAL" ]; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "agy_status=$AGY_STATUS_VAL")
fi

if DIFF_OBJ="$(_ledger_extract_diff "$R")"; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "diff=$DIFF_OBJ")
fi

if REV_OBJ="$(_ledger_extract_review "$DIR" "$R")"; then
  LEDGER_ARGS=("${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" "review=$REV_OBJ")
fi

ledger_append "$DIR" "${LEDGER_ARGS[@]+"${LEDGER_ARGS[@]}"}" 2>/dev/null || echo "phase.sh: could not record to ledger" >&2

printf '%s\n' "$LINE" | tee "$STATUS_FILE"
[ "$RC" -eq 0 ] || exit "$RC"
[ "$VRC" -eq 0 ] || exit 5
[ "$GIT_STATE_RC" -eq 0 ] || exit "$GIT_STATE_RC"
[ "$INTEGRITY_RC" -eq 0 ] || exit "$INTEGRITY_RC"
exit 0
