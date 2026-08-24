#!/usr/bin/env bash
# Exercise check-phase-range.sh: the refusal that stops a partial pipeline run
# from dispatching a worker onto artifacts no phase in the range produces.
#
#   tests/check-phase-range.sh
#
# Throwaway repos under ${TMPDIR:-/tmp}; nothing is written inside this repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-phase-range.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"
[ -f "$CHECK" ] || { echo "check-phase-range: script not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "check-phase-range: run-dir.sh not found next door" >&2; exit 2; }

. "$RUN_DIR_SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-range.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-30s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-30s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# new_repo <name> [artifact...] — a repo whose run directory holds exactly the named
# artifacts (each non-empty) with passing phase records in run.json.
new_repo() {
  local name="$1"; shift
  local r="$ROOT/$name"
  mkdir -p "$r"
  ( cd "$r" && git init -q . )
  local run_id="$(run_dir_new --dir "$r" --task "range test $name")"
  local run_dir="$r/.agy/runs/$run_id"
  for a in "$@"; do
    printf 'content\n' > "$run_dir/$a"
    case "$a" in
      DISCOVERY.md|TEST_COMMAND)
        run_dir_record_phase "$run_dir" DISCOVERY status=DONE verdict=DONE attempts=1
        ;;
      CHANGES.md)
        run_dir_record_phase "$run_dir" IMPLEMENT status=DONE verdict=DONE attempts=1
        ;;
      QA_REPORT.md)
        run_dir_record_phase "$run_dir" QA status=DONE verdict=DONE attempts=1
        ;;
    esac
  done
  printf '%s\n' "$r"
}

run() { "$CHECK" --dir "$1" "${@:2}" 2>&1; }
rc()  { "$CHECK" --dir "$1" "${@:2}" >/dev/null 2>&1; printf '%s' "$?"; }

# a. --from 0 is the whole pipeline and needs nothing on disk.
REPO="$(new_repo a-full)"
check a-full-rc "$(rc "$REPO" --from 0)" "0" "a full run is never refused"
case "$(run "$REPO" --from 0)" in "STATUS: RANGE_OK(from=0, to=4)"*)
    ok a-full-line "prints RANGE_OK" ;;
  *) bad a-full-line "unexpected: $(run "$REPO" --from 0)" ;; esac

# b. an empty run directory refuses anything past 0, and names every file it wants.
REPO="$(new_repo b-empty)"
check b-empty-rc "$(rc "$REPO" --from 3)" "1" "--from 3 on an empty run is refused"
OUT="$(run "$REPO" --from 3)"
for WANT in DISCOVERY.md TEST_COMMAND CHANGES.md; do
  case "$OUT" in *"missing: $WANT"*) ok "b-empty-$WANT" "named as missing" ;;
    *) bad "b-empty-$WANT" "not named: $OUT" ;; esac
done
case "$OUT" in *"written by Phase 1 (Implementation)"*)
    ok b-empty-producer "says which phase writes CHANGES.md" ;;
  *) bad b-empty-producer "no producer named: $OUT" ;; esac
case "$OUT" in "STATUS: RANGE_REFUSED(from=3)"*)
    ok b-empty-head "the first line is a STATUS the orchestrator can read" ;;
  *) bad b-empty-head "unexpected head: $OUT" ;; esac

# c. a repo with everything an implementation-onward run needs passes.
REPO="$(new_repo c-ready DISCOVERY.md TEST_COMMAND CHANGES.md)"
check c-ready-2 "$(rc "$REPO" --from 2)" "0" "--from 2 passes with discovery and changes"
check c-ready-3 "$(rc "$REPO" --from 3)" "0" "--from 3 passes too"
check c-ready-4 "$(rc "$REPO" --from 4)" "1" "--from 4 still wants the QA report"
case "$(run "$REPO" --from 4)" in *"missing: QA_REPORT.md — written by Phase 3 (QA)"*)
    ok c-ready-4-named "the QA report is the only thing named" ;;
  *) bad c-ready-4-named "unexpected: $(run "$REPO" --from 4)" ;; esac

# d. Phase 1 needs discovery, and nothing more.
REPO="$(new_repo d-discovered DISCOVERY.md TEST_COMMAND)"
check d-discovered "$(rc "$REPO" --from 1)" "0" "--from 1 passes on discovery alone"
check d-discovered-2 "$(rc "$REPO" --from 2)" "1" "--from 2 still wants the change"

# e. an empty file is missing. A zero-byte TEST_COMMAND is what a Phase 0 that
# gave up leaves behind, and it briefs a worker no better than an absent one.
REPO="$(new_repo e-empty-file DISCOVERY.md)"
RUN_ID_E="$(cat "$REPO/.agy/current")"
: > "$REPO/.agy/runs/$RUN_ID_E/TEST_COMMAND"
check e-empty-file "$(rc "$REPO" --from 1)" "1" "a zero-byte artifact counts as missing"

# f. argument validation, so a typo is a refusal and not a silent full run.
REPO="$(new_repo f-args)"
check f-out-of-range "$(rc "$REPO" --from 5)" "2" "a phase outside 0-4 exits 2"
check f-backwards    "$(rc "$REPO" --from 3 --to 1)" "2" "--from after --to exits 2"
check f-missing-from "$("$CHECK" --dir "$REPO" >/dev/null 2>&1; printf '%s' "$?")" "2" \
  "--from is required"
check f-unknown-arg  "$(rc "$REPO" --from 0 --sideways)" "2" "an unknown flag exits 2"
check f-bad-dir      "$("$CHECK" --from 0 --dir "$ROOT/nope" >/dev/null 2>&1; printf '%s' "$?")" "2" \
  "a missing --dir exits 2"

# g. provenance test: artifact files exist on disk, but run.json records no earlier phases -> refused!
REPO_PROV="$ROOT/g-provenance"
mkdir -p "$REPO_PROV"
( cd "$REPO_PROV" && git init -q . )
RUN_ID_PROV="$(run_dir_new --dir "$REPO_PROV" --task "provenance test")"
RUN_DIR_PROV="$REPO_PROV/.agy/runs/$RUN_ID_PROV"
printf 'discovery\n' > "$RUN_DIR_PROV/DISCOVERY.md"
printf 'npm test\n' > "$RUN_DIR_PROV/TEST_COMMAND"
printf 'changes\n' > "$RUN_DIR_PROV/CHANGES.md"
# run.json has no phase records
check g-provenance-refused "$(rc "$REPO_PROV" --from 3)" "1" "--from 3 refuses when files exist but run.json has no phase records"
OUT_PROV="$(run "$REPO_PROV" --from 3)"
case "$OUT_PROV" in *"missing: CHANGES.md"*)
    ok g-provenance-named "names CHANGES.md as missing despite file being on disk" ;;
  *) bad g-provenance-named "did not name CHANGES.md: $OUT_PROV" ;;
esac

# h. empty task: --from 0 is accepted, --from 2 is refused with note
REPO_EMPTY_TASK="$ROOT/h-empty-task"
mkdir -p "$REPO_EMPTY_TASK"
( cd "$REPO_EMPTY_TASK" && git init -q . )
RUN_ID_ET="$(run_dir_new --dir "$REPO_EMPTY_TASK" --task "")"
RUN_DIR_ET="$REPO_EMPTY_TASK/.agy/runs/$RUN_ID_ET"
printf 'discovery\n' > "$RUN_DIR_ET/DISCOVERY.md"
printf 'npm test\n' > "$RUN_DIR_ET/TEST_COMMAND"
printf 'changes\n' > "$RUN_DIR_ET/CHANGES.md"
run_dir_record_phase "$RUN_DIR_ET" DISCOVERY status=DONE verdict=DONE attempts=1
run_dir_record_phase "$RUN_DIR_ET" IMPLEMENT status=DONE verdict=DONE attempts=1

check h-empty-task-from-0 "$(rc "$REPO_EMPTY_TASK" --from 0)" "0" "--from 0 on run with empty task is accepted"
check h-empty-task-from-2-rc "$(rc "$REPO_EMPTY_TASK" --from 2)" "1" "--from 2 on run with empty task is refused"
OUT_ET="$(run "$REPO_EMPTY_TASK" --from 2)"
case "$OUT_ET" in "STATUS: RANGE_REFUSED(from=2) | Note: run has no recorded task"*)
    ok h-empty-task-from-2-note "refusal note matches for empty task on --from 2" ;;
  *) bad h-empty-task-from-2-note "unexpected output: $OUT_ET" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
