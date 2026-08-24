#!/usr/bin/env zsh
# core.sh — path/file assertions, array helpers, arithmetic, set comparison.
#
# Source with:  source /path/to/lib/core.sh

# ---------------------------------------------------------------------------
# check_dirs <dir> [dir ...]
# Assert every argument is an existing, readable directory.
# Returns the NUMBER of failures (0 = all good), so callers can `|| return`.
# ---------------------------------------------------------------------------
function check_dirs() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -eq 0 ]] && {
    print -r -- "Usage: check_dirs <dir> [dir ...]
Assert every path exists, is a directory, and is readable.
Exit status: number of paths that failed (0 = all passed)."
    return $(( $# == 0 ? 2 : 0 ))
  }
  local failed=0 dir
  for dir in "$@"; do
    if [[ ! -e "$dir" ]]; then
      print -P "%F{red}Directory does not exist: $dir%f" >&2; (( failed += 1 )); continue
    fi
    [[ ! -d "$dir" ]] && { print -P "%F{red}Not a directory: $dir%f" >&2; (( failed += 1 )); }
    [[ ! -r "$dir" ]] && { print -P "%F{red}Directory not readable: $dir%f" >&2; (( failed += 1 )); }
  done
  return $failed
}

# ---------------------------------------------------------------------------
# check_any_dir <dir> [dir ...]
# Passes when AT LEAST ONE argument is a readable directory. Use where a thing
# may live in one of several trees but need not be in all of them.
# ---------------------------------------------------------------------------
function check_any_dir() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -eq 0 ]] && {
    print -r -- "Usage: check_any_dir <dir> [dir ...]
Succeed if at least one path is a readable directory."
    return $(( $# == 0 ? 2 : 0 ))
  }
  local dir
  for dir in "$@"; do
    [[ -d "$dir" && -r "$dir" ]] && return 0
  done
  print -P "%F{red}None of these exist as readable directories: $*%f" >&2
  return 1
}

# ---------------------------------------------------------------------------
# check_files <file> [file ...]
# Assert every argument is an existing, readable regular file.
# Returns the NUMBER of failures.
# ---------------------------------------------------------------------------
function check_files() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -eq 0 ]] && {
    print -r -- "Usage: check_files <file> [file ...]
Assert every path exists, is a regular file, and is readable.
Exit status: number of paths that failed (0 = all passed)."
    return $(( $# == 0 ? 2 : 0 ))
  }
  local failed=0 file
  for file in "$@"; do
    if [[ ! -e "$file" ]]; then
      print -P "%F{red}File does not exist: $file%f" >&2; (( failed += 1 )); continue
    fi
    [[ ! -f "$file" ]] && { print -P "%F{red}Not a file: $file%f" >&2; (( failed += 1 )); }
    [[ ! -r "$file" ]] && { print -P "%F{red}File not readable: $file%f" >&2; (( failed += 1 )); }
  done
  return $failed
}

# ---------------------------------------------------------------------------
# is_array_empty_or_whitespace <elem> [elem ...]
# True when the argument list is empty or every element is blank.
# ---------------------------------------------------------------------------
function is_array_empty_or_whitespace() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: is_array_empty_or_whitespace <elem> [elem ...]
True (0) when no elements are given, or all elements are empty/whitespace."
    return 0
  }
  local elem
  for elem in "$@"; do
    [[ "$elem" == *[^[:space:]]* ]] && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# run_script <script_name> [args ...]
# Resolve a script by PATH lookup and exec it. Fails loudly when not found,
# rather than the silent "command not found" of a bare call.
# ---------------------------------------------------------------------------
function run_script() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: run_script <script_name> [args ...]
Resolve <script_name> via PATH and execute it with the remaining arguments."
    return $(( $# < 1 ? 2 : 0 ))
  }
  local cmd
  cmd=$(whence -p "$1") || cmd=""
  [[ -n "$cmd" ]] || { print -P "%F{red}run_script: '$1' not found in PATH%f" >&2; return 1; }
  shift
  "$cmd" "$@"
}

# ---------------------------------------------------------------------------
# calc_bc <expression>
# Float arithmetic via bc, rounded to 2 decimal places.
# ---------------------------------------------------------------------------
function calc_bc() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: calc_bc <expression>
Evaluate <expression> with bc (scale=4) and print it rounded to 2 decimals.
Example: calc_bc '100 * 7 / 9'   ->  77.78"
    return $(( $# < 1 ? 2 : 0 ))
  }
  print -r -- "scale=4; $1" | bc -l | awk '{printf "%.2f\n", $1}'
}

# ---------------------------------------------------------------------------
# pct_of <part> <whole>        — what percentage <part> is of <whole>
# pct_change <from> <to>       — percentage change from <from> to <to>
# ---------------------------------------------------------------------------
function pct_of() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -ne 2 ]] && {
    print -r -- "Usage: pct_of <part> <whole>
Print <part> as a percentage of <whole>.  Example: pct_of 7 9  ->  7 / 9 = 77.78%"
    return $(( $# == 2 ? 0 : 2 ))
  }
  print -r -- "$1 / $2 = $(calc_bc "100 * $1 / $2")%"
}

function pct_change() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -ne 2 ]] && {
    print -r -- "Usage: pct_change <from> <to>
Print the percentage change from <from> to <to>.
Example: pct_change 80 100  ->  80 -> 100 = 25.00%"
    return $(( $# == 2 ? 0 : 2 ))
  }
  print -r -- "$1 -> $2 = $(calc_bc "100 * ($2 - $1) / $1")%"
}

# ---------------------------------------------------------------------------
# uniq_compare <comm-flags> <file1> <file2> [output_file]
# Thin `comm` wrapper that sorts and de-duplicates both inputs first, so it
# works on unsorted files. Writes atomically when <output_file> is given.
# ---------------------------------------------------------------------------
function uniq_compare() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: uniq_compare <comm-flags> <file1> <file2> [output_file]
Sort -u both files and compare them with comm -<flags>.

  <comm-flags>  digits passed straight to comm (each digit SUPPRESSES a
                column), giving:
                  12  lines common to both files
                  13  lines unique to <file2>
                  23  lines unique to <file1>
Writes to stdout, or atomically to [output_file] when given.

Example: uniq_compare 23 old.txt new.txt only-in-old.txt"
    return 0
  }
  if (( $# < 3 || $# > 4 )); then
    print -P "%F{red}Usage: uniq_compare <comm-flags> <file1> <file2> [output_file]%f" >&2
    return 2
  fi
  check_files "$2" "$3" || return 2

  if (( $# == 4 )) && [[ -n "$4" ]]; then
    local -r tmpfile="${4}.tmp.$$"
    if comm -"$1" <(sort -u "$2") <(sort -u "$3") > "$tmpfile"; then
      mv "$tmpfile" "$4"
    else
      print -P "%F{red}uniq_compare: comm failed%f" >&2
      rm -f "$tmpfile"
      return 1
    fi
  else
    comm -"$1" <(sort -u "$2") <(sort -u "$3")
  fi
}

# ---------------------------------------------------------------------------
# wsl_interop_ok
# True when running under WSL *and* Windows interop (binfmt_misc) actually
# works. Result is cached in _WSL_INTEROP_OK for the life of the shell, because
# the probe costs a process spawn.
# ---------------------------------------------------------------------------
function wsl_interop_ok() {
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: wsl_interop_ok
Succeed when running under WSL with working Windows interop.
Caches the probe result in \$_WSL_INTEROP_OK.
Override the probe binary with \$WSL_INTEROP_PROBE."
    return 0
  }
  local -r probe="${WSL_INTEROP_PROBE:-/mnt/c/Windows/System32/cmd.exe}"
  if [[ -z "${_WSL_INTEROP_OK:-}" ]]; then
    if [[ -n "${WSL_DISTRO_NAME:-${WSL_INTEROP:-}}" ]] \
       && [[ -x "$probe" ]] \
       && "$probe" /c rem >/dev/null 2>&1; then
      typeset -gi _WSL_INTEROP_OK=1
    else
      typeset -gi _WSL_INTEROP_OK=0
    fi
  fi
  (( _WSL_INTEROP_OK ))
}
