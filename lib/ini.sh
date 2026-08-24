#!/usr/bin/env zsh
# ini.sh — INI file inspection.

# ---------------------------------------------------------------------------
# ini_keys [-s "section1 section2 ..."] <file.ini>
# Print the key names of an INI file, one per line. With -s, only keys inside
# the named sections are printed. Comments (# and ;) and valueless lines are
# skipped.
# ---------------------------------------------------------------------------
function ini_keys() {
  setopt local_options err_return nounset

  local -r usage="Usage: ini_keys [-s 'section1 section2 ...'] <file.ini>
Print the key names of an INI file, one per line.

  -s LIST   space-separated list of section names to restrict output to
            (default: every section)

Examples:
  ini_keys config.ini
  ini_keys -s 'Database Cache' config.ini"

  [[ "${1:-}" == (-h|--help) ]] && { print -r -- "$usage"; return 0; }

  local -A opts
  zparseopts -D -A opts s: || { print -r -- "$usage" >&2; return 1; }

  (( $# == 1 )) || { print -r -- "$usage" >&2; return 1; }
  [[ -f "$1" && -r "$1" ]] || {
    print -P "%F{red}ini_keys: file not found or unreadable: $1%f" >&2
    print -r -- "$usage" >&2
    return 1
  }

  awk -v secs_str="${opts[-s]:-}" -F'=' '
    BEGIN {
      if (length(secs_str) > 0) {
        n = split(secs_str, temp, /[[:space:]]+/)
        for (i = 1; i <= n; i++) if (temp[i] != "") target_secs[temp[i]] = 1
        filter_by_section = 1
      } else {
        filter_by_section = 0
      }
    }
    # Section header:  [name]
    /^[[:space:]]*\[[^]]+\]/ {
      match($0, /\[[^]]+\]/)
      current_sec = substr($0, RSTART + 1, RLENGTH - 2)
      next
    }
    # key=value, skipping comments and lines with no "="
    /^[[:space:]]*[^#;[:space:]=]+/ && /=/ {
      if (filter_by_section && !(current_sec in target_secs)) next
      key = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      print key
    }
  ' "$1"
}
