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
#     0  DIFF_SUSPICIOUS(...)     worth reading: prohibited files, scope creep, falling assertions
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
#     2. DIFF_SUSPICIOUS — no weakened tests, but touched prohibited files, scope
#        creep, a falling assertion count, an edited literal, or a suspected invented API.
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
# The scope check distinguishes permitted paths from prohibited paths in the brief.
# Paths in sentences that forbid (e.g. "Do not modify X") or under headings that
# forbid (e.g. "## Do not", "## Prohibitions") belong on a deny list.
# Touching a prohibited file is reported as DIFF_SUSPICIOUS(prohibited: ...).
# Touching an unmentioned file is reported as DIFF_SUSPICIOUS(scope: ...).
# When a path appears in both permitted and forbidden contexts, the deny reading
# is preferred.
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
# A deleted test file, an added test skip (@pytest.mark.skip, it.only, t.Skip), an
# assertion rewritten to a tautology (assert True), or an assertion whose comparison
# is weakened (exact equality becoming substring matching, wildcard matching, or
# mere existence/non-empty checking) is unequivocal evidence of a suite being dismantled.
# That is strong enough to override a phase verdict.
# Conversely, scope creep, touching prohibited files, or falling assertion counts
# may be legitimate refactors or benign additions; they warrant human attention
# (DIFF_SUSPICIOUS) but must not fail a build automatically.
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
# Scope check distinguishes permitted paths from prohibited paths in the brief.
# Paths in sentences that forbid (e.g. "Do not modify X") or under headings that
# forbid (e.g. "## Do not", "## Prohibitions") belong on a deny list.
# Touching a prohibited file is a distinct finding from ordinary scope creep.
# When a path appears in both permitted and forbidden contexts, deny is preferred.
# If zero paths are extracted, the check is reported as not run.
SCOPE_STATUS=""
SCOPE_CREEP=""
SCOPE_PROHIBITED=""
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

  BRIEF_PARSED="$(awk -v diff_dirs_str="$DIFF_DIRS" '
BEGIN {
    in_prohib_heading = 0
}

function clean_token(cand) {
    sub(/^['\''"`(\[<{\,\.\:\;\!\?\-]+/, "", cand)
    sub(/['\''"`\)\]\>}\,\.\:\;\!\?\-]+$/, "", cand)
    sub(/^\.\//, "", cand)
    sub(/^\//, "", cand)
    return cand
}

function is_valid_path(cand) {
    if (cand !~ /\//) return 0;
    if (cand ~ /\.(py|pyi|js|mjs|cjs|jsx|ts|mts|cts|tsx|go|rs|java|kt|kts|scala|groovy|sh|bash|zsh|c|h|cpp|hpp|cc|cxx|hh|hxx|cs|fs|rb|rake|php|swift|lua|html|htm|css|scss|sass|less|vue|svelte|md|markdown|txt|json|ya?ml|toml|ini|cfg|conf|csv|tsv|xml|sql|graphql|proto|patch|diff)$/) {
        return 1;
    }
    n = split(diff_dirs_str, darr, " ")
    for (i = 1; i <= n; i++) {
        d = darr[i]
        d_no_slash = d
        sub(/\/$/, "", d_no_slash)
        if (substr(cand, 1, length(d)) == d || cand == d_no_slash) {
            return 1;
        }
    }
    return 0;
}

function extract_paths_from_text(txt, polarity) {
    txt_clean = txt
    gsub(/[`"'\''\(\)\[\]<>{}\*]/, " ", txt_clean)
    num_toks = split(txt_clean, toks, /[[:space:]]+/)
    for (t = 1; t <= num_toks; t++) {
        cand = clean_token(toks[t])
        if (cand != "" && is_valid_path(cand)) {
            print polarity ":" cand
        }
    }
}

function is_prohibition_text(txt) {
    ltxt = tolower(txt)
    if (ltxt ~ /(^|[^a-z0-9_])(do[[:space:]]+not|never|no|must[[:space:]]+not|cannot|can[[:space:]]*not|should[[:space:]]+not|forbidden|prohibit|prohibited|prohibitions|prohibiting|deny|denied|denies|disallow|disallowed|not[[:space:]]+permitted|not[[:space:]]+allowed|not[[:space:]]+to[[:space:]]+touch|not[[:space:]]+to[[:space:]]+modify|not[[:space:]]+to[[:space:]]+change|not[[:space:]]+to[[:space:]]+edit|files?[[:space:]]+not[[:space:]]+to[[:space:]]+touch|files?[[:space:]]+to[[:space:]]+avoid|untouched|out[[:space:]]+of[[:space:]]+scope|off[[:space:]]+limits|avoid([[:space:]]+(modifying|touching|changing|editing))?|exclude[ds]?|excluding)($|[^a-z0-9_])/) {
        return 1
    }
    return 0
}

# Heading check
/^[[:space:]]*#/ {
    htext = $0
    sub(/^[[:space:]]*#+[[:space:]]*/, "", htext)
    sub(/[[:space:]]*#+[[:space:]]*$/, "", htext)
    if (is_prohibition_text(htext)) {
        in_prohib_heading = 1
    } else {
        in_prohib_heading = 0
    }
}

{
    line = $0
    if (in_prohib_heading) {
        extract_paths_from_text(line, "DENY")
        next
    }

    sline = line
    # If the line starts with a list item header like "Files not to touch:", treat rest of line as prohibition
    if (sline ~ /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+.*\:/) {
        prefix = sline
        sub(/\:.*$/, "", prefix)
        rest = sline
        sub(/^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+[^:]*\:[[:space:]]*/, "", rest)
        if (is_prohibition_text(prefix)) {
            extract_paths_from_text(rest, "DENY")
            next
        }
    }

    # Split into clauses by . (followed by space), ;, !, ?, or , but / , except
    gsub(/\.([[:space:]]+|$)/, "\n", sline)
    gsub(/;[[:space:]]*/, "\n", sline)
    gsub(/[!?]([[:space:]]+|$)/, "\n", sline)
    gsub(/,[[:space:]]+(but|except)[[:space:]]+/, "\n\\1 ", sline)

    num_segs = split(sline, segs, "\n")
    for (s = 1; s <= num_segs; s++) {
        seg = segs[s]
        if (seg ~ /^[[:space:]]*$/) continue
        if (is_prohibition_text(seg)) {
            extract_paths_from_text(seg, "DENY")
        } else {
            extract_paths_from_text(seg, "ALLOW")
        }
    }
}
' "$BRIEF" 2>/dev/null)"

  ALLOW_TOKENS="$(printf '%s\n' "$BRIEF_PARSED" | grep '^ALLOW:' | sed 's/^ALLOW://' | sort -u)"
  DENY_TOKENS="$(printf '%s\n' "$BRIEF_PARSED" | grep '^DENY:' | sed 's/^DENY://' | sort -u)"

  if [ -n "$ALLOW_TOKENS" ] || [ -n "$DENY_TOKENS" ]; then
    SCOPE_RAN=1
    while IFS= read -r F; do
      [ -n "$F" ] || continue
      BASE_F="$(basename "$F")"

      # Check if F matches DENY_TOKENS
      IS_DENIED=0
      if [ -n "$DENY_TOKENS" ]; then
        # 1. Exact match
        if printf '%s\n' "$DENY_TOKENS" | grep -F -x -q -- "$F" 2>/dev/null; then
          IS_DENIED=1
        # 2. Basename match
        elif printf '%s\n' "$DENY_TOKENS" | grep -F -x -q -- "$BASE_F" 2>/dev/null; then
          IS_DENIED=1
        else
          # 3. Directory prefix match
          while IFS= read -r DT; do
            [ -n "$DT" ] || continue
            CLEAN_DT="${DT%/}"
            case "$F" in
              "$CLEAN_DT"/*) IS_DENIED=1; break ;;
            esac
          done <<EOF
$DENY_TOKENS
EOF
        fi
      fi

      if [ "$IS_DENIED" -eq 1 ]; then
        if [ -z "$SCOPE_PROHIBITED" ]; then
          SCOPE_PROHIBITED="$F"
        else
          SCOPE_PROHIBITED="$SCOPE_PROHIBITED, $F"
        fi
        continue
      fi

      # Check if F matches ALLOW_TOKENS
      IS_ALLOWED=0
      if [ -n "$ALLOW_TOKENS" ]; then
        # 1. Exact match
        if printf '%s\n' "$ALLOW_TOKENS" | grep -F -x -q -- "$F" 2>/dev/null; then
          IS_ALLOWED=1
        # 2. Basename match
        elif printf '%s\n' "$ALLOW_TOKENS" | grep -F -x -q -- "$BASE_F" 2>/dev/null; then
          IS_ALLOWED=1
        else
          # 3. Directory prefix match
          while IFS= read -r AT; do
            [ -n "$AT" ] || continue
            CLEAN_AT="${AT%/}"
            case "$F" in
              "$CLEAN_AT"/*) IS_ALLOWED=1; break ;;
            esac
          done <<EOF
$ALLOW_TOKENS
EOF
          if [ "$IS_ALLOWED" -eq 0 ]; then
            # 4. Test file for named source file
            STEM="$(basename "$F" | sed -e 's/\.[^.]*$//' -e 's/^test_//' -e 's/_test$//' -e 's/\.test$//' -e 's/\.spec$//' -e 's/Test$//' -e 's/^Test//')"
            if [ -n "$STEM" ]; then
              while IFS= read -r AT; do
                [ -n "$AT" ] || continue
                AT_BASE="$(basename "$AT" | sed -e 's/\.[^.]*$//')"
                if [ "$AT_BASE" = "$STEM" ]; then
                  IS_ALLOWED=1
                  break
                fi
              done <<EOF
$ALLOW_TOKENS
EOF
            fi
          fi
        fi
      fi

      if [ "$IS_ALLOWED" -eq 0 ]; then
        if [ -z "$SCOPE_CREEP" ]; then
          SCOPE_CREEP="$F"
        else
          SCOPE_CREEP="$SCOPE_CREEP, $F"
        fi
      fi
    done <<EOF
$PATHS
EOF

    if [ -n "$SCOPE_PROHIBITED" ] && [ -n "$SCOPE_CREEP" ]; then
      SCOPE_STATUS="prohibited ($SCOPE_PROHIBITED), creep ($SCOPE_CREEP)"
    elif [ -n "$SCOPE_PROHIBITED" ]; then
      SCOPE_STATUS="prohibited ($SCOPE_PROHIBITED)"
    elif [ -n "$SCOPE_CREEP" ]; then
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
    hunk_exact_assert = 0
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

function is_exact_assert(line, lang) {
    if (line ~ /^[[:space:]]*assert[[:space:]]+.+==/) return 1;
    if (line ~ /^[[:space:]]*assert\(.+==.+\)/) return 1;
    if (line ~ /^[[:space:]]*self\.assert(Equal|Equals|StrictEqual)\(/) return 1;
    if (line ~ /expect\(.+\)\.(toBe|toEqual|toStrictEqual)\(/) return 1;
    if (line ~ /assert\.(strictEqual|equal|deepEqual|deepStrictEqual)\(/) return 1;
    if (line ~ /assert\.(Equal|DeepEqual)\(/ || line ~ /require\.(Equal|DeepEqual)\(/) return 1;
    if (line ~ /assert_eq!\(/) return 1;
    if (line ~ /assertEquals\(/ || line ~ /assertSame\(/) return 1;
    if (lang == "bash") {
        if (line ~ /^[[:space:]]*check[[:space:]]+/) return 1;
        if (line ~ /^[[:space:]]*assert(_eq|_equal)[[:space:]]+/) return 1;
        if (line ~ /\[\[?[[:space:]]+.*[!=]==?[[:space:]]+.*\]\]?/) return 1;
    }
    return 0;
}

function check_weakened_comparison(sline, lang, rem_line) {
    # 1. Substring matching / containment replacing exact equality
    if (sline ~ /^[[:space:]]*assert[[:space:]]+.+[[:space:]]in[[:space:]]+/ && rem_line ~ /==|assert(Equal|Equals)/) {
        return "substring match replacing exact equality";
    }
    if (sline ~ /^[[:space:]]*self\.assertIn\(/ && rem_line ~ /==|assert(Equal|Equals)/) {
        return "self.assertIn() replacing exact equality";
    }
    if (sline ~ /^[[:space:]]*assert[[:space:]]+.+\.(startswith|endswith)\(/ && rem_line ~ /==|assert(Equal|Equals)/) {
        return "prefix/suffix match replacing exact equality";
    }
    if (sline ~ /^[[:space:]]*assert[[:space:]]+re\.(search|match|findall)\(/ && rem_line ~ /==|assert(Equal|Equals)/) {
        return "regex pattern replacing exact equality";
    }
    if (sline ~ /expect\(.+\)\.(toContain|toMatch|stringContaining|stringMatching)\(/ && rem_line ~ /toBe|toEqual|toStrictEqual|assert(Equal|Equals)/) {
        return "expect().toContain()/toMatch() replacing exact equality";
    }
    if (sline ~ /expect\(.+\)\.(objectContaining|arrayContaining|anything|any)\(/ && rem_line ~ /toBe|toEqual|toStrictEqual/) {
        return "pattern/wildcard matching replacing exact equality";
    }
    if (sline ~ /assert\.(match|includes)\(/ && rem_line ~ /strictEqual|equal|deepEqual/) {
        return "assert.match() replacing exact equality";
    }
    if ((sline ~ /assert\.(Contains|Subset)\(/ || sline ~ /require\.(Contains|Subset)\(/) && rem_line ~ /assert\.(Equal|DeepEqual)|require\.(Equal|DeepEqual)/) {
        return "assert.Contains() replacing exact equality";
    }
    if (sline ~ /assert!\(.+\.contains\(/ && rem_line ~ /assert_eq!/) {
        return "assert!(contains) replacing assert_eq!";
    }
    if (sline ~ /assertTrue\(.+\.contains\(/ && rem_line ~ /assertEquals|assertSame/) {
        return "assertTrue(contains) replacing assertEquals";
    }
    if (sline ~ /assertThat\(.+,[[:space:]]*containsString\(/ && rem_line ~ /assertEquals|assertSame/) {
        return "containsString replacing assertEquals";
    }
    if (lang == "bash") {
        if (sline ~ /^[[:space:]]*case[[:space:]]+.+[[:space:]]+in[[:space:]]+\*.*\*\)/ && rem_line ~ /check[[:space:]]+|assert(_eq|_equal)|==/) {
            return "substring glob match replacing exact check";
        }
        if (sline ~ /^[[:space:]]*assert_contains[[:space:]]+/ && rem_line ~ /check[[:space:]]+|assert(_eq|_equal)|==/) {
            return "assert_contains replacing exact equality";
        }
        if (sline ~ /\[\[[[:space:]]+.+[[:space:]]*=~[[:space:]]*.+\]\]/ && rem_line ~ /check[[:space:]]+|assert(_eq|_equal)|==/) {
            return "regex match =~ replacing exact check";
        }
        if (sline ~ /\[\[[[:space:]]+.+[[:space:]]*==[[:space:]]*\*.*\*[[:space:]]*\]\]/ && rem_line ~ /check[[:space:]]+|assert(_eq|_equal)|==/) {
            return "wildcard match replacing exact check";
        }
    }

    # 2. Value comparison becoming mere existence / non-empty / non-null check
    if (sline ~ /expect\(.*\)\.toBeDefined\(\)/ && rem_line ~ /toBe|toEqual|toStrictEqual/) {
        return "expect().toBeDefined() replacing value comparison";
    }
    if (sline ~ /expect\(.*\)\.(toBeTruthy|toBeFalsy|not\.toBeNull|toBeInstanceOf|toHaveLength|not\.toBeEmpty)\(\)/ && rem_line ~ /toBe\(|toEqual\(/) {
        return "expect() presence/truthiness check replacing value comparison";
    }
    if (sline ~ /^[[:space:]]*assert[[:space:]]+.+[[:space:]]+is[[:space:]]+not[[:space:]]+None/ && rem_line ~ /==|assertEqual/) {
        return "assert is not None replacing exact equality";
    }
    if (sline ~ /^[[:space:]]*assert[[:space:]]+len\(.+\)[[:space:]]*>[[:space:]]*0/ && rem_line ~ /==|assertEqual/) {
        return "assert len > 0 replacing exact equality";
    }
    if (sline ~ /^[[:space:]]*self\.assert(IsNotNone|True)\(/ && rem_line ~ /assertEqual/) {
        return "self.assertIsNotNone()/assertTrue() replacing assertEqual";
    }
    if ((sline ~ /assert\.(NotEmpty|NotNil|True)\(/ || sline ~ /require\.(NotEmpty|NotNil|True)\(/) && rem_line ~ /assert\.(Equal|DeepEqual)|require\.(Equal|DeepEqual)/) {
        return "assert.NotEmpty()/NotNil() replacing Equal";
    }
    if (sline ~ /assert!\(.+\.is_some\(\)\)/ && rem_line ~ /assert_eq!/) {
        return "assert!(is_some) replacing assert_eq!";
    }
    if (sline ~ /assert!\(!.+\.is_empty\(\)\)/ && rem_line ~ /assert_eq!/) {
        return "assert!(!is_empty) replacing assert_eq!";
    }
    if (sline ~ /assertNotNull\(/ && rem_line ~ /assertEquals|assertSame/) {
        return "assertNotNull replacing assertEquals";
    }

    return "";
}

/^@@ / {
    hunk_assert_rem = ""
    hunk_exact_assert = 0
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
    hunk_exact_assert = 0
    
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
        if (curr_lang == "bash" && (line ~ /^[[:space:]]*(assert|check|ok|bad)[[:space:]]+/ || line ~ /\[\[?.*\]\]?/ || line ~ /^[[:space:]]*case[[:space:]]+/)) is_assert = 1;
        
        if (is_assert) {
            file_asserts_removed++
            hunk_assert_rem = line
            if (is_exact_assert(line, curr_lang)) {
                hunk_exact_assert = 1
            }
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
        weak_comp = ""
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
        
        if (triv_found != "") {
            print "WEAKENED:trivial_assertion: " triv_found " in " curr_file
        } else if (hunk_exact_assert && hunk_assert_rem != "") {
            weak_comp = check_weakened_comparison(sline, curr_lang, hunk_assert_rem)
            if (weak_comp != "") {
                print "WEAKENED:comparison_weakened: " weak_comp " in " curr_file
            }
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
        if (curr_lang == "bash" && (line ~ /^[[:space:]]*(assert|check|ok|bad)[[:space:]]+/ || line ~ /\[\[?.*\]\]?/ || line ~ /^[[:space:]]*case[[:space:]]+/)) is_assert = 1;
        
        if (is_assert) {
            file_asserts_added++
            if (hunk_assert_rem != "" && hunk_assert_rem != line && triv_found == "" && weak_comp == "") {
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

# If prohibited files were touched, add to suspicious (prioritized before creep)
if [ -n "$SCOPE_PROHIBITED" ]; then
  PROHIB_FINDING="prohibited: $SCOPE_PROHIBITED"
  if [ -z "$SUSPICIOUS_ITEMS" ]; then
    SUSPICIOUS_ITEMS="$PROHIB_FINDING"
  else
    SUSPICIOUS_ITEMS="$PROHIB_FINDING"$'\n'"$SUSPICIOUS_ITEMS"
  fi
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

CHECKS_INFO="deleted_tests, skips, trivial_assertions, weakened_comparisons, assertion_counts, literals"
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
