#!/usr/bin/env bash
# Lint briefs before dispatch.
#
#   check-brief.sh --phase <NAME> --brief <file> [--dir <repo>] [--run <id>]
#                  [--allow-shell]
#
# Reads:   <brief>                       the brief to inspect
#          <dir>                         repository root (to verify input paths exist)
# Writes:  nothing.
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes, one per outcome:
#     0  BRIEF_VALID             brief satisfies all structural and content rules
#     2  bad arguments or missing file/dir
#     3  BRIEF_INVALID(...)      brief violates one or more rules
#
# Checks performed:
#   1. Verdict contract path: present and names the resolved
#      <run-dir>/phases/<PHASE>/verdict (not another phase's and not stale .tmp/).
#   2. Both verdict routes: write the file AND print the line.
#   3. Shell prohibition: "do not run shell commands" is present unless
#      --allow-shell is passed. That flag is the seam for driver-capabilities
#      work in #23: a backend that permits shell commands makes this rule
#      unnecessary, and the flag is where that will plug in.
#   4. Input files exist: every path named as an input exists inside the repo.
#   5. No outside paths: no paths outside the repo (~/... or absolute paths
#      outside --dir) are referenced.
#   6. Git prohibition: "do not touch git" / "do not commit" is present.
#
# Report what was checked:
#   BRIEF_VALID names the checks that ran, in the same style as check-review.sh
#   and check-diff-integrity.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

PHASE=""
BRIEF=""
DIR="$PWD"
RUN_TARGET=""
ALLOW_SHELL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)       PHASE="$2";      shift 2 ;;
    --brief)       BRIEF="$2";      shift 2 ;;
    --dir)         DIR="$2";        shift 2 ;;
    --run)         RUN_TARGET="$2"; shift 2 ;;
    --allow-shell) ALLOW_SHELL=1;   shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "check-brief: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -n "$PHASE" ] || { echo "check-brief: --phase required" >&2; exit 2; }
[ -n "$BRIEF" ] || { echo "check-brief: --brief required" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "check-brief: brief not found: $BRIEF" >&2; exit 2; }
[ -d "$DIR" ]   || { echo "check-brief: dir not found: $DIR" >&2; exit 2; }

DIR="$(cd "$DIR" && pwd)"

clean_candidate() {
  local cand="$1"
  while :; do
    case "$cand" in
      [\'\"\`\(\[\<\{]*) cand="${cand#?}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$cand" in
      *[\'\"\`\)\]\>\}\:\,\.\;\!\?]) cand="${cand%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$cand"
}

should_discard_path() {
  local cand="$1"
  case "$cand" in
    http://*|https://*|mailto:*|\#*) return 0 ;;
    \~*|\~/*) return 0 ;;
    -*) return 0 ;;
    *\**|*\?*|*\$*|*\<*|*\>*|*…*|*...*) return 0 ;;
  esac
  [ -z "$cand" ] && return 0

  # Output files for phase should not be checked as inputs
  case "$cand" in
    */phases/"$PHASE"/verdict|phases/"$PHASE"/verdict) return 0 ;;
    */phases/"$PHASE"/status|phases/"$PHASE"/status) return 0 ;;
    */phases/"$PHASE"/log|phases/"$PHASE"/log) return 0 ;;
    */phases/"$PHASE"/brief.md|phases/"$PHASE"/brief.md) return 0 ;;
  esac

  case "$PHASE" in
    DISCOVERY)
      case "$cand" in
        */DISCOVERY.md|DISCOVERY.md|*/TEST_COMMAND|TEST_COMMAND) return 0 ;;
      esac
      ;;
    IMPLEMENT)
      case "$cand" in
        */CHANGES.md|CHANGES.md) return 0 ;;
      esac
      ;;
    REVIEW)
      case "$cand" in
        */REVIEW_FEEDBACK.md|REVIEW_FEEDBACK.md) return 0 ;;
      esac
      ;;
    QA)
      case "$cand" in
        */QA_REPORT.md|QA_REPORT.md) return 0 ;;
      esac
      ;;
    RELEASE)
      case "$cand" in
        */RELEASE_PLAN.md|RELEASE_PLAN.md) return 0 ;;
      esac
      ;;
    DELEGATE)
      case "$cand" in
        */CHANGES.md|CHANGES.md) return 0 ;;
      esac
      ;;
  esac

  # Plain phrases with slashes that are not paths
  case "$cand" in
    and/or|either/or|true/false|pass/fail|input/output|read/write|import/export|yes/no) return 0 ;;
    text/plain|application/*|image/*) return 0 ;;
  esac

  return 1
}

# Check if brief is empty
if [ ! -s "$BRIEF" ] || [ -z "$(awk 'NF { print "x"; exit }' "$BRIEF" 2>/dev/null)" ]; then
  printf '%s\n' "STATUS: BRIEF_INVALID(empty_brief) | Phase: $PHASE | Brief: $BRIEF | Note: the brief is empty"
  exit 3
fi

BRIEF_TEXT="$(tr '\n' ' ' < "$BRIEF" 2>/dev/null | tr -s ' ')"

# Resolve RUN_ID and run directory R
if [ -n "$RUN_TARGET" ]; then
  RUN_ID="$RUN_TARGET"
  R="$DIR/.agy/runs/$RUN_ID"
else
  if R="$(run_dir_resolve --dir "$DIR" --run current 2>/dev/null)"; then
    RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
  else
    RUN_ID=""
    R=""
    case "$BRIEF" in
      */.agy/runs/*)
        EXTRACTED_RUN="$(printf '%s' "$BRIEF" | sed -n 's|.*/\.agy/runs/\([^/]*\)/.*|\1|p')"
        if [ -n "$EXTRACTED_RUN" ]; then
          RUN_ID="$EXTRACTED_RUN"
          R="$DIR/.agy/runs/$RUN_ID"
        fi
        ;;
    esac
  fi
fi

RUN_FIELD=""
[ -n "$RUN_ID" ] && RUN_FIELD=" | Run: $RUN_ID"

# =============================================================================
# Check 5: No paths outside repository (~/... or absolute paths outside DIR)
# =============================================================================
TILDE_PATHS="$(grep -a -o -E '(^|[[:space:]`"'\''\(])~[A-Za-z0-9_./+-]*' "$BRIEF" 2>/dev/null | sed -e 's/^[[:space:]`"'\''\(]*//' | sort -u)"
while IFS= read -r TP; do
  [ -n "$TP" ] || continue
  TP="$(clean_candidate "$TP")"
  case "$TP" in
    ""|"~"|"~/"|*\**|*\?*|*\$*|*\<*|*\>*|*…*|*...*) continue ;;
  esac
  printf '%s\n' "STATUS: BRIEF_INVALID(outside_path:$TP) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief references path outside repository ($TP)"
  exit 3
done <<EOF
$TILDE_PATHS
EOF

ABS_PATHS="$(grep -a -o -E '(^|[[:space:]`"'\''\(])/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+' "$BRIEF" 2>/dev/null | sed -e 's/^[[:space:]`"'\''\(]*//' | sort -u)"
REAL_DIR="$(cd "$DIR" && pwd -P 2>/dev/null || echo "$DIR")"
while IFS= read -r AP; do
  [ -n "$AP" ] || continue
  AP="$(clean_candidate "$AP")"
  [ -n "$AP" ] || continue
  case "$AP" in
    /dev/null|/dev/null/*) continue ;;
    "$DIR"/*|"$DIR"|"$REAL_DIR"/*|"$REAL_DIR") continue ;;
    *)
      printf '%s\n' "STATUS: BRIEF_INVALID(outside_path:$AP) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief references absolute path outside repository ($AP)"
      exit 3
      ;;
  esac
done <<EOF
$ABS_PATHS
EOF

# =============================================================================
# Check 1: Verdict Contract - Target Path & Layout
# =============================================================================
# a. Catch stale .tmp/ verdict path (Issue #44)
if printf '%s\n' "$BRIEF_TEXT" | grep -a -E '\.tmp/([^[:space:]`"'\''\)]*\.)?verdict|\.tmp/' 2>/dev/null | grep -q 'verdict'; then
  STALE_TMP="$(grep -a -o -E '[^[:space:]`"'\''\(\)]*\.tmp/[^[:space:]`"'\''\)]*' "$BRIEF" 2>/dev/null | head -1)"
  STALE_TMP="$(clean_candidate "${STALE_TMP:-.tmp/$PHASE.verdict}")"
  printf '%s\n' "STATUS: BRIEF_INVALID(stale_verdict_path:$STALE_TMP) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief names a stale .tmp/ verdict path; verdicts must be written under .agy/runs/<run-id>/phases/$PHASE/verdict"
  exit 3
fi

# b. Catch another phase's verdict path
PHASE_VERDICTS="$(grep -a -o -E 'phases/[A-Za-z0-9_-]+/verdict' "$BRIEF" 2>/dev/null | sed -e 's|^phases/||' -e 's|/verdict$||' | sort -u)"
WRONG_PHASE=""
while IFS= read -r PV; do
  [ -n "$PV" ] || continue
  PV="$(clean_candidate "$PV")"
  if [ "$PV" != "$PHASE" ]; then
    WRONG_PHASE="$PV"
    break
  fi
done <<EOF
$PHASE_VERDICTS
EOF

if [ -n "$WRONG_PHASE" ]; then
  printf '%s\n' "STATUS: BRIEF_INVALID(wrong_phase_verdict_path:phases/$WRONG_PHASE/verdict) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief names verdict path for phase '$WRONG_PHASE' but phase being dispatched is '$PHASE'"
  exit 3
fi

# c. Ensure verdict path for current phase is present
if ! printf '%s\n' "$BRIEF_TEXT" | grep -a -q -E "phases/$PHASE/verdict" 2>/dev/null; then
  printf '%s\n' "STATUS: BRIEF_INVALID(missing_verdict_path) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief must specify verdict path .agy/runs/<run-id>/phases/$PHASE/verdict"
  exit 3
fi

# d. Check for mismatched concrete run ID if RUN_ID is known
if [ -n "$RUN_ID" ]; then
  NAMED_RUNS="$(grep -a -o -E '\.agy/runs/[A-Za-z0-9._-]+/phases/' "$BRIEF" 2>/dev/null | sed -e 's|^\.agy/runs/||' -e 's|/phases/$||' | grep -v '^<run-id>$' | grep -v '^RUN_ID$' | grep -v '^<run-dir>$' | sort -u)"
  while IFS= read -r NR; do
    [ -n "$NR" ] || continue
    NR="$(clean_candidate "$NR")"
    if [ "$NR" != "$RUN_ID" ]; then
      printf '%s\n' "STATUS: BRIEF_INVALID(wrong_run_verdict_path:.agy/runs/$NR/phases/$PHASE/verdict) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief names run '$NR' but current run is '$RUN_ID'"
      exit 3
    fi
  done <<EOF
$NAMED_RUNS
EOF
fi

# =============================================================================
# Check 2: Both Verdict Routes (Write File AND Print Line)
# =============================================================================
HAS_FILE_ROUTE=0
if printf '%s\n' "$BRIEF_TEXT" | grep -a -i -E '(write|save|output|record|put)[^;]*verdict|(write|save|output|record|put)[^;]*phases/'"$PHASE"'/verdict|to[[:space:]]+`?[^`[:space:]]*phases/'"$PHASE"'/verdict|phases/'"$PHASE"'/verdict[^;]*(write|save|output|record|put)' 2>/dev/null | grep -q -i 'verdict'; then
  HAS_FILE_ROUTE=1
elif printf '%s\n' "$BRIEF_TEXT" | grep -a -i -E '(write|save|output|record|put).*(verdict|phases/'"$PHASE"'/verdict)' 2>/dev/null | grep -q -i 'verdict'; then
  HAS_FILE_ROUTE=1
fi

if [ "$HAS_FILE_ROUTE" -eq 0 ]; then
  printf '%s\n' "STATUS: BRIEF_INVALID(missing_verdict_file_route) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief must instruct worker to write verdict to .agy/runs/<run-id>/phases/$PHASE/verdict"
  exit 3
fi

HAS_PRINT_ROUTE=0
if printf '%s\n' "$BRIEF_TEXT" | grep -a -i -E '(print|echo)[[:space:]]+(that[[:space:]]+same[[:space:]]+line|the[[:space:]]+(same[[:space:]]+)?line|it[[:space:]]+as|STATUS:|verdict|line|it)|(print|echo)[[:space:]]+.*(last|final|stdout|output)|(last|final)[[:space:]]+line[[:space:]]+of[[:space:]]+(your[[:space:]]+)?output' 2>/dev/null | grep -q .; then
  HAS_PRINT_ROUTE=1
fi

if [ "$HAS_PRINT_ROUTE" -eq 0 ]; then
  printf '%s\n' "STATUS: BRIEF_INVALID(missing_verdict_print_route) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief must instruct worker to print verdict line to stdout"
  exit 3
fi

# =============================================================================
# Check 3: Shell Command Prohibition
# =============================================================================
SHELL_CHECK_STATUS="shell_prohibition"
if [ "$ALLOW_SHELL" -eq 1 ]; then
  SHELL_CHECK_STATUS="shell_prohibition (skipped: --allow-shell)"
else
  HAS_SHELL_PROHIBITION=0
  if printf '%s\n' "$BRIEF_TEXT" | grep -a -i -E '(do[[:space:]]+not|never|no|must[[:space:]]+not|cannot)[[:space:]]+(run|execute)[[:space:]]+(any[[:space:]]+)?(shell[[:space:]]+)?commands|(do[[:space:]]+not|never|no|must[[:space:]]+not)[[:space:]]+run[[:space:]]+shell|forbidden[[:space:]]+(from[[:space:]]+running[[:space:]]+)?shell|shell[[:space:]]+commands[[:space:]]+(are[[:space:]]+)?(prohibited|denied|forbidden)' 2>/dev/null | grep -q .; then
    HAS_SHELL_PROHIBITION=1
  fi

  if [ "$HAS_SHELL_PROHIBITION" -eq 0 ]; then
    printf '%s\n' "STATUS: BRIEF_INVALID(missing_shell_prohibition) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief must prohibit shell commands (or pass --allow-shell if driver permits)"
    exit 3
  fi
fi

# =============================================================================
# Check 6: Git Prohibition
# =============================================================================
HAS_GIT_PROHIBITION=0
if printf '%s\n' "$BRIEF_TEXT" | grep -a -i -E '(do[[:space:]]+not|never|no|must[[:space:]]+not)[[:space:]]+(touch[[:space:]]+git|commit|stage|branch|make[[:space:]]+commits|create[[:space:]]+commits)|leave[[:space:]]+changes[[:space:]]+in[[:space:]]+the[[:space:]]+working[[:space:]]+tree|nothing[[:space:]]+here[[:space:]]+commits|do[[:space:]]+not[[:space:]]+run[[:space:]]+.*git' 2>/dev/null | grep -q .; then
  HAS_GIT_PROHIBITION=1
fi

if [ "$HAS_GIT_PROHIBITION" -eq 0 ]; then
  printf '%s\n' "STATUS: BRIEF_INVALID(missing_git_prohibition) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: brief must prohibit git commits and staging"
  exit 3
fi

# =============================================================================
# Check 4: Input Files Exist Inside Repository
# =============================================================================
# Bias: prefer under-reporting to crying wolf.
# Only treat a token as an input path when it contains a '/'.
# A bare filename with no directory is a generic mention in prose
# (e.g. "the SKILL.md files", "a package.json", "your Makefile"), not an
# assertion that a file exists at the repo root.
#
# Classification:
# 1. A path inside an ## Output Contract section is an output.
# 2. A path introduced with creation words (create, creates, write, writes, add,
#    adds, new file, produce, ship, generate) is an output.
# 3. Everything else containing '/' is treated as an input.
# 4. If a path appears both as input and output, treat as input.
list_contains() {
  local list="$1"
  local item="$2"
  [ -z "$list" ] && return 1
  printf '%s\n' "$list" | grep -F -x -q -- "$item"
}

is_output_context() {
  local ctx=" $1 "
  local norm=" $(printf '%s' "$ctx" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ') "

  case "$norm" in
    *" create "*|*" creates "*|*" write "*|*" writes "*|*" add "*|*" adds "*|*" new file "*|*" produce "*|*" ship "*|*" generate "*)
      ;;
    *)
      return 1
      ;;
  esac

  local last_after=""
  local shortest_len=999999
  local cand_after=""
  local cand_len=0
  for kw in " create " " creates " " write " " writes " " add " " adds " " new file " " produce " " ship " " generate "; do
    case "$norm" in
      *"$kw"*)
        cand_after="${norm##*$kw}"
        cand_len="${#cand_after}"
        if [ "$cand_len" -lt "$shortest_len" ]; then
          shortest_len="$cand_len"
          last_after="$cand_after"
        fi
        ;;
    esac
  done

  case " $last_after " in
    *" read "*|*" reads "*|*" follow "*|*" follows "*|*" inspect "*|*" inspects "*|*" examine "*|*" examines "*|*" check "*|*" checks "*|*" review "*|*" reviews "*|*" from "*)
      return 1
      ;;
  esac

  return 0
}

SEEN_PATHS=""
INPUT_PATHS=""
OUTPUT_PATHS=""

record_path_occurrence() {
  local p="$1"
  local is_out="$2"

  if ! list_contains "$SEEN_PATHS" "$p"; then
    if [ -z "$SEEN_PATHS" ]; then
      SEEN_PATHS="$p"
    else
      SEEN_PATHS="$SEEN_PATHS
$p"
    fi
  fi

  if [ "$is_out" -eq 1 ]; then
    if ! list_contains "$OUTPUT_PATHS" "$p"; then
      if [ -z "$OUTPUT_PATHS" ]; then
        OUTPUT_PATHS="$p"
      else
        OUTPUT_PATHS="$OUTPUT_PATHS
$p"
      fi
    fi
  else
    if ! list_contains "$INPUT_PATHS" "$p"; then
      if [ -z "$INPUT_PATHS" ]; then
        INPUT_PATHS="$p"
      else
        INPUT_PATHS="$INPUT_PATHS
$p"
      fi
    fi
  fi
}

IN_OUTPUT_SECTION=0
PREV_WINDOW=""

while IFS= read -r LINE || [ -n "$LINE" ]; do
  case "$LINE" in
    \#*)
      HEADING_TEXT="$(printf '%s' "$LINE" | sed -e 's/^#*[[:space:]]*//' | tr '[:upper:]' '[:lower:]')"
      case "$HEADING_TEXT" in
        output\ contract*|"output contract"*)
          IN_OUTPUT_SECTION=1
          ;;
        *)
          IN_OUTPUT_SECTION=0
          ;;
      esac
      PREV_WINDOW=""
      ;;
    -[[:space:]]*|\*[[:space:]]*|[0-9]*.[[:space:]]*)
      PREV_WINDOW=""
      ;;
  esac

  set -f
  for TOK in $LINE; do
    set +f
    CAND_LIST=""
    case "$TOK" in
      *']('*')'*)
        REST="$TOK"
        while case "$REST" in *']('*')'*) true ;; *) false ;; esac; do
          REST="${REST#*']('}"
          TARGET="${REST%%')'*}"
          REST="${REST#*')'}"
          CAND_LIST="$CAND_LIST $TARGET"
        done
        ;;
    esac

    case "$TOK" in
      *'`'*'`'*)
        REST="$TOK"
        while case "$REST" in *'`'*'`'*) true ;; *) false ;; esac; do
          REST="${REST#*'`'}"
          CODE_TOK="${REST%%'`'*}"
          REST="${REST#*'`'}"
          CAND_LIST="$CAND_LIST $CODE_TOK"
        done
        ;;
    esac

    case "$TOK" in
      */*)
        CAND_LIST="$CAND_LIST $TOK"
        ;;
    esac

    if [ -n "$CAND_LIST" ]; then
      for RAW_CAND in $CAND_LIST; do
        CAND="$(clean_candidate "$RAW_CAND")"
        if [ -z "$CAND" ] || should_discard_path "$CAND"; then
          continue
        fi
        case "$CAND" in
          */*) ;;
          *) continue ;;
        esac

        IS_OUTPUT_OCCURRENCE=0
        if [ "$IN_OUTPUT_SECTION" -eq 1 ]; then
          IS_OUTPUT_OCCURRENCE=1
        elif is_output_context "$PREV_WINDOW"; then
          IS_OUTPUT_OCCURRENCE=1
        fi

        record_path_occurrence "$CAND" "$IS_OUTPUT_OCCURRENCE"
      done
    fi

    PREV_WINDOW="$PREV_WINDOW $TOK"

    case "$TOK" in
      *[\.\!\?\;])
        case "$TOK" in
          *\`*|*\"*|*\'*)
            case "$TOK" in
              *[\`\"\'][\.\!\?\;]) PREV_WINDOW="" ;;
            esac
            ;;
          *)
            case "$TOK" in
              */*) ;;
              *) PREV_WINDOW="" ;;
            esac
            ;;
        esac
        ;;
    esac
    set -f
  done
  set +f
done < "$BRIEF"

CHECKED_INPUTS=0
SKIPPED_OUTPUTS=0
MISSING_INPUT=""

if [ -n "$SEEN_PATHS" ]; then
  while IFS= read -r CAND; do
    [ -n "$CAND" ] || continue

    if list_contains "$INPUT_PATHS" "$CAND" || ! list_contains "$OUTPUT_PATHS" "$CAND"; then
      CHECKED_INPUTS=$((CHECKED_INPUTS + 1))

      RESOLVED=""
      case "$CAND" in
        "$DIR"/*) RESOLVED="$CAND" ;;
        ./*)      RESOLVED="$DIR/${CAND#./}" ;;
        *)        RESOLVED="$DIR/$CAND" ;;
      esac

      if [ ! -e "$RESOLVED" ]; then
        MISSING_INPUT="$CAND"
        break
      fi
    else
      SKIPPED_OUTPUTS=$((SKIPPED_OUTPUTS + 1))
    fi
  done <<EOF
$SEEN_PATHS
EOF
fi

if [ -n "$MISSING_INPUT" ]; then
  printf '%s\n' "STATUS: BRIEF_INVALID(missing_input_file:$MISSING_INPUT) | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF | Note: referenced input file '$MISSING_INPUT' does not exist in repository"
  exit 3
fi

if [ "$SKIPPED_OUTPUTS" -gt 0 ]; then
  if [ "$SKIPPED_OUTPUTS" -eq 1 ]; then
    OUTPUT_STR="1 output skipped"
  else
    OUTPUT_STR="$SKIPPED_OUTPUTS outputs skipped"
  fi
  if [ "$CHECKED_INPUTS" -gt 0 ]; then
    INPUT_CHECK_STATUS="input_paths ($CHECKED_INPUTS checked, $OUTPUT_STR)"
  else
    INPUT_CHECK_STATUS="input_paths (0 checked, $OUTPUT_STR)"
  fi
elif [ "$CHECKED_INPUTS" -gt 0 ]; then
  INPUT_CHECK_STATUS="input_paths ($CHECKED_INPUTS checked)"
else
  INPUT_CHECK_STATUS="input_paths (none in brief)"
fi

# =============================================================================
# Success Report
# =============================================================================
CHECKS_LIST="verdict_path, verdict_routes, $SHELL_CHECK_STATUS, $INPUT_CHECK_STATUS, outside_paths, git_prohibition"
printf '%s\n' "STATUS: BRIEF_VALID | Checks: $CHECKS_LIST | Phase: $PHASE$RUN_FIELD | Brief: $BRIEF"
exit 0
