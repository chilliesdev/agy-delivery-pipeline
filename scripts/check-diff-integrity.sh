#!/usr/bin/env bash
# Mechanically detect weakened tests, scope creep, and unverified diffs.
#
#   check-diff-integrity.sh [--dir <repo>] [--run <id|current|last>]
#                           [--patch <path>] [--brief <path>] [--stat <path>]
#
# Reads:   <run-dir>/REVIEW_DIFF.patch   the unified diff under review
#          <run-dir>/REVIEW_DIFF.stat    the per-file summary
#          <brief>                       task description (for scope check)
# Writes:  nothing.
# Prints:  the STATUS line only — stdout belongs to it alone, as everywhere else.
#
# Exit codes, one per outcome:
#     0  DIFF_CLEAN               nothing found — and the line says what was checked
#     0  DIFF_SUSPICIOUS(...)     worth reading: scope creep, falling assertions
#     3  DIFF_TESTS_WEAKENED(...) strong enough to fail the phase
#     0  DIFF_UNCHECKED(lang=?)   nothing was analysed — say so loudly
#     2  bad arguments
#
# Precedence of outcomes:
#     1. DIFF_TESTS_WEAKENED — if any weakened-test finding exists, this is the
#        status and the exit code is 3, whatever else was found. DIFF_TESTS_WEAKENED
#        is the only one of these strong enough to fail a phase, and a status that
#        silently demotes it means the one finding that should stop a run does not.
#        A DIFF_TESTS_WEAKENED line still mentions any suspicious findings in its fields.
#     2. DIFF_SUSPICIOUS — no weakened tests, but scope creep, a falling assertion
#        count, an edited literal, or a suspected invented API.
#     3. DIFF_UNCHECKED — nothing was analysed at all.
#     4. DIFF_CLEAN — checks ran and found nothing.
#
# Why this exists. --verify proves a command exited zero; it cannot tell you the
# tests were not gutted to make it do so. check-review.sh can only tell you
# whether the reviewer cited anything, not whether what it cited was right.
# The two highest-consequence failure modes — tests weakened to make things green,
# and scope creep — have previously rested on a human reading a patch. This
# script mechanises those checks.
#
# Scope check rule:
# The scope check is a set difference between the paths a brief names and the
# paths a diff touches.
#
# What counts as a path:
# Path-shaped tokens are extracted from anywhere in the brief (in prose sentences,
# bulleted lists, backticks, or links). A token counts as a path if:
#   1. It contains '/' after stripping surrounding punctuation and markdown
#      (backticks, quotes, brackets, parentheses, trailing '.', ',', ':', ';').
#   2. AND either ends in a recognisable source extension or begins with a
#      directory that appears in the diff.
# Bare directories ('src/', 'tests/') name everything beneath them.
#
# Safety net (zero paths extracted):
# If zero paths are extracted from a brief, the scope check has not run.
# Finding no paths means the check could not run rather than that everything is
# creep. An unparsed brief must not falsely flag honest diffs as scope creep.
#
# Why DIFF_TESTS_WEAKENED fails (exit 3) while DIFF_SUSPICIOUS advises (exit 0).
# A deleted test file, an added test skip (@pytest.mark.skip, it.only, t.Skip), or
# an assertion rewritten to a tautology (assert True) is unequivocal evidence of
# a suite being dismantled. That is strong enough to override a phase verdict.
# Conversely, scope creep or falling assertion counts may be legitimate refactors
# or benign additions; they warrant human attention (DIFF_SUSPICIOUS) but must
# not fail a build automatically.
#
# Why edited expected literals are reported as suspicion.
# Changing an expected value in an assertion (e.g. from 42 to 99) with no
# corresponding change in source code is the most common way tests are dishonestly
# turned green. However, static diff analysis cannot know author intent without
# semantic evaluation. Thus, it is flagged as DIFF_SUSPICIOUS for human review.
#
# Why DIFF_UNCHECKED exists.
# A check that silently ran nothing is a known failure mode (like REVIEW_THIN).
# If the diff touches languages with no supported rules, DIFF_UNCHECKED reports
# that explicitly rather than falsely claiming DIFF_CLEAN.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/run-dir.sh"

DIR="$PWD"; PATCH=""; BRIEF=""; STAT=""; RUN_TARGET="current"
BRIEF_EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2";        shift 2 ;;
    --run)   RUN_TARGET="$2"; shift 2 ;;
    --patch) PATCH="$2";      shift 2 ;;
    --brief) BRIEF="$2"; BRIEF_EXPLICIT=1; shift 2 ;;
    --stat)  STAT="$2";       shift 2 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "check-diff-integrity: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -d "$DIR" ] || { echo "check-diff-integrity: dir not found: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

if [ -z "$PATCH" ] || [ -z "$STAT" ] || { [ "$BRIEF_EXPLICIT" -eq 0 ] && [ -z "$BRIEF" ]; }; then
  if R="$(run_dir_resolve --dir "$DIR" --run "$RUN_TARGET" 2>/dev/null)"; then
    PATCH="${PATCH:-$R/REVIEW_DIFF.patch}"
    STAT="${STAT:-$R/REVIEW_DIFF.stat}"
    if [ "$BRIEF_EXPLICIT" -eq 0 ] && [ -z "$BRIEF" ]; then
      if [ -f "$R/phases/IMPLEMENT/brief.md" ]; then
        BRIEF="$R/phases/IMPLEMENT/brief.md"
      elif [ -f "$R/phases/1/brief.md" ]; then
        BRIEF="$R/phases/1/brief.md"
      elif [ -f "$R/brief.md" ]; then
        BRIEF="$R/brief.md"
      fi
    fi
  fi
fi

if [ -z "$PATCH" ]; then
  echo "check-diff-integrity: patch file not specified and run directory could not be resolved" >&2
  exit 2
fi

if [ ! -f "$PATCH" ]; then
  echo "check-diff-integrity: patch file not found: $PATCH" >&2
  exit 2
fi

# Extract all paths touched in the diff
PATHS="$(LC_ALL=C sed -n -e 's|^+++ b/||p' -e 's|^--- a/||p' "$PATCH" 2>/dev/null \
  | LC_ALL=C sed -e 's/[[:space:]].*$//' | grep -v '^/dev/null$' | sort -u)"

if [ -z "$PATHS" ]; then
  printf '%s\n' "STATUS: DIFF_CLEAN | Checked: 0 files | Note: patch contains no file changes | Patch: $PATCH"
  exit 0
fi

TOTAL_FILES="$(printf '%s\n' "$PATHS" | grep -c . | tr -cd '0-9')"
TOTAL_FILES="${TOTAL_FILES:-0}"

# Count added and removed lines in the patch (excluding patch headers)
ADDED_LINES="$(grep -a -E '^\+' "$PATCH" 2>/dev/null | grep -a -v -E '^\+\+\+' | grep -c . | tr -cd '0-9')"
ADDED_LINES="${ADDED_LINES:-0}"
REMOVED_LINES="$(grep -a -E '^-' "$PATCH" 2>/dev/null | grep -a -v -E '^---' | grep -c . | tr -cd '0-9')"
REMOVED_LINES="${REMOVED_LINES:-0}"
DIFF_COUNTS="+$ADDED_LINES/-$REMOVED_LINES"

# --- Scope check -----------------------------------------------------------
# Scope check is a set difference between the paths a brief names and the paths
# a diff touches. If zero paths are extracted, the check is reported as not run.
SCOPE_STATUS=""
SCOPE_CREEP=""
SCOPE_RAN=0

if [ -n "$BRIEF" ] && [ -f "$BRIEF" ] && [ -s "$BRIEF" ]; then
  DIFF_DIRS=""
  while IFS= read -r P; do
    [ -n "$P" ] || continue
    CUR="$P"
    while case "$CUR" in */*) true ;; *) false ;; esac; do
      CUR="${CUR%/*}"
      DIFF_DIRS="$DIFF_DIRS $CUR/"
    done
  done <<EOF
$PATHS
EOF

  RAW_TOKENS=""
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    LINE_CLEAN="$(printf '%s' "$LINE" | tr '`"'\''()[]<>{}*' ' ')"
    set -f
    for TOK in $LINE_CLEAN; do
      CAND="$TOK"
      while :; do
        case "$CAND" in
          [\'\"\`\(\[\<\{\,\.\:\;\!\?\-]*) CAND="${CAND#?}" ;;
          *) break ;;
        esac
      done
      while :; do
        case "$CAND" in
          *[\'\"\`\)\]\>\}\,\.\:\;\!\?]) CAND="${CAND%?}" ;;
          *) break ;;
        esac
      done

      [ -n "$CAND" ] || continue

      case "$CAND" in
        ./*) CAND="${CAND#./}" ;;
        /*)  CAND="${CAND#/}" ;;
      esac

      case "$CAND" in
        */*) ;;
        *) continue ;;
      esac

      IS_PATH=0
      case "$CAND" in
        *.py|*.pyi|\
        *.js|*.mjs|*.cjs|*.jsx|*.ts|*.mts|*.cts|*.tsx|\
        *.go|*.rs|*.java|*.kt|*.kts|*.scala|*.groovy|\
        *.sh|*.bash|*.zsh|\
        *.c|*.h|*.cpp|*.hpp|*.cc|*.cxx|*.hh|*.hxx|\
        *.cs|*.fs|*.rb|*.rake|*.php|*.swift|*.lua|\
        *.html|*.htm|*.css|*.scss|*.sass|*.less|*.vue|*.svelte|\
        *.md|*.markdown|*.txt|*.json|*.yaml|*.yml|*.toml|*.ini|*.cfg|*.conf|*.csv|*.tsv|*.xml|*.sql|*.graphql|*.proto|*.patch|*.diff)
          IS_PATH=1
          ;;
      esac

      if [ "$IS_PATH" -eq 0 ]; then
        for D in $DIFF_DIRS; do
          case "$CAND" in
            "$D"*|"${D%/}")
              IS_PATH=1
              break
              ;;
          esac
        done
      fi

      if [ "$IS_PATH" -eq 1 ]; then
        RAW_TOKENS="$RAW_TOKENS"$'\n'"$CAND"
      fi
    done
    set +f
  done < "$BRIEF"

  BRIEF_TOKENS="$(printf '%s\n' "$RAW_TOKENS" | sed '/^$/d' | sort -u)"

  if [ -n "$BRIEF_TOKENS" ]; then
    SCOPE_RAN=1
    while IFS= read -r F; do
      [ -n "$F" ] || continue
      
      # 1. Exact match
      if printf '%s\n' "$BRIEF_TOKENS" | grep -F -x -q -- "$F" 2>/dev/null; then
        continue
      fi
      
      # 2. Basename match
      BASE_F="$(basename "$F")"
      if printf '%s\n' "$BRIEF_TOKENS" | grep -F -x -q -- "$BASE_F" 2>/dev/null; then
        continue
      fi
      
      # 3. Directory prefix match (e.g. brief names "scripts/" or "tests/" or "src")
      DIR_COVERED=0
      while IFS= read -r BT; do
        [ -n "$BT" ] || continue
        CLEAN_BT="${BT%/}"
        case "$F" in
          "$CLEAN_BT"/*) DIR_COVERED=1; break ;;
        esac
      done <<EOF
$BRIEF_TOKENS
EOF
      [ "$DIR_COVERED" -eq 1 ] && continue
      
      # 4. Test file for named source file
      STEM="$(basename "$F" | sed -e 's/\.[^.]*$//' -e 's/^test_//' -e 's/_test$//' -e 's/\.test$//' -e 's/\.spec$//' -e 's/Test$//' -e 's/^Test//')"
      STEM_COVERED=0
      if [ -n "$STEM" ]; then
        while IFS= read -r BT; do
          [ -n "$BT" ] || continue
          BT_BASE="$(basename "$BT" | sed -e 's/\.[^.]*$//')"
          if [ "$BT_BASE" = "$STEM" ]; then
            STEM_COVERED=1
            break
          fi
        done <<EOF
$BRIEF_TOKENS
EOF
      fi
      [ "$STEM_COVERED" -eq 1 ] && continue
      
      # If not covered, record as scope creep
      if [ -z "$SCOPE_CREEP" ]; then
        SCOPE_CREEP="$F"
      else
        SCOPE_CREEP="$SCOPE_CREEP, $F"
      fi
    done <<EOF
$PATHS
EOF

    if [ -n "$SCOPE_CREEP" ]; then
      SCOPE_STATUS="creep ($SCOPE_CREEP)"
    else
      SCOPE_STATUS="clean (all paths in brief)"
    fi
  else
    SCOPE_STATUS="not run (no paths in brief)"
  fi
else
  SCOPE_STATUS="not run (no brief supplied)"
fi

# --- Patch analysis for weakened tests and language rules -------------------
ANALYSIS="$(awk '
BEGIN {
    curr_file = ""
    curr_lang = ""
    curr_is_test = 0
    curr_is_deleted = 0
    curr_is_new = 0
    
    file_asserts_added = 0
    file_asserts_removed = 0
    file_funcs_added = 0
    file_funcs_removed = 0
    
    source_files_changed = 0
    test_files_changed = 0
    
    hunk_assert_rem = ""
}

function finish_file() {
    if (curr_file == "") return;
    
    if (curr_is_test) {
        test_files_changed++
        if (curr_is_deleted) {
            print "WEAKENED:test_file_deleted: " curr_file
        } else {
            if (file_asserts_removed > file_asserts_added) {
                diff_count = file_asserts_removed - file_asserts_added
                print "SUSPICIOUS:assertions_falling: " curr_file " (-" diff_count ")"
            }
            if (file_funcs_removed > file_funcs_added) {
                print "WEAKENED:test_function_removed: " curr_file
            }
        }
    } else {
        if (!curr_is_deleted || curr_is_new) {
            source_files_changed++
        }
    }
}

function get_lang_from_path(p) {
    if (p ~ /\.py$/) return "python";
    if (p ~ /\.(js|mjs|cjs|jsx)$/) return "javascript";
    if (p ~ /\.(ts|mts|cts|tsx)$/) return "typescript";
    if (p ~ /\.go$/) return "go";
    if (p ~ /\.rs$/) return "rust";
    if (p ~ /\.java$/) return "java";
    if (p ~ /\.(sh|bash|zsh)$/) return "bash";
    if (p ~ /\.(md|markdown|txt|json|ya?ml|toml|ini|cfg|csv)$/) return "doc_data";
    if (p ~ /\.rb$/) return "ruby";
    if (p ~ /\.lua$/) return "lua";
    if (p ~ /\.(c|h|cpp|hpp|cc|cxx)$/) return "c_cpp";
    if (p ~ /\.cs$/) return "csharp";
    if (p ~ /\.php$/) return "php";
    if (p ~ /\.swift$/) return "swift";
    if (p ~ /\.kt$/) return "kotlin";
    if (p ~ /\.scala$/) return "scala";
    return "unknown";
}

function is_test_file(p) {
    if (p ~ /(^|\/)tests?\//) return 1;
    if (p ~ /(^|\/)__tests__\//) return 1;
    if (p ~ /(^|\/)test_[^\/]+$/) return 1;
    if (p ~ /(^|\/)[^\/]+_test\.[^\/]+$/) return 1;
    if (p ~ /(^|\/)[^\/]+\.(test|spec)\.[^\/]+$/) return 1;
    if (p ~ /(^|\/)Test[^\/]+\.java$/) return 1;
    if (p ~ /(^|\/)[^\/]+Test(s|Case)?\.java$/) return 1;
    return 0;
}

/^@@ / {
    hunk_assert_rem = ""
    next
}

/^diff --git / {
    finish_file()
    
    curr_file = ""
    curr_lang = ""
    curr_is_test = 0
    curr_is_deleted = 0
    curr_is_new = 0
    file_asserts_added = 0
    file_asserts_removed = 0
    file_funcs_added = 0
    file_funcs_removed = 0
    hunk_assert_rem = ""
    
    p = $3
    sub(/^a\//, "", p)
    curr_file = p
    curr_lang = get_lang_from_path(curr_file)
    curr_is_test = is_test_file(curr_file)
    next
}

/^deleted file mode/ {
    curr_is_deleted = 1
    next
}

/^new file mode/ {
    curr_is_new = 1
    next
}

/^--- / {
    if ($2 == "/dev/null") {
        curr_is_new = 1
    } else {
        p = $2
        sub(/^a\//, "", p)
        if (curr_file == "") {
            curr_file = p
            curr_lang = get_lang_from_path(curr_file)
            curr_is_test = is_test_file(curr_file)
        }
    }
    next
}

/^\+\+\+ / {
    if ($2 == "/dev/null") {
        curr_is_deleted = 1
    } else {
        p = $2
        sub(/^b\//, "", p)
        curr_file = p
        curr_lang = get_lang_from_path(curr_file)
        curr_is_test = is_test_file(curr_file)
    }
    if (curr_lang != "" && curr_lang != "doc_data") {
        print "LANG:" curr_lang
    }
    next
}

/^-/ {
    line = substr($0, 2)
    
    if (curr_is_test) {
        if (line ~ /^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_/ || \
            line ~ /^[[:space:]]*func[[:space:]]+Test/ || \
            line ~ /^[[:space:]]*(it|test)[[:space:]]*\(/ || \
            line ~ /^[[:space:]]*(#\[test\]|fn[[:space:]]+test_)/ || \
            line ~ /^[[:space:]]*(@Test|public[[:space:]]+void[[:space:]]+test|void[[:space:]]+test)/ || \
            (curr_lang == "bash" && line ~ /^[[:space:]]*(function[[:space:]]+)?test_/)) {
            file_funcs_removed++
        }
        
        is_assert = 0
        if (line ~ /^[[:space:]]*assert([[:space:]]|\()/) is_assert = 1;
        if (line ~ /^[[:space:]]*self\.assert/) is_assert = 1;
        if (line ~ /^[[:space:]]*with[[:space:]]+pytest\.raises/) is_assert = 1;
        if (line ~ /expect\(/ || line ~ /assert\(/ || line ~ /assert\./ || line ~ /\.should\./) is_assert = 1;
        if (line ~ /t\.(Error|Fatal|Fail)/ || line ~ /assert\./ || line ~ /require\./) is_assert = 1;
        if (line ~ /assert!/ || line ~ /assert_eq!/ || line ~ /assert_ne!/) is_assert = 1;
        if (line ~ /assertEquals\(/ || line ~ /assertTrue\(/ || line ~ /assertFalse\(/ || line ~ /assertThat\(/) is_assert = 1;
        if (curr_lang == "bash" && (line ~ /^[[:space:]]*(assert|check|ok|bad)[[:space:]]+/)) is_assert = 1;
        
        if (is_assert) {
            file_asserts_removed++
            hunk_assert_rem = line
        }
    }
    next
}

/^\+/ {
    line = substr($0, 2)
    
    skip_found = ""
    if (line ~ /@pytest\.mark\.(skip|xfail)/) skip_found = "@pytest.mark.skip";
    else if (line ~ /@unittest\.skip/) skip_found = "@unittest.skip";
    else if (line ~ /pytest\.skip\(/) skip_found = "pytest.skip";
    else if (line ~ /(^|[^a-zA-Z0-9_])(it|describe|test)\.only($|[^a-zA-Z0-9_])/) skip_found = "it.only";
    else if (line ~ /(^|[^a-zA-Z0-9_])(it|describe|test)\.skip($|[^a-zA-Z0-9_])/) skip_found = "it.skip";
    else if (line ~ /(^|[^a-zA-Z0-9_])(xit|xtest|xdescribe|fit|fdescribe)($|[^a-zA-Z0-9_])/) skip_found = "xit";
    else if (line ~ /t\.Skip(f|Now)?\(/) skip_found = "t.Skip(";
    else if (line ~ /#\[ignore\]/) skip_found = "#[ignore]";
    else if (line ~ /@(Ignore|Disabled)($|[^a-zA-Z0-9_])/) skip_found = "@Ignore/@Disabled";
    else if (curr_lang == "bash" && curr_is_test && line ~ /^[[:space:]]*skip[[:space:]]+/) skip_found = "skip";
    
    if (skip_found != "") {
        print "WEAKENED:skip_added: " skip_found " in " curr_file
    }
    
    if (curr_is_test) {
        triv_found = ""
        sline = line
        sub(/^[[:space:]]+/, "", sline)
        sub(/[[:space:]]+$/, "", sline)
        
        if (sline ~ /^assert[[:space:]]+(True|true|1[[:space:]]*==[[:space:]]*1|0[[:space:]]*==[[:space:]]*0|1([[:space:]]*[,#].*)?$)/) triv_found = "assert True";
        else if (sline ~ /^assert\([[:space:]]*(True|true|1[[:space:]]*==[[:space:]]*1)[[:space:]]*\)/) triv_found = "assert True";
        else if (sline ~ /assert_?True\([[:space:]]*(true|True|1[[:space:]]*==[[:space:]]*1)[[:space:]]*\)/) triv_found = "assertTrue(true)";
        else if (sline ~ /expect\([[:space:]]*(true|1)[[:space:]]*\)\.toBe\([[:space:]]*(true|1)[[:space:]]*\)/) triv_found = "expect(true).toBe(true)";
        else if (sline ~ /expect\([[:space:]]*true[[:space:]]*\)\.toBeTruthy\(\)/) triv_found = "expect(true).toBeTruthy()";
        else if (sline ~ /assert!\([[:space:]]*true[[:space:]]*\)/) triv_found = "assert!(true)";
        else if (sline ~ /assert_eq!\([[:space:]]*(1[[:space:]]*,[[:space:]]*1|true[[:space:]]*,[[:space:]]*true)[[:space:]]*\)/) triv_found = "assert_eq!(true, true)";
        else if (sline ~ /assertEquals\([[:space:]]*(1[[:space:]]*,[[:space:]]*1|true[[:space:]]*,[[:space:]]*true)[[:space:]]*\)/) triv_found = "assertEquals(true, true)";
        else if (sline ~ /expect\(.*\)\.toBeDefined\(\)/ && hunk_assert_rem ~ /toBe|toEqual|strictEqual/) triv_found = "expect().toBeDefined() replacing value comparison";
        
        if (triv_found != "") {
            print "WEAKENED:trivial_assertion: " triv_found " in " curr_file
        }
        
        if (line ~ /^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_/ || \
            line ~ /^[[:space:]]*func[[:space:]]+Test/ || \
            line ~ /^[[:space:]]*(it|test)[[:space:]]*\(/ || \
            line ~ /^[[:space:]]*(#\[test\]|fn[[:space:]]+test_)/ || \
            line ~ /^[[:space:]]*(@Test|public[[:space:]]+void[[:space:]]+test|void[[:space:]]+test)/ || \
            (curr_lang == "bash" && line ~ /^[[:space:]]*(function[[:space:]]+)?test_/)) {
            file_funcs_added++
        }
        
        is_assert = 0
        if (line ~ /^[[:space:]]*assert([[:space:]]|\()/) is_assert = 1;
        if (line ~ /^[[:space:]]*self\.assert/) is_assert = 1;
        if (line ~ /^[[:space:]]*with[[:space:]]+pytest\.raises/) is_assert = 1;
        if (line ~ /expect\(/ || line ~ /assert\(/ || line ~ /assert\./ || line ~ /\.should\./) is_assert = 1;
        if (line ~ /t\.(Error|Fatal|Fail)/ || line ~ /assert\./ || line ~ /require\./) is_assert = 1;
        if (line ~ /assert!/ || line ~ /assert_eq!/ || line ~ /assert_ne!/) is_assert = 1;
        if (line ~ /assertEquals\(/ || line ~ /assertTrue\(/ || line ~ /assertFalse\(/ || line ~ /assertThat\(/) is_assert = 1;
        if (curr_lang == "bash" && (line ~ /^[[:space:]]*(assert|check|ok|bad)[[:space:]]+/)) is_assert = 1;
        
        if (is_assert) {
            file_asserts_added++
            if (hunk_assert_rem != "" && hunk_assert_rem != line) {
                print "POTENTIAL_LITERAL_EDIT:" curr_file
            }
        }
    }
    next
}

END {
    finish_file()
    print "SOURCE_FILES_CHANGED:" source_files_changed
    print "TEST_FILES_CHANGED:" test_files_changed
}
' "$PATCH" 2>/dev/null)"

SOURCE_FILES_CHANGED="$(printf '%s\n' "$ANALYSIS" | grep '^SOURCE_FILES_CHANGED:' | sed 's/^SOURCE_FILES_CHANGED://')"
SOURCE_FILES_CHANGED="${SOURCE_FILES_CHANGED:-0}"

# Collect detected languages
RAW_LANGS="$(printf '%s\n' "$ANALYSIS" | grep '^LANG:' | sed 's/^LANG://' | sort -u)"
SUPPORTED_LANGS=""
UNSUPPORTED_LANGS=""
ALL_LANGS=""

while IFS= read -r L; do
  [ -n "$L" ] || continue
  case "$L" in
    python|javascript|typescript|go|rust|java|bash)
      if [ -z "$SUPPORTED_LANGS" ]; then
        SUPPORTED_LANGS="$L"
      else
        SUPPORTED_LANGS="$SUPPORTED_LANGS, $L"
      fi
      ;;
    doc_data)
      ;;
    *)
      if [ -z "$UNSUPPORTED_LANGS" ]; then
        UNSUPPORTED_LANGS="$L"
      else
        UNSUPPORTED_LANGS="$UNSUPPORTED_LANGS, $L"
      fi
      ;;
  esac
  if [ "$L" != "doc_data" ]; then
    if [ -z "$ALL_LANGS" ]; then
      ALL_LANGS="$L"
    else
      ALL_LANGS="$ALL_LANGS, $L"
    fi
  fi
done <<EOF
$RAW_LANGS
EOF

# Collect WEAKENED and SUSPICIOUS findings
WEAKENED_ITEMS="$(printf '%s\n' "$ANALYSIS" | grep '^WEAKENED:' | sed 's/^WEAKENED://')"
SUSPICIOUS_ITEMS="$(printf '%s\n' "$ANALYSIS" | grep '^SUSPICIOUS:' | sed 's/^SUSPICIOUS://')"

# If literal edited with no source change, add to suspicious
POTENTIAL_LITERALS="$(printf '%s\n' "$ANALYSIS" | grep '^POTENTIAL_LITERAL_EDIT:' | sed 's/^POTENTIAL_LITERAL_EDIT://' | sort -u)"
if [ "$SOURCE_FILES_CHANGED" -eq 0 ] && [ -n "$POTENTIAL_LITERALS" ]; then
  while IFS= read -r PL; do
    [ -n "$PL" ] || continue
    LIT_FINDING="expected_literal_edited: $PL"
    if [ -z "$SUSPICIOUS_ITEMS" ]; then
      SUSPICIOUS_ITEMS="$LIT_FINDING"
    else
      SUSPICIOUS_ITEMS="$SUSPICIOUS_ITEMS"$'\n'"$LIT_FINDING"
    fi
  done <<EOF
$POTENTIAL_LITERALS
EOF
fi

# If scope creep was detected, add to suspicious
if [ -n "$SCOPE_CREEP" ]; then
  SCOPE_FINDING="scope: $SCOPE_CREEP"
  if [ -z "$SUSPICIOUS_ITEMS" ]; then
    SUSPICIOUS_ITEMS="$SCOPE_FINDING"
  else
    SUSPICIOUS_ITEMS="$SUSPICIOUS_ITEMS"$'\n'"$SCOPE_FINDING"
  fi
fi

# --- Verdict generation ---------------------------------------------------

CHECKS_INFO="deleted_tests, skips, trivial_assertions, assertion_counts, literals"
if [ "$SCOPE_RAN" -eq 1 ]; then
  CHECKS_INFO="$CHECKS_INFO, scope"
elif [ -n "$BRIEF" ] && [ -f "$BRIEF" ] && [ -s "$BRIEF" ]; then
  CHECKS_INFO="$CHECKS_INFO (skipped scope: no paths in brief)"
else
  CHECKS_INFO="$CHECKS_INFO (skipped scope: no brief supplied)"
fi
[ -n "$UNSUPPORTED_LANGS" ] && CHECKS_INFO="$CHECKS_INFO (skipped $UNSUPPORTED_LANGS: no language rules)"

LANG_NOTE=""
[ -n "$ALL_LANGS" ] && LANG_NOTE=" | Lang: $ALL_LANGS"

# 1. Weakened tests -> exit 3 (highest precedence, overrides all other findings)
if [ -n "$WEAKENED_ITEMS" ]; then
  FIRST_WEAK="$(printf '%s\n' "$WEAKENED_ITEMS" | head -n 1)"
  SUSP_NOTE=""
  if [ -n "$SUSPICIOUS_ITEMS" ]; then
    SUSP_LIST="$(printf '%s\n' "$SUSPICIOUS_ITEMS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
    SUSP_NOTE=" | Suspicious: $SUSP_LIST"
  fi
  printf '%s\n' "STATUS: DIFF_TESTS_WEAKENED($FIRST_WEAK)$LANG_NOTE$SUSP_NOTE | Checks: $CHECKS_INFO | Scope: $SCOPE_STATUS | Files: $TOTAL_FILES ($DIFF_COUNTS) | Next: revert test skips or deletions, or re-brief implementation; tests must not be weakened | Patch: $PATCH"
  exit 3
fi

# 2. Suspicious -> exit 0
if [ -n "$SUSPICIOUS_ITEMS" ]; then
  FIRST_SUSP="$(printf '%s\n' "$SUSPICIOUS_ITEMS" | head -n 1)"
  printf '%s\n' "STATUS: DIFF_SUSPICIOUS($FIRST_SUSP)$LANG_NOTE | Checks: $CHECKS_INFO | Scope: $SCOPE_STATUS | Files: $TOTAL_FILES ($DIFF_COUNTS) | Patch: $PATCH"
  exit 0
fi

# 3. Unsupported language with no rules -> exit 0
if [ -z "$SUPPORTED_LANGS" ]; then
  FIRST_UNSUP="$(printf '%s\n' "$UNSUPPORTED_LANGS" | head -n 1)"
  FIRST_UNSUP="${FIRST_UNSUP:-${ALL_LANGS:-unknown}}"
  printf '%s\n' "STATUS: DIFF_UNCHECKED(lang=$FIRST_UNSUP)$LANG_NOTE | Note: no rules available for detected language(s) $FIRST_UNSUP — diff was not analysed | Files: $TOTAL_FILES ($DIFF_COUNTS) | Patch: $PATCH"
  exit 0
fi

# 4. Clean diff -> exit 0
printf '%s\n' "STATUS: DIFF_CLEAN$LANG_NOTE | Checks: $CHECKS_INFO | Scope: $SCOPE_STATUS | Files: $TOTAL_FILES ($DIFF_COUNTS) | Patch: $PATCH"
exit 0
