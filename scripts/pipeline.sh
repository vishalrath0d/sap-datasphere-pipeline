#!/usr/bin/env bash
# The GitLab pipeline, runnable on your laptop with one command - against the real tenant
# (DS_MODE=real in .env) or the simulator (DS_MODE=mock).
#
# Every GitLab job calls `scripts/pipeline.sh stage <name>`, so a stage does exactly the same
# thing here and in CI. Locally, this script also plays the role of GitLab: it runs the stages
# in pipeline order, stops at the first failure (like `needs:`), asks before the manual
# deploy-prod job, and prints the pipeline summary.
#
#   bash scripts/pipeline.sh                 full: everything the pipeline and its schedules run
#   bash scripts/pipeline.sh --flow mr       merge request : validate plan
#   bash scripts/pipeline.sh --flow main     push to main  : validate plan deploy-test
#   bash scripts/pipeline.sh --flow tag      tag vX.Y.Z    : validate plan deploy-test deploy-prod
#   bash scripts/pipeline.sh --flow export   schedule      : export-dev
#   bash scripts/pipeline.sh --flow drift    schedule      : drift-test drift-prod
#   bash scripts/pipeline.sh --flow bootstrap first run against a tenant: deploy-test, then export
#                                            the result back so Git holds the tenant's canonical CSN
#   --yes                                    approve the manual deploy-prod without asking
#   bash scripts/pipeline.sh stage <name>    run one job (what .gitlab-ci.yml calls)
source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------------- the jobs
run_stage() {
  case "$1" in
    validate)
      for f in "$ROOT"/scripts/*.sh; do bash -n "$f"; done
      mkdir -p "$ROOT/reports"
      python3 "$ROOT/scripts/py/validate.py" --junit "$ROOT/reports/validate.xml" ;;
    plan)
      mkdir -p "$ROOT/reports"
      python3 "$ROOT/scripts/py/order.py" --plan | tee "$ROOT/reports/plan.txt" ;;
    preflight)   bash "$ROOT/scripts/preflight.sh" dev ;;
    deploy-test) bash "$ROOT/scripts/deploy.sh" test ;;
    deploy-prod) bash "$ROOT/scripts/deploy.sh" prod ;;
    drift-test)  bash "$ROOT/scripts/drift-check.sh" test ;;
    drift-prod)  bash "$ROOT/scripts/drift-check.sh" prod ;;
    export-dev)
      if [ -z "${CI:-}" ] && [ "${DS_FORCE_EXPORT:-0}" != "1" ] && command -v git >/dev/null \
         && [ -n "$(git -C "$ROOT" status --porcelain -- definitions 2>/dev/null)" ]; then
        die "definitions/ has uncommitted changes - commit or stash them first (export would overwrite them; DS_FORCE_EXPORT=1 to allow)"
      fi
      bash "$ROOT/scripts/export.sh" dev --discover
      if [ -n "${CI:-}" ]; then
        bash "$ROOT/scripts/export-to-mr.sh" dev          # CI: branch + merge request
      elif [ -n "$(git -C "$ROOT" status --porcelain -- definitions 2>/dev/null)" ]; then
        log "DEV differs from Git - review and commit (in CI this becomes a merge request):"
        git -C "$ROOT" status --short -- definitions >&2
        git -C "$ROOT" --no-pager diff --stat -- definitions >&2 || true
      else
        log "DEV matches Git - nothing to propose"
      fi ;;
    canonicalize)
      # Datasphere stores what you deploy in its own canonical form (defaults filled in, editor
      # settings added, ...). Read it back from TEST so Git matches what the tenant returns -
      # otherwise the first drift check flags formatting, not real changes.
      [ -z "$(git -C "$ROOT" status --porcelain -- definitions 2>/dev/null)" ] \
        || die "commit definitions/ first, so the canonical form shows up as a reviewable diff"
      bash "$ROOT/scripts/export.sh" test
      if [ -n "$(git -C "$ROOT" status --porcelain -- definitions 2>/dev/null)" ]; then
        log "the tenant's canonical form differs from what was committed - review and commit it:"
        git -C "$ROOT" --no-pager diff --stat -- definitions >&2 || true
        log "  git diff definitions        # what Datasphere added/changed"
        log "  git commit -am 'Canonical CSN from the tenant'   then: make pipeline"
      else
        log "Git already matches the tenant's canonical form"
      fi ;;
    *) die "unknown stage '$1' (validate plan preflight deploy-test deploy-prod drift-test drift-prod export-dev canonicalize)" ;;
  esac
}

if [ "${1:-}" = "stage" ]; then
  run_stage "${2:?usage: pipeline.sh stage <name>}"
  exit $?
fi

# ---------------------------------------------------------------- local orchestration
flow="full"; yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --flow) flow="${2:?--flow needs mr|main|tag|export|drift|bootstrap|full}"; shift ;;
    --yes)  yes=1 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

case "$flow" in
  mr)     stages="validate plan" ;;
  main)   stages="validate plan deploy-test" ;;
  tag)    stages="validate plan deploy-test deploy-prod" ;;
  export) stages="export-dev" ;;
  drift)  stages="drift-test drift-prod" ;;
  bootstrap) stages="validate plan deploy-test canonicalize" ;;
  full)   stages="validate plan deploy-test deploy-prod drift-test drift-prod export-dev" ;;
  *) die "unknown flow '$flow'" ;;
esac
# Against a real tenant, check the connection before anything deploys.
[ "$DS_MODE" = "real" ] && [ "$flow" != "mr" ] && stages="preflight $stages"

auth="n/a"
[ "$DS_MODE" = "real" ] && auth="${DS_AUTH:-oauth}"
spaces="$(for e in dev test prod; do printf '%s=%s ' "$e" "$(env_space "$e")"; done)"
printf '\n\033[1mPipeline (%s) - mode=%s auth=%s host=%s\033[0m\n%s\n' \
  "$flow" "$DS_MODE" "$auth" "${DS_HOST:-mock}" "$spaces" >&2

summary=""; failed=""
for s in $stages; do
  if [ -n "$failed" ]; then summary="$summary$(printf '%-12s skipped' "$s")\n"; continue; fi
  if [ "$s" = "deploy-prod" ] && [ "$yes" = 0 ]; then
    if [ -t 0 ]; then
      read -r -p "deploy-prod is a manual job in GitLab. Approve now? [y/N] " ans
    else
      ans="n"
    fi
    case "$ans" in y|Y|yes) ;; *) summary="$summary$(printf '%-12s manual - not approved' "$s")\n"; continue ;; esac
  fi
  printf '\n\033[1m=== %s\033[0m\n' "$s" >&2
  start=$(date +%s)
  # Separate process, not `if ( run_stage )`: inside an if-condition bash ignores `set -e`, so a
  # failing command in the middle of a stage would not stop it.
  if bash "$ROOT/scripts/pipeline.sh" stage "$s"; then
    summary="$summary$(printf '%-12s passed  %3ss' "$s" "$(( $(date +%s) - start ))")\n"
  else
    summary="$summary$(printf '%-12s FAILED  %3ss' "$s" "$(( $(date +%s) - start ))")\n"
    failed="$s"
  fi
done

printf '\n\033[1mPipeline summary\033[0m\n' >&2
printf "$summary" >&2
printf 'artifacts: reports/validate.xml reports/plan.txt reports/deploy-*.tsv\n' >&2
[ -z "$failed" ] || die "pipeline failed at $failed"
