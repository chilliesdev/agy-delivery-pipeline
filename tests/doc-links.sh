#!/usr/bin/env bash
# Check that relative markdown links and referenced repo paths in documentation exist.
#
#   tests/doc-links.sh
#
# Read-only — this suite inspects the repo and writes nothing anywhere.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CHECKED=0
FAIL=0
FAILURES=""

record_bad() {
  FAIL=$((FAIL + 1))
  FAILURES="${FAILURES}$1: broken reference to '$2'"$'\n'
}

# Documentation files to scan
DOC_FILES=""
[ -f "$ROOT/README.md" ] && DOC_FILES="$ROOT/README.md"
for S in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$S" ] && DOC_FILES="$DOC_FILES $S"
done
for C in "$ROOT"/commands/*.md; do
  [ -f "$C" ] && DOC_FILES="$DOC_FILES $C"
done

# Strip enclosing punctuation/quotes/brackets from a candidate reference
clean_candidate() {
  local cand="$1"
  while :; do
    case "$cand" in
      [\'\"\`\(\[\<]*) cand="${cand#?}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$cand" in
      *[:,\.\;\'\"\`\)\]\>]) cand="${cand%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$cand"
}

# Determine if a candidate should be discarded before resolution
should_discard() {
  local cand="$1"

  # 1. External links
  case "$cand" in
    http://*|https://*|mailto:*) return 0 ;;
  esac

  # 2. In-page anchors
  case "$cand" in
    \#*) return 0 ;;
  esac

  # 3. User-home paths (~, not a repo path)
  case "$cand" in
    \~*|\~/*) return 0 ;;
  esac

  # 4. Claude Code configuration paths in the user's home directory.
  # Three lines in this repo name Claude Code config paths deliberately:
  # README.md explains that ln -s "$PWD" ~/.claude/skills/multi-agent-delivery-pipeline no longer works,
  # and skills/agy-pipeline/SKILL.md has a section headed "A note on what is deliberately absent"
  # naming ~/.claude/skills/code-review/SKILL.md and .claude/skills/git-release-flow/SKILL.md.
  # Those lines are correct as written and must never resolve against the repo root.
  case "$cand" in
    .claude/*|*/.claude/*) return 0 ;;
  esac

  # 5. Globs, unexpanded variables, or template placeholders (contains *, ?, <, >, …, or $
  # other than a leading ${CLAUDE_PLUGIN_ROOT}/ prefix)
  local stripped="$cand"
  case "$stripped" in
    \$\{CLAUDE_PLUGIN_ROOT\}/*) stripped="${stripped#\$\{CLAUDE_PLUGIN_ROOT\}/}" ;;
  esac
  case "$stripped" in
    *\**|*\?*|*\$*|*\<*|*\>*|*…*|*...*) return 0 ;;
  esac

  # 6. Must not be empty
  [ -z "$cand" ] && return 0

  return 1
}

# Resolve candidate path to an absolute path on disk
resolve_path() {
  local ref="$1"
  local doc_dir="$2"

  case "$ref" in
    \$\{CLAUDE_PLUGIN_ROOT\}/*)
      printf '%s' "$ROOT/${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}"
      return 0
      ;;
  esac

  case "$ref" in
    *#*) ref="${ref%%#*}" ;;
  esac

  [ -z "$ref" ] && return 1

  case "$ref" in
    *../*|../*)
      printf '%s' "$doc_dir/$ref"
      return 0
      ;;
  esac

  case "$ref" in
    ./*)
      printf '%s' "$ROOT/${ref#./}"
      return 0
      ;;
  esac

  case "$ref" in
    scripts/*|tests/*|criteria/*|skills/*|commands/*|.claude-plugin/*|drivers/*)
      printf '%s' "$ROOT/$ref"
      return 0
      ;;
  esac

  if [ -e "$doc_dir/$ref" ]; then
    printf '%s' "$doc_dir/$ref"
  else
    printf '%s' "$ROOT/$ref"
  fi
  return 0
}

check_reference() {
  local raw="$1"
  local rel_doc="$2"
  local doc_dir="$3"
  local line_num="$4"

  local cand
  cand="$(clean_candidate "$raw")"

  if should_discard "$cand"; then
    return 0
  fi

  local resolved
  resolved="$(resolve_path "$cand" "$doc_dir")"

  CHECKED=$((CHECKED + 1))
  if [ ! -e "$resolved" ]; then
    record_bad "${rel_doc}:${line_num}" "$raw"
  fi
}

for DOC in $DOC_FILES; do
  [ -f "$DOC" ] || continue
  case "$DOC" in
    "$ROOT"/*) REL_DOC="${DOC#$ROOT/}" ;;
    *) REL_DOC="$DOC" ;;
  esac
  DOC_DIR="$(dirname "$DOC")"

  LINE_NUM=0
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    LINE_NUM=$((LINE_NUM + 1))

    # 1. Extract markdown link targets: text between ]( and matching )
    REST="$LINE"
    while case "$REST" in *']('*')'*) true ;; *) false ;; esac; do
      REST="${REST#*']('}"
      TARGET="${REST%%')'*}"
      REST="${REST#*')'}"
      check_reference "$TARGET" "$REL_DOC" "$DOC_DIR" "$LINE_NUM"
    done

    # 2. Extract bare repo paths: non-space tokens starting with known prefixes
    # First, strip markdown links so link text/targets are not re-parsed as malformed bare tokens
    STRIPPED_LINE=""
    REM="$LINE"
    while case "$REM" in *'['*']('*')'*) true ;; *) false ;; esac; do
      STRIPPED_LINE="$STRIPPED_LINE${REM%%'['*']('*')'*} "
      TEMP="${REM#*'['}"
      TEMP="${TEMP#*']('}"
      REM="${TEMP#*')'}"
    done
    STRIPPED_LINE="$STRIPPED_LINE$REM"

    # Disable globbing so word splitting does not expand wildcards
    set -f
    for TOKEN in $STRIPPED_LINE; do
      CLEAN_TOK="$(clean_candidate "$TOKEN")"
      case "$CLEAN_TOK" in
        scripts/*|tests/*|criteria/*|skills/*|commands/*|.claude-plugin/*|drivers/*|\$\{CLAUDE_PLUGIN_ROOT\}/*)
          check_reference "$CLEAN_TOK" "$REL_DOC" "$DOC_DIR" "$LINE_NUM"
          ;;
      esac
    done
    set +f
  done < "$DOC"
done

if [ "$FAIL" -gt 0 ]; then
  printf '%s' "$FAILURES"
  printf '\n%d checked, %d failed\n' "$CHECKED" "$FAIL"
  exit 1
fi

printf 'all %d referenced paths and links exist\n' "$CHECKED"
exit 0
