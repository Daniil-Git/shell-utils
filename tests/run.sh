#!/usr/bin/env zsh
# tests/run.sh — smoke tests for every exported function.
#
# Self-contained: creates scratch git repos and files under a temp dir and
# removes them on exit. Never touches the caller's repos, $HOME dotfiles, or
# any network resource.
#
# Usage:  zsh tests/run.sh [-v]

emulate -L zsh
setopt pipe_fail

readonly ROOT="${0:A:h:h}"
typeset -g VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

typeset -gi PASS=0 FAIL=0
typeset -ga FAILURES=()

TMP="$(mktemp -d "${TMPDIR:-/tmp}/shellkit-tests-XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- harness --------------------------------------------------------------
ok()   { (( PASS++ )); (( VERBOSE )) && print -P "%F{green}  ok%f   $1"; return 0; }
nope() { (( FAIL++ )); FAILURES+=("$1"); print -P "%F{red}  FAIL%f $1${2:+  -- $2}"; return 0; }

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else nope "$1" "expected [$2] got [$3]"; fi
}
# assert_status <label> <expected_status> <cmd...>
assert_status() {
  local label="$1" want="$2"; shift 2
  local out; local -i got
  out="$("$@" 2>&1)"; got=$?
  if (( got == want )); then ok "$label"; else nope "$label" "expected status $want got $got"; fi
}
# assert_contains <label> <needle> <haystack>
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else nope "$1" "[$3] does not contain [$2]"; fi
}
section() { print -P "%F{cyan}== $1%f"; }

# ---- load the libraries ---------------------------------------------------
section "load libraries"
for f in core text ini files git worktree secrets gitlab; do
  if source "$ROOT/lib/$f.sh" 2>/dev/null; then ok "source lib/$f.sh"; else nope "source lib/$f.sh"; fi
done

# ---- core.sh --------------------------------------------------------------
section "core.sh"
mkdir -p "$TMP/d1" "$TMP/d2"; print -r -- "x" > "$TMP/f1"

assert_status "check_dirs: two valid dirs -> 0"      0 check_dirs "$TMP/d1" "$TMP/d2"
assert_status "check_dirs: one missing -> 1 failure" 1 check_dirs "$TMP/d1" "$TMP/nope"
assert_status "check_dirs: two missing -> 2 failures" 2 check_dirs "$TMP/nope" "$TMP/nada"
assert_status "check_dirs: file is not a dir -> 1"   1 check_dirs "$TMP/f1"
assert_status "check_any_dir: one of two exists"     0 check_any_dir "$TMP/nope" "$TMP/d1"
assert_status "check_any_dir: none exist -> 1"       1 check_any_dir "$TMP/nope" "$TMP/nada"
assert_status "check_files: valid file -> 0"         0 check_files "$TMP/f1"
assert_status "check_files: dir is not a file -> 1"  1 check_files "$TMP/d1"
assert_status "check_dirs --help -> 0"               0 check_dirs --help
assert_status "check_dirs no args -> 2"              2 check_dirs

assert_status "is_array_empty_or_whitespace: empty"       0 is_array_empty_or_whitespace ""
assert_status "is_array_empty_or_whitespace: spaces"      0 is_array_empty_or_whitespace "   "
assert_status "is_array_empty_or_whitespace: real value"  1 is_array_empty_or_whitespace "a"

assert_eq "calc_bc: 100*7/9"        "77.78" "$(calc_bc '100 * 7 / 9')"
assert_eq "calc_bc: negative"       "-25.00" "$(calc_bc '100 * (3 - 4) / 4')"
assert_contains "pct_of output"     "77.78%" "$(pct_of 7 9)"
assert_contains "pct_change output" "25.00%" "$(pct_change 80 100)"
assert_status "calc_bc --help -> 0" 0 calc_bc --help
assert_status "pct_of wrong arity -> 2" 2 pct_of 1

print -l a b c   > "$TMP/s1"
print -l b c d e > "$TMP/s2"
assert_eq "uniq_compare 12 (common)"    $'b\nc'   "$(uniq_compare 12 "$TMP/s1" "$TMP/s2")"
assert_eq "uniq_compare 23 (only s1)"   "a"       "$(uniq_compare 23 "$TMP/s1" "$TMP/s2")"
assert_eq "uniq_compare 13 (only s2)"   $'d\ne'   "$(uniq_compare 13 "$TMP/s1" "$TMP/s2")"
uniq_compare 12 "$TMP/s1" "$TMP/s2" "$TMP/out.txt" >/dev/null
assert_eq "uniq_compare writes file"    $'b\nc'   "$(<"$TMP/out.txt")"
assert_status "uniq_compare missing file -> 2" 2 uniq_compare 12 "$TMP/s1" "$TMP/gone"
assert_status "uniq_compare bad arity -> 2"    2 uniq_compare 12 "$TMP/s1"

assert_status "run_script: resolves PATH cmd" 0 run_script true
assert_status "run_script: unknown -> 1"      1 run_script definitely-not-a-real-binary-xyz
assert_status "run_script --help -> 0"        0 run_script --help
assert_status "wsl_interop_ok --help -> 0"    0 wsl_interop_ok --help

# ---- text.sh --------------------------------------------------------------
section "text.sh"
assert_eq "map_case: pattern applied"      "BazQUX"  "$(map_case 'FooBAR' 'bazqux')"
assert_eq "map_case: target longer"        "BaZQUx"  "$(map_case 'FoOBAr' 'bazqux')"
assert_eq "map_case: reference shorter"    "Bazqux"  "$(map_case 'F' 'bazqux')"
assert_eq "map_case: non-alpha in ref"     "abc"     "$(map_case '123' 'abc')"
assert_status "map_case wrong arity -> 2"  2 map_case a

typeset -gA PATH_SHORTEN_MAP=( "$TMP/deep/nest" '~/N' "$TMP/deep" '~/D' )
assert_eq "path_shorten: longest prefix wins" "~/N/x" "$(path_shorten --plain "$TMP/deep/nest/x")"
assert_eq "path_shorten: shorter prefix"      "~/D/y" "$(path_shorten --plain "$TMP/deep/y")"
unset PATH_SHORTEN_MAP
assert_eq "path_shorten: HOME fallback"       "~/zzz" "$(path_shorten --plain "$HOME/zzz")"
assert_eq "path_shorten: unmatched untouched" "/opt/x" "$(path_shorten --plain /opt/x)"
assert_eq "path_shorten: no colour when piped" "/opt/x" "$(path_shorten /opt/x)"

typeset -A NMAP=( '"/tmp/a/"' '"val/"' '/' '/' )
map_normalize NMAP
assert_eq "map_normalize: key cleaned"   "val"  "${NMAP[/tmp/a]}"
assert_eq "map_normalize: root preserved" "/"   "${NMAP[/]}"
typeset -a NOTAMAP=(1 2)
assert_status "map_normalize: rejects non-assoc -> 4" 4 map_normalize NOTAMAP
assert_status "map_normalize --help -> 0" 0 map_normalize --help

# ---- ini.sh ---------------------------------------------------------------
section "ini.sh"
cat > "$TMP/t.ini" <<'INI'
; a comment
[Alpha]
one = 1
two=2
# skipped
[Beta]
three = 3
novalue
INI
assert_eq "ini_keys: all keys"        $'one\ntwo\nthree' "$(ini_keys "$TMP/t.ini")"
assert_eq "ini_keys: -s Alpha"        $'one\ntwo'        "$(ini_keys -s 'Alpha' "$TMP/t.ini")"
assert_eq "ini_keys: -s two sections" $'one\ntwo\nthree' "$(ini_keys -s 'Alpha Beta' "$TMP/t.ini")"
assert_eq "ini_keys: -s unknown"      ""                 "$(ini_keys -s 'Nope' "$TMP/t.ini")"
assert_status "ini_keys: missing file -> 1" 1 ini_keys "$TMP/no.ini"
assert_status "ini_keys --help -> 0"        0 ini_keys --help

# ---- files.sh -------------------------------------------------------------
section "files.sh"
mk() { print -l 'alpha' '    beta KEY here' 'gamma' > "$1"; }

mk "$TMP/e1"; update_line replace 'KEY' 'REPLACED' "$TMP/e1" >/dev/null
assert_eq "update_line replace (keeps indent)" $'alpha\n    REPLACED\ngamma' "$(<"$TMP/e1")"

mk "$TMP/e2"; update_line before 'KEY' 'ABOVE' "$TMP/e2" >/dev/null
assert_eq "update_line before" $'alpha\n    ABOVE\n    beta KEY here\ngamma' "$(<"$TMP/e2")"

mk "$TMP/e3"; update_line after 'KEY' 'BELOW' "$TMP/e3" >/dev/null
assert_eq "update_line after" $'alpha\n    beta KEY here\n    BELOW\ngamma' "$(<"$TMP/e3")"

mk "$TMP/e4"; update_line delete 'KEY' "$TMP/e4" >/dev/null
assert_eq "update_line delete" $'alpha\ngamma' "$(<"$TMP/e4")"

mk "$TMP/e5"; update_line --dry-run replace 'KEY' 'NOPE' "$TMP/e5" >/dev/null
assert_eq "update_line --dry-run leaves file intact" $'alpha\n    beta KEY here\ngamma' "$(<"$TMP/e5")"

mk "$TMP/e6"
assert_contains "update_line: no-match warns" "No match" "$(update_line replace 'ZZZ' 'x' "$TMP/e6" 2>&1)"
assert_eq "update_line: no-match leaves file" $'alpha\n    beta KEY here\ngamma' "$(<"$TMP/e6")"

assert_status "update_line: bad mode -> 2"      2 update_line frobnicate k v "$TMP/e6"
assert_status "update_line: too few args -> 2"  2 update_line replace KEY
assert_status "update_line: missing file -> 1"  1 update_line replace KEY v "$TMP/absent"
assert_status "update_line --help -> 0"         0 update_line --help

# multi-file in one call
mk "$TMP/m1"; mk "$TMP/m2"
update_line delete 'KEY' "$TMP/m1" "$TMP/m2" >/dev/null
assert_eq "update_line: multi-file 1" $'alpha\ngamma' "$(<"$TMP/m1")"
assert_eq "update_line: multi-file 2" $'alpha\ngamma' "$(<"$TMP/m2")"

# backup / restore against scratch files only
print -r -- "original" > "$TMP/rc"
rcfile_backup "$TMP/rc" "$TMP/bk" >/dev/null
assert_status "rcfile_backup created a copy" 0 test -f "$TMP/bk/rc_$(date +%Y_%m_%d).backup"
print -r -- "changed" > "$TMP/rc"
print "y" | rcfile_restore "$TMP/bk/rc_$(date +%Y_%m_%d).backup" "$TMP/rc" >/dev/null 2>&1
assert_eq "rcfile_restore restored content" "original" "$(<"$TMP/rc")"
print -r -- "changed2" > "$TMP/rc"
print "n" | rcfile_restore "$TMP/bk/rc_$(date +%Y_%m_%d).backup" "$TMP/rc" >/dev/null 2>&1
assert_eq "rcfile_restore honours 'n'" "changed2" "$(<"$TMP/rc")"
assert_status "rcfile_restore missing backup -> 1" 1 rcfile_restore "$TMP/nofile" "$TMP/rc"

# ---- git.sh / worktree.sh -------------------------------------------------
section "git.sh + worktree.sh (local scratch repos)"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.invalid
git config --global user.name  Tester
git config --global init.defaultBranch main

UP="$TMP/upstream.git"; WK="$TMP/work"
git init --quiet --bare "$UP"
git init --quiet "$WK"
print -r -- "hello" > "$WK/a.txt"
git -C "$WK" add . >/dev/null
git -C "$WK" commit --quiet -m "first commit"
git -C "$WK" remote add origin "$UP"
git -C "$WK" push --quiet --set-upstream origin main 2>/dev/null

assert_eq "git_remote_project_path: strips .git" "${${UP#/}%.git}" "$(git_remote_project_path "$WK")"
assert_eq "git_remote_project_path: override"   "grp/proj" "$(git_remote_project_path "$WK" "grp/proj/")"
assert_status "git_remote_project_path: non-repo -> 1" 1 git_remote_project_path "$TMP/d1"

assert_status "git_has_commit_message: present -> 0" 0 git_has_commit_message "$WK" "first commit"
assert_status "git_has_commit_message: absent -> 1"  1 git_has_commit_message "$WK" "no such message"
assert_status "git_has_commit_message: partial is not a match -> 1" 1 git_has_commit_message "$WK" "first"

assert_status "git_safe_pull: clean repo -> 0"   0 git_safe_pull "$WK"
assert_status "git_safe_pull: non-repo -> 2"     2 git_safe_pull "$TMP/d1"
assert_status "git_pull_repos: bad path -> 2"    2 git_pull_repos "$TMP/nope"
assert_status "git_pull_all: bad root -> 2"      2 git_pull_all "$TMP/nope"
assert_contains "git_pull_all: finds the repo" "visited 1 repository" "$(git_pull_all "$TMP" 3 2>/dev/null)"

# dirty worktree must be skipped, not pulled or clobbered
print -r -- "local edit" >> "$WK/a.txt"
assert_status "git_safe_pull: dirty -> 0 (skip)" 0 git_safe_pull "$WK"
assert_contains "git_safe_pull: dirty file untouched" "local edit" "$(<"$WK/a.txt")"

# git_reset_hard_branch must discard that edit, and only when confirmed
assert_status "git_reset_hard_branch: no args -> 2" 2 git_reset_hard_branch
print "n" | git_reset_hard_branch main "$WK" >/dev/null 2>&1
assert_contains "reset declined leaves edit" "local edit" "$(<"$WK/a.txt")"
git_reset_hard_branch main "$WK" -y >/dev/null 2>&1
assert_eq "reset -y discards edit" "hello" "$(<"$WK/a.txt")"
assert_status "git_reset_hard_branch: unknown branch -> 1" 1 git_reset_hard_branch no-such-branch "$WK" -y

# branch lifecycle
git_checkout_upsert feature/x "$WK" >/dev/null 2>&1
assert_eq "git_checkout_upsert created branch" "feature/x" "$(git -C "$WK" symbolic-ref --short HEAD)"
git_checkout_upsert main "$WK" >/dev/null 2>&1
assert_eq "git_checkout_upsert switched back" "main" "$(git -C "$WK" symbolic-ref --short HEAD)"
git -C "$WK" checkout --quiet feature/x
assert_status "git_delete_merged_branch: merged branch removed" 0 git_delete_merged_branch "$WK"
assert_status "branch is gone" 1 git -C "$WK" show-ref --verify --quiet refs/heads/feature/x

git -C "$WK" checkout --quiet -b unmerged
print -r -- "diverge" > "$WK/b.txt"
git -C "$WK" add . >/dev/null; git -C "$WK" commit --quiet -m "unmerged work"
assert_status "git_delete_merged_branch: refuses unmerged -> 1" 1 git_delete_merged_branch "$WK"
assert_status "unmerged branch survives" 0 git -C "$WK" show-ref --verify --quiet refs/heads/unmerged
git -C "$WK" checkout --quiet main
assert_status "git_delete_merged_branch: refuses default branch -> 1" 1 git_delete_merged_branch "$WK"

# read-only worktrees
export WORKTREE_RO_TMPDIR="$TMP"
RO="$(worktree_ro_create "$WK" 2>/dev/null)"
if [[ -n "$RO" && -d "$RO" ]]; then
  ok "worktree_ro_create made a worktree"
  assert_eq "worktree contents match HEAD" "hello" "$(<"$RO/a.txt")"
  assert_status "worktree is detached" 1 git -C "$RO" symbolic-ref --quiet --short HEAD
  worktree_ro_remove "$WK" "$RO"
  assert_status "worktree_ro_remove cleaned up" 1 test -d "$RO"
else
  nope "worktree_ro_create made a worktree" "returned [$RO]"
fi
assert_status "worktree_ro_remove: empty args is a no-op" 0 worktree_ro_remove "" ""
assert_status "worktree_ro_create: non-repo -> 2" 2 worktree_ro_create "$TMP/d1"
assert_status "worktree_panic_cleanup always succeeds" 0 worktree_panic_cleanup "" "" "$TMP/nothing"
assert_status "worktree_ro_prune: tolerates bad repo" 0 worktree_ro_prune "$TMP/nope"

# sparse checkout path
print -r -- "a.txt" > "$TMP/sparse.txt"
print -r -- "second" > "$WK/c.txt"
git -C "$WK" add . >/dev/null; git -C "$WK" commit --quiet -m "add c"
git -C "$WK" push --quiet origin main 2>/dev/null
RO2="$(worktree_ro_create "$WK" "" "$TMP/sparse.txt" 2>/dev/null)"
if [[ -n "$RO2" && -d "$RO2" ]]; then
  assert_status "sparse worktree has a.txt"    0 test -f "$RO2/a.txt"
  assert_status "sparse worktree lacks c.txt"  1 test -f "$RO2/c.txt"
  worktree_ro_remove "$WK" "$RO2"
else
  nope "sparse worktree_ro_create" "returned [$RO2]"
fi

assert_status "git_repo_format_v0_if_safe: tolerates non-repo" 0 git_repo_format_v0_if_safe "$TMP/d1"
assert_status "git_repo_format_v0_all: bad root -> 1"          1 git_repo_format_v0_all "$TMP/nope"
git -C "$WK" config core.repositoryformatversion 1
git -C "$WK" config extensions.worktreeConfig true
git_repo_format_v0_if_safe "$WK" >/dev/null
assert_eq "repo format lowered to 0" "0" "$(git -C "$WK" config --get core.repositoryformatversion)"
git -C "$WK" config core.repositoryformatversion 1
git -C "$WK" config extensions.someOtherThing true
git_repo_format_v0_if_safe "$WK" >/dev/null 2>&1
assert_eq "refuses when a foreign extension is set" "1" \
  "$(git config -f "$WK/.git/config" --get core.repositoryformatversion)"
git config -f "$WK/.git/config" --remove-section extensions 2>/dev/null
git config -f "$WK/.git/config" core.repositoryformatversion 0

# ---- secrets.sh (no network, no gpg-agent) --------------------------------
section "secrets.sh"
export SECRET_STORE_DIR="$TMP/secrets"
assert_eq "secret_path" "$TMP/secrets/demo/.env.gpg" "$(secret_path demo)"
assert_status "secret_load: missing namespace -> 1" 1 secret_load demo
assert_status "gpg_passphrase --help -> 0"          0 gpg_passphrase --help
assert_status "secret_store: no args -> 2"          2 secret_store
assert_status "secret_set: too few args -> 2"       2 secret_set demo

print -r -- "hunter2" > "$TMP/pass"
export DEMO_GPG_PASSPHRASE_FILE="$TMP/pass"
assert_eq "gpg_passphrase reads passphrase file" "hunter2" "$(gpg_passphrase demo)"

if command -v gpg >/dev/null 2>&1; then
  if printf '%s' 'sk-secret-value' | secret_store demo DEMO_TOKEN >/dev/null 2>&1; then
    ok "secret_store wrote ciphertext"
    assert_status "ciphertext exists" 0 test -f "$TMP/secrets/demo/.env.gpg"
    if grep -qa 'sk-secret-value' "$TMP/secrets/demo/.env.gpg" 2>/dev/null; then
      nope "secret at rest is encrypted" "plaintext found in ciphertext file"
    else
      ok "secret at rest is encrypted"
    fi
    unset DEMO_TOKEN
    secret_load demo DEMO_TOKEN >/dev/null 2>&1
    assert_eq "secret_load round-trips the value" "sk-secret-value" "${DEMO_TOKEN:-}"
    assert_status "secret_load: required var present -> 0" 0 secret_load demo DEMO_TOKEN
    assert_status "secret_load: required var absent -> 1"  1 secret_load demo NOT_PRESENT
  else
    nope "secret_store wrote ciphertext" "gpg symmetric encryption failed"
  fi
else
  print -P "%F{yellow}  skip%f gpg round-trip (gpg not installed)"
fi

# ---- gitlab.sh (against a local stub API, no external network) -------------
section "gitlab.sh"

# Argument / configuration handling, before any stub is running.
unset GITLAB_URL GITLAB_TOKEN
assert_status "gitlab_token_check --help -> 0"        0 gitlab_token_check --help
assert_status "gitlab_token_rotate --help -> 0"       0 gitlab_token_rotate --help
assert_status "gitlab_token_create --help -> 0"       0 gitlab_token_create --help
assert_status "gitlab_token_revoke --help -> 0"       0 gitlab_token_revoke --help
assert_status "gitlab_token_list --help -> 0"         0 gitlab_token_list --help
assert_status "no GITLAB_URL -> 2"                    2 gitlab_token_check
assert_contains "no GITLAB_URL names the variable"    "GITLAB_URL is not set" "$(gitlab_token_check 2>&1)"
assert_status "non-http URL rejected -> 2"            2 gitlab_token_check --url ftp://x
assert_status "unknown flag -> 2"                     2 gitlab_token_check --bogus
assert_status "create without --name -> 2"            2 gitlab_token_create --url http://localhost:1 --scopes api
assert_status "create without --scopes -> 2"          2 gitlab_token_create --url http://localhost:1 --name x
assert_status "revoke without --id/--self -> 2"       2 gitlab_token_revoke --url http://localhost:1

# Stub GitLab API.
cat > "$TMP/stub.py" <<'STUB'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKENS = {
    "good":    {"id": 7, "name": "ci", "active": True, "expires_at": "2030-01-01", "scopes": ["api"]},
    "noscope": {"id": 8, "name": "ro", "active": True, "expires_at": "2030-01-01", "scopes": ["read_api"]},
}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, code, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body: self.wfile.write(body)

    def _auth(self):
        return TOKENS.get(self.headers.get("PRIVATE-TOKEN", ""))

    def do_GET(self):
        tok = self._auth()
        if tok is None: return self._send(401, {"message": "401 Unauthorized"})
        if self.path.startswith("/api/v4/personal_access_tokens/self"):
            return self._send(200, tok)
        if self.path.startswith("/api/v4/personal_access_tokens"):
            return self._send(200, list(TOKENS.values()))
        if self.path == "/api/v4/user":
            return self._send(200, {"id": 42, "username": "tester"})
        self._send(404, {"message": "404 Not Found"})

    def do_POST(self):
        tok = self._auth()
        if tok is None: return self._send(401, {"message": "401 Unauthorized"})
        if self.path.endswith("/self/rotate"):
            return self._send(200, {"token": "rotated-token-value", "expires_at": "2031-02-03"})
        if "/personal_access_tokens" in self.path and "/users/" in self.path:
            if self.path != "/api/v4/users/42/personal_access_tokens":
                return self._send(403, {"message": "403 Forbidden"})
            return self._send(201, {"token": "created-token-value", "expires_at": "2031-04-05"})
        self._send(404, {"message": "404 Not Found"})

    def do_DELETE(self):
        tok = self._auth()
        if tok is None: return self._send(401, {"message": "401 Unauthorized"})
        if self.path.endswith("/personal_access_tokens/999"):
            return self._send(404, {"message": "404 Not Found"})
        if "/personal_access_tokens/" in self.path:
            return self._send(204)
        self._send(404, {"message": "404 Not Found"})

srv = HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()
STUB

if (( ${+commands[curl]} && ${+commands[jq]} && ${+commands[python3]} )); then
  python3 "$TMP/stub.py" "$TMP/port" >/dev/null 2>&1 &
  STUB_PID=$!
  for _ in {1..50}; do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  PORT="$(<"$TMP/port" 2>/dev/null)"

  if [[ -n "$PORT" ]]; then
    export GITLAB_URL="http://127.0.0.1:$PORT"
    ok "stub API listening on port $PORT"

    export GITLAB_TOKEN=good
    assert_status "token_check: valid + rotatable -> 0" 0 gitlab_token_check
    assert_contains "token_check reports scopes" "scopes=api" "$(gitlab_token_check 2>&1)"
    assert_contains "token_check reports id"     "id=7"       "$(gitlab_token_check 2>&1)"

    export GITLAB_TOKEN=noscope
    assert_status "token_check: valid but not rotatable -> 24" 24 gitlab_token_check
    assert_status "rotate refuses when pre-flight fails -> 24" 24 gitlab_token_rotate

    export GITLAB_TOKEN=bad
    assert_status "token_check: 401 -> 21"  21 gitlab_token_check
    assert_status "token_list: 401 -> 21"   21 gitlab_token_list
    assert_status "revoke: 401 -> 21"       21 gitlab_token_revoke --id 5

    export GITLAB_TOKEN=good
    assert_contains "token_list renders a table" "ACTIVE" "$(gitlab_token_list 2>&1)"
    assert_contains "token_list includes both tokens" "ro" "$(gitlab_token_list 2>&1)"
    assert_status "revoke by id -> 0"        0 gitlab_token_revoke --id 5
    assert_status "revoke unknown id -> 24"  24 gitlab_token_revoke --id 999
    assert_status "revoke --self -> 0"       0 gitlab_token_revoke --self

    # Rotation persists into the secret store and updates the shell.
    export GITLAB_SECRET_NS=stubforge
    print -r -- "hunter2" > "$TMP/pass"
    export STUBFORGE_GPG_PASSPHRASE_FILE="$TMP/pass"
    export GITLAB_TOKEN=good
    if command -v gpg >/dev/null 2>&1; then
      gitlab_token_rotate --days 30 >/dev/null 2>&1
      assert_eq "rotate updated GITLAB_TOKEN in the shell" "rotated-token-value" "${GITLAB_TOKEN:-}"
      assert_status "rotate persisted ciphertext" 0 test -f "$SECRET_STORE_DIR/stubforge/.env.gpg"
      unset GITLAB_TOKEN
      secret_load stubforge GITLAB_TOKEN >/dev/null 2>&1
      assert_eq "rotated token round-trips from the store" "rotated-token-value" "${GITLAB_TOKEN:-}"
    else
      print -P "%F{yellow}  skip%f rotate persistence (gpg not installed)"
    fi

    # Creation: user id resolution, then the create call.
    export GITLAB_TOKEN=good
    assert_contains "create reports the new token" "created-token-value" \
      "$(gitlab_token_create --name ci --scopes api --no-save 2>&1)"
    assert_status "create against a forbidden user id -> 22" 22 \
      gitlab_token_create --name ci --scopes api --user-id 99 --no-save

    # Network failure: point at a closed port.
    assert_status "unreachable host -> 6" 6 gitlab_token_check --url http://127.0.0.1:1

    # Point at an empty namespace so the auto-load from the secret store finds
    # nothing; otherwise the previously-stored token is (correctly) picked up.
    unset GITLAB_TOKEN
    export GITLAB_SECRET_NS=namespace-with-no-store
    assert_status "no token available -> 11" 11 gitlab_token_check
    assert_contains "no-token error is actionable" "GITLAB_TOKEN is empty" "$(gitlab_token_check 2>&1)"
    # ...and prove auto-load does work when the namespace does have one.
    if command -v gpg >/dev/null 2>&1; then
      export GITLAB_SECRET_NS=stubforge
      unset GITLAB_TOKEN
      assert_status "token auto-loaded from the secret store -> 21 (reached the API)" 21 gitlab_token_check
    fi
  else
    nope "stub API listening" "server did not report a port"
  fi
  [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null
  unset GITLAB_URL GITLAB_TOKEN GITLAB_SECRET_NS STUBFORGE_GPG_PASSPHRASE_FILE
else
  print -P "%F{yellow}  skip%f gitlab.sh live checks (curl, jq or python3 missing)"
fi

# ---- bin/ ------------------------------------------------------------------
section "bin/"
for b in update-line prefix-files strip-prefix; do
  assert_status "bin/$b is executable" 0 test -x "$ROOT/bin/$b"
done
assert_contains "bin/update-line --help" "Usage: update_line" "$("$ROOT/bin/update-line" --help 2>&1)"
assert_status  "bin/update-line no args -> 2" 2 "$ROOT/bin/update-line"
mk "$TMP/cli1"
"$ROOT/bin/update-line" replace 'KEY' 'FROM_CLI' "$TMP/cli1" >/dev/null
assert_eq "bin/update-line edits a file" $'alpha\n    FROM_CLI\ngamma' "$(<"$TMP/cli1")"

assert_contains "bin/prefix-files --help" "Usage:" "$("$ROOT/bin/prefix-files" --help 2>&1)"
assert_contains "bin/strip-prefix --help" "Usage:" "$("$ROOT/bin/strip-prefix" --help 2>&1)"

mkdir -p "$TMP/pf"; print -r -- x > "$TMP/pf/one.txt"; print -r -- x > "$TMP/pf/two.txt"
assert_contains "prefix-files --dry-run previews .txt (no longer pruned)" "one.txt" \
  "$("$ROOT/bin/prefix-files" "$TMP/pf" a-z 4 1 1 --dry-run 2>&1)"
assert_status "prefix-files --dry-run left originals" 0 test -f "$TMP/pf/one.txt"
"$ROOT/bin/prefix-files" "$TMP/pf" a-z 4 1 1 >/dev/null 2>&1
assert_status "prefix-files renamed the original away" 1 test -f "$TMP/pf/one.txt"
assert_eq "prefix-files produced 2 prefixed files" "2" \
  "$(print -l "$TMP/pf"/*_one.txt "$TMP/pf"/*_two.txt(N) | grep -c . )"
mkdir -p "$TMP/pf2"; print -r -- x > "$TMP/pf2/keep.txt"; print -r -- x > "$TMP/pf2/move.log"
"$ROOT/bin/prefix-files" "$TMP/pf2" a-z 4 1 1 --skip='*.txt' >/dev/null 2>&1
assert_status "--skip=*.txt honoured" 0 test -f "$TMP/pf2/keep.txt"
assert_status "--skip left non-matching file renamed" 1 test -f "$TMP/pf2/move.log"

# ---- hygiene: allowlist-based, no embedded wordlist -------------------------
section "hygiene"

# Any host referenced anywhere must be a documentation placeholder or the
# public forge. Allowlisting is used deliberately: an inline denylist of
# specific names would itself be a leak.
HOSTS="$(grep -rhoE '(https?://|git@)[A-Za-z0-9.-]+' "$ROOT"/lib "$ROOT"/bin "$ROOT"/README.md 2>/dev/null \
         | sed -E 's#^(https?://|git@)##' | sort -u \
         | grep -vE '^(host|example\.(com|org|invalid)|gitlab\.example\.com|github\.com|localhost|127\.0\.0\.1)$' || true)"
[[ -z "$HOSTS" ]] && ok "every referenced host is a placeholder or public forge" \
                 || nope "unexpected host referenced" "$HOSTS"

# No absolute paths tied to one machine or account.
HOMEPATHS="$(grep -rnE '(/home/[a-z]|/Users/[a-z]|/mnt/[a-z]/Users)' "$ROOT"/lib "$ROOT"/bin "$ROOT"/README.md 2>/dev/null || true)"
[[ -z "$HOMEPATHS" ]] && ok "no machine-specific absolute paths" \
                     || nope "machine-specific path" "$HOMEPATHS"

# No credential-shaped literals. The prefixes are assembled at runtime rather
# than written out, so this file does not match its own detector (and does not
# trip external secret scanners).
CRED_RE="($(print -r -- 'gl'; print -r -- 'pat-')[A-Za-z0-9_-]{8,}"
CRED_RE="${CRED_RE//$'\n'/}"
CRED_RE="${CRED_RE}|gh$(print -r -- 'p')_[A-Za-z0-9]{8,}"
CRED_RE="${CRED_RE}|AK$(print -r -- 'IA')[0-9A-Z]{16}"
CRED_RE="${CRED_RE}|xo$(print -r -- 'x')[baprs]-"
CRED_RE="${CRED_RE}|BEGIN [A-Z ]*PRIV$(print -r -- 'ATE') KEY)"
CREDS="$(grep -rnE "$CRED_RE" "$ROOT" 2>/dev/null || true)"
[[ -z "$CREDS" ]] && ok "no credential-shaped literals" \
                 || nope "credential-shaped literal" "$CREDS"

# Every documented env var must be namespaced to this project, not inherited
# from some other environment.
BAREVARS="$(grep -rhoE '\$\{?[A-Z][A-Z0-9_]{3,}\}?' "$ROOT"/lib 2>/dev/null | tr -d '${}' | sort -u \
            | grep -vE '^(HOME|TMPDIR|PATH|TERM|IFS|RANDOM|XDG_DATA_HOME|GITLAB_URL|GITLAB_TOKEN|GITLAB_SECRET_NS|GITLAB_TOKEN_DEFAULT_DAYS|SECRET_STORE_DIR|PATH_SHORTEN_MAP|WORKTREE_RO_TMPDIR|WSL_DISTRO_NAME|WSL_INTEROP|WSL_INTEROP_PROBE|BASH_SOURCE|LINENO)$' || true)"
[[ -z "$BAREVARS" ]] && ok "no undocumented external env vars referenced" \
                    || nope "undocumented env var" "$BAREVARS"

# ---- summary ---------------------------------------------------------------
print
print -P "%F{cyan}────────────────────────────────────────%f"
if (( FAIL == 0 )); then
  print -P "%F{green}All $PASS checks passed.%f"
  exit 0
else
  print -P "%F{red}$FAIL failed%f, $PASS passed."
  print -l -- "${FAILURES[@]}" | sed 's/^/  - /'
  exit 1
fi
