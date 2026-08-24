#!/usr/bin/env zsh
# worktree.sh — disposable read-only git worktrees, and the repo-format
# workaround that makes sparse checkouts safe for older gitstatusd builds.
#
# Where the read-only worktrees are created (default: system temp dir):
#     WORKTREE_RO_TMPDIR=${WORKTREE_RO_TMPDIR:-${TMPDIR:-/tmp}}

: ${WORKTREE_RO_TMPDIR:=${TMPDIR:-/tmp}}

# ---------------------------------------------------------------------------
# worktree_ro_create <repo> [ref] [sparse_paths_file]
#
# Print the path of a fresh, detached worktree of <repo> at <ref>. The caller
# gets a stable snapshot to read from without touching the user's branch,
# stash, staged changes or uncommitted work.
#
# <ref> defaults to the upstream of the currently checked-out branch, falling
# back to origin/HEAD.
#
# When <sparse_paths_file> is given and non-empty, only the gitignore-style
# patterns it lists (one per line) are materialised. On a large repository this
# is the difference between copying the whole tree and copying a handful of
# files, and the result is identical for any reader whose paths match.
#
# Pair every successful call with worktree_ro_remove in an `always { }` block.
# ---------------------------------------------------------------------------
function worktree_ro_create() {
  setopt local_options local_traps err_return nounset

  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: worktree_ro_create <repo> [ref] [sparse_paths_file]
Create a detached, disposable worktree of <repo> and print its path.

  ref                 default: upstream of the current branch, else origin/HEAD
  sparse_paths_file   file of gitignore-style patterns; only those paths are
                      checked out (much faster on large repositories)

Set WORKTREE_RO_TMPDIR to control where the worktree is created.
Always pair with: worktree_ro_remove <repo> <path>"
    return 0
  }

  if (( $# < 1 || $# > 3 )); then
    print -P "%F{red}Usage: worktree_ro_create <repo> [ref] [sparse_paths_file]%f" >&2
    return 2
  fi

  local -r repo="$1" explicit_ref="${2:-}" sparse_file="${3:-}"

  # Signal-safe self-cleanup: between mktemp and the final print, the caller
  # has no way to know the worktree exists, so a signal here would leak it.
  # The traps below remove it; we clear tmpdir on the success path first.
  local tmpdir=""
  trap '[[ -n "$tmpdir" ]] && { git -C "$repo" worktree remove --force "$tmpdir" 2>/dev/null; rm -rf "$tmpdir" 2>/dev/null; }; return 130' INT
  trap '[[ -n "$tmpdir" ]] && { git -C "$repo" worktree remove --force "$tmpdir" 2>/dev/null; rm -rf "$tmpdir" 2>/dev/null; }; return 143' TERM
  trap '[[ -n "$tmpdir" ]] && { git -C "$repo" worktree remove --force "$tmpdir" 2>/dev/null; rm -rf "$tmpdir" 2>/dev/null; }; return 129' HUP
  trap '[[ -n "$tmpdir" ]] && { git -C "$repo" worktree remove --force "$tmpdir" 2>/dev/null; rm -rf "$tmpdir" 2>/dev/null; }; return 131' QUIT

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    print -P "%F{red}worktree_ro_create: '$repo' is not a git work tree%f" >&2; return 2; }

  git -C "$repo" fetch --quiet --prune origin >/dev/null 2>&1 || {
    print -P "%F{red}worktree_ro_create: fetch failed in $repo%f" >&2; return 3; }

  local ref
  if [[ -n "$explicit_ref" ]]; then
    ref="$explicit_ref"
  else
    ref=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || ref=""
    [[ -n "$ref" ]] || ref=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
    [[ -n "$ref" ]] || {
      print -P "%F{red}worktree_ro_create: cannot resolve upstream or origin/HEAD in $repo%f" >&2; return 4; }
  fi

  git -C "$repo" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || {
    print -P "%F{red}worktree_ro_create: ref '$ref' not found in $repo%f" >&2; return 5; }

  tmpdir=$(mktemp -d "${WORKTREE_RO_TMPDIR%/}/${repo:t}-ro-XXXXXX") || return 6

  if [[ -n "$sparse_file" && -s "$sparse_file" ]]; then
    # Deliberately the LEGACY (no-extension) sparse API.
    # `git sparse-checkout init --no-cone` sets extensions.worktreeConfig and
    # bumps core.repositoryformatversion to 1, which older gitstatusd builds
    # (as shipped with some powerlevel10k releases) refuse to read — silently
    # blanking the prompt's git status. The plumbing below is equivalent:
    #   1. add the worktree with --no-checkout (stamps HEAD, writes no files)
    #   2. write patterns to the LINKED worktree's info/sparse-checkout
    #   3. set core.sparseCheckout in the shared config — safe, because the
    #      primary worktree has no patterns file and so stays full
    #   4. materialise with read-tree -m -u HEAD (legacy sparse-aware path)
    git -C "$repo" worktree add --no-checkout --quiet --detach "$tmpdir" "$ref" >/dev/null 2>&1 || {
      rm -rf "$tmpdir" 2>/dev/null
      print -P "%F{red}worktree_ro_create: worktree add at '$ref' failed in $repo%f" >&2; return 7; }

    local linked_gitdir
    linked_gitdir=$(git -C "$tmpdir" rev-parse --git-dir 2>/dev/null) || {
      rm -rf "$tmpdir" 2>/dev/null
      print -P "%F{red}worktree_ro_create: cannot resolve gitdir for $tmpdir%f" >&2; return 8; }

    mkdir -p "$linked_gitdir/info"
    cp "$sparse_file" "$linked_gitdir/info/sparse-checkout" || {
      rm -rf "$tmpdir" 2>/dev/null
      print -P "%F{red}worktree_ro_create: cannot write sparse patterns%f" >&2; return 9; }

    git -C "$repo" config core.sparseCheckout true
    git -C "$tmpdir" read-tree -m -u HEAD >/dev/null 2>&1 || {
      rm -rf "$tmpdir" 2>/dev/null
      print -P "%F{red}worktree_ro_create: sparse read-tree failed in $tmpdir%f" >&2; return 10; }
  else
    git -C "$repo" worktree add --quiet --detach "$tmpdir" "$ref" >/dev/null 2>&1 || {
      rm -rf "$tmpdir" 2>/dev/null
      print -P "%F{red}worktree_ro_create: worktree add at '$ref' failed in $repo%f" >&2; return 7; }
  fi

  print -r -- "$tmpdir"
}

# ---------------------------------------------------------------------------
# worktree_ro_remove <repo> <worktree_path>
# Idempotent counterpart to worktree_ro_create. A missing or empty path is a
# no-op, so it slots into `always { }` blocks without guarding.
# ---------------------------------------------------------------------------
function worktree_ro_remove() {
  setopt local_options nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: worktree_ro_remove <repo> <worktree_path>
Remove a worktree created by worktree_ro_create. Safe to call with an empty or
already-removed path."
    return 0
  }
  local -r repo="${1:-}" tmpdir="${2:-}"
  [[ -z "$repo" || -z "$tmpdir" || ! -d "$tmpdir" ]] && return 0
  git -C "$repo" worktree remove --force "$tmpdir" 2>/dev/null
  # worktree remove usually deletes the directory; rm -rf covers the case where
  # the user moved it manually and the prune fails.
  rm -rf "$tmpdir" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# worktree_panic_cleanup <repo> <worktree> [tmpfile ...]
# Best-effort teardown for trap handlers: deletes any listed temp files, then
# the worktree. Never fails.
# ---------------------------------------------------------------------------
function worktree_panic_cleanup() {
  emulate -L zsh
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: worktree_panic_cleanup <repo> <worktree> [tmpfile ...]
Best-effort cleanup for use inside trap handlers. Always returns 0."
    return 0
  }
  local repo="${1:-}" worktree="${2:-}"
  (( $# >= 2 )) && shift 2
  local f
  for f in "$@"; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f" 2>/dev/null
  done
  if [[ -n "$repo" && -n "$worktree" && -e "$worktree" ]]; then
    git -C "$repo" worktree remove --force "$worktree" 2>/dev/null
    rm -rf "$worktree" 2>/dev/null
  fi
  return 0
}

# ---------------------------------------------------------------------------
# worktree_ro_prune <repo> [age_minutes]
# Remove leftover read-only worktrees of <repo> older than <age_minutes>
# (default 60), then prune git's worktree registry.
# ---------------------------------------------------------------------------
function worktree_ro_prune() {
  emulate -L zsh
  setopt local_options nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: worktree_ro_prune <repo> [age_minutes]
Delete stale worktrees created by worktree_ro_create (matching
\$WORKTREE_RO_TMPDIR/<repo-name>-ro-*) that are older than [age_minutes]
(default 60), then run 'git worktree prune'."
    return 0
  }

  local -r repo="${1:-}"
  local -ri age_min="${2:-60}"
  [[ -n "$repo" && -d "$repo" ]] || return 0

  local -r base="${repo:t}"
  local wt
  for wt in "${WORKTREE_RO_TMPDIR%/}/${base}"-ro-*(N/); do
    # -mmin +N selects entries last modified more than N minutes ago
    if find "$wt" -maxdepth 0 -mmin "+$age_min" -print -quit 2>/dev/null | IFS= read -r _; then
      git -C "$repo" worktree remove --force "$wt" 2>/dev/null
      rm -rf "$wt" 2>/dev/null
      print -P "%F{cyan}worktree_ro_prune: removed stale $wt%f"
    fi
  done
  git -C "$repo" worktree prune 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# git_repo_format_v0_if_safe <repo>
# Roll core.repositoryformatversion back from 1 to 0 when the only reason it
# was raised is extensions.worktreeConfig and no per-worktree config exists.
#
# Why: sparse-checkout raises the format version, and some older gitstatusd
# builds refuse to read such repos, silently blanking the shell prompt's git
# status. Refuses (leaving the repo untouched) if any other extension is set or
# any worktree has its own config, since unsetting would lose data.
# ---------------------------------------------------------------------------
function git_repo_format_v0_if_safe() {
  emulate -L zsh
  setopt local_options nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: git_repo_format_v0_if_safe <repo>
Lower core.repositoryformatversion from 1 to 0 when it is safe: only
extensions.worktreeConfig is set, and no worktree has per-worktree config.
Otherwise the repo is left untouched. Fixes prompts that blank out under older
gitstatusd builds after a sparse checkout."
    return 0
  }

  local -r repo="${1:-}"
  [[ -n "$repo" ]] || return 0
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || return 0
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local fmt
  fmt=$(git -C "$repo" config --get core.repositoryformatversion 2>/dev/null) || fmt=""
  [[ "$fmt" == "1" ]] || return 0   # already v0 or unset -> nothing to do

  local -a exts
  exts=( ${(f)"$(git -C "$repo" config --get-regexp '^extensions\.' 2>/dev/null | awk '{print $1}')"} )

  local e
  for e in "${exts[@]}"; do
    [[ -z "$e" ]] && continue
    if [[ "${e:l}" != "extensions.worktreeconfig" ]]; then
      print -P "%F{yellow}git_repo_format_v0_if_safe: $repo has extension '$e' — leaving alone%f" >&2
      return 0
    fi
  done

  local f
  for f in "$repo"/.git/config.worktree "$repo"/.git/worktrees/*/config.worktree(N); do
    if [[ -e "$f" ]]; then
      print -P "%F{yellow}git_repo_format_v0_if_safe: $repo uses per-worktree config ($f) — leaving alone%f" >&2
      return 0
    fi
  done

  git -C "$repo" config --unset extensions.worktreeconfig 2>/dev/null
  # Drop the now-empty [extensions] section so the config file looks pristine.
  git -C "$repo" config --remove-section extensions 2>/dev/null || :
  git -C "$repo" config core.repositoryformatversion 0
  print -P "%F{green}git_repo_format_v0_if_safe: ${repo:t} <- v0%f"
}

# ---------------------------------------------------------------------------
# git_repo_format_v0_all [root] [max_depth]
# Apply git_repo_format_v0_if_safe to every repository under <root>, visiting
# each git dir once. Defaults: root = $PWD, max_depth = 3.
# ---------------------------------------------------------------------------
function git_repo_format_v0_all() {
  emulate -L zsh
  setopt local_options nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: git_repo_format_v0_all [root] [max_depth]
Run git_repo_format_v0_if_safe on every repository found under [root].

  root        default: \$PWD
  max_depth   default: 3"
    return 0
  }

  local -r root="${1:-$PWD}"
  local -ri max_depth="${2:-3}"
  [[ -d "$root" ]] || { print -P "%F{red}git_repo_format_v0_all: not a directory: $root%f" >&2; return 1; }

  local found repo gitdir
  typeset -A seen
  while IFS= read -r -d '' found || [[ -n "$found" ]]; do
    repo=${found:h}
    gitdir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || continue
    [[ "$gitdir" = /* ]] || gitdir="$repo/$gitdir"
    gitdir=${gitdir:A}
    [[ -n "${seen[$gitdir]:-}" ]] && continue
    seen[$gitdir]=1
    git_repo_format_v0_if_safe "$repo"
  done < <(find "$root" -mindepth 1 -maxdepth "$max_depth" \
                \( -type d -o -type f \) -name .git -print0 2>/dev/null)
}
