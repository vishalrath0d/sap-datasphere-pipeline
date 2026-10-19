#!/usr/bin/env bash
# Starts a separate Chrome window (own profile, not your normal one) that stays signed in to your
# Datasphere tenant, so tools/passcode/get-passcode.mjs can read a fresh one-time passcode for
# every CLI call. For tenants without App Integration (no OAuth client), e.g. the 30-day trial.
# Works on macOS, Linux and Windows (Git Bash).
#
#   bash tools/passcode/chrome-session.sh          start it; sign in once in the window that opens
#   bash tools/passcode/chrome-session.sh test     print one fresh passcode (proves it works)
#   bash tools/passcode/chrome-session.sh stop     close it when you are done
#
# Security: while it runs, any program on this machine can control that Chrome window through
# 127.0.0.1:$port. Use it for the trial only and stop it afterwards. Never on a shared machine/CI.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../../scripts/env.sh"      # DS_HOST / DS_PASSCODE_URL / DS_USER ... from .env
port="${DS_PASSCODE_CDP_PORT:-9333}"
profile="${DS_PASSCODE_PROFILE:-$HOME/.datasphere-passcode-chrome}"

# Prints the Chrome/Chromium executable for this OS (or nothing). CHROME_BIN in .env overrides.
find_chrome() {
  if [ -n "${CHROME_BIN:-}" ]; then printf '%s\n' "$CHROME_BIN"; return; fi
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ;;
    MINGW*|MSYS*|CYGWIN*)                                  # Windows, Git Bash
      for c in "/c/Program Files/Google/Chrome/Application/chrome.exe" \
               "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"; do
        if [ -f "$c" ]; then printf '%s\n' "$c"; return; fi
      done ;;
    *)                                                     # Linux
      for c in google-chrome google-chrome-stable chromium chromium-browser; do
        if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return; fi
      done ;;
  esac
}

passcode_url() {
  if [ -n "${DS_PASSCODE_URL:-}" ]; then printf '%s\n' "$DS_PASSCODE_URL"; return; fi
  : "${DS_HOST:?set DS_HOST (tenant URL) or DS_PASSCODE_URL in .env (cp .env.example .env)}"
  datasphere config passcode-url --host "$DS_HOST" 2>/dev/null | grep -o 'https://[^[:space:]]*' | head -n1
}

case "${1:-start}" in
  test)  exec node "$here/get-passcode.mjs" "$(passcode_url)" ;;
  stop)  exec node "$here/get-passcode.mjs" --close ;;      # through the debugging port: any OS
  start) ;;
  *)     echo "usage: chrome-session.sh [start|test|stop]" >&2; exit 1 ;;
esac

if curl -fsS "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
  echo "already running on 127.0.0.1:$port"; exit 0
fi

url="$(passcode_url)"
[ -n "$url" ] || { echo "could not work out the passcode URL - set DS_PASSCODE_URL in .env" >&2; exit 1; }
chrome="$(find_chrome)"
if [ -z "$chrome" ] || [ ! -e "$chrome" ]; then
  echo "Chrome/Chromium not found - set CHROME_BIN in .env to its full path" >&2; exit 1
fi

# Windows Chrome wants a Windows-style path (C:\Users\...) for its profile folder.
profile_arg="$profile"
if command -v cygpath >/dev/null 2>&1; then profile_arg="$(cygpath -w "$profile")"; fi

"$chrome" --remote-debugging-port="$port" --user-data-dir="$profile_arg" \
  --no-first-run --no-default-browser-check "$url" >/dev/null 2>&1 &

for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 || { echo "Chrome did not open its debugging port" >&2; exit 1; }

cat <<EOF
Chrome is running with its own profile ($profile).
1. Sign in to Datasphere in that window - or, with DS_AUTO_LOGIN=1 in .env, skip this:
   the first passcode request signs in for you in the background.
2. Minimise the window (do not close it). Passcodes are fetched in the background from its
   session - nothing opens or takes focus while the pipeline runs.
3. Test it:  make passcode-test
Stop it later with:  make passcode-stop
EOF
