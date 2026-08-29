#!/usr/bin/env bash
# Start the AGY Control Center local observability server.
#
#   scripts/serve.sh [--port 7749] [--repo <path>]... [--registry <file>]
#                    [--scan <dir>] [--no-open]
#                    [--default-view fleet|repo|run]
#                    [--default-tab overview|transcript|trace|diff|brief|fleet]
#                    [--show-dollars] [--price-per-mtok <n>]
#
# Flags:
#   --port <n>             Port to bind on 127.0.0.1 (default: 7749)
#   --repo <path>          Additional repository directory to watch (repeatable)
#   --registry <file>      Replace fleet registry file list with <file>
#   --scan <dir>           Scan <dir> for git worktrees with .agy/ directories
#   --no-open              Do not automatically open the browser
#   --default-view <v>     Default view: fleet, repo, or run (default: fleet)
#   --default-tab <t>      Default tab: overview, transcript, trace, diff, brief, fleet
#   --show-dollars         Show estimated dollar cost in display
#   --price-per-mtok <n>   Price per million tokens for dollar estimates
#   -h, --help             Show this help
#
# Reads:   Fleet registry ($AGY_FLEET, ~/.config/agy/fleet, ~/.agy/fleet),
#          <repo>/.agy/ state directories, git repository metadata
# Writes:  Nothing (read-only server)
# Prints:  Server status and listening URL on startup
#
# Exit codes:
#     0  fine / clean shutdown
#     2  bad arguments
#     4  Node missing or too old (< 20)
#
# Why this launcher exists:
# The delivery pipeline core runs on pure Bash and POSIX utilities with zero Node
# dependency. The web control center UI requires Node.js >= 20. This launcher
# isolates the Node requirement so that no other pipeline component depends on Node.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT=7749

# Parse and validate arguments
PASS_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] || { echo "serve: --port requires an argument" >&2; exit 2; }
      PORT="$2"
      case "$PORT" in
        ''|*[!0-9]*) echo "serve: --port wants a positive integer, got '$PORT'" >&2; exit 2 ;;
      esac
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || { echo "serve: --repo requires an argument" >&2; exit 2; }
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    --registry)
      [ $# -ge 2 ] || { echo "serve: --registry requires an argument" >&2; exit 2; }
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    --scan)
      [ $# -ge 2 ] || { echo "serve: --scan requires an argument" >&2; exit 2; }
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    --no-open)
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      shift
      ;;
    --default-view)
      [ $# -ge 2 ] || { echo "serve: --default-view requires an argument" >&2; exit 2; }
      case "$2" in
        fleet|repo|run) ;;
        *) echo "serve: invalid --default-view '$2' (want fleet|repo|run)" >&2; exit 2 ;;
      esac
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    --default-tab)
      [ $# -ge 2 ] || { echo "serve: --default-tab requires an argument" >&2; exit 2; }
      case "$2" in
        overview|transcript|trace|diff|brief|fleet) ;;
        *) echo "serve: invalid --default-tab '$2' (want overview|transcript|trace|diff|brief|fleet)" >&2; exit 2 ;;
      esac
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    --show-dollars)
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      shift
      ;;
    --price-per-mtok)
      [ $# -ge 2 ] || { echo "serve: --price-per-mtok requires an argument" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9.]*) echo "serve: --price-per-mtok wants a numeric value, got '$2'" >&2; exit 2 ;;
      esac
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    --tick)
      [ $# -ge 2 ] || { echo "serve: --tick requires an argument" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*) echo "serve: --tick wants a positive integer, got '$2'" >&2; exit 2 ;;
      esac
      PASS_ARGS[${#PASS_ARGS[@]}]="$1"
      PASS_ARGS[${#PASS_ARGS[@]}]="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      echo "serve: unknown arg $1" >&2
      exit 2
      ;;
  esac
done

# Check for Node.js >= 20
if ! command -v node >/dev/null 2>&1; then
  echo "serve: node not found on PATH — the control center needs Node >= 20 (the pipeline itself does not)" >&2
  exit 4
fi

NODE_VERSION="$(node -v 2>/dev/null || true)"
NODE_MAJOR="$(printf '%s\n' "$NODE_VERSION" | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')"

if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt 20 ]; then
  echo "serve: node version ${NODE_VERSION:-unknown} too old — the control center needs Node >= 20 (the pipeline itself does not)" >&2
  exit 4
fi

SERVER_JS="$HERE/serve/server.js"
if [ ! -f "$SERVER_JS" ]; then
  echo "serve: server implementation not found at $SERVER_JS" >&2
  exit 2
fi

exec node "$SERVER_JS" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
