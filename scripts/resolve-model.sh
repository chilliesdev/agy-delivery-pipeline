#!/usr/bin/env bash
# Resolve model and tier binding from agy.toml configuration.
#
#   resolve-model.sh [--tier <low|medium|high|raw-id>] [--phase <NAME>]
#                    [--dir <repo>] [--fallbacks]
#
# Resolution order (first hit wins):
#   1. <repo>/.claude/agy.toml     the project's own configuration
#   2. <repo>/agy.toml             project root configuration
#   3. <this repo>/agy.toml        vendored default configuration
#
# If no config file is found, built-in defaults apply:
#   low    -> gemini-3.7-flash-low
#   medium -> gemini-3.7-flash-medium
#   high   -> gemini-3.7-flash-high
#
# Prints:
#   STDOUT: Resolved model id (or fallback list if --fallbacks) — one line
#   STDERR: Which config file and entry decided the resolution
#
# Exit codes:
#   0  model resolved
#   2  bad arguments, unknown tier, or malformed config
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse and validate restricted-subset TOML into flattened section.key=value lines.
_resolve_model_parse_toml() {
  local toml_file="$1"
  [ -f "$toml_file" ] || return 1

  local current_section=""
  local lineno=0
  local line=""

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    # Strip leading/trailing whitespace
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    # Empty line
    if [ -z "$trimmed" ]; then
      continue
    fi

    # Comment line
    case "$trimmed" in
      \#*) continue ;;
    esac

    # Section header [section] or [section.subsection]
    case "$trimmed" in
      \[*\])
        local sec="${trimmed#\[}"
        sec="${sec%\]}"
        sec="${sec#"${sec%%[![:space:]]*}"}"
        sec="${sec%"${sec##*[![:space:]]}"}"

        case "$sec" in
          ""|*[[:space:]]*)
            echo "resolve-model: malformed config in $toml_file:$lineno: invalid section header '$line'" >&2
            return 2
            ;;
          *.*.*)
            echo "resolve-model: malformed config in $toml_file:$lineno: nested tables beyond one level not supported: '[$sec]'" >&2
            return 2
            ;;
          *[!a-zA-Z0-9_.-]*)
            echo "resolve-model: malformed config in $toml_file:$lineno: invalid characters in section '[$sec]'" >&2
            return 2
            ;;
        esac
        current_section="$sec"
        continue
        ;;
      \[*)
        echo "resolve-model: malformed config in $toml_file:$lineno: invalid section header '$line'" >&2
        return 2
        ;;
    esac

    case "$trimmed" in
      *=*) ;;
      *)
        echo "resolve-model: malformed config in $toml_file:$lineno: unrecognized line '$line'" >&2
        return 2
        ;;
    esac

    if [ -z "$current_section" ]; then
      echo "resolve-model: malformed config in $toml_file:$lineno: key defined outside of a section: '$line'" >&2
      return 2
    fi

    local key="${trimmed%%=*}"
    local val="${trimmed#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    case "$key" in
      ""|*[!a-zA-Z0-9_-]*)
        echo "resolve-model: malformed config in $toml_file:$lineno: invalid key '$key'" >&2
        return 2
        ;;
    esac

    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    case "$val" in
      \"*\")
        local inside="${val#\"}"
        inside="${inside%\"}"
        case "$inside" in
          *\"*)
            echo "resolve-model: malformed config in $toml_file:$lineno: invalid string or trailing comment in '$line'" >&2
            return 2
            ;;
        esac
        printf '%s.%s=%s\n' "$current_section" "$key" "$inside"
        ;;
      \"*)
        echo "resolve-model: malformed config in $toml_file:$lineno: unclosed string or trailing content: '$val'" >&2
        return 2
        ;;
      \[*\])
        local arr_raw="${val#\[}"
        arr_raw="${arr_raw%\]}"
        arr_raw="${arr_raw#"${arr_raw%%[![:space:]]*}"}"
        arr_raw="${arr_raw%"${arr_raw##*[![:space:]]}"}"

        local items=""
        if [ -n "$arr_raw" ]; then
          local save_ifs="$IFS"
          IFS=','
          local elem
          for elem in $arr_raw; do
            elem="${elem#"${elem%%[![:space:]]*}"}"
            elem="${elem%"${elem##*[![:space:]]}"}"
            case "$elem" in
              \"*\")
                local str="${elem#\"}"
                str="${str%\"}"
                case "$str" in
                  *\"*)
                    IFS="$save_ifs"
                    echo "resolve-model: malformed config in $toml_file:$lineno: invalid string in array element '$elem'" >&2
                    return 2
                    ;;
                esac
                if [ -z "$items" ]; then
                  items="$str"
                else
                  items="$items $str"
                fi
                ;;
              *)
                IFS="$save_ifs"
                echo "resolve-model: malformed config in $toml_file:$lineno: array items must be double-quoted strings: '$elem'" >&2
                return 2
                ;;
            esac
          done
          IFS="$save_ifs"
        fi
        printf '%s.%s=%s\n' "$current_section" "$key" "$items"
        ;;
      \[*)
        echo "resolve-model: malformed config in $toml_file:$lineno: multi-line array or malformed array: '$val'" >&2
        return 2
        ;;
      *)
        case "$val" in
          ""|*[!0-9]*)
            echo "resolve-model: malformed config in $toml_file:$lineno: unsupported value type or trailing comment: '$val'" >&2
            return 2
            ;;
          *)
            printf '%s.%s=%s\n' "$current_section" "$key" "$val"
            ;;
        esac
        ;;
    esac
  done < "$toml_file"

  return 0
}

_resolve_model_get_val() {
  local target_key="$1"
  local flat_data="$2"
  printf '%s\n' "$flat_data" | sed -n "s/^${target_key}=//p" | head -1
}

# Resolve candidate config file path (first existing wins)
resolve_config_path() {
  local dir="${1:-$PWD}"
  [ -d "$dir" ] || return 1
  dir="$(cd "$dir" && pwd)"

  local candidate
  for candidate in "$dir/.claude/agy.toml" "$dir/agy.toml" "$HERE/../agy.toml"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}

resolve_model() {
  local tier=""
  local phase=""
  local dir="$PWD"
  local want_fallbacks=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --tier)      tier="$2"; shift 2 ;;
      --phase)     phase="$2"; shift 2 ;;
      --dir)       dir="$2"; shift 2 ;;
      --fallbacks) want_fallbacks=1; shift ;;
      -h|--help)   sed -n '2,20p' "$0"; return 0 2>/dev/null || exit 0 ;;
      -*)          echo "resolve-model: unknown arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
      *)           echo "resolve-model: unexpected arg $1" >&2; return 2 2>/dev/null || exit 2 ;;
    esac
  done

  [ -d "$dir" ] || { echo "resolve-model: dir not found: $dir" >&2; return 2 2>/dev/null || exit 2; }
  dir="$(cd "$dir" && pwd)"

  local config_file=""
  local parsed=""

  if config_file="$(resolve_config_path "$dir")"; then
    parsed="$(_resolve_model_parse_toml "$config_file")"
    local prc=$?
    if [ "$prc" -ne 0 ]; then
      return "$prc" 2>/dev/null || exit "$prc"
    fi
  else
    config_file=""
  fi

  if [ "$want_fallbacks" -eq 1 ]; then
    local fb=""
    if [ -n "$phase" ]; then
      fb="$(_resolve_model_get_val "phases.${phase}.fallbacks" "$parsed")"
    fi
    if [ -n "$fb" ]; then
      local m
      for m in $fb; do
        printf '%s\n' "$m"
      done
      return 0 2>/dev/null || exit 0
    else
      # If no explicit fallbacks configured, fall back to resolved primary model
      local primary
      primary="$(resolve_model ${tier:+--tier "$tier"} ${phase:+--phase "$phase"} --dir "$dir" 2>/dev/null)" || return $?
      printf '%s\n' "$primary"
      return 0 2>/dev/null || exit 0
    fi
  fi

  local model=""
  local decision=""

  if [ -n "$tier" ]; then
    local lookup_val=""
    if [ -n "$parsed" ]; then
      lookup_val="$(_resolve_model_get_val "tiers.${tier}" "$parsed")"
    fi

    if [ -z "$lookup_val" ]; then
      case "$tier" in
        low)    lookup_val="gemini-3.7-flash-low" ;;
        medium) lookup_val="gemini-3.7-flash-medium" ;;
        high)   lookup_val="gemini-3.7-flash-high" ;;
      esac
    fi

    if [ -n "$lookup_val" ]; then
      model="$lookup_val"
      if [ -n "$config_file" ] && printf '%s\n' "$parsed" | grep -q "^tiers\.${tier}="; then
        decision="$config_file ([tiers].$tier)"
      else
        decision="built-in default (tier $tier)"
      fi
    else
      case "$tier" in
        *-*|*.*|*:*|*[0-9]*)
          model="$tier"
          decision="raw model id passed via --tier"
          ;;
        *)
          echo "resolve-model: unknown tier '$tier'" >&2
          return 2 2>/dev/null || exit 2
          ;;
      esac
    fi
  elif [ -n "$phase" ]; then
    local phase_tier=""
    if [ -n "$parsed" ]; then
      phase_tier="$(_resolve_model_get_val "phases.${phase}.tier" "$parsed")"
    fi

    if [ -n "$phase_tier" ]; then
      local lookup_val=""
      if [ -n "$parsed" ]; then
        lookup_val="$(_resolve_model_get_val "tiers.${phase_tier}" "$parsed")"
      fi
      if [ -z "$lookup_val" ]; then
        case "$phase_tier" in
          low)    lookup_val="gemini-3.7-flash-low" ;;
          medium) lookup_val="gemini-3.7-flash-medium" ;;
          high)   lookup_val="gemini-3.7-flash-high" ;;
          *-*|*.*|*:*|*[0-9]*) lookup_val="$phase_tier" ;;
          *)
            echo "resolve-model: unknown tier '$phase_tier' for phase $phase" >&2
            return 2 2>/dev/null || exit 2
            ;;
        esac
      fi
      model="$lookup_val"
      decision="$config_file ([phases.$phase].tier = $phase_tier)"
    else
      local default_tier="medium"
      case "$phase" in
        REVIEW)    default_tier="high" ;;
        DISCOVERY) default_tier="low" ;;
      esac
      local lookup_val=""
      if [ -n "$parsed" ]; then
        lookup_val="$(_resolve_model_get_val "tiers.${default_tier}" "$parsed")"
      fi
      if [ -z "$lookup_val" ]; then
        case "$default_tier" in
          low)    lookup_val="gemini-3.7-flash-low" ;;
          medium) lookup_val="gemini-3.7-flash-medium" ;;
          high)   lookup_val="gemini-3.7-flash-high" ;;
        esac
      fi
      model="$lookup_val"
      if [ -n "$config_file" ] && printf '%s\n' "$parsed" | grep -q "^tiers\.${default_tier}="; then
        decision="$config_file (default tier $default_tier -> [tiers].$default_tier)"
      else
        decision="built-in default (phase $phase -> tier $default_tier)"
      fi
    fi
  else
    local lookup_val=""
    if [ -n "$parsed" ]; then
      lookup_val="$(_resolve_model_get_val "tiers.medium" "$parsed")"
    fi
    if [ -z "$lookup_val" ]; then
      lookup_val="gemini-3.7-flash-medium"
      decision="built-in default (tier medium)"
    else
      decision="$config_file ([tiers].medium)"
    fi
    model="$lookup_val"
  fi

  echo "resolve-model: resolved '$model' from $decision" >&2
  printf '%s\n' "$model"
  return 0 2>/dev/null || exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  resolve_model "$@"
  exit $?
fi
