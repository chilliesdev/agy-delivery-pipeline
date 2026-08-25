#!/usr/bin/env bash
# Run one brief through the Antigravity CLI (agy) headlessly.
#
#   agy-run.sh --brief <file> [--dir <workdir>] [--log <file>]
#              [--model <id>] [--mode accept-edits|plan|full]
#              [--effort low|medium|high] [--timeout 30m] [--sandbox]
#
# Thin shim over drivers/agy.sh for backward compatibility.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../drivers/agy.sh"

driver_run "$@"
exit $?
