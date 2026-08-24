#!/usr/bin/env zsh
# files.sh — in-place line editing and timestamped file backup/restore.
#
# Depends on: lib/text.sh (path_shorten) — optional, degrades gracefully.

# Internal: display helper that works with or without lib/text.sh loaded.
function _files_disp() {
  if (( ${+functions[path_shorten]} )); then
    path_shorten --plain "$1"
  else
    print -r -- "$1"
  fi
}

# ---------------------------------------------------------------------------
# update_line [--dry-run] <before|replace|after|delete> <keyword> [new_line] <file> [file ...]
#
# Edit every line containing <keyword> in each file, in place. Indentation of
# inserted lines is inferred from the surrounding lines. <new_line> is omitted
# in delete mode.
# ---------------------------------------------------------------------------
function update_line() {
  setopt local_options err_return nounset

  local -r usage="Usage: update_line [--dry-run] <mode> <keyword> [new_line] <file> [file ...]

Modes:
  before    insert <new_line> above every line containing <keyword>
  replace   replace every line containing <keyword> with <new_line>
  after     insert <new_line> below every line containing <keyword>
  delete    remove every line containing <keyword>  (<new_line> is omitted)

Options:
  --dry-run   show what would change; write nothing

<keyword> is matched as a plain substring, not a regex. Inserted lines inherit
the indentation of the neighbouring line with the deeper indent.

Examples:
  update_line replace 'timeout=' 'timeout=30' app.conf
  update_line after '[core]' '  autocrlf = input' ~/.gitconfig
  update_line --dry-run delete 'DEPRECATED' src/*.py"

  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && { dry_run=1; shift; }
  [[ "${1:-}" == (-h|--help) ]] && { print -r -- "$usage"; return 0; }

  (( $# < 3 )) && { print -r -- "$usage" >&2; return 2; }

  local -r mode="$1" keyword="$2"
  shift 2

  case "$mode" in
    before|replace|after|delete) ;;
    *) print -P "%F{red}update_line: invalid mode '$mode'%f" >&2
       print -r -- "$usage" >&2; return 2 ;;
  esac

  local new_line=""
  if [[ "$mode" != "delete" ]]; then
    new_line="$1"; shift
  fi

  local -a files=("$@")
  (( ${#files[@]} )) || { print -P "%F{red}update_line: no files given%f" >&2; return 2; }
  [[ -n "$keyword" ]] || { print -P "%F{red}update_line: empty keyword%f" >&2; return 2; }

  local file tmp hits
  local -i failed=0
  for file in "${files[@]}"; do
    if [[ ! -f "$file" ]]; then
      print -P "%F{red}File not found: $(_files_disp "$file")%f" >&2; (( failed += 1 )); continue
    fi
    if (( ! dry_run )) && [[ ! -w "$file" ]]; then
      print -P "%F{red}No write permission for $(_files_disp "$file")%f" >&2; (( failed += 1 )); continue
    fi

    hits=$(grep -c -F -- "$keyword" "$file" 2>/dev/null) || hits=0
    if (( hits == 0 )); then
      print -P "%F{yellow}No match for '$keyword' in $(_files_disp "$file") — skipped%f" >&2
      continue
    fi

    tmp="${file}.update_line.$$"

    case "$mode" in
      before)
        awk -v kw="$keyword" -v nl="$new_line" '
          {
            curr_indent = match($0, /^[ \t]*/) ? substr($0, RSTART, RLENGTH) : ""
            insert_indent = (length(prev_indent) > length(curr_indent)) ? prev_indent : curr_indent
            if (index($0, kw) > 0) print insert_indent nl
            print $0
            prev_indent = curr_indent
          }' "$file" > "$tmp" || { rm -f "$tmp"; (( failed += 1 )); continue; }
        ;;
      replace)
        awk -v kw="$keyword" -v nl="$new_line" '
          {
            indent = match($0, /^[ \t]*/) ? substr($0, RSTART, RLENGTH) : ""
            if (index($0, kw) > 0) print indent nl; else print $0
          }' "$file" > "$tmp" || { rm -f "$tmp"; (( failed += 1 )); continue; }
        ;;
      after)
        awk -v kw="$keyword" -v nl="$new_line" '
          { lines[NR] = $0
            indents[NR] = match($0, /^[ \t]*/) ? substr($0, RSTART, RLENGTH) : "" }
          END {
            for (i = 1; i <= NR; i++) {
              print lines[i]
              if (index(lines[i], kw) > 0) {
                indent1 = indents[i]
                indent2 = (i + 1 <= NR) ? indents[i+1] : ""
                print ((length(indent2) > length(indent1)) ? indent2 : indent1) nl
              }
            }
          }' "$file" > "$tmp" || { rm -f "$tmp"; (( failed += 1 )); continue; }
        ;;
      delete)
        awk -v kw="$keyword" 'index($0, kw) == 0' "$file" > "$tmp" \
          || { rm -f "$tmp"; (( failed += 1 )); continue; }
        ;;
    esac

    if (( dry_run )); then
      print -P "%F{cyan}--- would ${mode} (${hits} match(es)) in $(_files_disp "$file")%f"
      diff -u "$file" "$tmp" | tail -n +3 || true
      rm -f "$tmp"
    else
      mv "$tmp" "$file" || { rm -f "$tmp"; (( failed += 1 )); continue; }
      print -P "%F{green}${mode}: ${hits} match(es) for '$keyword' in $(_files_disp "$file")%f"
    fi
  done

  return $failed
}

# ---------------------------------------------------------------------------
# rcfile_backup [file] [backup_dir]
# Copy <file> into <backup_dir> with a YYYY_MM_DD suffix.
# Defaults: ~/.zshrc  ->  ~/.rc_backups/
# ---------------------------------------------------------------------------
function rcfile_backup() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: rcfile_backup [file] [backup_dir]
Copy [file] into [backup_dir], suffixed with the current date.

  file         default: ~/.zshrc
  backup_dir   default: ~/.rc_backups

Example: rcfile_backup ~/.vimrc ~/dotfile-backups"
    return 0
  }

  local -r src="${1:-$HOME/.zshrc}"
  local -r dir="${2:-$HOME/.rc_backups}"

  [[ -f "$src" && -r "$src" ]] || {
    print -P "%F{red}rcfile_backup: no readable file at $src%f" >&2; return 1; }
  mkdir -p "$dir" || {
    print -P "%F{red}rcfile_backup: cannot create $dir%f" >&2; return 1; }

  local -r dest="$dir/${src:t}_$(date +%Y_%m_%d).backup"
  cp -p "$src" "$dest" || {
    print -P "%F{red}rcfile_backup: copy to $dest failed%f" >&2; return 1; }
  print -P "%F{green}Backed up $(_files_disp "$src") -> $(_files_disp "$dest")%f"
}

# ---------------------------------------------------------------------------
# rcfile_restore <backup_file> [target]
# Restore <backup_file> over [target], taking a timestamped safety copy of the
# current target first. Prompts before overwriting.
# Default target: ~/.zshrc
# ---------------------------------------------------------------------------
function rcfile_restore() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: rcfile_restore <backup_file> [target]
Restore <backup_file> over [target] after taking a timestamped safety copy of
the current [target]. Prompts for confirmation.

  target   default: ~/.zshrc

Example: rcfile_restore ~/.rc_backups/.zshrc_2026_08_01.backup"
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r backup="$1"
  local -r target="${2:-$HOME/.zshrc}"

  [[ -f "$backup" && -r "$backup" ]] || {
    print -P "%F{red}rcfile_restore: backup not found: $backup%f" >&2; return 1; }

  if [[ -f "$target" ]]; then
    local -r safety="${target}_$(date +%Y_%m_%d_%H%M%S).backup"
    cp -p "$target" "$safety" || {
      print -P "%F{red}rcfile_restore: could not save current $target%f" >&2; return 1; }
    print -P "%F{cyan}Current $(_files_disp "$target") saved to $(_files_disp "$safety")%f"
  fi

  local reply=""
  print -n "Restore '$backup' over '$target'? (y/N): " >&2
  read -r reply || true
  [[ "$reply" == [Yy]* ]] || { print -P "%F{yellow}Restore cancelled.%f" >&2; return 1; }

  cp "$backup" "$target" || {
    print -P "%F{red}rcfile_restore: restore failed%f" >&2; return 1; }
  print -P "%F{green}Restored $(_files_disp "$target") from $(_files_disp "$backup")%f"
}
