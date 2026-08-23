#!/usr/bin/env bash
# Fail fast if agy cannot run the phase that is about to be dispatched.
#
#   preflight.sh [--model <id>] [--tier low|medium|high] [--timeout <n>]
#                [--quiet]
#
# Checks in order, each with its own exit code:
#   127  agy is not on PATH — honours $AGY_BIN exactly as agy-run.sh does
#     3  `agy models` failed or came back empty: the CLI is not signed in
#     4  the requested model is absent from that listing
#     7  the listing never came back inside --timeout (default 30s)
#     8  no writable scratch directory to catch the listing in
#     2  bad arguments
#
# `agy models` is the authentication check. agy has no whoami subcommand, and
# the listing is a live authenticated fetch, so a listing that arrives at all
# is the sign-in signal. It is re-fetched every time and never cached: the
# listing varies by account and moves over time, and a cached copy has been
# seen missing a model a fresh fetch offered. Only parsed model ids are ever
# printed — never the raw output, which is where an auth payload would sit.
#
# Two agy behaviours this depends on: the "Fetching available models..." banner
# goes to stderr, and agy hangs when its stdout is a plain file — so the listing
# still reaches this script down a pipe, never a `>` redirect, watchdog or no
# watchdog. The fetch writes into `cat`; it is `cat` that owns the file.
#
# The fetch is bounded because phase.sh runs this before *every* dispatch, and a
# hang there stalls the pipeline with nothing an orchestrator can act on — no
# STATUS line, no worker log, no retry file. One real fetch sat for ten minutes
# while three immediate re-runs answered in three seconds. macOS ships no
# timeout(1) or gtimeout(1), so the bound is the same hand-rolled watchdog
# check-test-command.sh runs: `set -m` gives the fetch its own process group,
# the watchdog TERMs that group and then KILLs it, and a marker file records
# that it fired. --timeout 0 disables it and restores the old, unbounded wait.
#
# 7 for that timeout rather than 5 or 6: phase.sh exits with this script's code
# verbatim, and 5 and 6 are already its own VERIFY_FAILED and RETRY_CAP_REACHED.
set -uo pipefail

AGY="${AGY_BIN:-agy}"
MODEL=""; TIER=""; QUIET=""; TIMEOUT="${AGY_PREFLIGHT_TIMEOUT:-30}"

while [ $# -gt 0 ]; do
  case "$1" in
    --model)    MODEL="$2"; shift 2 ;;
    --tier)     TIER="$2";  shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --quiet|-q) QUIET=1;    shift ;;
    -h|--help)  sed -n '2,37p' "$0"; exit 0 ;;
    *) echo "preflight: unknown arg $1" >&2; exit 2 ;;
  esac
done

# --timeout takes seconds, or the same number with an s or m suffix, exactly as
# check-test-command.sh takes it. 0 disables the bound.
case "$TIMEOUT" in
  *m) LIMIT="${TIMEOUT%m}"; MULT=60 ;;
  *s) LIMIT="${TIMEOUT%s}"; MULT=1 ;;
  *)  LIMIT="$TIMEOUT";     MULT=1 ;;
esac
case "$LIMIT" in
  ''|*[!0-9]*) echo "preflight: --timeout wants seconds (or 30s / 5m), got '$TIMEOUT'" >&2; exit 2 ;;
esac
LIMIT=$((LIMIT * MULT))

# --model takes a raw id and wins; --tier maps the way phase.sh maps it, raw
# ids included. With neither, check the model agy-run.sh would have defaulted to.
if [ -z "$MODEL" ] && [ -n "$TIER" ]; then
  case "$TIER" in
    low|medium|high) MODEL="gemini-3.7-flash-$TIER" ;;
    *) MODEL="$TIER" ;;
  esac
fi
MODEL="${MODEL:-${AGY_MODEL:-gemini-3.7-flash-medium}}"

# 1. the CLI itself
if ! command -v "$AGY" >/dev/null 2>&1; then
  echo "preflight: agy not found on PATH (looked for '$AGY')." >&2
  echo "preflight: install it with" >&2
  echo "  curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
  echo "preflight: it lands in ~/.local/bin — put that on your PATH, or point AGY_BIN at it." >&2
  exit 127
fi

# 2. authentication, by way of a live listing, under the watchdog described up
# top. The scratch directory is outside any repo — nothing here belongs in a
# user's tree — and holds two files: what the fetch printed, and the marker the
# watchdog writes if it had to fire.
FETCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")" || {
  echo "preflight: could not create a scratch directory under ${TMPDIR:-/tmp}." >&2
  echo "preflight: that is where the model listing is caught — point TMPDIR somewhere writable." >&2
  exit 8
}
trap 'rm -rf "$FETCH_DIR"' EXIT INT TERM
RAW_FILE="$FETCH_DIR/models"
MARKER="$FETCH_DIR/timeout"

# agy's own stdout is the pipe, which is the behaviour it needs; `cat` is what
# faces the file. The subshell exits with agy's code, not cat's.
set -m
( "$AGY" models 2>/dev/null | cat > "$RAW_FILE"; exit "${PIPESTATUS[0]}" ) &
FETCH_PID=$!
set +m

WATCH_PID=""
if [ "$LIMIT" -gt 0 ]; then
  ( sleep "$LIMIT"
    printf 'fired\n' > "$MARKER" 2>/dev/null
    kill -TERM -"$FETCH_PID" 2>/dev/null || kill -TERM "$FETCH_PID" 2>/dev/null
    sleep 2
    kill -KILL -"$FETCH_PID" 2>/dev/null ) >/dev/null 2>&1 &
  WATCH_PID=$!
fi

# Braced so the shell's own "Terminated: 15" job notice — job control is on for
# the fetch above — cannot reach stderr and be mistaken for agy's.
{ wait "$FETCH_PID"; RC=$?; } 2>/dev/null
if [ -n "$WATCH_PID" ]; then
  kill "$WATCH_PID" 2>/dev/null
  { wait "$WATCH_PID"; } 2>/dev/null
fi

if [ -f "$MARKER" ]; then
  echo "preflight: \`agy models\` did not return within ${LIMIT}s — the fetch hung and was killed." >&2
  echo "preflight: the hang is transient on agy's side; an immediate re-run usually answers in seconds." >&2
  echo "preflight: raise the bound with --timeout, or drop preflight for this dispatch with --no-preflight." >&2
  exit 7
fi

RAW="$(cat "$RAW_FILE" 2>/dev/null)"

# One id per line as `<id>\t<Human Label>`. Keep only fields that look like an
# id, which drops the banner and any warning line that reaches stdout instead.
AVAILABLE="$(printf '%s\n' "$RAW" | awk -F'\t' '
  { id = $1
    sub(/^[[:space:]]+/, "", id)
    sub(/[[:space:]]+$/, "", id)
    if (id ~ /^[A-Za-z0-9][A-Za-z0-9._:-]*$/) print id }
')"

if [ "$RC" -ne 0 ] || [ -z "$AVAILABLE" ]; then
  echo "preflight: \`agy models\` listed no models (rc=$RC) — agy appears not to be signed in." >&2
  echo "preflight: run \`agy\` once interactively and complete the sign-in it prompts for," >&2
  echo "preflight: then re-run this check. Do not paste tokens into a brief or a script." >&2
  exit 3
fi

# 3. the model this phase would ask for
if ! printf '%s\n' "$AVAILABLE" | grep -Fxq -- "$MODEL"; then
  echo "preflight: model '$MODEL' is not available to this account right now." >&2
  echo "preflight: \`agy models\` currently offers:" >&2
  printf '%s\n' "$AVAILABLE" | sed 's/^/  /' >&2
  exit 4
fi

# 4. all clear
if [ -z "$QUIET" ]; then
  COUNT="$(printf '%s\n' "$AVAILABLE" | grep -c .)"
  printf 'preflight: ok — agy signed in, %s available (%s models listed)\n' "$MODEL" "$COUNT"
fi
exit 0
