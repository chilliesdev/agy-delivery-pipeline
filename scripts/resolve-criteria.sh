#!/usr/bin/env bash
# Print the absolute path of the criteria file a review/QA brief should cite.
#
#   resolve-criteria.sh <code-review|qa> [--dir <repo>]
#
# Precedence (first hit wins):
#   1. <repo>/.claude/criteria/<name>.md     project-local override
#   2. ~/.claude/skills/<skill>/SKILL.md     the user's own Claude skill
#   3. <this repo>/criteria/<name>.md        vendored fallback, always present
#
# --dir defaults to $PWD and is the repo being worked on, not this one. The
# vendored fallback ships in this repo, so resolution never fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=""; DIR="$PWD"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "resolve-criteria: unknown arg $1" >&2; exit 2 ;;
    *) [ -z "$NAME" ] || { echo "resolve-criteria: unexpected arg $1" >&2; exit 2; }
       NAME="$1"; shift ;;
  esac
done

case "$NAME" in
  code-review) SKILL="$HOME/.claude/skills/code-review/SKILL.md" ;;
  qa)          SKILL="$HOME/.claude/skills/e2e-qa-tester/SKILL.md" ;;
  "") echo "resolve-criteria: name required (code-review|qa)" >&2; exit 2 ;;
  *)  echo "resolve-criteria: unknown criteria $NAME (want code-review|qa)" >&2; exit 2 ;;
esac

[ -d "$DIR" ] || { echo "resolve-criteria: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

for CANDIDATE in "$DIR/.claude/criteria/$NAME.md" "$SKILL" "$HERE/../criteria/$NAME.md"; do
  if [ -f "$CANDIDATE" ]; then
    printf '%s\n' "$(cd "$(dirname "$CANDIDATE")" && pwd)/$(basename "$CANDIDATE")"
    exit 0
  fi
done

echo "resolve-criteria: no criteria file found for $NAME" >&2
exit 1
