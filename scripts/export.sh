#!/usr/bin/env bash
# Automated extraction: pull artifact definitions out of a Datasphere space as machine-readable
# JSON (CSN) via the CLI and write them, normalised, into definitions/.
#
# Usage: scripts/export.sh <env> [--discover] [--objects type:NAME,type:NAME] [--out DIR] [--keep-going]
#   default      re-export every object already tracked in definitions/ (refresh)
#   --discover   list every supported object type in the space and export what is found (adds new objects)
#   --objects    export exactly these objects, e.g. local-tables:SALES_ORDERS,views:V_SALES_BY_REGION
#   --out DIR    write somewhere else (drift-check uses this)
#   --keep-going do not stop at the first object that cannot be read; exit 2 at the end if any failed
source "$(dirname "$0")/lib.sh"

env="${1:?usage: export.sh <env> [options]}"; shift
discover=0; objects=""; out="$DEF_DIR"; keep_going=0
while [ $# -gt 0 ]; do
  case "$1" in
    --discover)   discover=1 ;;
    --objects)    objects="${2:?--objects needs a value}"; shift ;;
    --out)        out="${2:?--out needs a value}"; shift ;;
    --keep-going) keep_going=1 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

space="$(env_space "$env")"
log "export: env=$env space=$space mode=$DS_MODE -> $out"
ds_login

worklist="$(tmpfile)"
if [ -n "$objects" ]; then
  tr ',' '\n' <<<"$objects" | awk -F: 'NF==2 {print $1 "\t" $2}' >"$worklist"   # not sed 's/:/\t/': BSD sed has no \t
elif [ "$discover" = 1 ]; then
  for t in $(python3 "$ROOT/scripts/py/order.py" --types); do
    # A type the tenant does not offer (or you have no privilege for) is skipped, not fatal.
    names="$(retry 2 ds_list_names "$t" "$space" 2>/dev/null)" || { log "skip type $t (list failed)"; continue; }
    for n in $names; do printf '%s\t%s\n' "$t" "$n"; done >>"$worklist"
  done
else
  python3 "$ROOT/scripts/py/order.py" --list >"$worklist"
fi
[ -s "$worklist" ] || die "nothing to export (no tracked objects). Use --discover or --objects type:NAME"

# --output instead of stdout: the CLI prints warnings (outdated CLI, unsupported Node) on stdout.
fetch() { # fetch <type> <name> <rawfile>
  ds objects "$1" read --space "$space" --technical-name "$2" --accept "$DS_READ_ACCEPT" --output "$3" >/dev/null
}

ok=0; failed=0
while IFS=$'\t' read -r type name; do
  [ -n "$type" ] || continue
  raw="$(tmpfile)"
  if retry 3 fetch "$type" "$name" "$raw"; then
    mkdir -p "$out/$type"
    if python3 "$ROOT/scripts/py/normalize.py" --name "$name" <"$raw" >"$out/$type/$name.json"; then
      log "exported $type/$name"; ok=$((ok + 1))
    else
      rm -f "$out/$type/$name.json"; failed=$((failed + 1))
      [ "$keep_going" = 1 ] || die "could not normalise output for $type/$name"
    fi
  else
    log "MISSING in $space: $type/$name"; failed=$((failed + 1))
    [ "$keep_going" = 1 ] || die "could not read $type/$name from $space"
  fi
done <"$worklist"

log "export finished: $ok exported, $failed failed"
[ "$failed" -eq 0 ] || exit 2
