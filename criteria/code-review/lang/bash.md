## Bash language checks

Check every Bash hunk against these concrete failure patterns:

- **Unquoted variable expansions** — `$var` or `$(cmd)` without double quotes (`"$var"`, `"$(cmd)"`). Unquoted expansions undergo word splitting and pathname (glob) expansion, breaking on spaces or special characters. → quote all expansions.
- **Missing or improper shell options** — scripts omitting `set -uo pipefail` (or `-euo pipefail` where specified). Missing options allow pipelines to hide failure and undefined variables to evaluate silently to empty strings. → set appropriate safety options at script top.
- **Fragile test syntax** — using `[ ]` where `[[ ]]` is available (in bash) or failing to quote variables inside `[ "$x" = "y" ]`. Unquoted variables in single brackets cause syntax errors when empty. → quote operands in `[ ]` or use `[[ ]]`.
- **Non-portable Bash 4+ constructs** — using `mapfile`, `readarray`, `declare -A`, `${var^^}`, or `declare -n` in scripts required to support Bash 3.2 (macOS default). → use portable while-read loops and standard string manipulations.
- **Malformed array expansions** — expanding arrays as `$ARR` or `$ARR[@]` without quotes instead of `"${ARR[@]}"` or `${ARR[@]+"${ARR[@]}"}`. → use standard array expansion syntax.
