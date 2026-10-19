# Datasphere GitOps pipeline

Hands-on project that does what the client role describes:

| Job-profile bullet | Where it lives in this repo |
|---|---|
| **Automated extraction** - artifacts exported as machine-readable definitions with scripts + the SAP Datasphere CLI | `scripts/export.sh` (CLI `objects <type> read` -> normalised JSON/CSN) |
| **Version control** - definitions + deployment scripts in a central GitLab repo, traceability, controlled change | `definitions/`, `scripts/`, merge-request gate (`validate` job), `reports/deploy-*.tsv` audit trail |
| **CI/CD deployment** - GitLab pipelines export from source and deploy approved versions to target spaces/tenants via the CLI | `.gitlab-ci.yml` -> `scripts/deploy.sh` (dependency-ordered, idempotent), manual prod approval on tags |

Extras that make it production-shaped: drift detection (`scripts/drift-check.sh`), export-to-merge-request bot (`scripts/export-to-mr.sh`), JUnit validation report, per-environment secrets.

## Read this first - three honest caveats

1. **Your BTP trial probably cannot create Datasphere.** I could not confirm Datasphere is in the BTP *trial* catalog (a community thread reports it can't be added there), the 30-day *Basic Trial* is a shared tenant without admin/integration rights (so no OAuth client, so no CLI), and a real tenant normally comes from a free-tier *Pay-As-You-Go* account. Check in 2 minutes and pick a path: [docs/01](docs/01-datasphere-tenant-and-ui-tour.md).
2. **The repo runs without any tenant.** `DS_MODE=mock` (default) swaps the SAP CLI for a small simulator in `tools/mock-datasphere/`, so you can see and demo the whole loop today. Mock mode proves the pipeline logic, **not** that Datasphere accepts these files.
3. **The sample definitions are illustrative.** Real CSN comes from your tenant. The first thing to do on a real tenant is export your own objects (`docs/02`, step 5) and commit those instead.

What is verified against SAP's docs vs. assumed is listed at the bottom.

## One command

```bash
cp .env.example .env     # real tenant settings (trial: passcode mode) - or DS_MODE=mock
make passcode-start      # trial only: sign in once in the window that opens
make bootstrap           # first real run only: deploy, then commit the tenant's canonical CSN
make pipeline            # everything GitLab CI runs, locally, against the tenant in .env
```

What gets deployed: SAP's official **Bike Sales** sample (9 local tables with associations, from
[SAP-samples/datasphere-content](https://github.com/SAP-samples/datasphere-content), Apache 2.0)
plus 3 SQL views on top - see `sample-data/sap-bike-sales/NOTICE.md`.

Step-by-step for the SAP trial tenant: [docs/00-RUNBOOK.md](docs/00-RUNBOOK.md), Track T.

## 2-minute quickstart (no tenant)

```bash
python3 scripts/py/validate.py      # static checks (what the merge-request gate runs)
python3 scripts/py/order.py --plan  # dependency-ordered deploy plan
bash scripts/demo-local.sh          # full loop: seed DEV -> UI change -> export diff -> TEST -> PROD -> drift
```

Requirements: bash, python3 (3.8+), diff. On Windows use WSL or Git Bash.

## Going real

1. Get a tenant -> [docs/01](docs/01-datasphere-tenant-and-ui-tour.md)
2. Install CLI, create OAuth client, export your first objects -> [docs/02](docs/02-cli-and-oauth.md)
3. Push to GitLab, set variables, protect tags, switch `DS_MODE=real` -> [docs/03](docs/03-gitlab-setup.md)
4. Rehearse the interview with the mapping in [docs/04](docs/04-interview-cheatsheet.md)
5. Links: [docs/05](docs/05-references.md)

## How it flows

```
 Datasphere DEV space ──(export.sh: CLI read + normalise)──▶ definitions/*.json ──▶ merge request
        ▲                                                         │ validate + plan (no tenant needed)
   modelers build in UI                                            ▼
                                                               main branch
                                                                   │ auto
                                                                   ▼
                                                          deploy-test (TEST space)
                                                                   │ git tag vX.Y.Z + manual approval
                                                                   ▼
                                                          deploy-prod (PROD space)

   schedules:  export-dev -> opens an MR with UI changes   |   drift-check -> alerts if TEST/PROD != Git
```

## Layout

```
.gitlab-ci.yml            pipeline (mock by default)
definitions/<type>/<NAME>.json   one CSN file per object; folder = CLI object type (local-tables, views, ...)
config/environments.json  env -> space name          config/policy.json  naming rules for the MR gate
scripts/                  export.sh deploy.sh drift-check.sh export-to-mr.sh ds-login via lib.sh
scripts/py/               validate.py order.py normalize.py parse_list.py dslib.py
tools/mock-datasphere/    simulator used when DS_MODE=mock
sample-data/              two CSVs to load into the sample tables
docs/                     01 tenant+UI  02 CLI+OAuth  03 GitLab  04 interview  05 references
```

## Pipeline behaviour

| Trigger | Jobs |
|---|---|
| Merge request | `validate` (JSON/CSN shape, naming policy, secrets scan, dependency + cycle check) -> `plan` |
| Push to `main` | validate -> plan -> `deploy-test` (automatic) |
| Tag `vX.Y.Z` | validate -> plan -> deploy-test -> `deploy-prod` (**manual**, `resource_group` serialised) |
| Schedule `SCHEDULE_JOB=export-dev` | export DEV -> commit -> open MR with the differences |
| Schedule `SCHEDULE_JOB=drift-check` | export TEST/PROD, diff against Git, fail on drift |

Design choices worth being able to explain: deploys are **idempotent** (update if exists, else create) and **never delete**; objects are deployed **dependencies-first** (tables before views before views-on-views); the CLI version is **pinned** via `DS_CLI_VERSION`; JSON keys are **not sorted** on export because the order of `elements` is the column order.

## Verified vs. assumed

| Item | Status |
|---|---|
| `npm install -g @sap/datasphere-cli`; `config cache init --host --secrets-file`; secrets.json fields; OAuth "Interactive Usage" client; login valid ~720 h | Verified in SAP's npm README |
| `datasphere objects local-tables create/read/update/delete --space --technical-name --file-path` | Verified in an SAP blog (local tables); other object types follow the same pattern per that blog |
| `datasphere objects ... list` | SAP Help says objects supports list/read/delete; **output format not confirmed** -> `parse_list.py` is tolerant |
| `datasphere config host set <url>` | Command name from memory; SAP Help has a section "Set a Host Value..." - **verify with `datasphere config -h`** |
| `views` as the CLI type for SQL/graphical views, and the CSN layout of the sample files | Plausible, **illustrative** - replace with your tenant's real export |
| Non-interactive auth in CI | Works via refresh token in secrets.json, which expires; see docs/02 step 6 for the proper options |
