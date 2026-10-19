#!/usr/bin/env bash
# CI/CD deployment: push the approved definitions from Git into the target space, dependencies first.
# Idempotent - safe to re-run: existing objects are updated, missing ones created.
# It never deletes anything; removals are a deliberate, manual act.
#
# The CLI saves AND deploys on create/update (unless --no-deploy), and refuses to create an
# object whose sources are not in the space yet - hence the dependency order from order.py.
#
# Usage: scripts/deploy.sh <env> [--dry-run] [--only NAME,NAME]
#   DS_SAVE_ANYWAY=1  pass --save-anyway (save even with validation warnings) - use deliberately
source "$(dirname "$0")/lib.sh"

env="${1:?usage: deploy.sh <env> [--dry-run] [--only NAME,NAME]}"; shift
dry=0; only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --only)    only="${2:?--only needs a value}"; shift ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

space="$(env_space "$env")"
version="${CI_COMMIT_TAG:-${CI_COMMIT_SHORT_SHA:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}}"
log "deploy: env=$env space=$space version=$version mode=$DS_MODE dry_run=$dry"

python3 "$ROOT/scripts/py/validate.py" >/dev/null || { python3 "$ROOT/scripts/py/validate.py" || true; die "validation failed - refusing to deploy"; }

plan="$(tmpfile)"
python3 "$ROOT/scripts/py/order.py" >"$plan"
[ -s "$plan" ] || die "no objects found in $DEF_DIR"

[ "$dry" = 1 ] || ds_login

extra=""
[ "${DS_SAVE_ANYWAY:-0}" = "1" ] && extra="--save-anyway"

# What already exists in the target space: ONE list call per object type, filtered to the names
# we are about to deploy (saves API calls - and passcodes in DS_AUTH=passcode mode).
# If we cannot ask the tenant we stop: guessing "create" would fail or duplicate.
existing="$(mktemp -d)"; trap 'rm -rf "$existing"; _cleanup' EXIT
if [ "$dry" = 0 ]; then
  for t in $(cut -f1 "$plan" | sort -u); do
    names="$(awk -F'\t' -v t="$t" '$1 == t {print $2}' "$plan" | paste -sd, -)"
    if [ "$(tr ',' '\n' <<<"$names" | grep -c .)" -gt 100 ]; then names=""; fi   # long filter: list everything
    retry 3 ds_list_names "$t" "$space" "$names" >"$existing/$t" || die "could not list $t in $space (auth? network? space name?)"
  done
fi

apply() { # apply <type> <name> <file>  -> echoes created|updated
  local t=$1 n=$2 f=$3
  if grep -qxF -- "$n" "$existing/$t"; then
    ds objects "$t" update --space "$space" --technical-name "$n" --file-path "$f" $extra >&2 && echo updated
  else
    ds objects "$t" create --space "$space" --technical-name "$n" --file-path "$f" $extra >&2 \
      && echo "$n" >>"$existing/$t" && echo created
  fi
}

mkdir -p "$ROOT/reports"
report="$ROOT/reports/deploy-$env.tsv"
printf 'timestamp\tversion\tenv\tspace\ttype\tname\taction\n' >"$report"

n_created=0; n_updated=0
while IFS=$'\t' read -r type name file; do
  if [ -n "$only" ] && ! grep -qw -- "$name" <<<"${only//,/ }"; then continue; fi
  if [ "$dry" = 1 ]; then
    log "DRY-RUN would deploy $type/$name -> $space"
    printf '%s\t%s\t%s\t%s\t%s\t%s\tdry-run\n' "$(date -u +%FT%TZ)" "$version" "$env" "$space" "$type" "$name" >>"$report"
    continue
  fi
  log "deploying $type/$name -> $space"
  action="$(retry 3 apply "$type" "$name" "$file")" || die "deployment of $type/$name failed - stopping (objects after it were NOT deployed)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$version" "$env" "$space" "$type" "$name" "$action" >>"$report"
  case "$action" in created) n_created=$((n_created + 1)) ;; updated) n_updated=$((n_updated + 1)) ;; esac
done <"$plan"

log "done: $n_created created, $n_updated updated. Audit trail: reports/deploy-$env.tsv"
