#!/usr/bin/env zsh
# clipboard.sh — clipboard copy/paste that degrades through every backend.
#
# Oh My Zsh ships its own clipcopy/clippaste. If you use both, source this
# AFTER oh-my-zsh.sh so these definitions win — OMZ installs a lazy stub that
# would otherwise overwrite them on first call.
#
# Backends are tried in order and the first that works wins:
#   WSL interop (clip.exe / powershell.exe) -> Wayland -> X11 -> tmux -> OSC 52
#
# The WSL probe matters: when binfmt_misc interop is unregistered, calling
# clip.exe fails with "exec format error" rather than a clean non-zero, which
# is why wsl_interop_ok (lib/core.sh) gates it. Without core.sh loaded the WSL
# path is simply skipped.
#
# OSC 52 is the last resort: it asks the terminal emulator itself to set the
# clipboard, so it works over SSH with no local helper installed — provided
# the terminal has it enabled.

# ---------------------------------------------------------------------------
# clipcopy [file]
# Copy <file>, or stdin when no file is given, to the system clipboard.
# ---------------------------------------------------------------------------
function clipcopy() {
  emulate -L zsh
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: clipcopy [file]
Copy [file] — or stdin when no file is given — to the system clipboard.

Tries, in order: WSL interop, Wayland (wl-copy), X11 (xclip, xsel), tmux
buffer, then OSC 52 to the terminal. Returns non-zero and warns once if no
backend works."
    return 0
  }

  local input
  if (( $# > 0 )) && [[ -e "$1" ]]; then
    input=$(<"$1")
  else
    input=$(cat -)
  fi

  if (( ${+functions[wsl_interop_ok]} )) && wsl_interop_ok && (( ${+commands[clip.exe]} )); then
    print -rn -- "$input" | clip.exe 2>/dev/null && return 0
  fi
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && (( ${+commands[wl-copy]} )); then
    print -rn -- "$input" | wl-copy 2>/dev/null && return 0
  fi
  if [[ -n "${DISPLAY:-}" ]] && (( ${+commands[xclip]} )); then
    print -rn -- "$input" | xclip -selection clipboard -in 2>/dev/null && return 0
  fi
  if [[ -n "${DISPLAY:-}" ]] && (( ${+commands[xsel]} )); then
    print -rn -- "$input" | xsel --clipboard --input 2>/dev/null && return 0
  fi
  if [[ -n "${TMUX:-}" ]]; then
    print -rn -- "$input" | tmux load-buffer - 2>/dev/null && return 0
  fi
  if [[ -t 2 ]] && (( ${+commands[base64]} )); then
    local b64
    b64=$(print -rn -- "$input" | base64 -w0 2>/dev/null) \
      || b64=$(print -rn -- "$input" | base64 2>/dev/null | tr -d '\n')
    [[ -n "$b64" ]] && printf '\033]52;c;%s\a' "$b64" >/dev/tty 2>/dev/null && return 0
  fi

  # Warn once per shell — a failing clipboard in a loop shouldn't spam.
  if [[ -z "${_CLIPCOPY_WARNED:-}" ]]; then
    typeset -g _CLIPCOPY_WARNED=1
    print -P "%F{yellow}clipcopy: no working clipboard backend (install wl-copy, xclip or xsel)%f" >&2
  fi
  return 1
}

# ---------------------------------------------------------------------------
# clippaste
# Print the clipboard contents to stdout.
# ---------------------------------------------------------------------------
function clippaste() {
  emulate -L zsh
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: clippaste
Print the system clipboard to stdout.

Tries, in order: WSL interop, Wayland (wl-paste), X11 (xclip, xsel), then the
tmux buffer. Returns non-zero when no backend works.
Note: OSC 52 is write-only, so there is no terminal fallback for reading."
    return 0
  }

  if (( ${+functions[wsl_interop_ok]} )) && wsl_interop_ok && (( ${+commands[powershell.exe]} )); then
    powershell.exe -noprofile -command Get-Clipboard 2>/dev/null && return 0
  fi
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && (( ${+commands[wl-paste]} )); then
    wl-paste --no-newline 2>/dev/null && return 0
  fi
  if [[ -n "${DISPLAY:-}" ]] && (( ${+commands[xclip]} )); then
    xclip -out -selection clipboard 2>/dev/null && return 0
  fi
  if [[ -n "${DISPLAY:-}" ]] && (( ${+commands[xsel]} )); then
    xsel --clipboard --output 2>/dev/null && return 0
  fi
  if [[ -n "${TMUX:-}" ]]; then
    tmux save-buffer - 2>/dev/null && return 0
  fi
  return 1
}
