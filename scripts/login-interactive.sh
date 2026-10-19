#!/usr/bin/env bash
# One-time browser login from your laptop with an OAuth client of purpose "Interactive Usage"
# (redirect URI http://localhost:8080). Afterwards run the other scripts with DS_SKIP_LOGIN=1.
#
#   bash scripts/login-interactive.sh
#
# Reads DS_HOST, DS_UI_CLIENT_ID, DS_UI_CLIENT_SECRET, DS_AUTH_URL, DS_TOKEN_URL from the
# environment (e.g. `set -a; source .env; set +a`) and prompts for anything missing.
# The secret goes through a temporary options file, never the command line.
set -euo pipefail
command -v datasphere >/dev/null || { echo "install the CLI first: npm install -g @sap/datasphere-cli@2026.21.0" >&2; exit 1; }

ask() { # ask VAR "prompt" [secret]
  local cur; eval "cur=\${$1:-}"
  if [ -z "$cur" ]; then
    if [ "${3:-}" = secret ]; then read -r -s -p "$2: " cur; echo >&2; else read -r -p "$2: " cur; fi
    eval "$1=\$cur"
  fi
}
ask DS_HOST            "Tenant URL (https://<tenant>.<region>.hcs.cloud.sap)"
ask DS_UI_CLIENT_ID     "OAuth client ID (Interactive Usage)"
ask DS_UI_CLIENT_SECRET "OAuth client secret" secret
ask DS_AUTH_URL         "Authorization URL (App Integration page)"
ask DS_TOKEN_URL        "Token URL (App Integration page)"

opts="$(mktemp)"; chmod 600 "$opts"; trap 'rm -f "$opts"' EXIT
DS_HOST="$DS_HOST" CID="$DS_UI_CLIENT_ID" CSEC="$DS_UI_CLIENT_SECRET" AURL="$DS_AUTH_URL" TURL="$DS_TOKEN_URL" \
python3 - "$opts" <<'PY'
import json, os, sys
e = os.environ
json.dump({"host": e["DS_HOST"], "client-id": e["CID"], "client-secret": e["CSEC"],
           "authorization-url": e["AURL"], "token-url": e["TURL"],
           "authorization-flow": "authorization_code"}, open(sys.argv[1], "w"))
PY

datasphere config host set "$DS_HOST"
echo "A browser window opens - sign in with your Datasphere user (port ${CLI_HTTP_PORT:-8080} must be free)." >&2
datasphere login --options-file "$opts" --browser "${DS_BROWSER:-chrome}" --force
datasphere config cache init --host "$DS_HOST"

cat >&2 <<EOF

Logged in. Try:
  datasphere objects local-tables list --space DEV_SALES
Run the repo scripts against this session with:
  export DS_MODE=real DS_SKIP_LOGIN=1 DS_HOST=$DS_HOST
  bash scripts/preflight.sh dev
EOF
