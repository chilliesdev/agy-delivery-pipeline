#!/usr/bin/env bash
# Snapshot and compare git state to verify no-push/no-mutation guarantees.
#
#   check-git-state.sh snapshot --dir <repo> --out <file>
#   check-git-state.sh compare  --dir <repo> --before <file>
#
# Reads:   HEAD, tags, and refs of the target git repository.
# Writes:  only the file named by --out in snapshot mode.
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes:
#     0  GIT_STATE_UNCHANGED (or snapshot success)
#     2  bad arguments, missing options, or not a git repository
#     3  GIT_STATE_CHANGED(<what changed>)
set -uo pipefail


CMD=""
DIR="$PWD"
OUT_FILE=""
BEFORE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    snapshot|compare)
      if [ -n "$CMD" ] && [ "$CMD" != "$1" ]; then
        echo "check-git-state: multiple commands specified: $CMD, $1" >&2
        exit 2
      fi
      CMD="$1"; shift ;;
    --dir)
      [ $# -ge 2 ] || { echo "check-git-state: --dir requires an argument" >&2; exit 2; }
      DIR="$2"; shift 2 ;;
    --out)
      [ $# -ge 2 ] || { echo "check-git-state: --out requires an argument" >&2; exit 2; }
      OUT_FILE="$2"; shift 2 ;;
    --before)
      [ $# -ge 2 ] || { echo "check-git-state: --before requires an argument" >&2; exit 2; }
      BEFORE_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "check-git-state: unknown arg $1" >&2; exit 2 ;;
  esac
done

if [ -z "$CMD" ]; then
  echo "check-git-state: command required (snapshot|compare)" >&2
  exit 2
fi

[ -d "$DIR" ] || { echo "check-git-state: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

if ! ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "check-git-state: not a git repository: $DIR" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

_get_state() {
  local target="$1"
  local head_sha
  head_sha="$(git -C "$target" rev-parse HEAD 2>/dev/null || true)"
  printf 'HEAD: %s\n' "${head_sha:-none}"
  printf -- '--- TAGS ---\n'
  git -C "$target" tag -l 2>/dev/null | LC_ALL=C sort
  printf -- '--- REFS ---\n'
  git -C "$target" for-each-ref 2>/dev/null | LC_ALL=C sort
}

if [ "$CMD" = "snapshot" ]; then
  if [ -z "$OUT_FILE" ]; then
    echo "check-git-state: snapshot requires --out <file>" >&2
    exit 2
  fi
  OUT_DIR="$(dirname "$OUT_FILE")"
  mkdir -p "$OUT_DIR" 2>/dev/null || { echo "check-git-state: could not create directory for $OUT_FILE" >&2; exit 2; }
  _get_state "$ROOT" > "$OUT_FILE" 2>/dev/null || { echo "check-git-state: could not write to $OUT_FILE" >&2; exit 2; }
  printf '%s\n' "STATUS: GIT_STATE_UNCHANGED | Checks: head, tags, refs | Snapshot: $OUT_FILE | Dir: $ROOT"
  exit 0
fi

if [ "$CMD" = "compare" ]; then
  if [ -z "$BEFORE_FILE" ]; then
    echo "check-git-state: compare requires --before <file>" >&2
    exit 2
  fi
  if [ ! -f "$BEFORE_FILE" ]; then
    echo "check-git-state: before file not found: $BEFORE_FILE" >&2
    exit 2
  fi

  BEFORE_HEAD="$(grep '^HEAD: ' "$BEFORE_FILE" 2>/dev/null | head -1 | sed 's/^HEAD: //')"
  BEFORE_TAGS="$(awk '/^--- TAGS ---$/{flag=1; next} /^--- REFS ---$/{flag=0} flag' "$BEFORE_FILE" 2>/dev/null)"
  BEFORE_REFS="$(awk '/^--- REFS ---$/{flag=1; next} flag' "$BEFORE_FILE" 2>/dev/null)"

  CURR_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  CURR_HEAD="${CURR_HEAD:-none}"
  CURR_TAGS="$(git -C "$ROOT" tag -l 2>/dev/null | LC_ALL=C sort)"
  CURR_REFS="$(git -C "$ROOT" for-each-ref 2>/dev/null | LC_ALL=C sort)"

  CHANGED_ITEMS=()
  if [ "$BEFORE_HEAD" != "$CURR_HEAD" ]; then
    CHANGED_ITEMS[${#CHANGED_ITEMS[@]}]="head"
  fi
  if [ "$BEFORE_TAGS" != "$CURR_TAGS" ]; then
    CHANGED_ITEMS[${#CHANGED_ITEMS[@]}]="tags"
  fi
  if [ "$BEFORE_REFS" != "$CURR_REFS" ]; then
    CHANGED_ITEMS[${#CHANGED_ITEMS[@]}]="refs"
  fi

  if [ ${#CHANGED_ITEMS[@]} -eq 0 ]; then
    printf '%s\n' "STATUS: GIT_STATE_UNCHANGED | Checks: head, tags, refs | Head: $CURR_HEAD | Dir: $ROOT"
    exit 0
  else
    WHAT_CHANGED=""
    for item in "${CHANGED_ITEMS[@]}"; do
      if [ -z "$WHAT_CHANGED" ]; then
        WHAT_CHANGED="$item"
      else
        WHAT_CHANGED="$WHAT_CHANGED, $item"
      fi
    done

    DETAILS=""
    if [ "$BEFORE_HEAD" != "$CURR_HEAD" ]; then
      DETAILS=" | Head: $BEFORE_HEAD -> $CURR_HEAD"
    else
      DETAILS=" | Head: $CURR_HEAD"
    fi

    printf '%s\n' "STATUS: GIT_STATE_CHANGED($WHAT_CHANGED) | Checks: head, tags, refs$DETAILS | Dir: $ROOT"
    exit 3
  fi
fi
