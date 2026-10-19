.PHONY: help pipeline bootstrap pipeline-mr pipeline-main pipeline-tag validate plan demo install-cli passcode-start passcode-stop passcode-test login preflight spaces deploy-dev deploy-test deploy-prod export-dev drift-prod

help:           ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

pipeline:       ## THE ONE COMMAND: run the whole GitLab pipeline locally (real tenant per .env)
	bash scripts/pipeline.sh
bootstrap:      ## FIRST real run: deploy to the tenant, read back its canonical CSN into Git
	bash scripts/pipeline.sh --flow bootstrap
pipeline-mr:    ## what a merge request runs: validate, plan
	bash scripts/pipeline.sh --flow mr
pipeline-main:  ## what a push to main runs: + deploy-test
	bash scripts/pipeline.sh --flow main
pipeline-tag:   ## what a vX.Y.Z tag runs: + deploy-prod (asks for approval)
	bash scripts/pipeline.sh --flow tag

validate:       ## static checks, no tenant needed
	python3 scripts/py/validate.py

plan:           ## show deploy order
	python3 scripts/py/order.py --plan

demo:           ## full rehearsal against the built-in simulator (also acts as the test)
	bash scripts/demo-local.sh

# Real targets: `cp .env.example .env`, fill it in, `set -a; source .env; set +a` (docs/00-RUNBOOK.md)
install-cli:    ## install the pinned SAP Datasphere CLI (needs Node 20-24)
	DS_MODE=real bash scripts/install-cli.sh
passcode-start: ## trial tenant: open the passcode Chrome window (sign in once)
	bash tools/passcode/chrome-session.sh
passcode-stop:  ## close the passcode Chrome window
	bash tools/passcode/chrome-session.sh stop
passcode-test:  ## print one fresh passcode (proves the automation works)
	bash tools/passcode/chrome-session.sh test
login:          ## one-time browser login with the Interactive Usage client
	bash scripts/login-interactive.sh
preflight:      ## read-only check: can these credentials see the spaces?
	bash scripts/preflight.sh dev
spaces:         ## create DEV/TEST/PROD spaces from config/environments.json (admin only)
	bash scripts/create-spaces.sh
deploy-dev:     ## deploy definitions/ to the dev space
	bash scripts/deploy.sh dev
deploy-test:    ## deploy definitions/ to the test space
	bash scripts/deploy.sh test
deploy-prod:    ## deploy definitions/ to the prod space
	bash scripts/deploy.sh prod
export-dev:     ## refresh definitions/ from the dev space (then: git diff)
	bash scripts/export.sh dev
drift-prod:     ## does prod still match Git?
	bash scripts/drift-check.sh prod
