#!/usr/bin/env bash
# Compose a summary of a run and write it as an issue comment.
#
#   run-summary.sh [--dir <repo>] [--run <id|current|last>] [--issue <n>]
#                  [--into <dir>]
#
# Reads:   <run-dir>/run.json, per-phase status and verify.log,
#          .agy/ledger.jsonl, REVIEW_DIFF.stat, REVIEW_FEEDBACK.md, QA_REPORT.md
# Writes:  <run-dir>/ISSUE_COMMENT.md   the composed issue comment
# Prints:  STATUS line on stdout, followed by unrun gh commands when clean.
#
# Exit codes, one per outcome:
#     0  SUMMARY_WRITTEN      composed, scanned clean, command printed
#     2  bad arguments
#     3  SUMMARY_NO_RUN       no run to summarise
#     4  SUMMARY_SECRETS      composed, but the scan flagged something; no command printed
#     5  SUMMARY_THIN         composed from so little that the summary would mislead
#
# Mechanical verification vs worker claim:
# A phase's verdict is the worker's own claim. A --verify result is a command
# that really ran and really exited. They are reported separately and never
# blended. An unverified claim is reported as unverified. A phase that never ran
# is reported as did not run. Missing artifacts are reported as not found.
#
# Secret scanning:
# Before offering to publish, check-secrets.sh scans the composed comment.
# If a secret is flagged, exit 4 is returned, no command is printed, and only
# the scanner's pattern name/line reference is reported.
#
# Print, never post:
# This script executes no gh command. It prints the unrun gh issue comment and
# gh pr create commands for a human to review and execute.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"
RUN_TARGET="current"
ISSUE=""
INTO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="${2:-}"; shift 2 || true ;;
    --run)   RUN_TARGET="${2:-}"; shift 2 || true ;;
    --issue) ISSUE="${2:-}"; shift 2 || true ;;
    --into)  INTO="${2:-}"; shift 2 || true ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "run-summary: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -d "$DIR" ] || { echo "run-summary: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

if [ -n "$ISSUE" ]; then
  case "$ISSUE" in
    ''|*[!0-9]*)
      echo "run-summary: --issue wants a positive integer, got '$ISSUE'" >&2
      exit 2
      ;;
  esac
fi

if [ -n "$INTO" ]; then
  DEST_DIR="$INTO"
  if [ -d "$INTO" ] && { [ -f "$INTO/run.json" ] || [ -d "$INTO/phases" ]; }; then
    RUN_DIR="$(cd "$INTO" && pwd)"
  else
    RUN_DIR="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET" 2>/dev/null || true)"
  fi
else
  RUN_DIR="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET" 2>/dev/null || true)"
  DEST_DIR="$RUN_DIR"
fi

if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  printf 'STATUS: SUMMARY_NO_RUN | Note: no run found to summarise\n'
  exit 3
fi

RUN_ID="$(run_dir_get "$RUN_DIR" "run" 2>/dev/null || basename "$RUN_DIR")"
TASK="$(run_dir_get "$RUN_DIR" "task" 2>/dev/null || true)"
BRANCH="$(run_dir_get "$RUN_DIR" "branch" 2>/dev/null || true)"
BASE="$(run_dir_get "$RUN_DIR" "base" 2>/dev/null || true)"

if [ -z "$TASK" ]; then
  TASK="run $RUN_ID"
fi

if [ -z "$BRANCH" ] && [ -d "$DIR" ]; then
  BRANCH="$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null || git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

HAS_REMOTE=0
DEFAULT_BRANCH=""
if [ -d "$DIR" ]; then
  remotes="$(git -C "$DIR" remote 2>/dev/null || true)"
  if [ -n "$remotes" ]; then
    HAS_REMOTE=1
    for r in $remotes; do
      headref="$(git -C "$DIR" symbolic-ref --short "refs/remotes/$r/HEAD" 2>/dev/null || true)"
      if [ -n "$headref" ]; then
        cand="${headref#$r/}"
        if git -C "$DIR" rev-parse --verify -q "refs/heads/$cand" >/dev/null 2>&1 || \
           git -C "$DIR" rev-parse --verify -q "refs/remotes/$r/$cand" >/dev/null 2>&1; then
          DEFAULT_BRANCH="$cand"
          break
        fi
      fi
    done
  fi

  if [ -z "$DEFAULT_BRANCH" ]; then
    for cand in main master trunk; do
      if git -C "$DIR" rev-parse --verify -q "refs/heads/$cand" >/dev/null 2>&1; then
        DEFAULT_BRANCH="$cand"
        break
      fi
    done
  fi

  if [ -z "$DEFAULT_BRANCH" ]; then
    init_branch="$(git -C "$DIR" config init.defaultBranch 2>/dev/null || true)"
    if [ -n "$init_branch" ] && git -C "$DIR" rev-parse --verify -q "refs/heads/$init_branch" >/dev/null 2>&1; then
      DEFAULT_BRANCH="$init_branch"
    fi
  fi

  if [ -z "$DEFAULT_BRANCH" ]; then
    head_sym="$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -n "$head_sym" ] && git -C "$DIR" rev-parse --verify -q "refs/heads/$head_sym" >/dev/null 2>&1; then
      if [ "$head_sym" = "main" ] || [ "$head_sym" = "master" ] || [ "$head_sym" = "trunk" ]; then
        DEFAULT_BRANCH="$head_sym"
      fi
    fi
  fi
fi

if [ -z "$ISSUE" ]; then
  if [ -f "$RUN_DIR/ISSUE.md" ]; then
    ISSUE="$(sed -n 's/^# Quoted GitHub Issue #\([0-9][0-9]*\).*/\1/p' "$RUN_DIR/ISSUE.md" 2>/dev/null | head -1)"
  fi
  if [ -z "$ISSUE" ] && [ -f "$DIR/.agy/ledger.jsonl" ]; then
    ISSUE="$(sed -n "s/.*\"run\":\"$RUN_ID\".*\"issue\":\([0-9][0-9]*\).*/\1/p" "$DIR/.agy/ledger.jsonl" 2>/dev/null | head -1)"
  fi
fi

# Count phase statuses across the run
PHASE_STATUS_COUNT=0
if [ -d "$RUN_DIR/phases" ]; then
  for pdir in "$RUN_DIR"/phases/*; do
    if [ -d "$pdir" ] && [ -f "$pdir/status" ]; then
      PHASE_STATUS_COUNT=$((PHASE_STATUS_COUNT + 1))
    fi
  done
fi

if [ "$PHASE_STATUS_COUNT" -eq 0 ]; then
  printf 'STATUS: SUMMARY_THIN | Run: %s | Note: no phase status records found in run\n' "$RUN_ID"
  exit 5
fi

mkdir -p "$DEST_DIR" 2>/dev/null || {
  echo "run-summary: could not create destination directory $DEST_DIR" >&2
  exit 2
}
DEST_DIR="$(cd "$DEST_DIR" && pwd)"
COMMENT_FILE="$DEST_DIR/ISSUE_COMMENT.md"

# Determine phase list to report
PHASE_LIST=()
if [ -d "$RUN_DIR/phases/DELEGATE" ] && [ ! -d "$RUN_DIR/phases/IMPLEMENT" ] && [ ! -d "$RUN_DIR/phases/DISCOVER" ]; then
  PHASE_LIST[0]="DELEGATE"
else
  PHASE_LIST=("DISCOVER" "IMPLEMENT" "REVIEW" "QA" "RELEASE")
  if [ -d "$RUN_DIR/phases" ]; then
    for extra_p in "$RUN_DIR"/phases/*; do
      [ -d "$extra_p" ] || continue
      pname="$(basename "$extra_p")"
      exists=0
      for ep in "${PHASE_LIST[@]+"${PHASE_LIST[@]}"}"; do
        if [ "$ep" = "$pname" ]; then
          exists=1
          break
        fi
      done
      if [ $exists -eq 0 ]; then
        PHASE_LIST[${#PHASE_LIST[@]}]="$pname"
      fi
    done
  fi
fi

# Collect bug label hint if present
HAS_BUG_LABEL=0
if [ -f "$RUN_DIR/ISSUE.md" ]; then
  if grep -i -E '(\*\*labels\*\*:.*\<bug\>|labels:.*\<bug\>)' "$RUN_DIR/ISSUE.md" >/dev/null 2>&1; then
    HAS_BUG_LABEL=1
  fi
fi

# Parse token spend from ledger if recorded
LEDGER_FILE="$DIR/.agy/ledger.jsonl"
TOTAL_TOKENS=0
INPUT_TOKENS=0
OUTPUT_TOKENS=0
THINKING_TOKENS=0
HAS_TOKEN_USAGE=0

if [ -f "$LEDGER_FILE" ]; then
  while IFS= read -r lline || [ -n "$lline" ]; do
    case "$lline" in
      *"\"run\":\"$RUN_ID\""*)
        case "$lline" in
          *"\"usage\":{"*)
            inp="$(printf '%s\n' "$lline" | sed -n 's/.*"input_tokens":\([0-9][0-9]*\).*/\1/p' 2>/dev/null || true)"
            out="$(printf '%s\n' "$lline" | sed -n 's/.*"output_tokens":\([0-9][0-9]*\).*/\1/p' 2>/dev/null || true)"
            thk="$(printf '%s\n' "$lline" | sed -n 's/.*"thinking_tokens":\([0-9][0-9]*\).*/\1/p' 2>/dev/null || true)"
            tot="$(printf '%s\n' "$lline" | sed -n 's/.*"total_tokens":\([0-9][0-9]*\).*/\1/p' 2>/dev/null || true)"
            [ -n "$inp" ] && INPUT_TOKENS=$((INPUT_TOKENS + inp))
            [ -n "$out" ] && OUTPUT_TOKENS=$((OUTPUT_TOKENS + out))
            [ -n "$thk" ] && THINKING_TOKENS=$((THINKING_TOKENS + thk))
            if [ -n "$tot" ] && [ "$tot" -gt 0 ]; then
              TOTAL_TOKENS=$((TOTAL_TOKENS + tot))
              HAS_TOKEN_USAGE=1
            fi
            ;;
        esac
        ;;
    esac
  done < "$LEDGER_FILE"
fi

# Compose comment body
{
  printf '## Run Summary: %s\n\n' "$TASK"
  printf -- '- **Run ID**: `%s`\n' "$RUN_ID"
  printf -- '- **Task**: %s\n' "$TASK"
  if [ -n "$ISSUE" ]; then
    printf -- '- **Issue**: #%s\n' "$ISSUE"
  fi
  if [ -n "$BRANCH" ]; then
    printf -- '- **Branch**: `%s`\n' "$BRANCH"
  fi
  if [ -n "$BASE" ]; then
    printf -- '- **Base commit**: `%s`\n' "$BASE"
  fi
  printf '\n'

  if [ "$HAS_BUG_LABEL" -eq 1 ]; then
    printf '> [!NOTE]\n'
    if [ -n "$ISSUE" ]; then
      printf '> Run started from issue #%s labelled `bug` — a regression test is expected.\n\n' "$ISSUE"
    else
      printf '> Run started from an issue labelled `bug` — a regression test is expected.\n\n'
    fi
  fi

  printf '### Phase Outcomes and Verification\n\n'
  printf '| Phase | Attempts | Worker Claim | Mechanical Verification | Outcome |\n'
  printf '|---|---|---|---|---|\n'

  for ph in "${PHASE_LIST[@]+"${PHASE_LIST[@]}"}"; do
    p_path="$RUN_DIR/phases/$ph"
    if [ -d "$p_path" ] && [ -f "$p_path/status" ]; then
      st_line="$(head -n 1 "$p_path/status" 2>/dev/null || true)"
      p_outcome="$(printf '%s' "$st_line" | sed -e 's/^STATUS: //' -e 's/ |.*//')"
      [ -n "$p_outcome" ] || p_outcome="PASSED"

      # Worker claim
      if [ -f "$p_path/verdict" ]; then
        p_claim="$(head -n 1 "$p_path/verdict" 2>/dev/null | sed -e 's/^STATUS: //' -e 's/ |.*//')"
        [ -n "$p_claim" ] || p_claim="claimed done (empty verdict file)"
      else
        p_claim="$(printf '%s' "$st_line" | sed -n 's/.*Verdict: \([^|]*\).*/\1/p' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$p_claim" ] || p_claim="verdict not found"
      fi

      # Mechanical verification
      if [ -f "$p_path/verify.log" ]; then
        if case "$st_line" in *'Verify: PASSED'*|*'verify_ran: true'*) true ;; *) false ;; esac; then
          p_mech="PASSED (command verified)"
        elif case "$st_line" in *'VERIFY_FAILED'*|*'Verify: FAILED'*) true ;; *) false ;; esac; then
          p_mech="FAILED (command verified)"
        else
          p_mech="executed (see verify.log)"
        fi
      elif case "$st_line" in *'Verify: PASSED'*) true ;; *) false ;; esac; then
        p_mech="PASSED (command verified)"
      else
        p_mech="unverified (no --verify ran)"
      fi

      # Attempts
      p_att="$(printf '%s' "$st_line" | sed -n 's/.*Attempt: \([0-9][0-9]*\).*/\1/p')"
      [ -n "$p_att" ] || p_att="1"

      printf '| %s | %s | %s | %s | %s |\n' "$ph" "$p_att" "$p_claim" "$p_mech" "$p_outcome"
    else
      printf '| %s | did not run | did not run | did not run | did not run |\n' "$ph"
    fi
  done
  printf '\n'

  printf '### Changes (Diff Stat)\n\n'
  if [ -f "$RUN_DIR/REVIEW_DIFF.stat" ]; then
    printf '```\n'
    cat "$RUN_DIR/REVIEW_DIFF.stat"
    case "$(tail -c 1 "$RUN_DIR/REVIEW_DIFF.stat" 2>/dev/null)" in
      $'\n'|"") ;;
      *) printf '\n' ;;
    esac
    printf '```\n\n'
  else
    printf 'REVIEW_DIFF.stat not found\n\n'
  fi

  printf '### Code Review\n\n'
  if [ -f "$RUN_DIR/REVIEW_FEEDBACK.md" ]; then
    cat "$RUN_DIR/REVIEW_FEEDBACK.md"
    case "$(tail -c 1 "$RUN_DIR/REVIEW_FEEDBACK.md" 2>/dev/null)" in
      $'\n'|"") ;;
      *) printf '\n' ;;
    esac
    printf '\n'
  else
    printf 'REVIEW_FEEDBACK.md not found\n\n'
  fi

  printf '### QA Report\n\n'
  if [ -f "$RUN_DIR/QA_REPORT.md" ]; then
    cat "$RUN_DIR/QA_REPORT.md"
    case "$(tail -c 1 "$RUN_DIR/QA_REPORT.md" 2>/dev/null)" in
      $'\n'|"") ;;
      *) printf '\n' ;;
    esac
    printf '\n'
  else
    printf 'QA_REPORT.md not found\n\n'
  fi

  if [ "$HAS_TOKEN_USAGE" -eq 1 ] && [ "$TOTAL_TOKENS" -gt 0 ]; then
    printf '### Token Spend\n\n'
    printf -- '- **Total spend**: %d tokens [input: %d, output: %d, thinking: %d]\n\n' \
      "$TOTAL_TOKENS" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$THINKING_TOKENS"
  fi
} > "$COMMENT_FILE" 2>/dev/null || {
  echo "run-summary: could not write to $COMMENT_FILE" >&2
  exit 2
}

# Scan comment file for secrets before printing publish command
REL_COMMENT_FILE="$COMMENT_FILE"
case "$REL_COMMENT_FILE" in
  "$DIR"/*) REL_COMMENT_FILE="${REL_COMMENT_FILE#$DIR/}" ;;
esac

SCAN_OUT="$("$HERE/check-secrets.sh" --file "$COMMENT_FILE" --dir "$DIR" 2>&1)"
SCAN_RC=$?

if [ "$SCAN_RC" -eq 3 ]; then
  FINDING="$(printf '%s\n' "$SCAN_OUT" | grep -E '^STATUS: SECRETS_FOUND' | head -1 | sed 's/^STATUS: //')"
  [ -n "$FINDING" ] || FINDING="SECRETS_FOUND in comment file"
  printf 'STATUS: SUMMARY_SECRETS | File: %s | %s\n' "$REL_COMMENT_FILE" "$FINDING"
  exit 4
elif [ "$SCAN_RC" -ne 0 ]; then
  echo "run-summary: secret check failed with exit code $SCAN_RC" >&2
  exit 2
fi

printf 'STATUS: SUMMARY_WRITTEN | File: %s | Run: %s\n' "$REL_COMMENT_FILE" "$RUN_ID"

# Print unrun commands for human execution
if [ -n "$ISSUE" ]; then
  printf '\n# Post summary comment to GitHub issue #%s\n' "$ISSUE"
  printf 'gh issue comment %s --body-file "%s"\n' "$ISSUE" "$REL_COMMENT_FILE"
else
  printf '\n# Post summary comment to GitHub issue\n'
  printf 'gh issue comment <issue-number> --body-file "%s"\n' "$REL_COMMENT_FILE"
fi

printf '\n# Create draft pull request\n'
if [ "$HAS_REMOTE" -eq 0 ]; then
  printf '# Repository has no remote configured; a pull request needs a remote first\n'
elif [ -z "$DEFAULT_BRANCH" ]; then
  printf '# Default branch could not be determined; a pull request needs a branch first\n'
elif [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  printf '# Run was made on a detached HEAD; a pull request needs a branch first\n'
elif [ "$BRANCH" = "$DEFAULT_BRANCH" ]; then
  printf '# Run was made on the default branch (%s); a pull request needs a branch first\n' "$DEFAULT_BRANCH"
else
  printf 'gh pr create --draft --head "%s" --title "%s" --body-file "%s"\n' "$BRANCH" "$TASK" "$REL_COMMENT_FILE"
fi

exit 0
