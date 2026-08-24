#!/usr/bin/env zsh
# secrets.sh — GPG-symmetric secret store for shell environments.
#
# One store, namespaced per service, so adding a service costs no new code.
#
# Secrets live at rest ONLY as gpg AES256 ciphertext, under:
#     $SECRET_STORE_DIR/<namespace>/.env.gpg
# defaulting to ${XDG_DATA_HOME:-$HOME/.local/share}/secret-store
#
# Non-interactive use: set <PREFIX>_GPG_PASSPHRASE_FILE to a file containing the
# passphrase, where <PREFIX> is the uppercased namespace (e.g. FORGE). gpg-agent
# and pinentry are deliberately bypassed — they fail with "Inappropriate ioctl
# for device" when GPG_TTY is unset in cron and other headless contexts.

: ${SECRET_STORE_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/secret-store}

# Internal: uppercase a namespace into an env-var prefix ('forge' -> 'FORGE').
function _secret_prefix() { print -r -- "${${1//[^A-Za-z0-9]/_}:u}"; }

# ---------------------------------------------------------------------------
# gpg_passphrase <prefix> [confirm]
# Print a gpg passphrase on stdout. Sources it from the file named by
# <PREFIX>_GPG_PASSPHRASE_FILE when set, otherwise prompts on /dev/tty (which
# works even when stdin is a pipe). "confirm" asks twice and requires a match.
# ---------------------------------------------------------------------------
function gpg_passphrase() {
  emulate -L zsh
  setopt local_options
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: gpg_passphrase <prefix> [confirm]
Print a gpg passphrase on stdout.

  prefix    names the env var <PREFIX>_GPG_PASSPHRASE_FILE to read from
  confirm   prompt twice and require both entries to match

Falls back to a hidden prompt on /dev/tty. Never uses gpg-agent or pinentry."
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r pfx="$(_secret_prefix "$1")" mode="${2:-}"
  local p="" p2="" envvar="${pfx}_GPG_PASSPHRASE_FILE"

  if [[ -n "${(P)envvar:-}" && -r "${(P)envvar}" ]]; then
    p="$(<"${(P)envvar}")"; p="${p%%$'\n'*}"
    [[ -n "$p" ]] || { print -P "%F{red}gpg_passphrase: ${envvar} is empty.%f" >&2; return 1; }
    print -r -- "$p"; return 0
  fi

  [[ -r /dev/tty ]] || {
    print -P "%F{red}gpg_passphrase: no /dev/tty — set ${envvar} for non-interactive use.%f" >&2
    return 1; }

  print -n "GPG passphrase: " >/dev/tty
  IFS= read -rs p </dev/tty; print "" >/dev/tty
  [[ -n "$p" ]] || { print -P "%F{red}gpg_passphrase: empty passphrase.%f" >&2; return 1; }

  if [[ "$mode" == confirm ]]; then
    print -n "Confirm passphrase: " >/dev/tty
    IFS= read -rs p2 </dev/tty; print "" >/dev/tty
    [[ "$p" == "$p2" ]] || { print -P "%F{red}gpg_passphrase: passphrases do not match.%f" >&2; return 1; }
  fi
  print -r -- "$p"
}

# ---------------------------------------------------------------------------
# secret_path <namespace>
# Print the encrypted store path for a namespace.
# ---------------------------------------------------------------------------
function secret_path() {
  emulate -L zsh
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: secret_path <namespace>
Print the ciphertext path for <namespace> (\$SECRET_STORE_DIR/<namespace>/.env.gpg)."
    return $(( $# < 1 ? 2 : 0 ))
  }
  print -r -- "${SECRET_STORE_DIR%/}/$1/.env.gpg"
}

# ---------------------------------------------------------------------------
# secret_store <namespace> <VAR_NAME> [value]
# Encrypt `export VAR_NAME=<value>` into the namespace's store, atomically.
# Reads the value from stdin when not given as an argument, so it never lands
# in shell history, argv, or `ps` output. Plaintext temp files are shredded.
# ---------------------------------------------------------------------------
function secret_store() {
  emulate -L zsh
  setopt local_options err_return pipe_fail
  [[ "${1:-}" == (-h|--help) || $# -lt 2 ]] && {
    print -r -- "Usage: secret_store <namespace> <VAR_NAME> [value]
Encrypt 'export VAR_NAME=<value>' to \$SECRET_STORE_DIR/<namespace>/.env.gpg
using gpg symmetric AES256.

Reads <value> from stdin when omitted, keeping it out of history and argv:
  printf '%s' \"\$tok\" | secret_store forge FORGE_TOKEN

Any plaintext .env beside the ciphertext is shredded afterwards."
    return $(( $# < 2 ? 2 : 0 ))
  }

  command -v gpg >/dev/null || { print -P "%F{red}secret_store: gpg not found.%f" >&2; return 1; }

  local -r ns="$1" var="$2"
  local value="${3:-}"
  [[ -n "$value" ]] || IFS= read -r value || true
  [[ -n "$value" ]] || { print -P "%F{red}secret_store: empty value.%f" >&2; return 2; }

  local -r dir="${SECRET_STORE_DIR%/}/$ns"
  local -r enc="$dir/.env.gpg" plain="$dir/.env"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null

  local tmp; tmp="$(mktemp "${dir}/.env.XXXXXX")" || return 1
  chmod 600 "$tmp"
  printf 'export %s=%q\n' "$var" "$value" > "$tmp"

  local pass
  pass="$(gpg_passphrase "$ns" confirm)" || {
    command -v shred >/dev/null && shred -u "$tmp" 2>/dev/null || rm -f "$tmp"; return 1; }

  if ! print -r -- "$pass" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
        --symmetric --cipher-algo AES256 --output "$enc" "$tmp"; then
    pass=""
    command -v shred >/dev/null && shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
    print -P "%F{red}secret_store: gpg encryption failed.%f" >&2
    return 1
  fi
  pass=""
  command -v shred >/dev/null && shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
  [[ -f "$plain" ]] && { command -v shred >/dev/null && shred -u "$plain" 2>/dev/null || rm -f "$plain"; }
  chmod 600 "$enc" 2>/dev/null
  print -P "%F{green}Stored encrypted -> ${enc}%f"
}

# ---------------------------------------------------------------------------
# secret_load <namespace> [REQUIRED_VAR]
# Decrypt the namespace's store and export its variables into the current
# shell. Prefers ciphertext; falls back to a plaintext .env when present.
# With [REQUIRED_VAR], fails if that variable is still unset afterwards.
# ---------------------------------------------------------------------------
function secret_load() {
  emulate -L zsh
  setopt local_options pipe_fail
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: secret_load <namespace> [REQUIRED_VAR]
Decrypt \$SECRET_STORE_DIR/<namespace>/.env.gpg and export its variables into
the current shell. Falls back to a plaintext .env in the same directory.
With [REQUIRED_VAR], returns non-zero when that variable is unset after loading.

Example: secret_load forge FORGE_TOKEN"
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r ns="$1" required="${2:-}"
  local -r dir="${SECRET_STORE_DIR%/}/$ns"
  local -r enc="$dir/.env.gpg" plain="$dir/.env"

  if [[ -f "$enc" ]]; then
    local pass; pass="$(gpg_passphrase "$ns")" || return 1
    set -a
    source <(print -r -- "$pass" | gpg --batch --quiet --pinentry-mode loopback \
               --passphrase-fd 0 -d "$enc" | sed 's/^[[:space:]]*export //')
    set +a
    pass=""
  elif [[ -f "$plain" ]]; then
    set -a; source <(sed 's/^[[:space:]]*export //' "$plain"); set +a
  else
    print -P "%F{red}secret_load: no .env.gpg or .env in '${dir}'%f" >&2
    return 1
  fi

  if [[ -n "$required" ]]; then
    [[ -n "${(P)required:-}" ]] || {
      print -P "%F{red}secret_load: ${required} unset after loading '${ns}'.%f" >&2; return 1; }
  fi
}

# ---------------------------------------------------------------------------
# secret_strip_plaintext <VAR_NAME> [replacement_comment]
# Comment out every plaintext `export VAR_NAME=...` across the usual login
# files, backing up each one it touches. Files whose names look like backups
# are skipped on purpose.
# ---------------------------------------------------------------------------
function secret_strip_plaintext() {
  emulate -L zsh
  setopt local_options
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: secret_strip_plaintext <VAR_NAME> [replacement_comment]
Comment out plaintext 'export <VAR_NAME>=...' lines in ~/.zshrc, ~/.zshenv,
~/.zprofile, ~/.zlogin, ~/.bashrc, ~/.bash_profile and ~/.profile.
Each modified file is backed up as <file>.bak.<timestamp>.
Files matching *backup* or *.bak* are skipped."
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r var="$1"
  local -r note="${2:-# ${var} is gpg-encrypted; run: secret_load <namespace> ${var}}"
  local -a files=(
    "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zlogin"
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"
  )
  local stamp; stamp="$(date +%Y%m%d%H%M%S 2>/dev/null || print -r -- bak)"
  local rc; local -i changed=0

  for rc in "${files[@]}"; do
    [[ -f "$rc" ]] || continue
    [[ "$rc" == *backup* || "$rc" == *.bak* ]] && continue
    grep -qE "^[[:space:]]*export[[:space:]]+${var}=" "$rc" || continue
    cp -p "$rc" "${rc}.bak.${stamp}" || {
      print -P "%F{yellow}  backup of $rc failed; skipped.%f" >&2; continue; }
    sed -i -E "s|^[[:space:]]*export[[:space:]]+${var}=.*|${note}|" "$rc"
    print -P "%F{green}  cleaned $rc (backup ${rc}.bak.${stamp})%f"
    changed=1
  done
  (( changed )) || print -P "%F{cyan}  no plaintext ${var} lines found.%f"
}

# ---------------------------------------------------------------------------
# secret_set <namespace> <VAR_NAME>
# Interactive bootstrap: prompt for the secret with hidden input, encrypt it,
# strip any plaintext copies from login files, then load it. The value never
# reaches shell history, argv or `ps`.
# ---------------------------------------------------------------------------
function secret_set() {
  emulate -L zsh
  setopt local_options
  [[ "${1:-}" == (-h|--help) || $# -lt 2 ]] && {
    print -r -- "Usage: secret_set <namespace> <VAR_NAME>
Prompt for a secret (hidden input), encrypt it into <namespace>, remove any
plaintext copies from login files, and load it into the current shell.

Example: secret_set forge FORGE_TOKEN"
    return $(( $# < 2 ? 2 : 0 ))
  }

  local -r ns="$1" var="$2"
  local tok
  print -n "Paste value for ${var} (input hidden): "
  IFS= read -rs tok; print
  [[ -n "$tok" ]] || { print -P "%F{red}secret_set: empty input.%f" >&2; return 2; }
  if ! print -r -- "$tok" | secret_store "$ns" "$var"; then tok=""; return 1; fi
  tok=""
  secret_strip_plaintext "$var"
  secret_load "$ns" "$var"
}
