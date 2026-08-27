#!/usr/bin/env bash
# Roll several repositories' ledgers up into one view.
#
#   fleet.sh add    --repo <path>        register a repository
#   fleet.sh remove --repo <path>        unregister it
#   fleet.sh list                        show the registry
#   fleet.sh status [--since <date>] [--ceiling <tokens>]
#   fleet.sh report --repo <path> [...]  hand off to report.sh for one repo
#
# Registry:  $AGY_FLEET, else ~/.agy/fleet — one absolute repository path per
#            line, blank lines and #-comments ignored. --repo <path> (repeatable)
#            overrides the registry for a single invocation.
#
# Writes:    only the registry file, and only on add/remove.
# Prints:    one row per repository, then the fleet totals.
#
# Exit codes:
#     0  fine (including an empty registry)
#     2  bad arguments
#     3  a registered path is not a git work tree — named, and skipped
#
# What this does and does not do.
#
# Every repository keeps its own independent ledger under its own .agy, and
# nothing has ever read more than one of them. A person running the pipeline
# across five repositories could answer "how is this repo doing" five times and
# "how is the fleet doing" not at all.
#
# This is a roll-up, deliberately coarse: which repositories are busy, which have
# work parked, which have gone quiet, and what the whole fleet has spent. It
# recomputes only the handful of totals that make sense to add across repositories.
# Everything finer — pass rates by phase, retry convergence, gate corroboration —
# stays report.sh's, per repository, because those numbers do not mean anything
# added together. `fleet.sh report --repo <path>` is a direct hand-off to it.
#
# On the token column: total_tokens is what a dispatch was billed. cache_read is
# reported by agy outside that total and is not added here, because adding it
# would report a fleet at several times its real spend.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/queue.sh"

FLEET_FILE="${AGY_FLEET:-$HOME/.agy/fleet}"

_fleet_registry() {
  [ -f "$FLEET_FILE" ] || return 0
  grep -v '^[[:space:]]*#' "$FLEET_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' || true
}

# Live workers, counted the way phase.sh's cap counts them: a record whose process
# is gone is a crash, not a worker, and must not read as one.
_fleet_live_workers() {
  local repo="$1" n=0 rec
  [ -d "$repo/.agy/workers" ] || { printf '0'; return 0; }
  for rec in "$repo/.agy/workers"/*; do
    [ -f "$rec" ] || continue
    local pid
    pid="$(sed -n 's/^pid=//p' "$rec" 2>/dev/null | head -1)"
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}

# A dispatch is quiet when its heartbeat still says running and nothing has been
# written for longer than the liveness limit. This is the only way to tell a
# thinking worker from a hung one from outside, and it is a warning, never a verdict.
_fleet_quiet_dispatches() {
  local repo="$1" n=0 hb
  local now; now="$(date +%s)"
  local limit="${AGY_LIVENESS_INTERVAL_SECONDS:-300}"
  for hb in "$repo"/.agy/runs/*/phases/*/heartbeat; do
    [ -f "$hb" ] || continue
    [ "$(sed -n 's/^state=//p' "$hb" 2>/dev/null | head -1)" = "running" ] || continue
    local last
    last="$(sed -n 's/^last_write=\([0-9][0-9]*\)$/\1/p' "$hb" 2>/dev/null | head -1)"
    [ -n "$last" ] || continue
    [ "$((now - last))" -ge "$limit" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# One pass over a repository's ledger. Coarse by intent — see the header.
# Emits: dispatches refusals unknown passes tokens last_started
_fleet_ledger_scan() {
  local ledger="$1"
  local since="${2:-}"
  [ -f "$ledger" ] || { printf '0 0 0 0 0 -'; return 0; }
  awk -v since="$since" '
    {
      has_ctx = ($0 ~ /"run":"/)
      if (!has_ctx) next

      # ISO-8601 timestamps in a fixed format compare correctly as strings, which
      # is the only date comparison available without a date library.
      if (since != "") {
        if (!match($0, /"started":"[^"]*"/)) next
        st = substr($0, RSTART + 11, RLENGTH - 12)
        if (st < since) next
      }

      if ($0 ~ /"dispatched":true/) disp++
      else if ($0 ~ /"dispatched":false/) refused++
      else unknown++

      # A pass is a worker claim that a verify did not overturn. A refusal never
      # ran, so it is neither a pass nor a failure and is excluded from both.
      if ($0 !~ /"dispatched":false/) {
        if ($0 ~ /"status":"(DONE|PASSED)"/) passed++
      }

      if (match($0, /"total_tokens":[0-9]+/)) {
        t = substr($0, RSTART + 15, RLENGTH - 15) + 0
        tokens += t
      }
      if (match($0, /"started":"[^"]*"/)) {
        s = substr($0, RSTART + 11, RLENGTH - 12)
        if (s > last) last = s
      }
    }
    END {
      printf "%d %d %d %d %d %s", disp+0, refused+0, unknown+0, passed+0, tokens+0,
        (last == "" ? "-" : last)
    }
  ' "$ledger"
}

_fleet_state() {
  local live="$1" quiet="$2" queued="$3" last="$4"
  if [ "$quiet" -gt 0 ]; then printf 'QUIET'; return 0; fi
  if [ "$live" -gt 0 ]; then printf 'RUNNING'; return 0; fi
  if [ "$queued" -gt 0 ]; then printf 'PARKED'; return 0; fi
  if [ "$last" = "-" ]; then printf 'NO RUNS'; return 0; fi
  printf 'IDLE'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  CMD="${1:-}"
  [ $# -gt 0 ] && shift || true

  REPOS=(); SINCE=""; CEILING=""; PASSTHROUGH=(); SEEN_SEP=0
  while [ $# -gt 0 ]; do
    if [ "$SEEN_SEP" -eq 1 ]; then PASSTHROUGH[${#PASSTHROUGH[@]}]="$1"; shift; continue; fi
    case "$1" in
      --) SEEN_SEP=1; shift ;;
      --repo)    REPOS[${#REPOS[@]}]="$2"; shift 2 ;;
      --fleet)   FLEET_FILE="$2";          shift 2 ;;
      --since)   SINCE="$2";               shift 2 ;;
      --ceiling) CEILING="$2";             shift 2 ;;
      -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
      *) echo "fleet: unknown arg $1" >&2; exit 2 ;;
    esac
  done

  case "$CMD" in
    add)
      [ ${#REPOS[@]} -gt 0 ] || { echo "fleet: add wants --repo" >&2; exit 2; }
      mkdir -p "$(dirname "$FLEET_FILE")" 2>/dev/null || true
      for P in "${REPOS[@]}"; do
        [ -d "$P" ] || { echo "fleet: not a directory: $P" >&2; exit 2; }
        ABS="$(cd "$P" && pwd)"
        git -C "$ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
          echo "fleet: not a git repository: $ABS" >&2; exit 3; }
        if _fleet_registry | grep -Fqx "$ABS"; then
          echo "fleet: already registered: $ABS"
        else
          printf '%s\n' "$ABS" >> "$FLEET_FILE"
          echo "fleet: registered $ABS"
        fi
      done
      exit 0
      ;;

    remove)
      [ ${#REPOS[@]} -gt 0 ] || { echo "fleet: remove wants --repo" >&2; exit 2; }
      [ -f "$FLEET_FILE" ] || { echo "fleet: no registry at $FLEET_FILE" >&2; exit 3; }
      for P in "${REPOS[@]}"; do
        ABS="$(cd "$P" 2>/dev/null && pwd || printf '%s' "$P")"
        TMP="$FLEET_FILE.tmp.$$"
        grep -Fxv "$ABS" "$FLEET_FILE" > "$TMP" 2>/dev/null || true
        mv -f "$TMP" "$FLEET_FILE"
        echo "fleet: unregistered $ABS"
      done
      exit 0
      ;;

    list)
      if [ ! -f "$FLEET_FILE" ] || [ -z "$(_fleet_registry)" ]; then
        echo "No repositories registered. Add one with: fleet.sh add --repo <path>"
        echo "Registry would live at: $FLEET_FILE"
        exit 0
      fi
      printf 'Fleet registry (%s):\n\n' "$FLEET_FILE"
      _fleet_registry | while IFS= read -r P; do printf '  %s\n' "$P"; done
      exit 0
      ;;

    report)
      [ ${#REPOS[@]} -eq 1 ] || { echo "fleet: report wants exactly one --repo" >&2; exit 2; }
      exec /bin/bash "$HERE/report.sh" --dir "${REPOS[0]}" \
        ${SINCE:+--since "$SINCE"} ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
      ;;

    status|"")
      LIST=""
      if [ ${#REPOS[@]} -gt 0 ]; then
        for P in "${REPOS[@]}"; do LIST="$LIST$P
"; done
      else
        LIST="$(_fleet_registry)"
      fi

      if [ -z "$LIST" ]; then
        echo "No repositories registered. Add one with: fleet.sh add --repo <path>"
        echo "Registry would live at: $FLEET_FILE"
        exit 0
      fi

      printf 'Fleet status\n'
      printf '============\n\n'
      [ -n "$SINCE" ] && printf 'Counting dispatches started on or after %s\n\n' "$SINCE"
      printf '  %-22s %-8s %5s %6s %6s %6s %7s %12s  %s\n' \
        "repo" "state" "live" "parked" "disp" "refus" "pass" "tokens" "last activity"

      T_LIVE=0; T_PARKED=0; T_DISP=0; T_REF=0; T_PASS=0; T_TOK=0; N_REPOS=0; BAD=0
      while IFS= read -r P; do
        [ -n "$P" ] || continue
        if [ ! -d "$P" ] || ! git -C "$P" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          printf '  %-22s %s\n' "$(basename "$P")" "not a git work tree — skipped ($P)"
          BAD=1
          continue
        fi
        ABS="$(cd "$P" && pwd)"
        N_REPOS=$((N_REPOS + 1))

        LIVE="$(_fleet_live_workers "$ABS")"
        QUIET="$(_fleet_quiet_dispatches "$ABS")"
        PARKED="$(queue_depth "$ABS/.agy/queue")"
        PARKED="${PARKED:-0}"

        SCAN="$(_fleet_ledger_scan "$ABS/.agy/ledger.jsonl" "$SINCE")"
        read -r R_DISP R_REF R_UNK R_PASS R_TOK R_LAST <<SCANEOF
$SCAN
SCANEOF

        # Refusals are excluded from the rate: a gate that fired before the dispatch
        # is not a worker that failed, and counting it as one understates the worker.
        RATED=$((R_DISP + R_UNK))
        if [ "$RATED" -gt 0 ]; then
          PCT="$(awk -v a="$R_PASS" -v b="$RATED" 'BEGIN { printf "%d%%", (a / b) * 100 }')"
        else
          PCT="-"
        fi

        STATE="$(_fleet_state "$LIVE" "$QUIET" "$PARKED" "$R_LAST")"

        printf '  %-22s %-8s %5s %6s %6s %6s %7s %12s  %s\n' \
          "$(basename "$ABS")" "$STATE" "$LIVE" "$PARKED" \
          "$((R_DISP + R_UNK))" "$R_REF" "$PCT" "$R_TOK" "$R_LAST"

        T_LIVE=$((T_LIVE + LIVE)); T_PARKED=$((T_PARKED + PARKED))
        T_DISP=$((T_DISP + R_DISP + R_UNK)); T_REF=$((T_REF + R_REF))
        T_PASS=$((T_PASS + R_PASS)); T_TOK=$((T_TOK + R_TOK))
      done <<EOF
$LIST
EOF

      printf '\n  %s repositor%s · %s worker%s running · %s parked · %s tokens across every phase\n' \
        "$N_REPOS" "$([ "$N_REPOS" -eq 1 ] && echo y || echo ies)" \
        "$T_LIVE" "$([ "$T_LIVE" -eq 1 ] && echo '' || echo s)" \
        "$T_PARKED" "$T_TOK"

      if [ "$T_DISP" -gt 0 ]; then
        printf '  %s of %s rated dispatches passed (%s) · %s refusals excluded from the rate\n' \
          "$T_PASS" "$T_DISP" \
          "$(awk -v a="$T_PASS" -v b="$T_DISP" 'BEGIN { printf "%d%%", (a / b) * 100 }')" \
          "$T_REF"
      fi

      if [ -n "$CEILING" ]; then
        case "$CEILING" in
          ''|*[!0-9]*) echo "fleet: --ceiling wants a whole number of tokens" >&2; exit 2 ;;
        esac
        printf '  %s of a %s token fleet ceiling (%s)\n' "$T_TOK" "$CEILING" \
          "$(awk -v a="$T_TOK" -v b="$CEILING" 'BEGIN { printf "%.1f%%", (a / b) * 100 }')"
      fi

      printf '\n  Rates and totals here are a roll-up. Pass rates by phase, retry\n'
      printf '  convergence and gate corroboration do not mean anything added across\n'
      printf '  repositories — read those per repository: fleet.sh report --repo <path>\n'
      printf '  Cache reads are excluded from the token column, as agy reports them\n'
      printf '  outside the billed total.\n'

      [ "$BAD" -eq 1 ] && exit 3
      exit 0
      ;;

    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "fleet: unknown command $CMD (want add|remove|list|status|report)" >&2; exit 2 ;;
  esac
fi
