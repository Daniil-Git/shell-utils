# shell-utils

[![CI](https://github.com/Daniil-Git/shell-utils/actions/workflows/ci.yml/badge.svg)](https://github.com/Daniil-Git/shell-utils/actions/workflows/ci.yml)

A small zsh toolkit of general-purpose shell utilities: filesystem assertions,
safe batch git operations, disposable read-only worktrees, in-place line
editing, INI inspection, a GPG-backed secret store, and a lean set of dotfiles.

Everything here is standalone — no framework, no plugin manager, and no
assumptions about your directory layout. Each function takes what it needs as
arguments or reads a documented environment variable. Only `lib/gitlab.sh`
touches the network.


## Requirements

- zsh 5.8+ (the `bin/` scripts are bash 4+)
- `git`, `awk`, `bc`, `comm`, `find` — all standard
- `gpg` — only for `lib/secrets.sh`
- `curl` and `jq` — only for `lib/gitlab.sh`

## Install

```sh
git clone https://github.com/<you>/shell-utils.git ~/.local/share/shell-utils
```

Add to `~/.zshrc`:

```zsh
SHELL_UTILS=~/.local/share/shell-utils
for f in core text ini files git worktree clipboard secrets gitlab; do
  source "$SHELL_UTILS/lib/$f.sh"
done
path=("$SHELL_UTILS/bin" $path)
```

Source only the files you want — they are independent, except that `files.sh`
uses `path_shorten` from `text.sh` when it is loaded and falls back to plain
paths when it is not.

Every function responds to `-h` / `--help`.

## Contents

### `lib/core.sh` — assertions, arithmetic, set comparison

| Function | Purpose |
|---|---|
| `check_dirs <dir>...` | Assert all paths are readable directories. Exit status = number of failures |
| `check_any_dir <dir>...` | Succeed if *at least one* path is a readable directory |
| `check_files <file>...` | Assert all paths are readable regular files |
| `is_array_empty_or_whitespace <e>...` | True when no elements, or all are blank |
| `run_script <name> [args]` | PATH-resolve a script and run it, failing loudly if absent |
| `calc_bc <expr>` | Float arithmetic via `bc`, rounded to 2 decimals |
| `pct_of <part> <whole>` | Percentage one number is of another |
| `pct_change <from> <to>` | Percentage change between two numbers |
| `uniq_compare <flags> <f1> <f2> [out]` | `comm` on sorted-unique inputs; `12`=common, `13`=only-in-f2, `23`=only-in-f1 |
| `wsl_interop_ok` | True under WSL with working Windows interop (cached) |

### `lib/text.sh` — strings, maps, path display

| Function | Purpose |
|---|---|
| `path_shorten [--plain] <path>` | Replace long prefixes with short aliases via `PATH_SHORTEN_MAP` |
| `map_case <ref> <target>` | Copy the upper/lower case pattern of one string onto another |
| `map_normalize <map_name>` | Strip quotes, newlines and trailing slashes from an assoc array, in place |
| `prompt_overwrite <default>` | Prompt for a replacement value; empty reply keeps the default |

### `lib/ini.sh` — INI inspection

| Function | Purpose |
|---|---|
| `ini_keys [-s "sections"] <file>` | Print key names, optionally restricted to named sections |

### `lib/files.sh` — line editing and backups

| Function | Purpose |
|---|---|
| `update_line [--dry-run] <mode> <keyword> [new] <file>...` | Insert before/after, replace, or delete lines matching a substring, preserving indentation |
| `rcfile_backup [file] [dir]` | Date-stamped copy of a config file |
| `rcfile_restore <backup> [target]` | Restore a backup, keeping a safety copy, with confirmation |

### `lib/git.sh` — batch-safe git

| Function | Purpose |
|---|---|
| `git_safe_pull <repo>` | Fast-forward-only pull that *skips* on dirty/detached/diverged instead of failing |
| `git_pull_repos <repo>...` | `git_safe_pull` over an explicit list, validated up front |
| `git_pull_all [root] [depth]` | Discover and pull every repo under a root, de-duplicating linked worktrees |
| `git_checkout_upsert <branch> [repo]` | Check out a branch, creating and pushing it if new |
| `git_reset_hard_branch <branch> [repo] [-y]` | Hard-reset onto `origin/<branch>`, listing what will be lost first |
| `git_delete_merged_branch [repo]` | Delete the current branch locally and remotely — only if already merged |
| `git_remote_project_path <repo> [override]` | `namespace/project` from any remote URL form (scp, ssh://, https://) |
| `git_has_commit_message <repo> <msg>` | True when that exact commit subject already exists in any ref |

### `lib/worktree.sh` — disposable read-only worktrees

| Function | Purpose |
|---|---|
| `worktree_ro_create <repo> [ref] [sparse_file]` | Detached snapshot worktree; optional sparse checkout for large repos |
| `worktree_ro_remove <repo> <path>` | Idempotent teardown, safe in `always { }` blocks |
| `worktree_panic_cleanup <repo> <wt> [tmp]...` | Best-effort cleanup for trap handlers; never fails |
| `worktree_ro_prune <repo> [minutes]` | Remove leftover worktrees older than N minutes |
| `git_repo_format_v0_if_safe <repo>` | Undo the repo-format bump from sparse checkout when it is safe |
| `git_repo_format_v0_all [root] [depth]` | The above across every repo under a root |

Sparse checkout raises `core.repositoryformatversion` to 1, which some older
`gitstatusd` builds refuse to read — silently blanking the git section of your
prompt. `worktree_ro_create` avoids the bump by using git's legacy sparse
plumbing, and `git_repo_format_v0_if_safe` repairs repos already affected.

### `lib/clipboard.sh` — clipboard with fallbacks

| Function | Purpose |
|---|---|
| `clipcopy [file]` | Copy a file, or stdin, to the clipboard |
| `clippaste` | Print the clipboard to stdout |

Backends are tried in order: WSL interop → Wayland → X11 → tmux → OSC 52. The
OSC 52 fallback asks the terminal itself to set the clipboard, so it works over
SSH with nothing installed on the remote host.

Source this *after* `oh-my-zsh.sh` if you use OMZ — it installs a lazy stub of
the same names that would otherwise overwrite these on first call.

### `lib/secrets.sh` — GPG secret store

Secrets live at rest only as GPG AES256 ciphertext under
`$SECRET_STORE_DIR/<namespace>/.env.gpg` (default
`${XDG_DATA_HOME:-~/.local/share}/secret-store`).

| Function | Purpose |
|---|---|
| `secret_set <ns> <VAR>` | Prompt (hidden), encrypt, strip plaintext copies, load |
| `secret_store <ns> <VAR> [value]` | Encrypt a value; reads stdin when omitted, keeping it out of argv and history |
| `secret_load <ns> [REQUIRED_VAR]` | Decrypt and export into the current shell |
| `secret_strip_plaintext <VAR>` | Comment out plaintext `export VAR=` lines across login files, with backups |
| `secret_path <ns>` | Print the ciphertext path |
| `gpg_passphrase <prefix> [confirm]` | Passphrase from `<PREFIX>_GPG_PASSPHRASE_FILE`, else a `/dev/tty` prompt |

`gpg-agent` and `pinentry` are deliberately bypassed: they fail with
"Inappropriate ioctl for device" when `GPG_TTY` is unset in cron and other
headless contexts. For non-interactive use set `<PREFIX>_GPG_PASSPHRASE_FILE`.

```zsh
secret_set forge FORGE_TOKEN     # once, interactively
secret_load forge FORGE_TOKEN    # later, in any shell or script
```

### `lib/gitlab.sh` — personal access token lifecycle

Manage PATs on any GitLab instance from the shell, so tokens can be kept
short-lived without a trip through the web UI. Integrates with `secrets.sh`:
new tokens are stored encrypted and loaded automatically.

`GITLAB_URL` is **required and has no default** — a misconfigured shell fails
loudly rather than talking to the wrong host. Override per call with `--url`.

| Function | Purpose |
|---|---|
| `gitlab_token_check` | Report id, expiry and scopes; whether the token can self-rotate |
| `gitlab_token_list` | Table of every PAT on the account |
| `gitlab_token_rotate [--days N \| --expires-at DATE]` | Rotate in place, pre-flighted so a working token is never revoked for nothing |
| `gitlab_token_create --name N --scopes S [--revoke-old]` | Create a token; revokes the old one only after the new one is persisted |
| `gitlab_token_revoke (--id N \| --self)` | Revoke by id or the token in use |

Shared exit statuses: `0` ok · `2` usage · `6` network · `11` no token ·
`21` 401 · `22` 403 · `24` 404/not-rotatable · `25` other HTTP ·
`26` malformed response · `27` obtained but not persisted.

```zsh
export GITLAB_URL=https://gitlab.example.com
secret_set gitlab GITLAB_TOKEN          # once
gitlab_token_check
gitlab_token_rotate --days 90
```

| Variable | Default | Purpose |
|---|---|---|
| `GITLAB_URL` | *(none — required)* | Instance base URL |
| `GITLAB_TOKEN` | *(from secret store)* | Token to authenticate with |
| `GITLAB_SECRET_NS` | `gitlab` | Secret-store namespace |
| `GITLAB_TOKEN_DEFAULT_DAYS` | `90` | Default lifetime for new/rotated tokens |

### `lib/py/` — python modules

| Module | Purpose |
|---|---|
| `store_lookup.py` | Resolve iOS ids/bundle ids against the live iTunes Lookup API (region-fallback across storefronts) and probe Play-Store package existence. Never raises on lookup failure — reports unresolved |
| `webforms.py` | Data-driven Selenium form engine: describe controls as data (`examples/forms.json.example`), the engine fills them — React-controlled inputs, overlay banners, stale elements, autocomplete matching |
| `mdtable.py` | Edit a markdown table inside a remote document: fetch → transform rows → diff → guarded post with re-read verification. Transport-pluggable (`RestDoc` covers issue/article-style REST stores) |

`webforms` and `mdtable` deliberately take configuration as *data*: swap the
JSON/env file, and the same code drives a different site or document.

Placeholder files in `examples/` document every consumed field with the parsing
style each loader expects — copy, rename, fill. Tokens are never among them;
they belong to the encrypted store.

Tests: `zsh tests/py/run.sh` (the live-Chrome group skips when selenium or a
chrome binary is absent).

### `bin/` — standalone executables

| Script | Purpose |
|---|---|
| `update-line` | CLI wrapper around `update_line` |
| `prefix-files` | Add cryptographically random prefixes to filenames, with ranges, filters, dry-run and parallelism |
| `strip-prefix` | Remove a regex-matched prefix from filenames |


## Dotfiles

A minimal, framework-only starting point. `dotfiles/zshrc` is wiring — prompt,
plugins, lazy loaders — and nothing else; everything with a value lives in
`dotfiles/zshenv.template`.

```sh
cp dotfiles/zshrc          ~/.zshrc
cp dotfiles/zshenv.template ~/.zshenv && chmod 600 ~/.zshenv
```

Then edit `~/.zshenv`: every value in it is a placeholder.

**`zshrc`** — Powerlevel10k instant prompt, Oh My Zsh with three plugins
(`git`, `zsh-autosuggestions`, `you-should-use`), lazy `nvm`, cached
`brew shellenv`, a `venv` helper, and an optional `shell-utils` load. Each
block is guarded, so a fresh machine with none of it installed still starts a
working shell.

Three things dominate zsh startup, and each is handled:

| Cost | Treatment |
|---|---|
| `compinit` rebuilding the completion dump | left to OMZ, which rebuilds at most daily |
| sourcing `nvm.sh` (0.5–1s) | lazy — stubs load it on the first `node`/`npm`/`npx`/`nvm` call |
| `brew shellenv` subprocess | cached to a file, regenerated only when `brew` is newer |

Measure yours with `time zsh -i -c exit`, or profile with
`zsh -i -c 'zmodload zsh/zprof; source ~/.zshrc; zprof'`.

**`zshenv.template`** — exports only, since `.zshenv` is read by *every* zsh
including scripts and editor subshells. Covers locale and pager, XDG paths,
`shell-utils` wiring, the secret store, GitLab, nvm, Homebrew, Python, and a
Claude Code block: telemetry opt-outs, timeouts, retry and context settings.

Provider routing (`ANTHROPIC_BASE_URL`, custom model ids) is deliberately left
**commented out**. A custom base URL is applied silently with no warning, so an
inherited one quietly sends your traffic somewhere you did not choose. Fill it
in per machine, not in a shared file.

No secrets belong in either file. `GITLAB_TOKEN` and friends go in the
encrypted store — `secret_set gitlab GITLAB_TOKEN`. Machine-specific values go
in `~/.zshrc.local` and `~/.zshenv.local`, both sourced last if present.

## Tests

```sh
zsh tests/run.sh      # shell libraries, bin, dotfiles — -v to list every check
zsh tests/py/run.sh   # python modules (live headless Chrome where available)
```

CI runs the same suite on every push and pull request
(`.github/workflows/ci.yml`): the full suite on Ubuntu, a shellcheck gate over
`bin/`, and a `zsh -n` parse check over every source file.

199 checks, fully self-contained. Scratch git repos, files, an isolated `$HOME`
and a stub GitLab API (on `127.0.0.1`) are created under a temp directory and
torn down on exit. Nothing touches your repos, your real dotfiles, or any
external network. The gpg round-trip is skipped when `gpg` is absent, and the
GitLab checks when `curl`, `jq` or `python3` are.

## Licence

MIT — see [LICENSE](LICENSE).
