#!/usr/bin/env bash
# Drift detection: does <env> still match what Git says should be deployed?
# Exports every tracked object from the environment into a temp dir and diffs it with definitions/.
# Exit 0 = in sync, 1 = drift (or missing objects). Run it on a GitLab pipeline schedule.
#
# Usage: scripts/drift-check.sh <env>
source "$(dirname "$0")/lib.sh"

env="${1:?usage: drift-check.sh <env>}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; _cleanup' EXIT

rc=0
"$ROOT/scripts/export.sh" "$env" --out "$tmp" --keep-going || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then die "export failed (exit $rc)"; fi

drift=0
while IFS=$'\t' read -r type name; do
  [ -n "$type" ] || continue
  want="$DEF_DIR/$type/$name.json"; got="$tmp/$type/$name.json"
  if [ ! -f "$got" ]; then
    log "DRIFT: $type/$name is in Git but missing in $env"; drift=1
  elif ! diff -u --label "git/$type/$name.json" --label "$env/$type/$name.json" "$want" "$got"; then
    log "DRIFT: $type/$name differs between Git and $env"; drift=1
  fi
done < <(python3 "$ROOT/scripts/py/order.py" --list)

if [ "$drift" -eq 0 ]; then log "no drift: $env matches Git"; fi
exit "$drift"
