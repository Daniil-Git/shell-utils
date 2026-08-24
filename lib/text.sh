#!/usr/bin/env zsh
# text.sh — string, map and path-display helpers.
#
# path_shorten colourises only when stdout is a terminal, so its output stays
# safe to capture in a variable.

# ---------------------------------------------------------------------------
# path_shorten [--plain] <path>
# Print <path> with long known prefixes replaced by short aliases.
#
# Configure by setting PATH_SHORTEN_MAP before calling — longest prefix wins:
#     typeset -gA PATH_SHORTEN_MAP=( "$HOME/work/projects" '~/pr' )
# $HOME -> ~ is always applied last as a fallback.
# ---------------------------------------------------------------------------
function path_shorten() {
  setopt local_options err_return nounset
  local plain=0
  [[ "${1:-}" == "--plain" ]] && { plain=1; shift; }
  [[ "${1:-}" == (-h|--help) || $# -ne 1 ]] && {
    print -r -- "Usage: path_shorten [--plain] <path>
Replace known long prefixes in <path> with short aliases.

  --plain   never colourise (also implied when stdout is not a terminal)

Configure via the associative array PATH_SHORTEN_MAP (longest prefix wins):
  typeset -gA PATH_SHORTEN_MAP=( \"\$HOME/work/projects\" '~/pr' )
\$HOME -> ~ is applied as a fallback."
    return $(( $# == 1 ? 0 : 2 ))
  }

  local -r local_path="$1"
  local out="$local_path" prefix best=""

  if (( ${+PATH_SHORTEN_MAP} )); then
    # Longest matching prefix wins, so nested roots behave predictably.
    for prefix in ${(k)PATH_SHORTEN_MAP}; do
      [[ -n "$prefix" && "$local_path" == "$prefix"* ]] || continue
      (( ${#prefix} > ${#best} )) && best="$prefix"
    done
    [[ -n "$best" ]] && out="${PATH_SHORTEN_MAP[$best]}${local_path#$best}"
  fi

  if [[ -z "$best" && -n "${HOME:-}" && "$local_path" == "$HOME"* ]]; then
    out="~${local_path#$HOME}"
  fi

  if (( plain )) || [[ ! -t 1 ]]; then
    print -r -- "$out"
  else
    print -rP -- "%F{cyan}${out}%f"
  fi
}

# ---------------------------------------------------------------------------
# map_case <reference> <target>
# Copy the per-character upper/lower case pattern of <reference> onto <target>.
# Characters beyond the length of <reference> are left untouched.
# ---------------------------------------------------------------------------
function map_case() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -ne 2 ]] && {
    print -r -- "Usage: map_case <reference> <target>
Apply the upper/lower case pattern of <reference> to <target>, character by
character. Characters past the end of <reference> are left as-is.

Example: map_case 'FooBAR' 'bazqux'  ->  BazQUX"
    return $(( $# == 2 ? 0 : 2 ))
  }

  local -r before="$1" after="$2"
  local result="" char_before char_after
  local -i cnt

  for (( cnt = 1; cnt <= ${#after}; cnt++ )); do
    char_after="${after[cnt]}"
    if (( cnt <= ${#before} )); then
      char_before="${before[cnt]}"
      if [[ "$char_before" == [[:upper:]] ]]; then
        char_after="${char_after:u}"
      elif [[ "$char_before" == [[:lower:]] ]]; then
        char_after="${char_after:l}"
      fi
    fi
    result+="$char_after"
  done

  print -r -- "$result"
}

# ---------------------------------------------------------------------------
# map_normalize <map_name>
# Strip quotes, trailing slashes and embedded newlines from every key and value
# of the named associative array, in place. A key or value that is exactly "/"
# is preserved (stripping it would yield an empty string).
# ---------------------------------------------------------------------------
function map_normalize() {
  setopt local_options nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: map_normalize <map_name>
Normalise an associative array in place: removes quotes, embedded newlines and
one trailing slash from every key and value. Pass the array NAME, not its value.

Example:
  typeset -A m=( '\"/tmp/a/\"' '\"x\"' )
  map_normalize m      # -> key /tmp/a, value x"
    return $(( $# < 1 ? 3 : 0 ))
  }

  local -r map_name="$1"
  [[ "${(tP)map_name}" == association* ]] || {
    print -P "%F{red}map_normalize: '$map_name' is not an associative array (got '${(tP)map_name}')%f" >&2
    return 4
  }

  local -a normalized_pairs
  local key value new_key new_value
  for key value in "${(@Pkv)map_name}"; do
    new_key="$key"; new_value="$value"
    [[ "$key"   != "/" ]] && new_key=${${key//[\"\']/}%%/}
    [[ "$value" != "/" ]] && new_value=${${value//[\"\']/}%%/}
    new_key=${new_key//$'\n'/}
    new_value=${new_value//$'\n'/}
    normalized_pairs+=("$new_key" "$new_value")
  done

  set -A "$map_name" "${(@)normalized_pairs}"
}

# ---------------------------------------------------------------------------
# prompt_overwrite <default>
# Prompt on stderr for a replacement string; echo <default> when the user just
# presses Enter. The chosen value goes to stdout so it is safely capturable.
# ---------------------------------------------------------------------------
function prompt_overwrite() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: prompt_overwrite <default>
Prompt (on stderr) for a replacement value and print the result on stdout.
An empty reply keeps <default>.

Example: msg=\$(prompt_overwrite 'initial commit')"
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r msg="$1"
  local new_msg=""
  print -P "%F{white}New value (Enter = keep '$msg'):%f" >&2
  read -r "?> " new_msg || true
  new_msg="${new_msg#"${new_msg%%[![:space:]]*}"}"
  new_msg="${new_msg%"${new_msg##*[![:space:]]}"}"
  [[ -n "$new_msg" ]] && print -r -- "$new_msg" || print -r -- "$msg"
}
