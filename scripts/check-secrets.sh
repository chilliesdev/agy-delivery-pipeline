#!/usr/bin/env bash
# Pre-dispatch secret scanner for brief and captured diff.
#
#   check-secrets.sh [--brief <file>] [--diff <file>] [--patch <file>]
#                    [--file <file>] [--dir <repo>] [--run <id|current|last>]
#                    [--phase <NAME>] [--skip <path>]
#
# Reads:   <brief>                       the brief about to be dispatched
#          <diff> | <patch>              the unified diff about to be reviewed
#          <file>                        any specific file to scan
# Writes:  nothing.
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes, one per outcome:
#     0  SECRETS_NONE                    clean scan, names checked patterns
#     0  SECRETS_UNCHECKED(<why>)        nothing scanned, said loudly
#     2  bad arguments or missing file
#     3  SECRETS_FOUND(<what>, <file>:<line>) refuse dispatch
#
# Never print the secret itself. Report the pattern name, the file and the line
# number. A refusal that echoes the credential into a terminal, a log and the
# run directory has multiplied the problem it exists to prevent.
#
# Patterns checked (high-confidence, low-false-positive set):
#   - private_key: private key headers and blocks (BEGIN ... PRIVATE KEY)
#   - aws_access_key: AWS access key IDs (AKIA + 16 uppercase alphanumerics)
#   - github_token: GitHub tokens (ghp_, gho_, ghu_, ghs_, ghr_, github_pat_)
#   - slack_token: Slack tokens (xoxb-, xoxa-, xoxp-, xoxr-, xoxs-)
#   - google_api_key: Google API keys (AIza + 35 chars)
#   - env_secret: .env-style assignments with non-placeholder secret values
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"
BRIEF=""
DIFF=""
FILES=()
SKIP_PATHS=("scripts/check-secrets.sh" "tests/check-secrets.sh")
PHASE=""
RUN_TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --brief)       BRIEF="$2"; shift 2 ;;
    --diff|--patch) DIFF="$2"; shift 2 ;;
    --file)        FILES[${#FILES[@]}]="$2"; shift 2 ;;
    --skip)        SKIP_PATHS[${#SKIP_PATHS[@]}]="$2"; shift 2 ;;
    --dir)         DIR="$2"; shift 2 ;;
    --run)         RUN_TARGET="$2"; shift 2 ;;
    --phase)       PHASE="$2"; shift 2 ;;
    -h|--help)     sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "check-secrets: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -d "$DIR" ] || { echo "check-secrets: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

normalize_path() {
  local p="$1"
  case "$p" in
    "$DIR"/*) p="${p#$DIR/}" ;;
  esac
  case "$p" in
    ./*) p="${p#./}" ;;
  esac
  printf '%s' "$p"
}

UNIQUE_SKIPS=()
for P in "${SKIP_PATHS[@]}"; do
  NORM_P="$(normalize_path "$P")"
  [ -n "$NORM_P" ] || continue
  ALREADY=0
  for U in "${UNIQUE_SKIPS[@]+"${UNIQUE_SKIPS[@]}"}"; do
    if [ "$U" = "$NORM_P" ]; then
      ALREADY=1
      break
    fi
  done
  if [ "$ALREADY" -eq 0 ]; then
    UNIQUE_SKIPS[${#UNIQUE_SKIPS[@]}]="$NORM_P"
  fi
done

SKIPPED_STR=""
for U in "${UNIQUE_SKIPS[@]+"${UNIQUE_SKIPS[@]}"}"; do
  if [ -z "$SKIPPED_STR" ]; then
    SKIPPED_STR="$U"
  else
    SKIPPED_STR="$SKIPPED_STR, $U"
  fi
done

RUN_ID=""
if [ -n "$RUN_TARGET" ]; then
  if R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET" 2>/dev/null)"; then
    RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
  else
    RUN_ID="$RUN_TARGET"
    R="$DIR/.agy/runs/$RUN_ID"
  fi
elif [ -n "$PHASE" ]; then
  if R="$(run_dir_resolve --dir "$DIR" --run current 2>/dev/null)"; then
    RUN_ID="$(run_dir_get "$R" "run" 2>/dev/null || basename "$R")"
  fi
fi

# Collect candidate files
SCANNED_BRIEFS=()
SCANNED_DIFFS=()
SCANNED_OTHER=()

if [ -n "$BRIEF" ]; then
  [ -f "$BRIEF" ] || { echo "check-secrets: brief not found: $BRIEF" >&2; exit 2; }
  SCANNED_BRIEFS[${#SCANNED_BRIEFS[@]}]="$BRIEF"
fi

if [ -n "$DIFF" ]; then
  [ -f "$DIFF" ] || { echo "check-secrets: diff not found: $DIFF" >&2; exit 2; }
  SCANNED_DIFFS[${#SCANNED_DIFFS[@]}]="$DIFF"
elif [ -n "${R:-}" ] && [ -f "$R/REVIEW_DIFF.patch" ]; then
  SCANNED_DIFFS[${#SCANNED_DIFFS[@]}]="$R/REVIEW_DIFF.patch"
fi

for F in "${FILES[@]+"${FILES[@]}"}"; do
  [ -f "$F" ] || { echo "check-secrets: file not found: $F" >&2; exit 2; }
  SCANNED_OTHER[${#SCANNED_OTHER[@]}]="$F"
done

TOTAL_FILES=$(( ${#SCANNED_BRIEFS[@]} + ${#SCANNED_DIFFS[@]} + ${#SCANNED_OTHER[@]} ))

RUN_FIELD=""
[ -n "$RUN_ID" ] && RUN_FIELD=" | Run: $RUN_ID"
PHASE_FIELD=""
[ -n "$PHASE" ] && PHASE_FIELD=" | Phase: $PHASE"

if [ "$TOTAL_FILES" -eq 0 ]; then
  printf '%s\n' "STATUS: SECRETS_UNCHECKED(no_files_scanned)$PHASE_FIELD$RUN_FIELD | Note: no brief or diff files were supplied to scan"
  exit 0
fi

# Helper: check private key header / block
is_private_key() {
  local line="$1"
  case "$line" in
    *"-----BEGIN "*"PRIVATE KEY"*) return 0 ;;
  esac
  return 1
}

# Helper: check AWS access key ID (AKIA + 16 alphanumeric characters)
is_aws_key() {
  local line="$1"
  case "$line" in
    *AKIA*) ;;
    *) return 1 ;;
  esac

  if ! printf '%s\n' "$line" | grep -q -E '(^|[^0-9A-Za-z])AKIA[0-9A-Z]{16}([^0-9A-Z]|$)'; then
    return 1
  fi

  # Extract matching candidate(s)
  local rest="$line"
  while case "$rest" in *AKIA*) true ;; *) false ;; esac; do
    rest="${rest#*AKIA}"
    local suffix="${rest%%[^0-9A-Za-z_]*}"
    local cand="AKIA${suffix}"
    if [ "${#cand}" -ge 20 ]; then
      local key20="${cand:0:20}"
      if printf '%s\n' "$key20" | grep -q -E '^AKIA[0-9A-Z]{16}$'; then
        case "$key20" in
          *EXAMPLE*|*XXXX*|*0000*|*YOUR*|*DUMMY*|*TEST*|*SAMPLE*|*FAKE*) ;;
          *) return 0 ;;
        esac
      fi
    fi
  done

  return 1
}

# Helper: check GitHub tokens
is_github_token() {
  local line="$1"
  case "$line" in
    *ghp_*|*gho_*|*ghu_*|*ghs_*|*ghr_*|*github_pat_*) ;;
    *) return 1 ;;
  esac

  if ! printf '%s\n' "$line" | grep -q -E '(^|[^0-9A-Za-z])(gh[pousr]_[0-9A-Za-z]{16,}|github_pat_[0-9A-Za-z_]{20,})'; then
    return 1
  fi

  local lower
  lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *ghp_xxxx*|*ghp_your*|*ghp_placeholder*|*ghp_example*|*ghp_dummy*|*ghp_test*|*ghp_0000*)
      return 1
      ;;
    *gho_xxxx*|*gho_your*|*gho_placeholder*|*gho_example*|*gho_dummy*|*gho_test*|*gho_0000*)
      return 1
      ;;
    *ghu_xxxx*|*ghu_your*|*ghu_placeholder*|*ghu_example*|*ghu_dummy*|*ghu_test*|*ghu_0000*)
      return 1
      ;;
    *ghs_xxxx*|*ghs_your*|*ghs_placeholder*|*ghs_example*|*ghs_dummy*|*ghs_test*|*ghs_0000*)
      return 1
      ;;
    *ghr_xxxx*|*ghr_your*|*ghr_placeholder*|*ghr_example*|*ghr_dummy*|*ghr_test*|*ghr_0000*)
      return 1
      ;;
    *github_pat_xxxx*|*github_pat_your*|*github_pat_placeholder*|*github_pat_example*|*github_pat_dummy*|*github_pat_test*|*github_pat_0000*)
      return 1
      ;;
  esac

  return 0
}

# Helper: check Slack tokens
is_slack_token() {
  local line="$1"
  case "$line" in
    *xoxb-*|*xoxa-*|*xoxp-*|*xoxr-*|*xoxs-*) ;;
    *) return 1 ;;
  esac

  if ! printf '%s\n' "$line" | grep -q -E '(^|[^0-9A-Za-z])xox[baprs]-[0-9A-Za-z-]{10,}'; then
    return 1
  fi

  local lower
  lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *xox*-your*|*xox*-placeholder*|*xox*-example*|*xox*-dummy*|*xox*-test*|*xox*-xxxx*)
      return 1
      ;;
  esac

  return 0
}

# Helper: check Google API keys
is_google_key() {
  local line="$1"
  case "$line" in
    *AIza*) ;;
    *) return 1 ;;
  esac

  if ! printf '%s\n' "$line" | grep -q -E '(^|[^0-9A-Za-z_-])AIza[0-9A-Za-z_-]{30,}([^0-9A-Za-z_-]|$)'; then
    return 1
  fi

  local lower
  lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *aizasyyour*|*aizasydummy*|*aizasyexample*|*aizasyplaceholder*|*aizasyxxxx*|*aizasy0000*)
      return 1
      ;;
  esac

  return 0
}

# Helper: check .env-style secret assignments
is_env_secret() {
  local raw="$1"

  local line="$raw"
  case "$line" in
    +*|-*) line="${line#?}" ;;
  esac
  line="$(printf '%s' "$line" | sed 's/`[^`]*`//g')"
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  case "$line" in
    \#*|"//"*|"/*"*|"* "*) return 1 ;;
  esac

  case "$line" in
    export[[:space:]]*) line="${line#export}" ; line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')" ;;
  esac

  case "$line" in
    *=*) ;;
    *) return 1 ;;
  esac

  local var_name="${line%%=*}"
  local var_val="${line#*=}"

  var_name="$(printf '%s' "$var_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  local var_upper
  var_upper="$(printf '%s' "$var_name" | tr '[:lower:]' '[:upper:]')"

  case "$var_upper" in
    *KEY*|*SECRET*|*PASSWORD*|*PASSWD*|*TOKEN*|*AUTH*|*CREDENTIAL*|*PRIVATE*|*DATABASE_URL*|*DB_PASS*|*WEBHOOK_URL*)
      ;;
    *)
      return 1
      ;;
  esac

  case "$var_upper" in
    PRIMARY_KEY*|FOREIGN_KEY*|SORT_KEY*|KEY_CODE*|KEY_NAME*|KEY_DOWN*|KEY_UP*|HOTKEY*|KEYWORD*)
      return 1
      ;;
  esac

  var_val="$(printf '%s' "$var_val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  while :; do
    case "$var_val" in
      [\'\"\`]*[\'\"\`])
        var_val="${var_val#?}"
        var_val="${var_val%?}"
        ;;
      *) break ;;
    esac
  done
  var_val="$(printf '%s' "$var_val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [ "${#var_val}" -le 3 ]; then
    return 1
  fi

  case "$var_val" in
    '$'*|*'${'*'}'*|*'$('*')'*)
      return 1
      ;;
  esac

  case "$var_val" in
    *'<'*'>'*|'<'*|*'>')
      return 1
      ;;
  esac

  case "$var_val" in
    '('*')'|'{'*'}'|'['*']')
      return 1
      ;;
  esac

  local val_lower
  val_lower="$(printf '%s' "$var_val" | tr '[:upper:]' '[:lower:]')"

  case "$val_lower" in
    test|tests|value|values|key|keys|token|tokens|secret|secrets|password|passwords|passwd|pass|example|examples)
      return 1
      ;;
    changeme|change_me|change-me|change_this|changethis)
      return 1
      ;;
    your-*|your_*|yourapikey*|yourtoken*|yourpassword*|yoursecret*|yourkey*|yourvalue*|*your*)
      return 1
      ;;
    *placeholder*|*example*|*dummy*|*sample*|*fake*|*mock*|*todo*|*fixme*|*default*)
      return 1
      ;;
    *xxxx*|*0000*|*123456*)
      return 1
      ;;
    testpassword|mysecret|my_secret|secret123|admin|root|guest|user)
      return 1
      ;;
    my_*|insert_*|test_*|demo_*)
      return 1
      ;;
    *_here|*_value|*_key|*_token|*_secret|*_password)
      return 1
      ;;
    null|none|nil|false|true|undefined|unset|disabled|empty|na)
      return 1
      ;;
    \*\*\*|\.\.\.*)
      return 1
      ;;
  esac

  if printf '%s\n' "$var_val" | grep -q -E '^[A-Z0-9_]+$'; then
    case "$var_val" in
      *YOUR_*|*INSERT_*|*MY_*|*API_KEY*|*SECRET_KEY*|*TOKEN_HERE*|*KEY_HERE*|*PASSWORD_HERE*|*VALUE*|*KEY*|*TOKEN*|*SECRET*|*PASSWORD*)
        return 1
        ;;
    esac
  fi

  case "$val_lower" in
    http://localhost*|https://localhost*|http://127.0.0.1*|https://127.0.0.1*)
      return 1
      ;;
    postgres://localhost*|postgresql://localhost*|mysql://localhost*|redis://localhost*|mongodb://localhost*)
      return 1
      ;;
    postgres://*@localhost*|mysql://*@localhost*)
      if case "$val_lower" in *user:pass@*|*postgres:postgres@*|*root:root@*|*user:password@*) true ;; *) false ;; esac; then
        return 1
      fi
      ;;
  esac

  return 0
}

check_line_secret() {
  local line="$1"
  local in_fence="$2"
  local is_fence_line="$3"

  if is_private_key "$line"; then
    FOUND_WHAT="private_key"
    return 0
  fi

  if is_aws_key "$line"; then
    FOUND_WHAT="aws_access_key"
    return 0
  fi

  if is_github_token "$line"; then
    FOUND_WHAT="github_token"
    return 0
  fi

  if is_slack_token "$line"; then
    FOUND_WHAT="slack_token"
    return 0
  fi

  if is_google_key "$line"; then
    FOUND_WHAT="google_api_key"
    return 0
  fi

  if [ "$in_fence" -eq 0 ] && [ "$is_fence_line" -eq 0 ] && is_env_secret "$line"; then
    FOUND_WHAT="env_secret"
    return 0
  fi

  return 1
}

FOUND_WHAT=""
FOUND_FILE=""
FOUND_LINE=0

# Scan briefs
for FILE in "${SCANNED_BRIEFS[@]+"${SCANNED_BRIEFS[@]}"}"; do
  [ -f "$FILE" ] || continue
  LINE_NUM=0
  IN_FENCE=0
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    LINE_NUM=$((LINE_NUM + 1))

    STRIP_DIFF="$LINE"
    case "$STRIP_DIFF" in
      +*|-*) STRIP_DIFF="${STRIP_DIFF#?}" ;;
    esac
    TRIM_DIFF="$(printf '%s' "$STRIP_DIFF" | sed -e 's/^[[:space:]]*//')"
    IS_FENCE_LINE=0
    case "$TRIM_DIFF" in
      '```'*|'~~~'*)
        IS_FENCE_LINE=1
        if [ "$IN_FENCE" -eq 1 ]; then
          IN_FENCE=0
        else
          IN_FENCE=1
        fi
        ;;
    esac

    if check_line_secret "$LINE" "$IN_FENCE" "$IS_FENCE_LINE"; then
      FOUND_FILE="$FILE"
      FOUND_LINE="$LINE_NUM"
      break 2
    fi
  done < "$FILE"
done

# Scan diffs (with file-level skipping)
if [ -z "$FOUND_WHAT" ]; then
  for FILE in "${SCANNED_DIFFS[@]+"${SCANNED_DIFFS[@]}"}"; do
    [ -f "$FILE" ] || continue
    LINE_NUM=0
    IN_FENCE=0
    CURRENT_DIFF_FILE=""
    CANDIDATE_OLD_FILE=""
    CURRENT_FILE_SKIPPED=0

    while IFS= read -r LINE || [ -n "$LINE" ]; do
      LINE_NUM=$((LINE_NUM + 1))

      FILE_HEADER_SEEN=0
      case "$LINE" in
        "diff --git "*)
          FILE_HEADER_SEEN=1
          dpath="${LINE#diff --git }"
          case "$dpath" in
            *" b/"*)
              bpath="${dpath##* b/}"
              if [ "$bpath" != "/dev/null" ] && [ "$bpath" != "dev/null" ]; then
                CURRENT_DIFF_FILE="$bpath"
              else
                apath="${dpath% b/*}"
                case "$apath" in
                  a/*) apath="${apath#a/}" ;;
                esac
                CURRENT_DIFF_FILE="$apath"
              fi
              ;;
            *)
              CURRENT_DIFF_FILE=""
              ;;
          esac
          ;;
        "--- "*)
          FILE_HEADER_SEEN=1
          old_target="${LINE#--- }"
          old_target="${old_target%%	*}"
          old_target="${old_target%% *}"
          case "$old_target" in
            a/*) old_target="${old_target#a/}" ;;
          esac
          if [ "$old_target" != "/dev/null" ]; then
            CANDIDATE_OLD_FILE="$old_target"
            if [ -z "$CURRENT_DIFF_FILE" ]; then
              CURRENT_DIFF_FILE="$old_target"
            fi
          fi
          ;;
        "+++ "*)
          FILE_HEADER_SEEN=1
          new_target="${LINE#+++ }"
          new_target="${new_target%%	*}"
          new_target="${new_target%% *}"
          case "$new_target" in
            b/*) new_target="${new_target#b/}" ;;
          esac
          if [ "$new_target" != "/dev/null" ]; then
            CURRENT_DIFF_FILE="$new_target"
          elif [ -n "$CANDIDATE_OLD_FILE" ]; then
            CURRENT_DIFF_FILE="$CANDIDATE_OLD_FILE"
          fi
          ;;
      esac

      if [ "$FILE_HEADER_SEEN" -eq 1 ]; then
        CURRENT_FILE_SKIPPED=0
        if [ -n "$CURRENT_DIFF_FILE" ]; then
          NORM_DIFF_FILE="$(normalize_path "$CURRENT_DIFF_FILE")"
          for S in "${UNIQUE_SKIPS[@]+"${UNIQUE_SKIPS[@]}"}"; do
            if [ "$NORM_DIFF_FILE" = "$S" ]; then
              CURRENT_FILE_SKIPPED=1
              break
            fi
          done
        fi
      fi

      if [ "$CURRENT_FILE_SKIPPED" -eq 1 ]; then
        continue
      fi

      STRIP_DIFF="$LINE"
      case "$STRIP_DIFF" in
        +*|-*) STRIP_DIFF="${STRIP_DIFF#?}" ;;
      esac
      TRIM_DIFF="$(printf '%s' "$STRIP_DIFF" | sed -e 's/^[[:space:]]*//')"
      IS_FENCE_LINE=0
      case "$TRIM_DIFF" in
        '```'*|'~~~'*)
          IS_FENCE_LINE=1
          if [ "$IN_FENCE" -eq 1 ]; then
            IN_FENCE=0
          else
            IN_FENCE=1
          fi
          ;;
      esac

      if check_line_secret "$LINE" "$IN_FENCE" "$IS_FENCE_LINE"; then
        FOUND_FILE="$FILE"
        FOUND_LINE="$LINE_NUM"
        break 2
      fi
    done < "$FILE"
  done
fi

# Scan other files
if [ -z "$FOUND_WHAT" ]; then
  for FILE in "${SCANNED_OTHER[@]+"${SCANNED_OTHER[@]}"}"; do
    [ -f "$FILE" ] || continue
    LINE_NUM=0
    IN_FENCE=0
    while IFS= read -r LINE || [ -n "$LINE" ]; do
      LINE_NUM=$((LINE_NUM + 1))

      STRIP_DIFF="$LINE"
      case "$STRIP_DIFF" in
        +*|-*) STRIP_DIFF="${STRIP_DIFF#?}" ;;
      esac
      TRIM_DIFF="$(printf '%s' "$STRIP_DIFF" | sed -e 's/^[[:space:]]*//')"
      IS_FENCE_LINE=0
      case "$TRIM_DIFF" in
        '```'*|'~~~'*)
          IS_FENCE_LINE=1
          if [ "$IN_FENCE" -eq 1 ]; then
            IN_FENCE=0
          else
            IN_FENCE=1
          fi
          ;;
      esac

      if check_line_secret "$LINE" "$IN_FENCE" "$IS_FENCE_LINE"; then
        FOUND_FILE="$FILE"
        FOUND_LINE="$LINE_NUM"
        break 2
      fi
    done < "$FILE"
  done
fi

if [ -n "$FOUND_WHAT" ]; then
  REL_FILE="$FOUND_FILE"
  case "$REL_FILE" in
    "$DIR"/*) REL_FILE="${REL_FILE#$DIR/}" ;;
  esac
  printf '%s\n' "STATUS: SECRETS_FOUND($FOUND_WHAT, $REL_FILE:$FOUND_LINE)$PHASE_FIELD$RUN_FIELD | Note: secret pattern '$FOUND_WHAT' detected at $REL_FILE:$FOUND_LINE | Next: remove the credential and rotate it; it is in the file named here"
  exit 3
fi

SKIPPED_FIELD=""
if [ ${#SCANNED_DIFFS[@]} -gt 0 ] && [ -n "$SKIPPED_STR" ]; then
  SKIPPED_FIELD=" | Skipped: $SKIPPED_STR"
fi

CHECKS_LIST="private_key, aws_access_key, github_token, slack_token, google_api_key, env_secret"
printf '%s\n' "STATUS: SECRETS_NONE | Checks: $CHECKS_LIST$SKIPPED_FIELD$PHASE_FIELD$RUN_FIELD"
exit 0
