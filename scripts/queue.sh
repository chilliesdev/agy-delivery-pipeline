#!/usr/bin/env bash
# Park dispatches that hit the worker cap, and run them when a slot frees.
#
#   queue.sh add    --dir <repo> --run <id> --phase <NAME> -- <phase.sh args...>
#   queue.sh list   [--dir <repo>]
#   queue.sh position [--dir <repo>] --run <id> --phase <NAME>
#   queue.sh remove [--dir <repo>] --entry <name>
#   queue.sh drain  [--dir <repo>] [--max-workers <n>] [--once] [--dry-run]
#
# Reads/writes:  <repo>/.agy/queue/<entry>   one parked dispatch per file
# Prints:        one STATUS line for add/remove, a table for list, and for drain
#                the STATUS line of each dispatch it starts.
#
# Exit codes:
#     0  fine (including an empty queue)
#     2  bad arguments
#     3  no such entry
#     4  --dir is not a git work tree
#
# Why a queue, when the cap already refuses.
#
# `--max-workers` refuses at the cap and returns WORKER_CAP_EXCEEDED. That is the
# right answer for an orchestrator holding one task: it is told plainly that
# nothing was spent and it can decide. It is the wrong answer for a caller with
# five tasks and three slots, which has no way to express "run this when there is
# room" and must busy-poll or drop the work.
#
# So the refusal stays the default and this is opt-in through `phase.sh --queue`.
# A parked dispatch has spent nothing, holds no worker and blocks nothing; the
# queue is a directory of intentions, not a scheduler.
#
# There is no daemon, and draining is explicit.
#
# A background process that dispatched workers on its own would be the first thing
# in this repository to act without someone asking, and the hardest to reason about
# when it went wrong — an unattended run is already the case that is hard to see
# into. `drain` runs in the foreground, dispatches in the order things were queued,
# stops when the cap is reached, and prints what it did. It is a command a person
# or an orchestrator runs, like every other command here.
#
# Ordering is by queue time, oldest first, and is not a priority system. Entries
# are named <epoch>-<pid>-<run>-<phase> so that lexical order is arrival order.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

_queue_dir() {
  local dir="${1:-$PWD}"
  [ -d "$dir" ] || { echo "queue: dir not found: $dir" >&2; return 2; }
  dir="$(cd "$dir" && pwd)"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "queue: not a git repository: $dir" >&2
    return 4
  }
  printf '%s/.agy/queue\n' "$dir"
  return 0
}

# Entries in arrival order. Lexical order is arrival order by construction.
_queue_entries() {
  local qdir="$1"
  [ -d "$qdir" ] || return 0
  local f
  for f in "$qdir"/*; do
    [ -f "$f" ] || continue
    basename "$f"
  done | sort
}

_queue_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# The stored argv, one arg per line, in order.
_queue_args() { sed -n 's/^arg=//p' "$1" 2>/dev/null; }

queue_add() {
  local dir="$1" run="$2" phase="$3"
  shift 3

  local qdir
  qdir="$(_queue_dir "$dir")" || return $?
  mkdir -p "$qdir" 2>/dev/null || {
    echo "queue: could not create $qdir" >&2; return 2; }

  local entry
  entry="$(printf '%010d-%s-%s-%s' "$(date +%s)" "$$" "$run" "$phase")"

  {
    printf 'run=%s\n' "$run"
    printf 'phase=%s\n' "$phase"
    printf 'dir=%s\n' "$(cd "$dir" && pwd)"
    printf 'queued=%s\n' "$(date +%s)"
    printf 'queued_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    # Flattened the way ledger.sh flattens: one record per line is the invariant,
    # and a --task carrying a newline must not be able to break the file open.
    local a
    for a in "$@"; do
      a="${a//$'\r'/ }"
      a="${a//$'\n'/ }"
      printf 'arg=%s\n' "$a"
    done
  } > "$qdir/$entry" 2>/dev/null || {
    echo "queue: could not write $qdir/$entry" >&2; return 2; }

  printf '%s\n' "$entry"
  return 0
}

queue_position() {
  local qdir="$1" run="$2" phase="$3"
  local n=0 e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    n=$((n + 1))
    local e_run e_phase
    e_run="$(_queue_get "$qdir/$e" run)"
    e_phase="$(_queue_get "$qdir/$e" phase)"
    if [ "$e_run" = "$run" ] && [ "$e_phase" = "$phase" ]; then
      printf '%s\n' "$n"
      return 0
    fi
  done <<EOF
$(_queue_entries "$qdir")
EOF
  return 3
}

queue_depth() {
  local qdir="$1"
  _queue_entries "$qdir" | grep -c . | tr -cd '0-9'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  CMD="${1:-}"
  [ $# -gt 0 ] && shift || true

  DIR="$PWD"; RUN=""; PHASE=""; ENTRY=""; MAX_WORKERS=""; ONCE=0; DRY=0
  PASSTHROUGH=()
  SEEN_SEP=0
  while [ $# -gt 0 ]; do
    if [ "$SEEN_SEP" -eq 1 ]; then
      PASSTHROUGH[${#PASSTHROUGH[@]}]="$1"; shift; continue
    fi
    case "$1" in
      --) SEEN_SEP=1; shift ;;
      --dir)         DIR="$2";         shift 2 ;;
      --run)         RUN="$2";         shift 2 ;;
      --phase)       PHASE="$2";       shift 2 ;;
      --entry)       ENTRY="$2";       shift 2 ;;
      --max-workers) MAX_WORKERS="$2"; shift 2 ;;
      --once)        ONCE=1;           shift ;;
      --dry-run)     DRY=1;            shift ;;
      -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
      *) echo "queue: unknown arg $1" >&2; exit 2 ;;
    esac
  done

  QDIR="$(_queue_dir "$DIR")" || exit $?

  case "$CMD" in
    add)
      [ -n "$RUN" ] && [ -n "$PHASE" ] || {
        echo "queue: add wants --run and --phase" >&2; exit 2; }
      E="$(queue_add "$DIR" "$RUN" "$PHASE" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}")" || exit $?
      POS="$(queue_position "$QDIR" "$RUN" "$PHASE" || printf '?')"
      printf 'STATUS: QUEUED(position=%s, depth=%s) | Phase: %s | Run: %s | Entry: %s | Note: nothing dispatched and nothing spent — this is a parked intention, not a running worker | Next: run queue.sh drain when a slot frees, or raise --max-workers\n' \
        "$POS" "$(queue_depth "$QDIR")" "$PHASE" "$RUN" "$E"
      exit 0
      ;;

    list)
      DEPTH="$(queue_depth "$QDIR")"
      if [ "${DEPTH:-0}" -eq 0 ]; then
        echo "Queue is empty — nothing is parked."
        exit 0
      fi
      printf 'Queued dispatches (oldest first), depth %s:\n\n' "$DEPTH"
      printf '  %-4s %-22s %-12s %s\n' "pos" "run" "phase" "queued at"
      N=0
      while IFS= read -r E; do
        [ -n "$E" ] || continue
        N=$((N + 1))
        printf '  %-4s %-22s %-12s %s\n' "$N" \
          "$(_queue_get "$QDIR/$E" run)" \
          "$(_queue_get "$QDIR/$E" phase)" \
          "$(_queue_get "$QDIR/$E" queued_at)"
      done <<EOF
$(_queue_entries "$QDIR")
EOF
      printf '\n  Nothing here has been dispatched or has spent anything.\n'
      exit 0
      ;;

    position)
      [ -n "$RUN" ] && [ -n "$PHASE" ] || {
        echo "queue: position wants --run and --phase" >&2; exit 2; }
      queue_position "$QDIR" "$RUN" "$PHASE" || {
        echo "queue: not queued: $RUN/$PHASE" >&2; exit 3; }
      exit 0
      ;;

    remove)
      [ -n "$ENTRY" ] || { echo "queue: remove wants --entry" >&2; exit 2; }
      if [ -f "$QDIR/$ENTRY" ]; then
        rm -f "$QDIR/$ENTRY"
        printf 'STATUS: QUEUE_REMOVED | Entry: %s | Note: the parked dispatch was dropped; nothing had been spent on it\n' "$ENTRY"
        exit 0
      fi
      echo "queue: no such entry: $ENTRY" >&2
      exit 3
      ;;

    drain)
      DEPTH="$(queue_depth "$QDIR")"
      if [ "${DEPTH:-0}" -eq 0 ]; then
        echo "Queue is empty — nothing to drain."
        exit 0
      fi

      STARTED=0
      while IFS= read -r E; do
        [ -n "$E" ] || continue
        [ -f "$QDIR/$E" ] || continue

        E_RUN="$(_queue_get "$QDIR/$E" run)"
        E_PHASE="$(_queue_get "$QDIR/$E" phase)"
        E_DIR="$(_queue_get "$QDIR/$E" dir)"
        [ -n "$E_DIR" ] || E_DIR="$DIR"

        # Read the stored argv back one line at a time. It went in flattened, so
        # a line is an argument and nothing splits further.
        ARGS=()
        while IFS= read -r A; do
          ARGS[${#ARGS[@]}]="$A"
        done <<ARGEOF
$(_queue_args "$QDIR/$E")
ARGEOF

        if [ "$DRY" -eq 1 ]; then
          printf 'would dispatch: %s %s (%s)\n' "$E_RUN" "$E_PHASE" "$E"
          STARTED=$((STARTED + 1))
          [ "$ONCE" -eq 1 ] && break
          continue
        fi

        # Take the entry out of the queue before dispatching, not after. A drain
        # that died mid-dispatch would otherwise leave the entry behind and run it
        # twice on the next drain — and a phase dispatched twice is real spend.
        rm -f "$QDIR/$E" 2>/dev/null || true

        MW_ARGS=()
        [ -n "$MAX_WORKERS" ] && MW_ARGS=(--max-workers "$MAX_WORKERS")

        # Dispatched without --queue: if the cap is reached again the caller is
        # told, rather than the entry silently returning to the queue it just left.
        /bin/bash "$HERE/phase.sh" ${ARGS[@]+"${ARGS[@]}"} ${MW_ARGS[@]+"${MW_ARGS[@]}"}
        RC=$?
        STARTED=$((STARTED + 1))

        # Exit 8 is the cap: no slot freed, so stop rather than grinding through
        # the rest of the queue collecting refusals.
        if [ "$RC" -eq 8 ]; then
          echo "queue: worker cap reached — stopping the drain with $(queue_depth "$QDIR") still parked" >&2
          exit 0
        fi

        [ "$ONCE" -eq 1 ] && break
      done <<EOF
$(_queue_entries "$QDIR")
EOF

      printf 'queue: drain finished — %s dispatched, %s still parked\n' "$STARTED" "$(queue_depth "$QDIR")"
      exit 0
      ;;

    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    "") echo "queue: command required (add|list|position|remove|drain)" >&2; exit 2 ;;
    *)  echo "queue: unknown command $CMD (want add|list|position|remove|drain)" >&2; exit 2 ;;
  esac
fi
