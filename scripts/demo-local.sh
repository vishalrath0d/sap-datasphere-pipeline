#!/usr/bin/env bash
# End-to-end rehearsal of the whole GitOps loop using the built-in Datasphere simulator.
# Needs: bash, python3, diff.  No tenant, no network, nothing outside a temp folder is touched.
#
#   bash scripts/demo-local.sh
#
# It also works as a regression test: it exits non-zero if any expectation below is not met.
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp -r "$SRC_ROOT/definitions" "$WORK/definitions"
export DS_MODE=mock
export DS_NO_DOTENV=1          # never pick up your real .env in the self-test
export MOCK_DS_NOISE=1          # the real CLI prints warnings on stdout; prove the scripts cope
export DEF_DIR="$WORK/definitions"
export MOCK_DS_STATE="$WORK/state"
export DS_HOST="demo-tenant"

source "$SRC_ROOT/scripts/lib.sh"
cd "$SRC_ROOT"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
expect_fail() { if "$@"; then die "expected failure but command succeeded: $*"; else echo "   (failed as expected)"; fi; }

step "1. validate: static checks on definitions/ (this is the merge-request gate)"
python3 scripts/py/validate.py --root "$DEF_DIR"

step "2. plan: dependency-aware deploy order"
python3 scripts/py/order.py --plan

step "3. why order matters: deploying a view before its source tables fails"
expect_fail ds objects views create --space SCRATCH --technical-name V_SALES_BY_COUNTRY --file-path "$DEF_DIR/views/V_SALES_BY_COUNTRY.json"

step "4. seed DEV from Git (stands in for 'someone built these in the DEV space')"
bash scripts/deploy.sh dev

step "5. a modeler changes a view in the DEV UI (we simulate: add a column in DEV only)"
python3 - "$DEF_DIR/views/V_TOP_COUNTRIES.json" "$WORK/changed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
v = d["definitions"]["V_TOP_COUNTRIES"]
v["elements"]["AVG_ORDER_VALUE"] = {"@EndUserText.label": "Average Order Value", "type": "cds.Decimal", "precision": 31, "scale": 2}
v["query"]["SELECT"]["columns"].append({"ref": ["AVG_ORDER_VALUE"]})
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
ds objects views update --space "$(env_space dev)" --technical-name V_TOP_COUNTRIES --file-path "$WORK/changed.json"

step "6. automated extraction: export DEV -> definitions/, then show what changed (this diff becomes the merge request)"
cp -r "$DEF_DIR" "$WORK/before"
bash scripts/export.sh dev
changes=$(diff -ru "$WORK/before" "$DEF_DIR" || true)
echo "$changes"
grep -q "AVG_ORDER_VALUE" <<<"$changes" || die "expected the DEV change to show up in the exported diff"

step "7. promote: deploy the approved version to TEST, then PROD"
bash scripts/deploy.sh test
bash scripts/deploy.sh prod
echo; cat reports/deploy-prod.tsv

step "8. re-run PROD deploy: idempotent (everything is 'updated', nothing breaks)"
bash scripts/deploy.sh prod 2>&1 | tail -n 2

step "9. drift check: PROD matches Git"
bash scripts/drift-check.sh prod

step "10. someone hot-fixes PROD by hand -> drift check catches it"
python3 - "$DEF_DIR/views/V_SALES_BY_COUNTRY.json" "$WORK/hotfix.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["definitions"]["V_SALES_BY_COUNTRY"]["@EndUserText.label"] = "Sales by Country (HOTFIX in PROD)"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
ds objects views update --space "$(env_space prod)" --technical-name V_SALES_BY_COUNTRY --file-path "$WORK/hotfix.json"
expect_fail bash scripts/drift-check.sh prod

step "11. fix = redeploy from Git (Git is the source of truth); drift is gone"
bash scripts/deploy.sh prod 2>&1 | tail -n 1
bash scripts/drift-check.sh prod

printf '\n\033[1;32mDemo complete - all expectations met.\033[0m\n'
rm -f "$SRC_ROOT"/reports/deploy-*.tsv
