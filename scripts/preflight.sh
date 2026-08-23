#!/usr/bin/env bash
# Fail fast if agy cannot run the phase that is about to be dispatched.
#
#   preflight.sh [--model <id>] [--tier low|medium|high] [--quiet]
#
# Checks in order, each with its own exit code:
#   127  agy is not on PATH — honours $AGY_BIN exactly as agy-run.sh does
#     3  `agy models` failed or came back empty: the CLI is not signed in
#     4  the requested model is absent from that listing
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
# goes to stderr, and agy hangs when its stdout is a plain file — so the
# listing is read through a command substitution, never a redirect. There is no
# time bound on the fetch: macOS ships no `timeout` binary, so a hung fetch
# hangs here too.
set -uo pipefail

AGY="${AGY_BIN:-agy}"
MODEL=""; TIER=""; QUIET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model)    MODEL="$2"; shift 2 ;;
    --tier)     TIER="$2";  shift 2 ;;
    --quiet|-q) QUIET=1;    shift ;;
    -h|--help)  sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "preflight: unknown arg $1" >&2; exit 2 ;;
  esac
done

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

# 2. authentication, by way of a live listing
RAW="$("$AGY" models 2>/dev/null)"; RC=$?

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
