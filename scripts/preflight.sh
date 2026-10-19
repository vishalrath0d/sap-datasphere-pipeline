#!/usr/bin/env bash
# Read-only connectivity check. Run it first against a real tenant, locally or in CI:
#   DS_MODE=real ... bash scripts/preflight.sh [env]      (env defaults to dev)
# It answers, in order: is the CLI usable, can we log in, which spaces can these credentials see.
source "$(dirname "$0")/lib.sh"

env="${1:-dev}"
log "mode=$DS_MODE"
if [ "$DS_MODE" = "real" ]; then
  command -v datasphere >/dev/null || die "datasphere CLI not on PATH - run scripts/install-cli.sh"
  log "node $(node -v), datasphere $(datasphere --version | head -n1)"
fi

ds_login
[ "$DS_MODE" = "real" ] && log "host: $(ds config host show 2>/dev/null | grep -v '^WARNING' | head -n1)"

# Every environment in config/environments.json: can we list its tables?
# A Technical User only sees spaces that its scoped role includes.
fail=0
for e in $(python3 -c "import json;print(' '.join(k for k in json.load(open('$ROOT/config/environments.json')) if not k.startswith('_')))"); do
  s="$(env_space "$e")"
  if names="$(ds_list_names local-tables "$s")"; then
    n=$(printf '%s' "$names" | grep -c . || true)
    log "OK   $e -> $s: $n local table(s) visible"
  else
    log "FAIL $e -> $s: cannot list objects (space missing, or these credentials are not in a scoped role for it)"
    [ "$e" = "$env" ] && fail=1
  fi
done
[ "$fail" -eq 0 ] || die "preflight failed for $env"
log "preflight passed for $env"
