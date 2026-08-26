#!/usr/bin/env bash
# Exercise check-review.sh: that a review which shows its work passes, that the
# empty-but-correctly-shaped artifact from the #1 run does not, and that neither
# outcome touches the phase's verdict.
#
#   tests/check-review.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-review.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
[ -f "$CHECK" ] || { echo "check-review-test: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "check-review-test: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-review.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-32s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-32s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# A repo with a run directory. <n> is how many changed lines to fake in the
# patch, which is what the --trivial threshold scales against.
new_case() {
  R="$ROOT/cases/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q . )
  RUN_ID="$(run_dir_new --dir "$R" --task "review test $1")"
  RUN_DIR="$R/.agy/runs/$RUN_ID"
  {
    printf '# REVIEW_DIFF.patch — the change under review\n#\n# base: HEAD\n#\n'
    printf 'diff --git a/wordstat/cli.py b/wordstat/cli.py\n'
    printf 'index 1111111..2222222 100644\n--- a/wordstat/cli.py\n+++ b/wordstat/cli.py\n'
    printf '@@ -1,1 +1,%s @@\n' "$2"
    awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "+    line " i }'
  } > "$RUN_DIR/REVIEW_DIFF.patch"
  printf '%s' "$R"
}

# feedback <repo> — write REVIEW_FEEDBACK.md in current run directory from stdin.
feedback() {
  local r="$1"
  local id
  id="$(cat "$r/.agy/current" 2>/dev/null)"
  cat > "$r/.agy/runs/$id/REVIEW_FEEDBACK.md"
}

# run <repo> <args...> — STATUS line into $OUT, exit code into $CODE.
run() { R="$1"; shift; OUT="$(/bin/bash "$CHECK" --dir "$R" "$@" 2>/dev/null)"; CODE=$?; }
word_of() { printf '%s' "$1" | sed -n '1p' | awk '{print $2}'; }

# --- the artifact this script exists for ---------------------------------

# 1. The #1 run's review, verbatim. Correctly shaped, four zero counts, and not
#    one file, line or snippet anywhere in it. Every other gate passed it.
R="$(new_case empty-shape 40)"
feedback "$R" <<'EOF'
PASSED

- Critical: 0
- Major: 0
- Minor: 0
- Nit: 0

## Standards
No violations found.

## Spec
No violations found. Implementation matches all requirements from task description.
EOF
run "$R"
check empty-rc "$CODE" 3 "exit 3 on the empty-shape review"
case "$(word_of "$OUT")" in REVIEW_THIN*) ok empty-status "reported REVIEW_THIN" ;;
  *) bad empty-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"not a failed one"*) ok empty-advisory "the note says thin is not failed" ;;
  *) bad empty-advisory "the note reads as a failure: $OUT" ;; esac
case "$OUT" in *"Verdict: PASSED"*) ok empty-verdict "the worker's own verdict is carried through untouched" ;;
  *) bad empty-verdict "the verdict is not reported: $OUT" ;; esac

# 2. The same emptiness with the Examined list the criteria now demands. This is
#    the escape route a genuinely clean review takes, and it must work — a check
#    that made a clean review impossible to report would be worse than no check.
R="$(new_case clean-with-examined 40)"
feedback "$R" <<'EOF'
PASSED

- Critical: 0
- Major: 0

## Examined
- `wordstat/cli.py` (+10 / -1) — the new flag and the branch in `main()`.
  Checked: default value, output shape, the existing text path unchanged.

## Standards
No violations found.

## Spec
No violations found.
EOF
run "$R"
check clean-rc "$CODE" 0 "exit 0 for zero findings with a filled-in Examined list"
case "$(word_of "$OUT")" in REVIEW_EVIDENCED) ok clean-status "reported REVIEW_EVIDENCED" ;;
  *) bad clean-status "unexpected status: $OUT" ;; esac
case "$OUT" in *"Examined: listed"*) ok clean-examined "the Examined section is recognised" ;;
  *) bad clean-examined "the Examined section went unnoticed: $OUT" ;; esac

# 3. An Examined heading with nothing under it is not a list.
R="$(new_case examined-empty 40)"
feedback "$R" <<'EOF'
PASSED

## Examined

## Standards
No violations found.
EOF
run "$R"
check examined-empty-rc "$CODE" 3 "an empty Examined section does not clear the check"
case "$OUT" in *"Examined: none"*) ok examined-empty-report "and it is reported as absent" ;;
  *) bad examined-empty-report "an empty section counted as listed: $OUT" ;; esac

# 3b. The shape a real agy worker produced against these criteria: a title line,
#     then the verdict under its own heading. Reading line 1 as the verdict
#     prints the title back, which is how this was caught.
R="$(new_case titled 40)"
feedback "$R" <<'EOF'
# Review Feedback

## Verdict
PASSED

## Examined
- `wordstat/cli.py` (+9 / -1) — the new flag and the branch in `main()`.

## Standards
*(No findings)*
EOF
run "$R"
check titled-rc "$CODE" 0 "a titled report still clears the check"
case "$OUT" in *"Verdict: PASSED"*) ok titled-verdict "the verdict is read from under its heading, not from the title" ;;
  *) bad titled-verdict "the title was read as the verdict: $OUT" ;; esac

# --- what counts as an anchor --------------------------------------------

# 4. A file:line reference in a finding.
R="$(new_case fileline 40)"
feedback "$R" <<'EOF'
FAILED

- Minor: 1

## Standards
- **Minor** — `src/other.py:24`

  ```
  +    render = render_json if args.json else render_text
  ```

  The branch has no test that runs the entry point.
EOF
run "$R"
check fileline-rc "$CODE" 0 "a file:line anchor clears the check"
case "$OUT" in *"file:line 1"*) ok fileline-count "the file:line anchor is counted" ;;
  *) bad fileline-count "file:line not counted: $OUT" ;; esac
case "$OUT" in *"Verdict: FAILED"*) ok fileline-verdict "a FAILED review is checked the same way" ;;
  *) bad fileline-verdict "the verdict is wrong: $OUT" ;; esac

# 5. A path the diff actually touched, cited by basename — how a reviewer that
#    read the stat usually writes it.
R="$(new_case basename 40)"
feedback "$R" <<'EOF'
PASSED
No violations found in cli.py.
EOF
run "$R"
check basename-rc "$CODE" 0 "a changed file cited by basename counts"

# 6. A path the diff did *not* touch is not evidence of having read the diff.
R="$(new_case wrong-path 40)"
feedback "$R" <<'EOF'
PASSED
Nothing wrong in README or the build config.
EOF
run "$R"
check wrong-path-rc "$CODE" 3 "citing a file outside the diff does not count"

# 7. --min-anchors moves the bar.
R="$(new_case min-anchors 40)"
feedback "$R" <<'EOF'
PASSED
Looked at `wordstat/cli.py`.
EOF
run "$R"
check min-default "$CODE" 0 "one anchor clears the default bar"
run "$R" --min-anchors 3
check min-raised "$CODE" 3 "--min-anchors 3 wants more than one"

# --- the trivial-diff escape hatch ---------------------------------------

# 8. On a handful of changed lines, a review with nothing to point at is a
#    reasonable outcome and must not be flagged.
R="$(new_case trivial 4)"
feedback "$R" <<'EOF'
PASSED

- Critical: 0

## Standards
No violations found.
EOF
run "$R"
check trivial-rc "$CODE" 0 "a tiny diff excuses an unanchored review"
case "$OUT" in *"--trivial"*) ok trivial-why "and the status says that is why" ;;
  *) bad trivial-why "no reason given for the pass: $OUT" ;; esac

# 9. The threshold is where it says it is.
run "$R" --trivial 2
check trivial-lowered "$CODE" 3 "--trivial 2 puts a 4-line diff back above the bar"

# --- no artifact ---------------------------------------------------------

# 10. A phase that claimed PASSED and wrote nothing. Louder than thin: there is
#     no review at all, so there is nothing to read and decide about.
R="$(new_case absent 40)"
run "$R"
check absent-rc "$CODE" 4 "exit 4 when the artifact is missing"
case "$(word_of "$OUT")" in REVIEW_ABSENT) ok absent-status "reported REVIEW_ABSENT" ;;
  *) bad absent-status "unexpected status: $OUT" ;; esac

# 11. A file of blank lines is the same thing as no file.
R="$(new_case blank 40)"
RUN_ID_BLANK="$(cat "$R/.agy/current")"
printf '\n\n   \n' > "$R/.agy/runs/$RUN_ID_BLANK/REVIEW_FEEDBACK.md"
run "$R"
check blank-rc "$CODE" 4 "whitespace-only counts as absent"

# --- no diff -------------------------------------------------------------

# 12. If capture-diff.sh was never run, say so rather than silently excusing the
#     review: an unmeasurable diff is not a trivial one.
R="$ROOT/cases/no-diff"; mkdir -p "$R"
( cd "$R" && git init -q . )
run_dir_new --dir "$R" --task "no diff" >/dev/null
feedback "$R" <<'EOF'
PASSED
No violations found.
EOF
run "$R"
check nodiff-rc "$CODE" 3 "a missing patch does not excuse an unanchored review"
case "$OUT" in *"not found"*) ok nodiff-note "and the status says the diff was not found" ;;
  *) bad nodiff-note "the missing diff went unmentioned: $OUT" ;; esac

# --- output contract -----------------------------------------------------

# 13. One STATUS line on stdout, like every other script here, and nothing
#     written anywhere — this script only reads.
R="$(new_case stdout 40)"
feedback "$R" <<'EOF'
PASSED
`wordstat/cli.py` is fine.
EOF
RUN_ID_STDOUT="$(cat "$R/.agy/current")"
RUN_DIR_STDOUT="$R/.agy/runs/$RUN_ID_STDOUT"
BEFORE="$(ls "$RUN_DIR_STDOUT" | sort)"
run "$R"
check stdout-lines "$(printf '%s\n' "$OUT" | grep -c .)" 1 "stdout is one line"
case "$OUT" in STATUS:*) ok stdout-shape "and it starts with STATUS:" ;;
  *) bad stdout-shape "stdout is not a STATUS line: $OUT" ;; esac
check no-writes "$(ls "$RUN_DIR_STDOUT" | sort)" "$BEFORE" "the check writes nothing"

# 14. --file and --diff point elsewhere.
R="$(new_case explicit-paths 40)"
mkdir -p "$R/other"
feedback "$R" <<'EOF'
PASSED
nothing anchored here
EOF
printf 'PASSED\n`wordstat/cli.py` was examined.\n' > "$R/other/report.md"
run "$R" --file "$R/other/report.md"
check explicit-file "$CODE" 0 "--file reads the report it is given"

# --- argument handling ---------------------------------------------------

run "$R" --min-anchors nope
check bad-min "$CODE" 2 "exit 2 on a non-numeric --min-anchors"
run "$R" --bogus
check bad-arg "$CODE" 2 "exit 2 on an unknown flag"
OUT="$(/bin/bash "$CHECK" --dir "$ROOT/nope" 2>/dev/null)"; CODE=$?
check bad-dir "$CODE" 2 "exit 2 on a missing --dir"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
