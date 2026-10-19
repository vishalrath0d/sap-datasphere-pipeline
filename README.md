# Datasphere GitOps pipeline

A working proof of concept for this job profile:

| Job-profile bullet | What does it here |
|---|---|
| **Automated extraction** - SAP Datasphere artifacts exported as machine-readable definitions with automated scripts and the SAP Datasphere CLI | `scripts/export.sh` - `datasphere objects <type> read` -> normalised CSN/JSON, one file per object |
| **Version control** - definitions and deployment scripts in a central GitLab repository, traceability, controlled change | `definitions/` + `scripts/` in Git; merge-request gate (`validate`); audit trail `reports/deploy-*.tsv` |
| **CI/CD deployment** - GitLab pipelines export from source environments and deploy approved versions to target spaces/tenants through the CLI | `.gitlab-ci.yml` -> `scripts/deploy.sh` (dependency order, idempotent); manual approval for prod |

Plus: drift detection (did someone change PROD by hand?), export-to-merge-request on a schedule,
validation report, one command that runs the whole pipeline locally.

**How it all works - flow, code and syntax explained: [docs/06-how-it-works.md](docs/06-how-it-works.md).**

---

## Status - proven against a real SAP Datasphere tenant (2026-10-19)

On the SAP Datasphere trial tenant (`academydatasphere-1.ap11.hcs.cloud.sap`, space `SPACE_00031222`),
with the real SAP Datasphere CLI 2026.21.0:

- `make bootstrap`: **12 objects created** - 9 local tables from SAP's official *Bike Sales* sample
  (with associations) + 3 SQL views (one view on another view), deployed in dependency order.
- `make pipeline`: preflight, validate, plan, **deploy (12 updated)**, **drift checks clean**, export.
- The only difference between Git and the tenant's stored form was a `_meta` bookkeeping block,
  now stripped on export.

---

## Quick start (POC on the trial tenant)

Needs: **bash**, **git**, **Python 3.8+**, **Node.js 22-24**, **Google Chrome or Chromium**
(passcode mode only), **make** (optional - every target is one script line).

```bash
cp .env.example .env            # fill DS_PASSWORD (trial login) - .env is git-ignored
make install-cli                # SAP Datasphere CLI 2026.21.0
make passcode-start             # opens a separate Chrome; with DS_AUTO_LOGIN=1 it signs in itself
make passcode-test              # prints a one-time passcode = automation works
make bootstrap                  # first run only: create the objects, read back their stored form
make pipeline                   # everything GitLab CI runs, locally, against the real tenant
make passcode-stop              # when done
```

No tenant at hand? `make demo` (or `DS_MODE=mock make pipeline`) runs everything against a
built-in simulator of the CLI.

### Platforms

| | How to run | Notes |
|---|---|---|
| **macOS** | Terminal: commands above | Tested. `brew install node@24` (CLI supports Node 20-24). |
| **Linux** | Terminal: commands above | Same scripts; CI uses `node:22-bookworm`. `make test-linux` runs the self-test in that image (Docker). Chrome or Chromium on PATH, or `CHROME_BIN` in `.env`. |
| **Windows** | **Git Bash** (comes with Git for Windows): commands above | `make` is not in Git Bash - install it (`winget install GnuWin32.Make` / `choco install make`) or run the script lines from the `Makefile` directly, e.g. `bash scripts/pipeline.sh`. Python may be `python`/`py` - handled. Not tested yet. |

---

## How it runs today (POC) vs. what production needs

| Concern | POC - trial tenant (now) | Production |
|---|---|---|
| **Tenant / environments** | One shared trial tenant, **one space**: dev, test and prod all map to `SPACE_00031222` (`config/environments.json`) - promotion re-deploys into the same space | Separate spaces or tenants for DEV / QA / PROD, each mapped in `config/environments.json` (and `DS_HOST` per GitLab environment if tenants differ) |
| **Authentication** | **Passcodes**: no OAuth client in the trial, so every CLI call needs a one-time passcode; `tools/passcode/` reads them from a signed-in Chrome; optional auto-login with `DS_USER`/`DS_PASSWORD` from `.env` | **OAuth client, purpose Technical User** (client credentials): `DS_CLIENT_ID`, `DS_CLIENT_SECRET`, `DS_AUTH_URL`, `DS_TOKEN_URL` as masked GitLab variables, one client per environment, scoped role DW Modeler on its space only. No browser, no password, no passcodes. Already supported by `scripts/lib.sh` |
| **Where the pipeline runs** | Laptop: `make pipeline` (passcode mode needs your browser session, so not in GitLab) | GitLab runners (`.gitlab-ci.yml`, same stages); runner must reach the tenant (allow-list IPs if the tenant restricts them) |
| **Approvals** | Prompt `Approve now? [y/N]` before deploy-prod | Protected tags `v*`, protected variables; Protected Environments with approvers (GitLab Premium) |
| **Secrets** | `.env` on the laptop (git-ignored, plain text) | GitLab masked + protected variables, ideally from a vault; rotate client secrets (OAuth client expiry) |
| **Data** | Optional CSV upload in the UI | Never through this pipeline: replication flows, data flows, remote tables, task chains per environment |
| **Object types** | Local tables + SQL views proven | Test every type in use (graphical views, analytic models, flows, task chains, access controls); flows/remote tables need their **connections** created per tenant first |
| **Deletes / renames** | Not automated - by design, deploy never deletes | Decide a policy (manual, or an explicit "removals" list reviewed in the MR) |
| **CLI version** | Pinned `2026.21.0` | Pinned; bump deliberately with each Datasphere wave, test in QA first |

**Production checklist:** tenants/spaces created · scoped roles · one Technical User OAuth client per
environment · GitLab variables (masked, protected, environment-scoped) · protected `v*` tags ·
`DS_MODE=real` in CI · remove `DS_AUTH=passcode` · `config/environments.json` with real space names ·
connections per tenant · first run `--flow bootstrap` per environment · schedules for `export-dev`
and `drift-check`. Step by step: [docs/00-RUNBOOK.md](docs/00-RUNBOOK.md) Phases 0-7.

---

## Layout

```
Makefile                    one-line entry points (make help)
.gitlab-ci.yml              GitLab pipeline - every job calls scripts/pipeline.sh stage <name>
.env.example                settings template (copy to .env, git-ignored)
config/
  environments.json         env -> space name
  policy.json               merge-request rules (names, prefixes, excluded generated objects)
  normalize.json            what to strip from exports (e.g. _meta)
definitions/<type>/<NAME>.json   one CSN file per Datasphere object - the thing under version control
scripts/
  pipeline.sh               the pipeline: stages + local orchestration
  deploy.sh export.sh drift-check.sh preflight.sh export-to-mr.sh
  lib.sh env.sh             shared helpers (login, CLI wrapper, .env loading, cross-platform)
  install-cli.sh login-interactive.sh create-spaces.sh demo-local.sh
  py/                       validate, order (dependency plan), normalize, import_csn, parse_list
tools/passcode/             passcode automation (chrome-session.sh, get-passcode.mjs)
tools/mock-datasphere/      CLI simulator (DS_MODE=mock)
sample-data/sap-bike-sales/ SAP's original sample model + CSV data (Apache 2.0, see NOTICE.md)
docs/                       00 runbook · 01 tenant & UI · 02 CLI & OAuth · 03 GitLab · 04 interview · 05 links · 06 how it works
```

## Verified vs. assumed

| Item | Status |
|---|---|
| CLI install, `config host set`, `config cache init`, `objects <type> list/read/create/update`, `--output`, `--accept`, `--passcode` | Verified: SAP CLI guide 2026.21 + **run against the trial tenant** |
| Local tables and SQL views created/updated from Git, dependency order incl. associations | **Verified on the trial tenant** |
| Read-back equals what was deployed except `_meta` | **Verified on the trial tenant** |
| Technical User OAuth client supports `datasphere objects` (client credentials) | SAP CLI guide 2.3; login code path tested against an unreachable host, not a real tenant |
| GitLab pipeline in real mode | Not run (trial has no OAuth client); same stage scripts as the local run |
| Windows | Written for Git Bash, not tested |
| Auto-login | Tested against a simulated login page; the real SAP login page may differ (MFA/captcha -> sign in by hand) |
