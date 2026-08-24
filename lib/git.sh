#!/usr/bin/env zsh
# git.sh — safe batch pulls, branch lifecycle, remote URL parsing.
#
# Self-contained: no plugin framework, and nothing assumes a particular hosting
# provider or directory layout.

# Internal: name of the repo's default branch (origin/HEAD, else main/master).
function _git_default_branch() {
  local -r repo="${1:-.}"
  local ref
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) \
    && { print -r -- "${ref#origin/}"; return 0; }
  local b
  for b in main master trunk; do
    git -C "$repo" show-ref --verify --quiet "refs/heads/$b" && { print -r -- "$b"; return 0; }
  done
  return 1
}

# Internal: current branch name, or empty when detached.
function _git_current_branch() {
  git -C "${1:-.}" symbolic-ref --quiet --short HEAD 2>/dev/null
}

# ---------------------------------------------------------------------------
# git_safe_pull <repo>
# Fast-forward-only pull that refuses to do anything surprising. Skips (exit 0)
# when the worktree is dirty, HEAD is detached, there is no upstream, or the
# branch has diverged. Returns non-zero only on a real failure (bad path,
# fetch error), so it is safe to run in a loop over many repos.
# ---------------------------------------------------------------------------
function git_safe_pull() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: git_safe_pull <repo>
Fast-forward-only pull that skips rather than fails when the state is not
trivially safe: dirty worktree, detached HEAD, no upstream, or diverged branch.
Non-zero exit means a genuine error (not a git work tree, or fetch failed)."
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r repo="$1"
  local worktree
  worktree=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || {
    print -P "%F{red}git_safe_pull: '$repo' is not a git work tree%f" >&2
    return 2
  }

  # Detached HEAD (e.g. a read-only worktree) -> nothing to pull.
  local branch
  branch=$(_git_current_branch "$worktree") || return 0
  [[ -n "$branch" ]] || return 0

  # No upstream tracking branch -> nothing to pull.
  git -C "$worktree" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 || return 0

  git -C "$worktree" fetch --quiet --prune origin || {
    print -P "%F{red}git_safe_pull: fetch failed in $worktree%f" >&2
    return 1
  }

  local local_sha upstream_sha
  local_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || return 1
  upstream_sha=$(git -C "$worktree" rev-parse '@{upstream}' 2>/dev/null) || return 1
  [[ "$local_sha" == "$upstream_sha" ]] && return 0

  if ! git -C "$worktree" diff --quiet --ignore-submodules HEAD 2>/dev/null; then
    print -P "%F{yellow}git_safe_pull: $worktree dirty — skipping $branch%f" >&2
    return 0
  fi

  if ! git -C "$worktree" merge --ff-only --quiet '@{upstream}' >/dev/null 2>&1; then
    print -P "%F{yellow}git_safe_pull: $branch in $worktree diverged from upstream — skipping%f" >&2
    return 0
  fi
  print -P "%F{green}git_safe_pull: $branch updated in $worktree%f"
  return 0
}

# ---------------------------------------------------------------------------
# git_pull_repos <repo> [repo ...]
# Batch wrapper around git_safe_pull. Validates every path up front so a typo
# fails before any network work happens.
# ---------------------------------------------------------------------------
function git_pull_repos() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: git_pull_repos <repo> [repo ...]
Run git_safe_pull against each repository. All paths are validated first."
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -a repos=("$@")
  check_dirs "${repos[@]}" || return 2

  local repo
  local -i failed=0
  for repo in "${repos[@]}"; do
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    git_safe_pull "$repo" || { print -P "%F{red}git_pull_repos: failed in $repo%f" >&2; (( failed += 1 )); }
  done
  return $failed
}

# ---------------------------------------------------------------------------
# git_pull_all [root] [max_depth]
# Find every git repository under <root> and safely pull it. Worktrees that
# share a common git dir are pulled once, not once per worktree.
# Defaults: root = $PWD, max_depth = 3
# ---------------------------------------------------------------------------
function git_pull_all() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: git_pull_all [root] [max_depth]
Discover git repositories under [root] and git_safe_pull each one exactly once
(linked worktrees sharing a git dir are de-duplicated).

  root        default: \$PWD
  max_depth   default: 3   (how deep to search for .git)

Example: git_pull_all ~/code 4"
    return 0
  }

  local -r root="${1:-$PWD}"
  local -ri max_depth="${2:-3}"

  [[ -d "$root" ]] || { print -P "%F{red}git_pull_all: not a directory: $root%f" >&2; return 2; }

  typeset -A seen_gitdirs
  local found repo gitdir
  local -i count=0
  while IFS= read -r -d '' found || [[ -n "$found" ]]; do
    repo=${found:h}
    gitdir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || continue
    [[ "$gitdir" = /* ]] || gitdir="$repo/$gitdir"
    gitdir=${gitdir:A}
    [[ -n "${seen_gitdirs[$gitdir]:-}" ]] && continue
    seen_gitdirs[$gitdir]=1
    (( count += 1 ))
    git_safe_pull "$repo" || print -P "%F{red}git_pull_all: failed in $repo%f" >&2
  done < <(find "$root" -mindepth 1 -maxdepth "$max_depth" \
                \( -type d -o -type f \) -name .git -print0 2>/dev/null)

  print -P "%F{cyan}git_pull_all: visited $count repository/ies under $root%f"
}

# ---------------------------------------------------------------------------
# git_checkout_upsert <branch> [repo]
# Check out <branch>, creating it and pushing an upstream if it does not exist.
# ---------------------------------------------------------------------------
function git_checkout_upsert() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: git_checkout_upsert <branch> [repo]
Check out <branch>. If it does not exist locally, create it and push it with
--set-upstream origin <branch>.

  repo   default: current directory"
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r branch="$1" repo="${2:-.}"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" checkout "$branch"
  else
    git -C "$repo" checkout -b "$branch" \
      && git -C "$repo" push --set-upstream origin "$branch"
  fi
}

# ---------------------------------------------------------------------------
# git_reset_hard_branch <branch> [repo] [-y]
# Fetch <branch> from origin and hard-reset the worktree onto origin/<branch>.
#
# DESTRUCTIVE: discards uncommitted changes and any local commits not on the
# remote. Prints exactly what will be lost and prompts, unless -y is given.
# ---------------------------------------------------------------------------
function git_reset_hard_branch() {
  setopt local_options err_return nounset

  local assume_yes=0
  local -a positional=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes)   assume_yes=1 ;;
      -h|--help)
        print -r -- "Usage: git_reset_hard_branch <branch> [repo] [-y]
Fetch origin/<branch> and hard-reset the worktree onto it.

  repo   default: current directory
  -y     skip the confirmation prompt

DESTRUCTIVE: uncommitted changes and unpushed commits on the current branch are
discarded. Without -y, the losses are listed and confirmation is required."
        return 0 ;;
      *) positional+=("$arg") ;;
    esac
  done

  (( ${#positional[@]} >= 1 )) || {
    print -P "%F{red}Usage: git_reset_hard_branch <branch> [repo] [-y]%f" >&2; return 2; }

  local -r branch="${positional[1]}" repo="${positional[2]:-.}"

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    print -P "%F{red}git_reset_hard_branch: '$repo' is not a git work tree%f" >&2; return 2; }

  git -C "$repo" fetch origin "$branch" || {
    print -P "%F{red}git_reset_hard_branch: fetch of '$branch' failed%f" >&2; return 1; }

  git -C "$repo" rev-parse --verify --quiet "origin/$branch" >/dev/null || {
    print -P "%F{red}git_reset_hard_branch: origin/$branch does not exist%f" >&2; return 1; }

  if (( ! assume_yes )); then
    local dirty ahead
    dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
    ahead=$(git -C "$repo" log --oneline "origin/$branch..HEAD" 2>/dev/null)

    if [[ -z "$dirty" && -z "$ahead" ]]; then
      print -P "%F{green}Already clean and in sync with origin/$branch — nothing to discard.%f"
    else
      [[ -n "$dirty" ]] && { print -P "%F{yellow}Uncommitted changes that will be DISCARDED:%f"; print -r -- "$dirty"; }
      [[ -n "$ahead" ]] && { print -P "%F{yellow}Local commits that will be DISCARDED:%f"; print -r -- "$ahead"; }
      local reply=""
      print -n "Hard-reset onto origin/$branch? (y/N): " >&2
      read -r reply || true
      [[ "$reply" == [Yy]* ]] || { print -P "%F{yellow}Aborted.%f" >&2; return 1; }
    fi
  fi

  git -C "$repo" reset --hard "origin/$branch" \
    && print -P "%F{green}Reset to origin/$branch%f"
}

# ---------------------------------------------------------------------------
# git_delete_merged_branch [repo]
# Delete the current branch locally and on origin, but only after proving it is
# already merged into the default branch. Refuses on a dirty worktree.
# ---------------------------------------------------------------------------
function git_delete_merged_branch() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) ]] && {
    print -r -- "Usage: git_delete_merged_branch [repo]
Delete the CURRENT branch locally and on origin — but only if it is already an
ancestor of the default branch (origin/HEAD, else main/master/trunk).

Refuses when: on the default branch, detached, worktree dirty, or unmerged.

  repo   default: current directory"
    return 0
  }

  local -r repo="${1:-.}"
  local current main
  current=$(_git_current_branch "$repo") || current=""
  [[ -n "$current" ]] || { print -P "%F{red}Not on a branch (detached HEAD).%f" >&2; return 1; }

  main=$(_git_default_branch "$repo") || {
    print -P "%F{red}Cannot determine the default branch.%f" >&2; return 1; }
  [[ "$current" == "$main" ]] && { print -P "%F{red}Refusing to delete the default branch ($main).%f" >&2; return 1; }

  if ! git -C "$repo" diff --quiet || ! git -C "$repo" diff --cached --quiet; then
    print -P "%F{yellow}Uncommitted changes on $current — commit, stash, or reset first.%f" >&2
    return 1
  fi

  git -C "$repo" checkout "$main" || { print -P "%F{red}Failed to check out $main%f" >&2; return 1; }
  git -C "$repo" pull --ff-only    || { print -P "%F{red}Failed to update $main%f" >&2; return 1; }

  if git -C "$repo" merge-base --is-ancestor "$current" "$main"; then
    git -C "$repo" branch -d "$current" || git -C "$repo" branch -D "$current"
    if git -C "$repo" rev-parse --verify --quiet "origin/$current" >/dev/null 2>&1; then
      git -C "$repo" push origin --delete "$current"
    fi
    print -P "%F{green}Deleted $current locally and on origin.%f"
  else
    print -P "%F{red}$current is not merged into $main — aborting.%f" >&2
    git -C "$repo" checkout "$current"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# git_remote_project_path <repo> [override]
# Print the "group/subgroup/project" path of a repo's origin remote, with the
# scheme, host, port, user and trailing .git stripped. Works with scp-style
# (git@host:group/proj.git), ssh:// and https:// URLs alike.
# ---------------------------------------------------------------------------
function git_remote_project_path() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 1 ]] && {
    print -r -- "Usage: git_remote_project_path <repo> [override]
Print the namespace/project path derived from the repo's 'origin' remote.
Handles scp-style, ssh:// and https:// URLs, host ports and a trailing .git.
[override] short-circuits the lookup and is echoed back (minus a trailing /).

Examples:
  git@example.com:group/sub/proj.git      -> group/sub/proj
  https://example.com:8443/group/proj.git -> group/proj"
    return $(( $# < 1 ? 2 : 0 ))
  }

  local -r repo="$1" override="${2:-}"
  if [[ -n "$override" ]]; then
    print -r -- "${override%/}"
    return 0
  fi

  local url
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "$url" ]] || return 1

  local path="${url%.git}"
  if [[ "$path" == *"://"* ]]; then
    path="${path#*://}"   # drop scheme://[user@]host[:port]
    path="${path#*/}"     # drop host[:port]/
  else
    path="${path#*:}"     # scp-style user@host:group/proj
  fi
  path="${path#/}"
  [[ -n "$path" ]] || return 1
  print -r -- "${path%/}"
}

# ---------------------------------------------------------------------------
# git_has_commit_message <repo> <message>
# True when <message> already exists as a whole-line commit subject anywhere in
# the repo's history (all refs). Useful as a duplicate guard before committing.
# ---------------------------------------------------------------------------
function git_has_commit_message() {
  setopt local_options err_return nounset
  [[ "${1:-}" == (-h|--help) || $# -lt 2 ]] && {
    print -r -- "Usage: git_has_commit_message <repo> <message>
Exit 0 when <message> already appears as a complete commit subject line in any
ref of <repo>; exit 1 otherwise. Leading/trailing whitespace is trimmed."
    return $(( $# < 2 ? 2 : 0 ))
  }

  local -r repo="$1"
  local msg="$2"
  msg="${msg#"${msg%%[![:space:]]*}"}"
  msg="${msg%"${msg##*[![:space:]]}"}"
  [[ -n "$msg" ]] || return 1

  if git -C "$repo" log --all --grep="^${msg}$" --format=%h -1 2>/dev/null | grep -q .; then
    print -P "%F{yellow}Duplicate commit message exists: '$msg'%f" >&2
    return 0
  fi
  return 1
}
