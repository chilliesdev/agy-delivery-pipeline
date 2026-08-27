#!/usr/bin/env bash
# Exercise fleet.sh: the registry, the cross-repository roll-up, and the limits
# it is careful to state rather than paper over.
#
#   tests/fleet.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo, and the registry is redirected through $AGY_FLEET so a real one is
# never touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
FLEET_SH="$ROOT_REPO/scripts/fleet.sh"
LEDGER_SH="$ROOT_REPO/scripts/ledger.sh"

[ -f "$FLEET_SH" ] || { echo "fleet-test: fleet.sh not found next door" >&2; exit 2; }
[ -f "$LEDGER_SH" ] || { echo "fleet-test: ledger.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/ledger.sh
. "$LEDGER_SH"

SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")" && pwd)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

# Never touch a real registry.
export AGY_FLEET="$SCRATCH/registry"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

new_repo() {
  local r="$SCRATCH/repos/$1"; mkdir -p "$r"; r="$(cd "$r" && pwd)"
  ( cd "$r" && git init -q . && git config user.email t@e.com && git config user.name T \
      && git commit -q --allow-empty -m initial )
  printf '%s' "$r"
}

fleet() { /bin/bash "$FLEET_SH" "$@" 2>/dev/null; }

# --- an empty registry is not an error --------------------------------------

OUT="$(fleet list)"; CODE=$?
check empty-list-rc "$CODE" 0 "listing an empty registry is not an error"
if printf '%s\n' "$OUT" | grep -q 'No repositories registered'; then
  ok empty-list-says-so "an empty registry says so, and says where it would live"
else
  bad empty-list-says-so "unexpected: $OUT"
fi

OUT="$(fleet status)"; CODE=$?
check empty-status-rc "$CODE" 0 "status on an empty registry is not an error"

# --- registering -------------------------------------------------------------

RA="$(new_repo alpha)"
RB="$(new_repo beta)"

fleet add --repo "$RA" >/dev/null
check add-rc "$?" 0 "a git work tree can be registered"
fleet add --repo "$RB" >/dev/null

check registry-lines "$(grep -c . "$AGY_FLEET" 2>/dev/null | tr -cd '0-9')" "2" \
  "both repositories are in the registry"

OUT="$(fleet add --repo "$RA")"
if printf '%s\n' "$OUT" | grep -q 'already registered'; then
  ok add-idempotent "registering the same repository twice does not duplicate it"
else
  bad add-idempotent "unexpected: $OUT"
fi
check registry-still-two "$(grep -c . "$AGY_FLEET" 2>/dev/null | tr -cd '0-9')" "2" \
  "the registry did not grow on a duplicate add"

NOT_GIT="$SCRATCH/not-a-repo"; mkdir -p "$NOT_GIT"
fleet add --repo "$NOT_GIT" >/dev/null 2>&1
check add-non-git "$?" 3 "a directory that is not a work tree is refused with exit 3"

fleet add --repo "$SCRATCH/does-not-exist" >/dev/null 2>&1
check add-missing "$?" 2 "a path that does not exist is a bad argument"

# --- the roll-up -------------------------------------------------------------
#
# alpha: two dispatches, one passed, one overridden by verify, plus one refusal.
# beta:  one dispatch, passed.

ledger_append "$RA" run=a1 phase=IMPLEMENT status=DONE dispatched=true \
  started=2026-08-20T10:00:00Z usage='{"input_tokens":90,"output_tokens":10,"thinking_tokens":2,"cache_read_tokens":5000,"total_tokens":100}'
ledger_append "$RA" run=a1 phase=QA "status=VERIFY_FAILED(rc=1)" dispatched=true \
  started=2026-08-21T10:00:00Z usage='{"input_tokens":180,"output_tokens":20,"thinking_tokens":4,"cache_read_tokens":9000,"total_tokens":200}'
ledger_append "$RA" run=a2 phase=IMPLEMENT status=BRIEF_INVALID dispatched=false \
  started=2026-08-22T10:00:00Z
ledger_append "$RB" run=b1 phase=IMPLEMENT status=DONE dispatched=true \
  started=2026-08-23T10:00:00Z usage='{"input_tokens":45,"output_tokens":5,"thinking_tokens":1,"cache_read_tokens":0,"total_tokens":50}'

OUT="$(fleet status)"

ROW_A="$(printf '%s\n' "$OUT" | grep '^  alpha ' || true)"
ROW_B="$(printf '%s\n' "$OUT" | grep '^  beta ' || true)"

if printf '%s\n' "$ROW_A" | grep -q ' 300 '; then
  ok tokens-summed "a repository's billed tokens are summed"
else
  bad tokens-summed "token total wrong: $ROW_A"
fi

# The whole point of the token column: cache reads are excluded. Including the
# 14000 cache reads above would report alpha at nearly fifty times its real spend.
if printf '%s\n' "$ROW_A" | grep -q '14300'; then
  bad cache-excluded "cache reads were added into the token total"
else
  ok cache-excluded "cache reads are not added into the billed total"
fi

# Refusals are excluded from the rate: a gate that fired before a dispatch is not
# a worker that failed.
if printf '%s\n' "$ROW_A" | grep -q ' 50% '; then
  ok rate-excludes-refusals "one pass of two rated dispatches is 50%, with the refusal excluded"
else
  bad rate-excludes-refusals "pass rate wrong: $ROW_A"
fi
if printf '%s\n' "$ROW_A" | awk '{ print $6 }' | grep -qx '1'; then
  ok refusals-counted "the refusal is still counted and shown in its own column"
else
  bad refusals-counted "refusal column wrong: $ROW_A"
fi

if printf '%s\n' "$OUT" | grep -q '350 tokens across every phase'; then
  ok fleet-total "the fleet total adds the repositories together"
else
  bad fleet-total "fleet total wrong: $(printf '%s\n' "$OUT" | grep 'tokens across')"
fi
if printf '%s\n' "$OUT" | grep -q '2 of 3 rated dispatches passed'; then
  ok fleet-rate "the fleet rate is computed across repositories, refusals excluded"
else
  bad fleet-rate "fleet rate wrong: $(printf '%s\n' "$OUT" | grep 'rated dispatches')"
fi

if printf '%s\n' "$ROW_B" | grep -q '2026-08-23T10:00:00Z'; then
  ok last-activity "the most recent dispatch time is shown per repository"
else
  bad last-activity "last activity wrong: $ROW_B"
fi

# --- a window ----------------------------------------------------------------

OUT_SINCE="$(fleet status --since 2026-08-22)"
ROW_A_SINCE="$(printf '%s\n' "$OUT_SINCE" | grep '^  alpha ' || true)"
if printf '%s\n' "$ROW_A_SINCE" | awk '{ print $5 }' | grep -qx '0'; then
  ok since-filters "--since excludes dispatches started before the window"
else
  bad since-filters "window not applied: $ROW_A_SINCE"
fi
if printf '%s\n' "$OUT_SINCE" | grep -q 'Counting dispatches started on or after'; then
  ok since-stated "the window is stated rather than silently applied"
else
  bad since-stated "no window note in the output"
fi

# --- a ceiling ---------------------------------------------------------------

OUT_CEIL="$(fleet status --ceiling 1000)"
if printf '%s\n' "$OUT_CEIL" | grep -q '350 of a 1000 token fleet ceiling (35.0%)'; then
  ok ceiling "a fleet ceiling is reported against the real total when one is supplied"
else
  bad ceiling "ceiling wrong: $(printf '%s\n' "$OUT_CEIL" | grep ceiling)"
fi
if printf '%s\n' "$OUT" | grep -q 'fleet ceiling'; then
  bad ceiling-not-invented "a ceiling was shown when none was supplied"
else
  ok ceiling-not-invented "no ceiling is invented when none is supplied"
fi

# --- the roll-up states what it is not ---------------------------------------
#
# Pass rates by phase, convergence and gate corroboration do not mean anything
# added across repositories. Saying so is the difference between a roll-up and a
# misleading number.

if printf '%s\n' "$OUT" | grep -q 'do not mean anything added across'; then
  ok states-limits "the output says which figures do not survive being added up"
else
  bad states-limits "no note about what the roll-up cannot answer"
fi

# --- states ------------------------------------------------------------------

RC_REPO="$(new_repo parked)"
mkdir -p "$RC_REPO/.agy/queue"
printf 'run=c1\nphase=IMPLEMENT\n' > "$RC_REPO/.agy/queue/0000000001-1-c1-IMPLEMENT"
OUT_P="$(fleet status --repo "$RC_REPO")"
if printf '%s\n' "$OUT_P" | grep -q 'PARKED'; then
  ok state-parked "a repository with queued work reads as PARKED"
else
  bad state-parked "state wrong: $OUT_P"
fi

RD="$(new_repo quiet-worker)"
mkdir -p "$RD/.agy/runs/r1/phases/REVIEW"
{ printf 'state=running\n'; printf 'last_write=%s\n' "$(( $(date +%s) - 9000 ))"; } \
  > "$RD/.agy/runs/r1/phases/REVIEW/heartbeat"
OUT_Q="$(fleet status --repo "$RD")"
if printf '%s\n' "$OUT_Q" | grep -q 'QUIET'; then
  ok state-quiet "a dispatch that has stopped writing reads as QUIET"
else
  bad state-quiet "state wrong: $OUT_Q"
fi

RE_REPO="$(new_repo never-run)"
OUT_N="$(fleet status --repo "$RE_REPO")"
if printf '%s\n' "$OUT_N" | grep -q 'NO RUNS'; then
  ok state-no-runs "a repository that has never run is distinguished from an idle one"
else
  bad state-no-runs "state wrong: $OUT_N"
fi

# --- a broken registry entry is named, not fatal -----------------------------

printf '%s\n' "$SCRATCH/not-a-repo" >> "$AGY_FLEET"
OUT_BAD="$(fleet status)"; CODE=$?
check bad-entry-rc "$CODE" 3 "a registry entry that is not a work tree exits 3"
if printf '%s\n' "$OUT_BAD" | grep -q 'not a git work tree — skipped'; then
  ok bad-entry-named "the bad entry is named and skipped rather than stopping the report"
else
  bad bad-entry-named "bad entry not reported: $OUT_BAD"
fi
if printf '%s\n' "$OUT_BAD" | grep -q '^  alpha '; then
  ok bad-entry-continues "the other repositories are still reported"
else
  bad bad-entry-continues "the report stopped at the bad entry"
fi

# --- removal and argument handling -------------------------------------------

fleet remove --repo "$RA" >/dev/null
if grep -Fqx "$RA" "$AGY_FLEET" 2>/dev/null; then
  bad remove-entry "the repository is still in the registry"
else
  ok remove-entry "a repository can be unregistered"
fi

/bin/bash "$FLEET_SH" bogus >/dev/null 2>&1
check bad-command "$?" 2 "exit 2 on an unknown command"
/bin/bash "$FLEET_SH" status --bogus >/dev/null 2>&1
check bad-arg "$?" 2 "exit 2 on an unknown flag"
/bin/bash "$FLEET_SH" status --ceiling abc >/dev/null 2>&1
check bad-ceiling "$?" 2 "exit 2 on a non-numeric ceiling"

# --- reading a repository does not modify it ---------------------------------

BEFORE="$(find "$RB" -type f | sort)"
fleet status >/dev/null 2>&1
AFTER="$(find "$RB" -type f | sort)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok read-only "reporting on the fleet writes nothing inside a repository"
else
  bad read-only "fleet.sh wrote inside a registered repository"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
