#!/usr/bin/env zsh
# gitlab.sh — personal access token lifecycle against any GitLab instance.
#
# Check, list, rotate, create and revoke PATs from the shell, so a token can be
# kept short-lived without a trip through the web UI.
#
# Configuration:
#   GITLAB_URL                base URL of the instance. REQUIRED — there is no
#                             default, so a misconfigured shell fails loudly
#                             instead of talking to the wrong host.
#                             Override per call with --url.
#   GITLAB_TOKEN              the token to authenticate with. When unset and
#                             lib/secrets.sh is loaded, it is decrypted from the
#                             secret store automatically.
#   GITLAB_SECRET_NS          secret-store namespace to load from and persist
#                             to. Default: gitlab
#   GITLAB_TOKEN_DEFAULT_DAYS default lifetime for new/rotated tokens. Default: 90
#
# Requires curl; jq for everything except revoke.
#
# Exit statuses are shared across the suite so callers can branch on them:
#    0 ok            2 usage error    6 network error
#   11 no token     21 HTTP 401      22 HTTP 403      24 HTTP 404 / not rotatable
#   25 other HTTP   26 malformed response          27 obtained but not persisted

: ${GITLAB_SECRET_NS:=gitlab}
: ${GITLAB_TOKEN_DEFAULT_DAYS:=90}

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# Resolve and validate the base URL. $1 overrides GITLAB_URL when non-empty.
function _gitlab_base() {
  local base="${1:-${GITLAB_URL:-}}"
  [[ -n "$base" ]] || {
    print -P "%F{red}GITLAB_URL is not set. Export it, or pass --url https://gitlab.example.com%f" >&2
    return 2; }
  [[ "$base" == (http|https)://* ]] || {
    print -P "%F{red}GITLAB_URL must start with http:// or https:// (got '$base')%f" >&2
    return 2; }
  print -r -- "${base%/}"
}

# Ensure GITLAB_TOKEN is populated, pulling it from the secret store if needed.
function _gitlab_token() {
  if [[ -z "${GITLAB_TOKEN:-}" ]] && (( ${+functions[secret_load]} )); then
    secret_load "$GITLAB_SECRET_NS" GITLAB_TOKEN >/dev/null 2>&1 || true
  fi
  [[ -n "${GITLAB_TOKEN:-}" ]] || {
    print -P "%F{red}GITLAB_TOKEN is empty. Export it, or store it with: secret_set ${GITLAB_SECRET_NS} GITLAB_TOKEN%f" >&2
    return 11; }
  return 0
}

# Persist a token: encrypted when lib/secrets.sh is loaded, else tell the user.
# Returns non-zero when the caller must surface the token itself.
function _gitlab_persist() {
  local token="$1"
  if (( ${+functions[secret_store]} )); then
    print -r -- "$token" | secret_store "$GITLAB_SECRET_NS" GITLAB_TOKEN >/dev/null || return 1
    return 0
  fi
  return 1
}

# _gitlab_api <method> <base> <path> [curl_args...]
# Emit "<http_code>\n<body>". Returns 6 on transport failure.
function _gitlab_api() {
  local -r method="$1" base="$2" endpoint="$3"; shift 3
  local resp
  resp="$(curl -sS --max-time 25 -w $'\n%{http_code}' -X "$method" \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$@" "${base}${endpoint}")" || return 6
  local code="${resp##*$'\n'}" body="${resp%$'\n'*}"
  print -r -- "$code"
  print -r -- "$body"
}

# Map an HTTP code to a status + message. $2 is the response body.
function _gitlab_http_fail() {
  local -r code="$1" body="${2:-}"
  case "$code" in
    401) print -P "%F{red}HTTP 401 — token expired, revoked or invalid.%f" >&2; return 21 ;;
    403) print -P "%F{red}HTTP 403 — token lacks the required scope.%f" >&2; return 22 ;;
    404) print -P "%F{yellow}HTTP 404 — not found (already revoked?).%f" >&2; return 24 ;;
    *)   print -P "%F{red}HTTP ${code}:%f" >&2
         if (( ${+commands[jq]} )) && [[ -n "$body" ]]; then
           print -r -- "$body" | jq -r '.message? // .error? // .' 2>/dev/null >&2 || print -r -- "$body" >&2
         else
           [[ -n "$body" ]] && print -r -- "$body" >&2
         fi
         return 25 ;;
  esac
}

# Compute an expiry date. $1 explicit date, $2 days; falls back to the default.
function _gitlab_expiry() {
  local explicit="${1:-}" days="${2:-}"
  [[ -n "$explicit" ]] && { print -r -- "$explicit"; return 0; }
  [[ -n "$days" ]] || days="$GITLAB_TOKEN_DEFAULT_DAYS"
  date -d "+${days} days" +%F 2>/dev/null || date -v "+${days}d" +%F 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# gitlab_token_check [--url URL]
# Report the current token's id, name, expiry and scopes, and whether it is
# able to rotate itself.
#   0  valid and self-rotatable        24  valid but cannot self-rotate
# ---------------------------------------------------------------------------
function gitlab_token_check() {
  emulate -L zsh
  setopt local_options pipe_fail
  local url=""
  while (( $# )); do
    case "$1" in
      --url) url="$2"; shift 2 ;;
      -h|--help)
        print -r -- "Usage: gitlab_token_check [--url URL]
Report the current token's id, name, active flag, expiry and scopes, and
whether it can rotate itself (needs the 'api' or 'self_rotate' scope).

Exit: 0 valid and self-rotatable, 24 valid but not rotatable,
      21 invalid, 22 forbidden, 6 network, 11 no token."
        return 0 ;;
      *) print -P "%F{red}gitlab_token_check: unknown argument '$1'%f" >&2; return 2 ;;
    esac
  done

  (( ${+commands[curl]} && ${+commands[jq]} )) || {
    print -P "%F{red}gitlab_token_check: curl and jq are required.%f" >&2; return 1; }
  local base; base="$(_gitlab_base "$url")" || return 2
  _gitlab_token || return 11

  local out code body
  out="$(_gitlab_api GET "$base" /api/v4/personal_access_tokens/self)" || {
    print -P "%F{red}gitlab_token_check: network error reaching ${base}.%f" >&2; return 6; }
  code="${out%%$'\n'*}"; body="${out#*$'\n'}"
  [[ "$code" == 200 ]] || { _gitlab_http_fail "$code" "$body"; return $?; }

  print -r -- "$body" | jq -r '"id=\(.id)  name=\(.name)  active=\(.active)  expires=\(.expires_at // "never")  scopes=\(.scopes|join(","))"'
  local scopes; scopes="$(print -r -- "$body" | jq -r '.scopes|join(",")')"
  if print -r -- "$scopes" | grep -qE '(^|,)(api|self_rotate)(,|$)'; then
    print -P "%F{green}Token is valid and can self-rotate.%f"
    return 0
  fi
  print -P "%F{yellow}Token valid, but scopes [${scopes}] cannot self-rotate (need 'api' or 'self_rotate').%f" >&2
  return 24
}

# ---------------------------------------------------------------------------
# gitlab_token_list [--url URL]
# Table of every PAT on the account: id, active, expiry, scopes, name.
# ---------------------------------------------------------------------------
function gitlab_token_list() {
  emulate -L zsh
  setopt local_options pipe_fail
  local url=""
  while (( $# )); do
    case "$1" in
      --url) url="$2"; shift 2 ;;
      -h|--help)
        print -r -- "Usage: gitlab_token_list [--url URL]
List every personal access token on the account as a table:
id, active, expires, scopes, name. Useful for finding a token to revoke."
        return 0 ;;
      *) print -P "%F{red}gitlab_token_list: unknown argument '$1'%f" >&2; return 2 ;;
    esac
  done

  (( ${+commands[curl]} && ${+commands[jq]} )) || {
    print -P "%F{red}gitlab_token_list: curl and jq are required.%f" >&2; return 1; }
  local base; base="$(_gitlab_base "$url")" || return 2
  _gitlab_token || return 11

  local out code body
  out="$(_gitlab_api GET "$base" '/api/v4/personal_access_tokens?per_page=100')" || {
    print -P "%F{red}gitlab_token_list: network error.%f" >&2; return 6; }
  code="${out%%$'\n'*}"; body="${out#*$'\n'}"
  [[ "$code" == 200 ]] || { _gitlab_http_fail "$code" "$body"; return $?; }

  {
    print -r -- $'ID\tACTIVE\tEXPIRES\tSCOPES\tNAME'
    print -r -- "$body" | jq -r '.[] | "\(.id)\t\(.active)\t\(.expires_at // "never")\t[\(.scopes|join(","))]\t\(.name)"'
  } | { (( ${+commands[column]} )) && column -t -s $'\t' || cat }
}

# ---------------------------------------------------------------------------
# gitlab_token_rotate [--url URL] [--expires-at YYYY-MM-DD | --days N | DATE]
# Rotate the current token in place. Pre-flights with gitlab_token_check so a
# doomed rotation never revokes a working token.
# ---------------------------------------------------------------------------
function gitlab_token_rotate() {
  emulate -L zsh
  setopt local_options pipe_fail
  local url="" expires_at="" days=""
  while (( $# )); do
    case "$1" in
      --url)        url="$2"; shift 2 ;;
      --expires-at) expires_at="$2"; shift 2 ;;
      --days)       days="$2"; shift 2 ;;
      -h|--help)
        print -r -- "Usage: gitlab_token_rotate [--url URL] [--expires-at YYYY-MM-DD | --days N | DATE]
Rotate the current personal access token in place and persist the replacement.

  --expires-at DATE   explicit expiry for the new token
  --days N            expiry N days from today
  DATE                positional shorthand for --expires-at
                      (default: \$GITLAB_TOKEN_DEFAULT_DAYS days, currently ${GITLAB_TOKEN_DEFAULT_DAYS})

Pre-flights with gitlab_token_check and refuses to rotate if that fails, so a
working token is never revoked for nothing. The new token is written to the
encrypted secret store when lib/secrets.sh is loaded, and exported into the
current shell. If it cannot be persisted it is printed once — save it, because
the old token is already dead by then."
        return 0 ;;
      --) shift; break ;;
      --*) print -P "%F{red}gitlab_token_rotate: unknown flag '$1'%f" >&2; return 2 ;;
      *)  expires_at="$1"; shift ;;
    esac
  done

  (( ${+commands[curl]} && ${+commands[jq]} )) || {
    print -P "%F{red}gitlab_token_rotate: curl and jq are required.%f" >&2; return 1; }
  local base; base="$(_gitlab_base "$url")" || return 2
  _gitlab_token || return 11

  local -i chk=0
  gitlab_token_check --url "$base" >/dev/null 2>&1 || chk=$?
  if (( chk != 0 )); then
    print -P "%F{red}gitlab_token_rotate: pre-flight failed — not rotating. Details:%f" >&2
    gitlab_token_check --url "$base" >&2
    return $chk
  fi

  expires_at="$(_gitlab_expiry "$expires_at" "$days")"
  local -a data=()
  [[ -n "$expires_at" ]] && data=(--data-urlencode "expires_at=${expires_at}")

  local out code body new_token new_exp
  out="$(_gitlab_api POST "$base" /api/v4/personal_access_tokens/self/rotate "${data[@]}")" || {
    print -P "%F{red}gitlab_token_rotate: network error during rotate — old token unchanged.%f" >&2; return 6; }
  code="${out%%$'\n'*}"; body="${out#*$'\n'}"
  [[ "$code" == 200 || "$code" == 201 ]] || {
    print -P "%F{red}Rotate failed — old token unchanged.%f" >&2
    _gitlab_http_fail "$code" "$body"; return $?; }

  new_token="$(print -r -- "$body" | jq -r '.token // empty')"
  new_exp="$(print -r -- "$body" | jq -r '.expires_at // "n/a"')"
  [[ -n "$new_token" ]] || {
    print -P "%F{red}Rotate returned HTTP ${code} with no token field — the old token may already be revoked. Check the web UI.%f" >&2
    return 26; }

  if ! _gitlab_persist "$new_token"; then
    print -P "%F{red}Rotated, but could not persist. Copy this token NOW — the old one is revoked:%f" >&2
    print -r -- "$new_token"
    export GITLAB_TOKEN="$new_token"
    return 27
  fi
  export GITLAB_TOKEN="$new_token"
  print -P "%F{green}Token rotated and stored. New expiry: ${new_exp}. Shell updated.%f"
}

# ---------------------------------------------------------------------------
# gitlab_token_create --name N --scopes S [options]
# Create a brand new PAT. The per-user create endpoint is admin-only on GitLab;
# non-admins should mint the first token in the UI and use rotate thereafter.
# ---------------------------------------------------------------------------
function gitlab_token_create() {
  emulate -L zsh
  setopt local_options pipe_fail
  local url="" name="" scopes="" expires_at="" days="" desc="" uid=""
  local -i save=1 show=0 revoke_old=0
  while (( $# )); do
    case "$1" in
      --url)                 url="$2"; shift 2 ;;
      --name)                name="$2"; shift 2 ;;
      --scopes)              scopes="$2"; shift 2 ;;
      --expires-at)          expires_at="$2"; shift 2 ;;
      --days)                days="$2"; shift 2 ;;
      --description|--desc)  desc="$2"; shift 2 ;;
      --user-id)             uid="$2"; shift 2 ;;
      --no-save)             save=0; shift ;;
      --print)               show=1; shift ;;
      --revoke-old)          revoke_old=1; shift ;;
      -h|--help)
        print -r -- "Usage: gitlab_token_create --name NAME --scopes S1,S2 [options]
Create a new personal access token.

  --name NAME          required
  --scopes S1,S2       required, comma separated (e.g. api,self_rotate)
  --expires-at DATE    explicit expiry
  --days N             expiry N days from today (default ${GITLAB_TOKEN_DEFAULT_DAYS})
  --description TEXT   free-text description
  --user-id ID         target user (default: the authenticated user)
  --url URL            override \$GITLAB_URL
  --no-save            do not write to the secret store; print the token instead
  --print              print the token as well as saving it
  --revoke-old         revoke the previously-in-use token, but only after the
                       new one has been created AND persisted

Note: creating a token for a user is admin-only on GitLab. Non-admins should
create the first token in the web UI and use gitlab_token_rotate afterwards.

Example:
  gitlab_token_create --name ci-bot --scopes api,self_rotate --days 90 --revoke-old"
        return 0 ;;
      --) shift; break ;;
      *) print -P "%F{red}gitlab_token_create: unknown argument '$1'%f" >&2; return 2 ;;
    esac
  done

  (( ${+commands[curl]} && ${+commands[jq]} )) || {
    print -P "%F{red}gitlab_token_create: curl and jq are required.%f" >&2; return 1; }
  [[ -n "$name" ]]   || { print -P "%F{red}gitlab_token_create: --name is required.%f" >&2; return 2; }
  [[ -n "$scopes" ]] || { print -P "%F{red}gitlab_token_create: --scopes is required (e.g. api,self_rotate).%f" >&2; return 2; }
  local base; base="$(_gitlab_base "$url")" || return 2
  _gitlab_token || return 11

  # Capture the current token id first, so --revoke-old still knows the target
  # after GITLAB_TOKEN has been replaced.
  local old_id=""
  if (( revoke_old )); then
    local self_out
    self_out="$(_gitlab_api GET "$base" /api/v4/personal_access_tokens/self)" || self_out=""
    old_id="$(print -r -- "${self_out#*$'\n'}" | jq -r '.id // empty' 2>/dev/null)"
    [[ -n "$old_id" ]] || print -P "%F{yellow}gitlab_token_create: could not resolve the current token id — --revoke-old will be skipped.%f" >&2
  fi

  expires_at="$(_gitlab_expiry "$expires_at" "$days")"

  if [[ -z "$uid" ]]; then
    local user_out
    user_out="$(_gitlab_api GET "$base" /api/v4/user)" || {
      print -P "%F{red}gitlab_token_create: network error.%f" >&2; return 6; }
    [[ "${user_out%%$'\n'*}" == 200 ]] || { _gitlab_http_fail "${user_out%%$'\n'*}" "${user_out#*$'\n'}"; return $?; }
    uid="$(print -r -- "${user_out#*$'\n'}" | jq -r '.id // empty')"
    [[ -n "$uid" ]] || { print -P "%F{red}gitlab_token_create: could not resolve your user id.%f" >&2; return 21; }
  fi

  local -a data=(--data-urlencode "name=${name}")
  [[ -n "$expires_at" ]] && data+=(--data-urlencode "expires_at=${expires_at}")
  [[ -n "$desc" ]]       && data+=(--data-urlencode "description=${desc}")
  local s; for s in ${(s:,:)scopes}; do data+=(--data-urlencode "scopes[]=${s}"); done

  local out code body new_token new_exp
  out="$(_gitlab_api POST "$base" "/api/v4/users/${uid}/personal_access_tokens" "${data[@]}")" || {
    print -P "%F{red}gitlab_token_create: network error.%f" >&2; return 6; }
  code="${out%%$'\n'*}"; body="${out#*$'\n'}"
  if [[ "$code" != 200 && "$code" != 201 ]]; then
    [[ "$code" == 403 ]] && print -P "%F{yellow}Creating a token for a user is admin-only. Create one in the UI, then use gitlab_token_rotate.%f" >&2
    _gitlab_http_fail "$code" "$body"; return $?
  fi

  new_token="$(print -r -- "$body" | jq -r '.token // empty')"
  new_exp="$(print -r -- "$body" | jq -r '.expires_at // "n/a"')"
  [[ -n "$new_token" ]] || {
    print -P "%F{red}gitlab_token_create: created, but no token field was returned.%f" >&2
    print -r -- "$body" >&2; return 26; }

  print -P "%F{green}Created token '${name}' (scopes ${scopes}, expires ${new_exp}).%f"

  if (( save )); then
    if _gitlab_persist "$new_token"; then
      export GITLAB_TOKEN="$new_token"
      print -P "%F{green}  stored and loaded into this shell.%f"
    else
      print -P "%F{red}  created but could not be saved — copy it now:%f" >&2
      print -r -- "$new_token"
      return 27
    fi
  fi
  if (( show || ! save )); then
    (( save )) || print -P "%F{yellow}  (--no-save: shown once)%f" >&2
    print -r -- "$new_token"
  fi

  # Only revoke the old token once the new one is safely stored.
  if (( revoke_old )); then
    if [[ -z "$old_id" ]]; then
      print -P "%F{yellow}  --revoke-old: old id unknown; revoke it manually.%f" >&2
    elif (( ! save )); then
      print -P "%F{yellow}  --revoke-old skipped (--no-save). Once saved: gitlab_token_revoke --id ${old_id}%f" >&2
    elif gitlab_token_revoke --url "$base" --id "$old_id" >/dev/null 2>&1; then
      print -P "%F{green}  revoked the old token (id ${old_id}).%f"
    else
      print -P "%F{yellow}  could not revoke the old token — run: gitlab_token_revoke --id ${old_id}%f" >&2
    fi
  fi
}

# ---------------------------------------------------------------------------
# gitlab_token_revoke (--id N | --self) [--url URL]
# Revoke a token by id, or the one currently in use.
# ---------------------------------------------------------------------------
function gitlab_token_revoke() {
  emulate -L zsh
  setopt local_options pipe_fail
  local url="" id=""
  local -i self=0
  while (( $# )); do
    case "$1" in
      --url)  url="$2"; shift 2 ;;
      --id)   id="$2"; shift 2 ;;
      --self) self=1; shift ;;
      -h|--help)
        print -r -- "Usage: gitlab_token_revoke (--id N | --self) [--url URL]
Revoke a personal access token.

  --id N   revoke the token with this id (see gitlab_token_list)
  --self   revoke the token currently in use — needs the 'api' scope

Exit: 0 revoked, 24 not found (already revoked), 21 invalid, 22 forbidden."
        return 0 ;;
      --) shift; break ;;
      *) print -P "%F{red}gitlab_token_revoke: unknown argument '$1'%f" >&2; return 2 ;;
    esac
  done

  (( ${+commands[curl]} )) || { print -P "%F{red}gitlab_token_revoke: curl is required.%f" >&2; return 1; }
  local base; base="$(_gitlab_base "$url")" || return 2

  local endpoint
  if [[ -n "$id" ]]; then
    endpoint="/api/v4/personal_access_tokens/${id}"
  elif (( self )); then
    endpoint="/api/v4/personal_access_tokens/self"
  else
    print -P "%F{red}gitlab_token_revoke: specify --id N or --self.%f" >&2
    return 2
  fi

  _gitlab_token || return 11

  local out code body
  out="$(_gitlab_api DELETE "$base" "$endpoint")" || {
    print -P "%F{red}gitlab_token_revoke: network error.%f" >&2; return 6; }
  code="${out%%$'\n'*}"; body="${out#*$'\n'}"
  case "$code" in
    204|200) print -P "%F{green}Revoked token (${id:-self}).%f"; return 0 ;;
    *) _gitlab_http_fail "$code" "$body"; return $? ;;
  esac
}
