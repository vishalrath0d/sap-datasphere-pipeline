#!/usr/bin/env bash
# Shared helpers. `source` this file; do not execute it.
# Works with the bash 3.2 that ships with macOS (no associative arrays, no mapfile).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT/scripts/env.sh"   # reads .env locally (never in CI)

DEF_DIR="${DEF_DIR:-$ROOT/definitions}"
DS_MODE="${DS_MODE:-mock}"            # mock = built-in simulator, real = SAP Datasphere CLI
export DEF_DIR DS_MODE
export MOCK_DS_STATE="${MOCK_DS_STATE:-$ROOT/.mock-state}"

# Format `objects <type> read` returns. design-time is what SAP's CLI guide uses for
# read-from-one-space / create-in-another (it also includes the _Delta table of a
# delta-capture local table). Override with DS_READ_ACCEPT if your tenant needs another.
DS_READ_ACCEPT="${DS_READ_ACCEPT:-application/vnd.sap.datasphere.object.content.design-time+json}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

_TMP_FILES=""
_CI_LOGGED_IN=0
_cleanup() {
  [ -n "$_TMP_FILES" ] && rm -f $_TMP_FILES
  [ "$_CI_LOGGED_IN" = 1 ] && datasphere config secrets reset </dev/null >/dev/null 2>&1
  true
}
trap _cleanup EXIT
tmpfile() { local f; f="$(mktemp)"; _TMP_FILES="$_TMP_FILES $f"; printf '%s\n' "$f"; }

# Single entry point to the CLI so mock/real/passcode is decided in exactly one place.
ds() {
  if [ "$DS_MODE" = "mock" ]; then
    python3 "$ROOT/tools/mock-datasphere/datasphere" "$@"
  elif _needs_passcode "$@"; then
    local pc
    pc="$(get_passcode)" || return 1
    datasphere "$@" --passcode "$pc"
  else
    datasphere "$@"
  fi
}

# ---- passcode mode (DS_AUTH=passcode) -------------------------------------------------------
# For tenants where you cannot create an OAuth client (e.g. the shared 30-day trial: no
# System > Administration > App Integration). Without an OAuth login, the CLI needs a NEW
# one-time passcode for every call that reaches the tenant (SAP CLI guide 2.4, "Passcode Option").
#   DS_PASSCODE_SOURCE=chrome (default)  read it from the Chrome session of
#                                        tools/passcode/chrome-session.sh - fully automatic
#   DS_PASSCODE_SOURCE=prompt            open the passcode page, you paste the code
# Laptop only: it depends on your signed-in browser, so it cannot run in CI.

_needs_passcode() { # does this CLI call reach the tenant?
  [ "${DS_AUTH:-}" = "passcode" ] || return 1
  case "${1:-}" in
    config) [ "${2:-}" = "cache" ] && [ "${3:-}" = "init" ] ;;   # host/passcode-url/secrets are local
    login|logout|help|-h|--help|-v|--version) return 1 ;;
    *) return 0 ;;
  esac
}

get_passcode() {
  local url="${DS_PASSCODE_URL:?DS_PASSCODE_URL not set - ds_login computes it}" code
  if [ "${DS_PASSCODE_SOURCE:-chrome}" = "chrome" ] && code="$(node "$ROOT/tools/passcode/get-passcode.mjs" "$url")"; then
    printf '%s' "$code"; return 0
  fi
  [ -t 2 ] || die "no passcode: the Chrome helper failed and there is no terminal to ask"
  log "get a passcode from $url (refresh the page for each new one)"
  if [ "${DS_PASSCODE_OPEN:-1}" = "1" ]; then open_url "$url" || true; fi
  read -r -s -p "Passcode: " code </dev/tty; echo >&2
  [ -n "$code" ] || die "empty passcode"
  printf '%s' "$code"
}

# retry <attempts> <command...>   (linear back-off: 5s, 10s, ...)
retry() {
  local n=$1; shift
  local i=1
  until "$@"; do
    if [ "$i" -ge "$n" ]; then return 1; fi
    log "attempt $i/$n failed; retrying in $((i * 5))s: $*"
    sleep $((i * 5))
    i=$((i + 1))
  done
}

# env_space <env>  ->  technical name of the Datasphere space for that environment
env_space() {
  if [ -n "${DS_SPACE:-}" ]; then printf '%s\n' "$DS_SPACE"; return; fi
  python3 - "$ROOT/config/environments.json" "$1" <<'PY'
import json, sys
cfg, env = sys.argv[1], sys.argv[2]
data = json.load(open(cfg))
if env not in data or not isinstance(data[env], dict):
    sys.exit("unknown environment '%s' (known: %s)" % (env, ", ".join(k for k in data if not k.startswith("_"))))
print(data[env]["space"])
PY
}

# ds_login - authenticate the CLI. Four ways, checked in this order:
#
#   DS_SKIP_LOGIN=1        reuse the session you created yourself (scripts/login-interactive.sh).
#                          Good for running the scripts from your laptop.
#   DS_AUTH=passcode       no OAuth client available (trial): one passcode per call, see above.
#   DS_CLIENT_ID + DS_CLIENT_SECRET + DS_TOKEN_URL
#                          OAuth client with purpose "Technical User" (grant: client credentials).
#                          This is the CI path: no browser, nothing expires after 30 days.
#                          SAP supports technical users for `datasphere objects` (CLI guide 2.3).
#   DS_SECRETS_FILE        secrets file with access/refresh tokens taken from an interactive
#                          login (`datasphere config secrets show`). Tokens last 720 h.
#
# DS_HOST (tenant URL) is always required in real mode.
ds_login() {
  if [ "$DS_MODE" = "mock" ]; then
    ds login >/dev/null
    return 0
  fi
  : "${DS_HOST:?DS_HOST is required, e.g. https://<tenant>.<region>.hcs.cloud.sap}"
  ds config host set "$DS_HOST" >&2

  if [ "${DS_SKIP_LOGIN:-0}" = "1" ]; then
    log "DS_SKIP_LOGIN=1 - reusing the existing CLI session for $DS_HOST"
  elif [ "${DS_AUTH:-}" = "passcode" ]; then
    if [ -z "${DS_PASSCODE_URL:-}" ]; then
      DS_PASSCODE_URL="$(datasphere config passcode-url --host "$DS_HOST" 2>/dev/null | grep -o 'https://[^[:space:]]*' | head -n1)"
    fi
    [ -n "$DS_PASSCODE_URL" ] || die "could not work out the passcode URL - set DS_PASSCODE_URL"
    export DS_PASSCODE_URL
    log "passcode mode: one passcode per tenant call, from $DS_PASSCODE_URL (source: ${DS_PASSCODE_SOURCE:-chrome})"
    # Each passcode is single-use, so do not re-download the command list on every run.
    # (`objects --help` exits 0 even with an empty cache - it then prints the top-level usage
    #  instead of "Usage: datasphere objects", so test the text, not the exit code.)
    if [ "${DS_REFRESH_CACHE:-0}" != "1" ] && datasphere objects --help 2>/dev/null | grep -q "Usage: datasphere objects"; then
      log "CLI command cache present - skipping cache init (DS_REFRESH_CACHE=1 to force)"
      return 0
    fi
  elif [ -n "${DS_CLIENT_ID:-}" ]; then
    : "${DS_CLIENT_SECRET:?DS_CLIENT_SECRET is required with DS_CLIENT_ID}"
    : "${DS_TOKEN_URL:?DS_TOKEN_URL is required with DS_CLIENT_ID (App Integration > Token URL)}"
    # Even for client_credentials the CLI checks an authorization URL; without one it derives a
    # (wrong) URL from the host and fails with "auto-generated OAuth URLs are not reachable".
    : "${DS_AUTH_URL:?DS_AUTH_URL is required (App Integration > Authorization URL)}"
    local flow="${DS_AUTH_FLOW:-client_credentials}" opts
    opts="$(tmpfile)"; chmod 600 "$opts"
    # Options file instead of --client-secret on the command line: keeps the secret out of
    # `ps` output and CI logs, and avoids shell-escaping the ! and | that client IDs contain.
    python3 - "$opts" "$flow" <<'PY'
import json, os, sys
e = os.environ
json.dump({"host": e["DS_HOST"], "client-id": e["DS_CLIENT_ID"], "client-secret": e["DS_CLIENT_SECRET"],
           "authorization-url": e["DS_AUTH_URL"], "token-url": e["DS_TOKEN_URL"],
           "authorization-flow": sys.argv[2]}, open(sys.argv[1], "w"))
PY
    # The CLI keeps the client secret in ~/.@sap/datasphere-cli/.cache/secrets.json - even when the
    # login fails. Harmless in a throwaway CI container, not on a reused shell runner, so in CI it
    # is wiped when the script exits (flag set before the attempt, on purpose).
    [ -n "${CI:-}" ] && _CI_LOGGED_IN=1
    log "logging in to $DS_HOST (flow=$flow)"
    ds login --options-file "$opts" --force >&2
  elif [ -n "${DS_SECRETS_FILE:-}" ]; then
    [ -f "$DS_SECRETS_FILE" ] || die "DS_SECRETS_FILE=$DS_SECRETS_FILE does not exist"
    log "logging in to $DS_HOST with secrets file"
    ds login --secrets-file "$DS_SECRETS_FILE" --host "$DS_HOST" --force >&2
  else
    die "no credentials: set DS_CLIENT_ID/DS_CLIENT_SECRET/DS_TOKEN_URL, or DS_SECRETS_FILE, or DS_SKIP_LOGIN=1 after scripts/login-interactive.sh"
  fi
  # Downloads the tenant's command list; `datasphere objects ...` does not exist until this ran.
  ds config cache init --host "$DS_HOST" >&2
}

# ds_list_names <type> <space> [technical-name]  ->  one technical name per line.
# `objects <type> list` returns 25 rows by default and at most 200 per call, so page through.
ds_list_names() {
  local t=$1 space=$2 only=${3:-} page=200 skip=0 raw names count
  while :; do
    raw="$(mktemp)"   # not tmpfile(): this usually runs inside $(...), where the registry is lost
    if [ -n "$only" ]; then
      ds objects "$t" list --space "$space" --technical-names "$only" --output "$raw" >/dev/null || { rm -f "$raw"; return 1; }
    else
      ds objects "$t" list --space "$space" --top "$page" --skip "$skip" --output "$raw" >/dev/null || { rm -f "$raw"; return 1; }
    fi
    names="$(python3 "$ROOT/scripts/py/parse_list.py" <"$raw")"; rm -f "$raw"
    [ -n "$names" ] && printf '%s\n' "$names"
    count=$(printf '%s' "$names" | grep -c . || true)
    if [ -n "$only" ] || [ "$count" -lt "$page" ]; then return 0; fi
    skip=$((skip + page))
  done
}
