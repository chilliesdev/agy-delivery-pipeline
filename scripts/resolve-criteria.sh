#!/usr/bin/env bash
# Install the criteria file a review/QA/release brief should cite *inside* the
# target repo, and print the path the brief must carry.
#
#   resolve-criteria.sh <code-review|qa|release> [--dir <repo>] [--run <id|current|last>]
#                       [--into <dir>] [--print-source] [--max-lines <n>] [--max-langs <n>]
#
# Precedence (first hit wins):
#   1. <repo>/.claude/criteria/<name>.md     the project's own bar
#   2. <this repo>/criteria/<name>.md        vendored default, always present
#
# For code-review, when no project override is present, composes:
#   base.md + detected lang/*.md + configured concern/*.md
#
# Writes:  <run-dir>/criteria/<name>.md      the copy the worker actually reads
# Prints:  STDOUT: that copy's absolute path — one line, nothing else.
#          STDERR: the STATUS line naming composed/overridden packs and warnings.
#
# Exit codes:
#     0  installed (or, with --print-source, resolved)
#     1  no criteria file found for that name
#     2  bad arguments, unknown pack, or malformed config
#     3  resolved, but the copy could not be made
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

NAME=""; DIR="$PWD"; INTO=""; PRINT_SOURCE=""
RUN_TARGET="current"
MAX_LINES="1000"
MAX_LANGS="3"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)          DIR="$2";  shift 2 ;;
    --run)          RUN_TARGET="$2"; shift 2 ;;
    --into)         INTO="$2"; shift 2 ;;
    --print-source) PRINT_SOURCE=1; shift ;;
    --max-lines)    MAX_LINES="$2"; shift 2 ;;
    --max-langs)    MAX_LANGS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "resolve-criteria: unknown arg $1" >&2; exit 2 ;;
    *) [ -z "$NAME" ] || { echo "resolve-criteria: unexpected arg $1" >&2; exit 2; }
       NAME="$1"; shift ;;
  esac
done

case "$MAX_LINES" in
  ''|*[!0-9]*) echo "resolve-criteria: --max-lines wants a whole number, got '$MAX_LINES'" >&2; exit 2 ;;
esac
case "$MAX_LANGS" in
  ''|*[!0-9]*) echo "resolve-criteria: --max-langs wants a whole number, got '$MAX_LANGS'" >&2; exit 2 ;;
esac

case "$NAME" in
  code-review|qa|release) ;;
  "") echo "resolve-criteria: name required (code-review|qa|release)" >&2; exit 2 ;;
  *)  echo "resolve-criteria: unknown criteria $NAME (want code-review|qa|release)" >&2; exit 2 ;;
esac

[ -d "$DIR" ] || { echo "resolve-criteria: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

SOURCE=""
IS_OVERRIDE=0

if [ -f "$DIR/.claude/criteria/$NAME.md" ]; then
  SOURCE="$(cd "$DIR/.claude/criteria" && pwd)/$NAME.md"
  IS_OVERRIDE=1
elif [ -f "$HERE/../criteria/$NAME.md" ]; then
  SOURCE="$(cd "$HERE/../criteria" && pwd)/$NAME.md"
elif [ "$NAME" = "code-review" ] && [ -f "$HERE/../criteria/code-review/base.md" ]; then
  SOURCE="$(cd "$HERE/../criteria/code-review" && pwd)/base.md"
fi

[ -n "$SOURCE" ] || { echo "resolve-criteria: no criteria file found for $NAME" >&2; exit 1; }

if [ "$NAME" = "release" ] && [ -f "$DIR/.claude/skills/git-release-flow/SKILL.md" ]; then
  echo "resolve-criteria: note — $DIR/.claude/skills/git-release-flow/SKILL.md exists but is not used." >&2
  echo "resolve-criteria:        That path is from the old Phase 4 text and is a Claude Code skill, not" >&2
  echo "resolve-criteria:        a headless worker document. To override the vendored release flow, put" >&2
  echo "resolve-criteria:        your version at $DIR/.claude/criteria/release.md." >&2
fi

if [ -n "$PRINT_SOURCE" ]; then
  printf '%s\n' "$SOURCE"
  exit 0
fi

if [ -n "$INTO" ]; then
  DEST_DIR="$INTO"
  RUN_DIR=""
else
  R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET")" || exit $?
  DEST_DIR="$R/criteria"
  RUN_DIR="$R"
fi

mkdir -p "$DEST_DIR" 2>/dev/null \
  || { echo "resolve-criteria: could not create $DEST_DIR" >&2; exit 3; }
DEST_DIR="$(cd "$DEST_DIR" && pwd)"
DEST="$DEST_DIR/$NAME.md"

# If project override is in effect or criteria is not code-review, copy directly
if [ "$IS_OVERRIDE" -eq 1 ] || [ "$NAME" != "code-review" ]; then
  if [ "$DEST" != "$SOURCE" ]; then
    cp -f "$SOURCE" "$DEST" 2>/dev/null \
      || { echo "resolve-criteria: could not copy $SOURCE to $DEST" >&2; exit 3; }
  fi

  if [ "$IS_OVERRIDE" -eq 1 ]; then
    echo "STATUS: CRITERIA_OVERRIDDEN | Source: $SOURCE | Note: project override used directly without composition | File: $DEST" >&2
  fi

  printf '%s\n' "$DEST"
  exit 0
fi

# -----------------------------------------------------------------------------
# Code review composition
# -----------------------------------------------------------------------------

# Find REVIEW_DIFF.stat
STAT_FILE=""
if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/REVIEW_DIFF.stat" ]; then
  STAT_FILE="$RUN_DIR/REVIEW_DIFF.stat"
elif [ -f "$DEST_DIR/../REVIEW_DIFF.stat" ]; then
  STAT_FILE="$(cd "$DEST_DIR/.." && pwd)/REVIEW_DIFF.stat"
elif [ -f "$DIR/.agy/current" ]; then
  CURR_ID="$(cat "$DIR/.agy/current" 2>/dev/null || true)"
  if [ -n "$CURR_ID" ] && [ -f "$DIR/.agy/runs/$CURR_ID/REVIEW_DIFF.stat" ]; then
    STAT_FILE="$DIR/.agy/runs/$CURR_ID/REVIEW_DIFF.stat"
  fi
fi

# Helper: Detect language from a relative path
_detect_lang() {
  local p="$1"
  case "$p" in
    *.py|*.pyi) printf 'python\n'; return 0 ;;
    *.ts|*.tsx|*.mts|*.cts) printf 'typescript\n'; return 0 ;;
    *.go) printf 'go\n'; return 0 ;;
    *.rs) printf 'rust\n'; return 0 ;;
    *.sh|*.bash) printf 'bash\n'; return 0 ;;
  esac

  # Check shebang on disk if file exists
  local fpath="$DIR/$p"
  if [ -f "$fpath" ]; then
    local first_line=""
    first_line="$(head -n 1 "$fpath" 2>/dev/null || true)"
    case "$first_line" in
      '#!'*bash*) printf 'bash\n'; return 0 ;;
    esac
  fi

  return 1
}

# 1. Detect languages from REVIEW_DIFF.stat
DETECTED_LANGS=()
if [ -n "$STAT_FILE" ] && [ -f "$STAT_FILE" ]; then
  while IFS= read -r sline || [ -n "$sline" ]; do
    case "$sline" in
      '#'*|''|*'(no files changed'*|*'files changed,'*) continue ;;
    esac

    case "$sline" in
      *'|'*)
        raw_file="${sline%%|*}"
        # Trim leading/trailing whitespace
        raw_file="${raw_file#"${raw_file%%[![:space:]]*}"}"
        raw_file="${raw_file%"${raw_file##*[![:space:]]}"}"

        # Handle git rename syntax {old => new}
        case "$raw_file" in
          *'=>'*)
            clean_file="$(printf '%s' "$raw_file" | sed -e 's/{.* => \(.*\)}/\1/' -e 's/.* => //')"
            ;;
          *)
            clean_file="$raw_file"
            ;;
        esac

        if lfound="$(_detect_lang "$clean_file")"; then
          # Add if not already present
          already_present=0
          for dl in "${DETECTED_LANGS[@]+"${DETECTED_LANGS[@]}"}"; do
            if [ "$dl" = "$lfound" ]; then
              already_present=1
              break
            fi
          done
          if [ "$already_present" -eq 0 ]; then
            DETECTED_LANGS[${#DETECTED_LANGS[@]}]="$lfound"
          fi
        fi
        ;;
    esac
  done < "$STAT_FILE"
fi

# 2. Parse concern packs from agy.toml
_parse_toml_concerns() {
  local toml_file="$1"
  [ -f "$toml_file" ] || return 0

  local in_criteria=0
  local lineno=0
  local tline=""

  while IFS= read -r tline || [ -n "$tline" ]; do
    lineno=$((lineno + 1))
    local trimmed="${tline#"${tline%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [ -z "$trimmed" ] && continue
    case "$trimmed" in \#*) continue ;; esac

    case "$trimmed" in
      \[*\])
        local sec="${trimmed#\[}"
        sec="${sec%\]}"
        sec="${sec#"${sec%%[![:space:]]*}"}"
        sec="${sec%"${sec##*[![:space:]]}"}"
        if [ "$sec" = "criteria" ]; then
          in_criteria=1
        else
          in_criteria=0
        fi
        continue
        ;;
    esac

    if [ "$in_criteria" -eq 1 ]; then
      case "$trimmed" in
        *=*)
          local key="${trimmed%%=*}"
          local val="${trimmed#*=}"
          key="${key#"${key%%[![:space:]]*}"}"
          key="${key%"${key##*[![:space:]]}"}"
          val="${val#"${val%%[![:space:]]*}"}"
          val="${val%"${val##*[![:space:]]}"}"

          case "$key" in
            concerns|concern|packs|code-review|code_review)
              case "$val" in
                \[*\])
                  local arr_raw="${val#\[}"
                  arr_raw="${arr_raw%\]}"
                  local save_ifs="$IFS"
                  IFS=','
                  local elem
                  for elem in $arr_raw; do
                    elem="${elem#"${elem%%[![:space:]]*}"}"
                    elem="${elem%"${elem##*[![:space:]]}"}"
                    case "$elem" in
                      \"*\")
                        local str="${elem#\"}"
                        str="${str%\"}"
                        [ -n "$str" ] && printf '%s\n' "$str"
                        ;;
                      \'*\')
                        local str="${elem#\'}"
                        str="${str%\'}"
                        [ -n "$str" ] && printf '%s\n' "$str"
                        ;;
                      *)
                        [ -n "$elem" ] && printf '%s\n' "$elem"
                        ;;
                    esac
                  done
                  IFS="$save_ifs"
                  ;;
                \"*\")
                  local str="${val#\"}"
                  str="${str%\"}"
                  [ -n "$str" ] && printf '%s\n' "$str"
                  ;;
                \'*\')
                  local str="${val#\'}"
                  str="${str%\'}"
                  [ -n "$str" ] && printf '%s\n' "$str"
                  ;;
                *)
                  [ -n "$val" ] && printf '%s\n' "$val"
                  ;;
              esac
              ;;
          esac
          ;;
      esac
    fi
  done < "$toml_file"
}

CONFIG_FILE=""
for cand in "$DIR/.claude/agy.toml" "$DIR/agy.toml" "$HERE/../agy.toml"; do
  if [ -f "$cand" ]; then
    CONFIG_FILE="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
    break
  fi
done

NAMED_CONCERNS=()
if [ -n "$CONFIG_FILE" ]; then
  RAW_CONCERNS="$(_parse_toml_concerns "$CONFIG_FILE")"
  if [ -n "$RAW_CONCERNS" ]; then
    while IFS= read -r cname || [ -n "$cname" ]; do
      [ -z "$cname" ] && continue
      CONCERN_PACK="$HERE/../criteria/code-review/concern/${cname}.md"
      if [ ! -f "$CONCERN_PACK" ]; then
        echo "resolve-criteria: unknown criteria pack '$cname' (named in $CONFIG_FILE)" >&2
        exit 2
      fi
      c_present=0
      for ec in "${NAMED_CONCERNS[@]+"${NAMED_CONCERNS[@]}"}"; do
        if [ "$ec" = "$cname" ]; then
          c_present=1
          break
        fi
      done
      if [ "$c_present" -eq 0 ]; then
        NAMED_CONCERNS[${#NAMED_CONCERNS[@]}]="$cname"
      fi
    done <<EOF
$RAW_CONCERNS
EOF
  fi
fi

# If there is no diff stat and no concern packs configured, install plain vendored copy
if [ -z "$STAT_FILE" ] && [ ${#NAMED_CONCERNS[@]} -eq 0 ]; then
  if [ "$DEST" != "$SOURCE" ]; then
    cp -f "$SOURCE" "$DEST" 2>/dev/null \
      || { echo "resolve-criteria: could not copy $SOURCE to $DEST" >&2; exit 3; }
  fi

  printf '%s\n' "$DEST"
  exit 0
fi

# 3. Assemble composed criteria document
BASE_FILE="$HERE/../criteria/code-review/base.md"
[ -f "$BASE_FILE" ] || BASE_FILE="$HERE/../criteria/code-review.md"
[ -f "$BASE_FILE" ] || { echo "resolve-criteria: base criteria not found" >&2; exit 1; }

COMPOSED_FILES=("$BASE_FILE")
INCLUDED_PACKS=("base")
DROPPED_PACKS=()

CURRENT_LINES="$(wc -l < "$BASE_FILE" | tr -cd '0-9')"
CURRENT_LINES="${CURRENT_LINES:-0}"

# Add language packs (capped by MAX_LANGS and MAX_LINES)
LANG_COUNT=0
for lang in "${DETECTED_LANGS[@]+"${DETECTED_LANGS[@]}"}"; do
  LPACK="$HERE/../criteria/code-review/lang/${lang}.md"
  if [ ! -f "$LPACK" ]; then
    continue
  fi

  if [ "$LANG_COUNT" -ge "$MAX_LANGS" ]; then
    DROPPED_PACKS[${#DROPPED_PACKS[@]}]="lang/$lang (exceeded max languages cap of $MAX_LANGS)"
    continue
  fi

  PLINES="$(wc -l < "$LPACK" | tr -cd '0-9')"
  PLINES="${PLINES:-0}"
  NEXT_LINES=$((CURRENT_LINES + PLINES + 2))

  if [ "$NEXT_LINES" -le "$MAX_LINES" ]; then
    COMPOSED_FILES[${#COMPOSED_FILES[@]}]="$LPACK"
    INCLUDED_PACKS[${#INCLUDED_PACKS[@]}]="lang/$lang"
    CURRENT_LINES=$NEXT_LINES
    LANG_COUNT=$((LANG_COUNT + 1))
  else
    DROPPED_PACKS[${#DROPPED_PACKS[@]}]="lang/$lang (exceeded max lines cap of $MAX_LINES)"
  fi
done

# Add concern packs (capped by MAX_LINES)
for concern in "${NAMED_CONCERNS[@]+"${NAMED_CONCERNS[@]}"}"; do
  CPACK="$HERE/../criteria/code-review/concern/${concern}.md"
  if [ ! -f "$CPACK" ]; then
    continue
  fi

  PLINES="$(wc -l < "$CPACK" | tr -cd '0-9')"
  PLINES="${PLINES:-0}"
  NEXT_LINES=$((CURRENT_LINES + PLINES + 2))

  if [ "$NEXT_LINES" -le "$MAX_LINES" ]; then
    COMPOSED_FILES[${#COMPOSED_FILES[@]}]="$CPACK"
    INCLUDED_PACKS[${#INCLUDED_PACKS[@]}]="concern/$concern"
    CURRENT_LINES=$NEXT_LINES
  else
    DROPPED_PACKS[${#DROPPED_PACKS[@]}]="concern/$concern (exceeded max lines cap of $MAX_LINES)"
  fi
done

# Write the composed file
rm -f "$DEST" 2>/dev/null
FIRST_FILE=1
for cf in "${COMPOSED_FILES[@]+"${COMPOSED_FILES[@]}"}"; do
  if [ "$FIRST_FILE" -eq 1 ]; then
    cat "$cf" > "$DEST" 2>/dev/null || { echo "resolve-criteria: could not write $DEST" >&2; exit 3; }
    FIRST_FILE=0
  else
    printf '\n\n' >> "$DEST" 2>/dev/null || { echo "resolve-criteria: could not write $DEST" >&2; exit 3; }
    cat "$cf" >> "$DEST" 2>/dev/null || { echo "resolve-criteria: could not write $DEST" >&2; exit 3; }
  fi
done

# Format STATUS line
INCLUDED_STR=""
for p in "${INCLUDED_PACKS[@]+"${INCLUDED_PACKS[@]}"}"; do
  if [ -z "$INCLUDED_STR" ]; then
    INCLUDED_STR="$p"
  else
    INCLUDED_STR="$INCLUDED_STR, $p"
  fi
done

DROPPED_STR="none"
if [ ${#DROPPED_PACKS[@]} -gt 0 ]; then
  DROPPED_STR=""
  for d in "${DROPPED_PACKS[@]+"${DROPPED_PACKS[@]}"}"; do
    if [ -z "$DROPPED_STR" ]; then
      DROPPED_STR="$d"
    else
      DROPPED_STR="$DROPPED_STR, $d"
    fi
  done
fi

LANG_SUMMARY="none (no language pack applied)"
if [ ${#DETECTED_LANGS[@]} -gt 0 ]; then
  LANG_SUMMARY=""
  for l in "${DETECTED_LANGS[@]+"${DETECTED_LANGS[@]}"}"; do
    if [ -z "$LANG_SUMMARY" ]; then
      LANG_SUMMARY="$l"
    else
      LANG_SUMMARY="$LANG_SUMMARY, $l"
    fi
  done
fi

CONCERN_SUMMARY="none"
if [ ${#NAMED_CONCERNS[@]} -gt 0 ]; then
  CONCERN_SUMMARY=""
  for c in "${NAMED_CONCERNS[@]+"${NAMED_CONCERNS[@]}"}"; do
    if [ -z "$CONCERN_SUMMARY" ]; then
      CONCERN_SUMMARY="$c"
    else
      CONCERN_SUMMARY="$CONCERN_SUMMARY, $c"
    fi
  done
fi

if [ ${#DROPPED_PACKS[@]} -gt 0 ]; then
  TOTAL_PACKS=$(( ${#INCLUDED_PACKS[@]} + ${#DROPPED_PACKS[@]} ))
  echo "STATUS: CRITERIA_TRUNCATED(kept=${#INCLUDED_PACKS[@]}/$TOTAL_PACKS) | Included: $INCLUDED_STR | Dropped: $DROPPED_STR | Langs: $LANG_SUMMARY | Concerns: $CONCERN_SUMMARY | File: $DEST" >&2
else
  echo "STATUS: CRITERIA_COMPOSED | Included: $INCLUDED_STR | Langs: $LANG_SUMMARY | Concerns: $CONCERN_SUMMARY | Dropped: none | File: $DEST" >&2
fi

printf '%s\n' "$DEST"
exit 0
