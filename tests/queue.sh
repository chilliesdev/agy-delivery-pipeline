#!/usr/bin/env bash
# Exercise queue.sh and phase.sh --queue: parking a dispatch at the worker cap,
# and running the parked work when a slot frees.
#
#   tests/queue.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
#
# No real worker is ever dispatched: AGY_BIN points at a stub throughout.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
QUEUE_SH="$ROOT_REPO/scripts/queue.sh"
PHASE_SH="$ROOT_REPO/scripts/phase.sh"
RUN_DIR_SH="$ROOT_REPO/scripts/run-dir.sh"

for F in "$QUEUE_SH" "$PHASE_SH" "$RUN_DIR_SH"; do
  [ -f "$F" ] || { echo "queue-test: $F not found" >&2; exit 2; }
done

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/queue-test.XXXXXX")" && pwd)"
HOLDER_PID=""
cleanup() {
  [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null
  rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

STUB_AGY="$SCRATCH/stub_agy"
cat > "$STUB_AGY" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-medium\tGemini\n'; exit 0
fi
printf '{"conversation_id":"c","status":"SUCCESS","response":"STATUS: DONE | File: CHANGES.md","duration_seconds":0.1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":2,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":12}}\n'
exit 0
STUB
chmod +x "$STUB_AGY"

new_repo() {
  local r="$SCRATCH/repos/$1"; mkdir -p "$r"; r="$(cd "$r" && pwd)"
  ( cd "$r" && git init -q . && git config user.email t@e.com && git config user.name T \
      && git commit -q --allow-empty -m initial )
  printf '%s' "$r"
}

make_brief() {
  local repo="$1" phase="$2" run="$3" b="$1/brief_$2.md"
  cat > "$b" <<EOF
# Phase: $phase
Goal: queue test.
Rules:
- Do not run shell commands.
- Do not touch git.
Output Contract:
Write your one-line verdict to .agy/runs/$run/phases/$phase/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF
  printf '%s' "$b"
}

# A process the cap will count as a live worker. _is_worker_alive matches on the
# process arguments, so the holder has to genuinely look like a dispatch — a fake
# pid is culled as dead, which is the behaviour that makes the cap self-healing.
start_worker_holder() {
  local repo="$1" phase="$2"
  local fake="$SCRATCH/phase.sh"
  printf '#!/usr/bin/env bash\nsleep 120\n' > "$fake"
  chmod +x "$fake"
  /bin/bash "$fake" --phase "$phase" &
  HOLDER_PID=$!
  mkdir -p "$repo/.agy/workers"
  {
    printf 'pid=%s\n' "$HOLDER_PID"
    printf 'run=%s\n' "holder-run"
    printf 'phase=%s\n' "$phase"
  } > "$repo/.agy/workers/holder.rec"
}

# =============================================================================
# 1. At the cap, --queue parks instead of refusing
# =============================================================================

R="$(new_repo park)"
RUN_ID="$(run_dir_new --dir "$R" --task "queue test")"
BRIEF="$(make_brief "$R" IMPLEMENT "$RUN_ID")"
start_worker_holder "$R" HOLDER

OUT="$(AGY_BIN="$STUB_AGY" /bin/bash "$PHASE_SH" --phase IMPLEMENT --brief "$BRIEF" \
  --dir "$R" --run "$RUN_ID" --max-workers 1 --queue --no-preflight 2>/dev/null)"
CODE=$?

check park-exit "$CODE" 11 "parking exits 11, distinct from the cap's own refusal (8)"
if printf '%s\n' "$OUT" | grep -q 'STATUS: QUEUED('; then
  ok park-status "the caller is told QUEUED rather than refused"
else
  bad park-status "unexpected status: $OUT"
fi
if printf '%s\n' "$OUT" | grep -q 'nothing dispatched and nothing spent'; then
  ok park-says-nothing-spent "the line says plainly that nothing was spent"
else
  bad park-says-nothing-spent "no spend note: $OUT"
fi

# Parking must not run a worker.
if [ -s "$R/.agy/runs/$RUN_ID/phases/IMPLEMENT/log" ]; then
  bad park-no-worker "a worker log exists — the dispatch was not actually parked"
else
  ok park-no-worker "no worker log: parking dispatched nothing"
fi

L="$(tail -1 "$R/.agy/ledger.jsonl" 2>/dev/null)"
if printf '%s\n' "$L" | grep -q '"status":"QUEUED' \
   && printf '%s\n' "$L" | grep -q '"dispatched":false'; then
  ok park-ledger "the parked dispatch is recorded with dispatched=false"
else
  bad park-ledger "ledger record wrong: $L"
fi
if printf '%s\n' "$L" | grep -q '"usage"'; then
  bad park-no-usage "a parked dispatch carries usage it never spent"
else
  ok park-no-usage "a parked dispatch carries no usage"
fi

# =============================================================================
# 2. The queue can be read
# =============================================================================

LIST="$(/bin/bash "$QUEUE_SH" list --dir "$R" 2>/dev/null)"
if printf '%s\n' "$LIST" | grep -q "$RUN_ID"; then
  ok list-shows-entry "list shows the parked dispatch"
else
  bad list-shows-entry "entry missing from list: $LIST"
fi
check position-first "$(/bin/bash "$QUEUE_SH" position --dir "$R" --run "$RUN_ID" --phase IMPLEMENT 2>/dev/null)" \
  "1" "the only parked entry is at position 1"

# =============================================================================
# 3. Without --queue the cap still refuses — the default is unchanged
# =============================================================================

R2="$(new_repo refuse-default)"
RUN2="$(run_dir_new --dir "$R2" --task "queue test 2")"
B2="$(make_brief "$R2" IMPLEMENT "$RUN2")"
mkdir -p "$R2/.agy/workers"
{ printf 'pid=%s\n' "$HOLDER_PID"; printf 'run=holder-run\n'; printf 'phase=HOLDER\n'; } \
  > "$R2/.agy/workers/holder.rec"

OUT2="$(AGY_BIN="$STUB_AGY" /bin/bash "$PHASE_SH" --phase IMPLEMENT --brief "$B2" \
  --dir "$R2" --run "$RUN2" --max-workers 1 --no-preflight 2>/dev/null)"
CODE2=$?
check refuse-exit "$CODE2" 8 "without --queue the cap still refuses with exit 8"
if printf '%s\n' "$OUT2" | grep -q 'WORKER_CAP_EXCEEDED'; then
  ok refuse-status "the default refusal is unchanged"
else
  bad refuse-status "unexpected: $OUT2"
fi
if [ -d "$R2/.agy/queue" ] && [ -n "$(ls -A "$R2/.agy/queue" 2>/dev/null)" ]; then
  bad refuse-no-queue "a refusal wrote a queue entry without being asked to"
else
  ok refuse-no-queue "refusing writes nothing to the queue"
fi

# =============================================================================
# 4. Draining runs the parked work once a slot frees
# =============================================================================

DRY="$(/bin/bash "$QUEUE_SH" drain --dir "$R" --dry-run 2>/dev/null)"
if printf '%s\n' "$DRY" | grep -q "would dispatch: $RUN_ID IMPLEMENT"; then
  ok drain-dry-run "a dry run names what it would dispatch and runs nothing"
else
  bad drain-dry-run "dry run wrong: $DRY"
fi
check drain-dry-keeps-entry "$(/bin/bash "$QUEUE_SH" position --dir "$R" --run "$RUN_ID" --phase IMPLEMENT 2>/dev/null)" \
  "1" "a dry run leaves the entry parked"

# Free the slot, then drain for real.
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
rm -f "$R/.agy/workers/holder.rec"

DRAIN="$(AGY_BIN="$STUB_AGY" /bin/bash "$QUEUE_SH" drain --dir "$R" 2>/dev/null)"
if printf '%s\n' "$DRAIN" | grep -q 'STATUS: DONE'; then
  ok drain-dispatches "draining runs the parked dispatch and reports its status"
else
  bad drain-dispatches "drain did not dispatch: $DRAIN"
fi
if [ -s "$R/.agy/runs/$RUN_ID/phases/IMPLEMENT/log" ]; then
  ok drain-worker-ran "the drained dispatch really ran a worker"
else
  bad drain-worker-ran "no worker log after draining"
fi
check drain-empties "$(/bin/bash "$QUEUE_SH" list --dir "$R" 2>/dev/null | grep -c 'Queue is empty')" \
  "1" "the queue is empty once drained"

# The drained dispatch is a real one, and must be recorded as such.
LD="$(tail -1 "$R/.agy/ledger.jsonl" 2>/dev/null)"
if printf '%s\n' "$LD" | grep -q '"dispatched":true'; then
  ok drain-ledger "the drained dispatch is recorded as a dispatch, not a refusal"
else
  bad drain-ledger "drained record wrong: $LD"
fi

# =============================================================================
# 5. An entry is taken out of the queue before it is dispatched
#
# A drain that died mid-dispatch would otherwise leave the entry behind and run
# the phase twice on the next drain — and a phase dispatched twice is real spend.
# =============================================================================

R3="$(new_repo no-double-dispatch)"
RUN3="$(run_dir_new --dir "$R3" --task "queue test 3")"
B3="$(make_brief "$R3" IMPLEMENT "$RUN3")"
/bin/bash "$QUEUE_SH" add --dir "$R3" --run "$RUN3" --phase IMPLEMENT -- \
  --phase IMPLEMENT --brief "$B3" --dir "$R3" --run "$RUN3" --no-preflight >/dev/null 2>&1

COUNT_BEFORE="$(ls -1 "$R3/.agy/queue" 2>/dev/null | grep -c .)"
check add-one-entry "$COUNT_BEFORE" "1" "queue add parks exactly one entry"

AGY_BIN="$STUB_AGY" /bin/bash "$QUEUE_SH" drain --dir "$R3" >/dev/null 2>&1
COUNT_AFTER="$(ls -1 "$R3/.agy/queue" 2>/dev/null | grep -c .)"
check drain-removes-entry "$COUNT_AFTER" "0" "the entry is gone after draining, so it cannot run twice"

DISPATCH_COUNT="$(grep -c '"dispatched":true' "$R3/.agy/ledger.jsonl" 2>/dev/null | tr -cd '0-9')"
check drain-dispatches-once "$DISPATCH_COUNT" "1" "the parked phase ran exactly once"

# =============================================================================
# 6. Arguments survive the round trip, including one carrying spaces
# =============================================================================

R4="$(new_repo argv-roundtrip)"
RUN4="$(run_dir_new --dir "$R4" --task "argv test")"
/bin/bash "$QUEUE_SH" add --dir "$R4" --run "$RUN4" --phase REVIEW -- \
  --phase REVIEW --task "a task with spaces in it" --tier high >/dev/null 2>&1
ENTRY_FILE="$(ls -1 "$R4/.agy/queue"/* 2>/dev/null | head -1)"
if grep -qx 'arg=a task with spaces in it' "$ENTRY_FILE" 2>/dev/null; then
  ok argv-spaces "an argument containing spaces survives as one argument"
else
  bad argv-spaces "argument mangled: $(cat "$ENTRY_FILE" 2>/dev/null)"
fi
if grep -qx 'arg=--tier' "$ENTRY_FILE" 2>/dev/null && grep -qx 'arg=high' "$ENTRY_FILE" 2>/dev/null; then
  ok argv-order "flags and their values are stored separately, in order"
else
  bad argv-order "argv not stored as separate lines"
fi

# --queue must not be stored, or a drained entry would re-queue itself forever.
if grep -qx 'arg=--queue' "$ENTRY_FILE" 2>/dev/null; then
  bad argv-drops-queue-flag "--queue was stored and the entry would re-queue itself"
else
  ok argv-drops-queue-flag "--queue is dropped from the stored argv"
fi

# =============================================================================
# 7. Removing a parked entry, and argument handling
# =============================================================================

E_NAME="$(basename "$ENTRY_FILE")"
/bin/bash "$QUEUE_SH" remove --dir "$R4" --entry "$E_NAME" >/dev/null 2>&1
check remove-entry "$?" 0 "an entry can be removed"
check remove-gone "$(ls -1 "$R4/.agy/queue" 2>/dev/null | grep -c .)" "0" "the removed entry is gone"

/bin/bash "$QUEUE_SH" remove --dir "$R4" --entry "no-such-entry" >/dev/null 2>&1
check remove-missing "$?" 3 "removing an entry that is not there exits 3"

/bin/bash "$QUEUE_SH" bogus --dir "$R4" >/dev/null 2>&1
check bad-command "$?" 2 "exit 2 on an unknown command"
/bin/bash "$QUEUE_SH" list --bogus >/dev/null 2>&1
check bad-arg "$?" 2 "exit 2 on an unknown flag"

R_EMPTY="$(new_repo empty-queue)"
OUT_EMPTY="$(/bin/bash "$QUEUE_SH" drain --dir "$R_EMPTY" 2>/dev/null)"
check empty-drain-rc "$?" 0 "draining an empty queue is not an error"
if printf '%s\n' "$OUT_EMPTY" | grep -q 'nothing to drain'; then
  ok empty-drain-says-so "an empty drain says so plainly"
else
  bad empty-drain-says-so "unexpected: $OUT_EMPTY"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
