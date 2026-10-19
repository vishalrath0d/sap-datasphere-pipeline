#!/usr/bin/env bash
# Optional "spaces as code": create (or update) every space listed in config/environments.json.
# Needs an administrator login (DW Administrator) - a Technical User cannot run `spaces create`.
#
#   DS_MODE=real DS_SKIP_LOGIN=1 DS_HOST=... bash scripts/create-spaces.sh [--dry-run]
#
# Uses the space definition format from SAP's CLI guide (4.4); `spaces create` creates or updates.
# After creating, add yourself (and the CI technical user's scoped role) to each space.
source "$(dirname "$0")/lib.sh"

dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
storage="${DS_SPACE_STORAGE_BYTES:-500000000}"   # 500 MB disk  (min 100 MB) - trial tenants are small
ram="${DS_SPACE_RAM_BYTES:-500000000}"           # 500 MB memory

[ "$dry" = 1 ] || ds_login
for e in $(python3 -c "import json;print(' '.join(k for k in json.load(open('$ROOT/config/environments.json')) if not k.startswith('_')))"); do
  s="$(env_space "$e")"
  f="$(tmpfile)"
  python3 - "$f" "$s" "$e" "$storage" "$ram" <<'PY'
import json, sys
path, space, env, storage, ram = sys.argv[1:]
json.dump({space: {"spaceDefinition": {"version": "1.0.4", "label": "Sales (%s)" % env.upper(),
                                        "assignedStorage": int(storage), "assignedRam": int(ram)}}},
          open(path, "w"), indent=2)
PY
  if [ "$dry" = 1 ]; then log "DRY-RUN would create/update space $s:"; cat "$f" >&2; continue; fi
  [ "$DS_MODE" = "mock" ] && { log "mock: would create space $s"; continue; }
  log "creating/updating space $s"
  ds spaces create --file-path "$f" >&2
done
