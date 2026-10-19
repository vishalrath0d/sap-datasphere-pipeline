#!/usr/bin/env bash
# Starts a separate Chrome window (own profile, not your normal one) that stays signed in to your
# Datasphere tenant, so tools/passcode/get-passcode.mjs can read a fresh one-time passcode for
# every CLI call. For tenants without App Integration (no OAuth client), e.g. the 30-day trial.
#
#   bash tools/passcode/chrome-session.sh          start it; sign in once in the window that opens
#   bash tools/passcode/chrome-session.sh test     print one fresh passcode (proves it works)
#   bash tools/passcode/chrome-session.sh stop     close it when you are done
#
# Security: while it runs, any program on this Mac can control that Chrome window through
# 127.0.0.1:$port. Use it for the trial only and stop it afterwards. Never on a shared machine/CI.
set -euo pipefail
source "$(dirname "$0")/../../scripts/env.sh"      # DS_HOST / DS_PASSCODE_URL from .env
port="${DS_PASSCODE_CDP_PORT:-9333}"
profile="${DS_PASSCODE_PROFILE:-$HOME/.datasphere-passcode-chrome}"
chrome="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

passcode_url() {
  if [ -n "${DS_PASSCODE_URL:-}" ]; then printf '%s\n' "$DS_PASSCODE_URL"; return; fi
  : "${DS_HOST:?set DS_HOST (tenant URL) or DS_PASSCODE_URL in .env (cp .env.example .env)}"
  datasphere config passcode-url --host "$DS_HOST" 2>/dev/null | grep -o 'https://[^[:space:]]*' | head -n1
}

if [ "${1:-}" = "test" ]; then
  exec node "$(dirname "$0")/get-passcode.mjs" "$(passcode_url)"
fi

if [ "${1:-}" = "stop" ]; then
  pkill -f -- "--user-data-dir=$profile" && echo "stopped" || echo "not running"
  exit 0
fi

if curl -fsS "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
  echo "already running on 127.0.0.1:$port"; exit 0
fi

url="$(passcode_url)"
[ -n "$url" ] || { echo "could not work out the passcode URL - set DS_PASSCODE_URL in .env" >&2; exit 1; }
[ -x "$chrome" ] || { echo "Chrome not found at $chrome (set CHROME_BIN)" >&2; exit 1; }

"$chrome" --remote-debugging-port="$port" --user-data-dir="$profile" \
  --no-first-run --no-default-browser-check "$url" >/dev/null 2>&1 &

for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 || { echo "Chrome did not open its debugging port" >&2; exit 1; }

cat <<EOF
Chrome is running with its own profile ($profile).
1. Sign in to Datasphere in that window. You should then see "Temporary Authentication Code".
2. Leave the window open and run the scripts with DS_AUTH=passcode.
3. Test it:  make passcode-test
Stop it later with:  bash tools/passcode/chrome-session.sh stop
EOF
