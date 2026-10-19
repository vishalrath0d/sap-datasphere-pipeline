# 6. How it works - the flow, the code, the syntax

Read top to bottom once. Part A is the idea, B what one command does, C every stage, D the same
thing in GitLab, E how it talks to Datasphere, F the passcode automation, G-I syntax primers
(bash, make, GitLab YAML), J a file-by-file reference.

---

## A. The idea in one picture

```
            (1) automated extraction                         (3) CI/CD deployment
 ┌──────────────────────┐  export.sh   ┌──────────────────┐  deploy.sh   ┌──────────────────────┐
 │ Datasphere DEV space │ ───────────▶ │  Git repository  │ ───────────▶ │ TEST space, PROD     │
 │ (modelers build      │  CLI read    │  definitions/*.json  CLI create │ space (or tenants)   │
 │  in the UI)          │              │  (2) version     │  /update     │                      │
 └──────────────────────┘              │      control     │              └──────────────────────┘
            ▲                          └──────────────────┘                        │
            │                         review = merge request                       │
            └────────────── drift-check.sh: "does TEST/PROD still match Git?" ◀─────┘
```

- A Datasphere object (table, view, ...) is stored as **CSN**: JSON text. Text can live in Git.
- **Git is the source of truth.** What is in `main` (or in a tag) is what TEST/PROD must contain.
- Changes go **one way**: DEV (UI) -> Git (review) -> TEST -> PROD (after approval).
- **Drift check** catches anyone who edits TEST/PROD by hand.

Why anyone needs this: a data model is never finished - new KPIs, changed source systems, bug
fixes, new access rules. Several developers change DEV every week; those changes must reach PROD
**reviewed, in the right order, approved, traceable, and repeatable**. Doing that by hand (or with
manual transports) is slow and error-prone and leaves no diff, no review, no rollback point.

---

## B. What `make pipeline` does - the call chain

```
make pipeline
└─ bash scripts/pipeline.sh                    # orchestrator: plays "GitLab" on your laptop
   ├─ source scripts/lib.sh                    # helpers; lib.sh itself sources scripts/env.sh (.env)
   ├─ bash scripts/pipeline.sh stage preflight     └─ scripts/preflight.sh dev
   ├─ bash scripts/pipeline.sh stage validate      └─ scripts/py/validate.py
   ├─ bash scripts/pipeline.sh stage plan          └─ scripts/py/order.py --plan
   ├─ bash scripts/pipeline.sh stage deploy-test   └─ scripts/deploy.sh test
   ├─ [ prompt: Approve now? [y/N] ]
   ├─ bash scripts/pipeline.sh stage deploy-prod   └─ scripts/deploy.sh prod
   ├─ bash scripts/pipeline.sh stage drift-test    └─ scripts/drift-check.sh test  └─ export.sh --out tmp
   ├─ bash scripts/pipeline.sh stage drift-prod    └─ scripts/drift-check.sh prod
   └─ bash scripts/pipeline.sh stage export-dev    └─ scripts/export.sh dev --discover
```

Every box that talks to Datasphere ends in **one function**, `ds` in `scripts/lib.sh`, which runs
the real CLI (`datasphere ...`) or the simulator, and adds a passcode when needed (part E).

**GitLab runs exactly the same `bash scripts/pipeline.sh stage <name>` lines** - one per job
(part D). That is why "it works with `make pipeline`" means "the GitLab jobs do the same thing".

### The orchestrator, explained (`scripts/pipeline.sh`)

```bash
if [ "${1:-}" = "stage" ]; then          # called as: pipeline.sh stage deploy-test
  run_stage "${2:?usage: pipeline.sh stage <name>}"
  exit $?
fi
```
- `${1:-}` = first argument, or empty if there is none (`:-` = default value).
- `${2:?msg}` = second argument; if missing, stop with `msg`.
- This branch is what GitLab calls. Without `stage`, the script runs the local orchestration below.

```bash
case "$flow" in
  mr)     stages="validate plan" ;;
  main)   stages="validate plan deploy-test" ;;
  tag)    stages="validate plan deploy-test deploy-prod" ;;
  full)   stages="validate plan deploy-test deploy-prod drift-test drift-prod export-dev" ;;
  ...
esac
```
A *flow* = which GitLab pipeline you are imitating (merge request, push to main, tag, ...).

```bash
for s in $stages; do
  if [ -n "$failed" ]; then summary="...skipped"; continue; fi        # like GitLab `needs:`
  if [ "$s" = "deploy-prod" ] && [ "$yes" = 0 ]; then                 # like `when: manual`
    read -r -p "deploy-prod is a manual job in GitLab. Approve now? [y/N] " ans
    ...
  fi
  if bash "$ROOT/scripts/pipeline.sh" stage "$s"; then ... passed ... else ... failed="$s"; fi
done
```
- Each stage runs as a **separate process** (`bash ... stage "$s"`), like a separate CI job.
  (Inside an `if` condition, bash ignores `set -e` for that shell; a child process keeps its own
  `set -e`, so a failing command inside a stage really stops that stage.)
- After the first failure, later stages are `skipped`.
- `--yes` skips the approval prompt.

---

## C. The stages

### preflight - can we reach the tenant? (`scripts/preflight.sh`)
Logs in (`ds_login`), then for each environment lists its local tables. Read-only. Fails early with
a clear message instead of failing halfway through a deploy.

### validate - the merge-request gate (`scripts/py/validate.py`)
No tenant needed. For every `definitions/<type>/<NAME>.json`:
- valid JSON, has `definitions.<NAME>` (file name = technical name), has columns;
- name follows `config/policy.json` (`name_regex`, views must start with `V_`);
- no secrets in the file (regex scan);
- every source (view `FROM`/`JOIN`) and every association target exists in the repo;
- no dependency cycles.
Writes `reports/validate.xml` (JUnit format) - GitLab shows it as a test report.

### plan - deploy order (`scripts/py/order.py --plan`)
Builds a dependency graph and sorts it ("topological sort"): an object comes after everything it
depends on. Datasphere refuses to create a view whose sources do not exist yet, or a table whose
association target does not exist yet - so order matters.
```
 1. local-tables   Addresses           depends on: -
 2. local-tables   BusinessPartners    depends on: Addresses           (association _Addresses)
 ...
12. views          V_TOP_COUNTRIES     depends on: V_SALES_BY_COUNTRY  (view on a view)
```
Core of it, `scripts/py/dslib.py`:
```python
def structural_refs(obj):
    return set(_query_refs(obj.entity.get("query"))) | association_targets(obj)
```
`_query_refs` walks the CSN `query` (`SELECT.from`, nested `join.args`) and collects every
`{"ref": ["NAME"]}`; `association_targets` collects `"target"` of `cds.Association` columns.

### deploy-test / deploy-prod - Git -> space (`scripts/deploy.sh <env>`)
1. `env_space test` -> space name from `config/environments.json`.
2. Re-run validation; refuse to deploy if it fails.
3. `ds_login`.
4. **One** `list` call per object type, filtered to the names we will deploy -> which exist already.
5. For each object in plan order: exists -> `update`, else `create`:
   ```bash
   ds objects "$t" update --space "$space" --technical-name "$n" --file-path "$f"
   ds objects "$t" create --space "$space" --technical-name "$n" --file-path "$f"
   ```
   The CLI **saves and deploys** in one call ("Saved and deployed 'X' in 'SPACE'").
6. Retries each object up to 3 times (5 s, 10 s back-off); stops at the first object that still
   fails - objects after it are **not** deployed (no half-random state).
7. Appends a line per object to `reports/deploy-<env>.tsv` (time, git version, env, space, object,
   created/updated) - the audit trail.
8. **Never deletes.** Removing an object is a deliberate, manual act.

*Idempotent* = running it twice gives the same result (second run: everything `updated`).

### drift-test / drift-prod - has anyone changed it by hand? (`scripts/drift-check.sh <env>`)
Exports every tracked object from the environment into a temp folder (same normaliser as below),
then `diff -u` against `definitions/`. Any difference -> prints the diff and fails. Fix = redeploy
from Git (Git wins) or bring the change into Git through a merge request.

### export-dev - automated extraction (`scripts/export.sh dev --discover`)
1. For each supported type: `ds objects <type> list` (paged, max 200 per call) -> names.
2. Skip generated objects (`policy.json` `discover_exclude`, e.g. `SAP.TIME.*`).
3. For each: `ds objects <type> read --technical-name N --accept ...design-time+json --output tmp`.
   (`--output` instead of stdout because the CLI prints warnings on stdout.)
4. `scripts/py/normalize.py`: find the JSON, keep only this object's own definition (SAP: one
   object per file), strip `_meta` (server bookkeeping), keep key order (column order matters).
5. Write `definitions/<type>/<NAME>.json`.
Locally it shows `git status`/`git diff` - you review and commit. In GitLab,
`scripts/export-to-mr.sh` commits to a new branch and opens a **merge request** automatically.

### canonicalize - only in `make bootstrap`
Deploy once, then export back from TEST into `definitions/`, so Git holds exactly what the tenant
stores. On the trial the only difference was `_meta`, now stripped.

---

## D. The same pipeline in GitLab (`.gitlab-ci.yml`)

Which jobs run depends on **what triggered the pipeline**:

| Trigger | Jobs | Local equivalent |
|---|---|---|
| Merge request | validate, plan | `make pipeline-mr` |
| Push/merge to `main` | validate, plan, deploy-test | `make pipeline-main` |
| Tag `v1.2.3` | validate, plan, deploy-test, **deploy-prod (manual button)** | `make pipeline-tag` |
| Schedule `SCHEDULE_JOB=export-dev` | export-dev -> merge request | `bash scripts/pipeline.sh --flow export` |
| Schedule `SCHEDULE_JOB=drift-check` | drift-test, drift-prod | `bash scripts/pipeline.sh --flow drift` |
| "Run pipeline" button | + manual preflight | `make preflight` |

A typical change, end to end:
1. Developer changes a view in DEV (UI) -> nightly `export-dev` opens an MR with the JSON diff
   (or the developer edits `definitions/` directly and opens an MR).
2. MR pipeline: `validate` + `plan` must be green; a reviewer approves; merge.
3. Merge to `main`: `deploy-test` runs automatically -> TEST is updated; testers check.
4. Release: `git tag v1.4.0 && git push origin v1.4.0` -> pipeline stops at `deploy-prod`; an
   approver clicks *Run* -> PROD is updated. The tag is the exact version that went to PROD.
5. Every 6 h: `drift-check` -> alerts if TEST/PROD no longer match Git.

---

## E. How the code talks to Datasphere (`scripts/lib.sh`)

### One wrapper for every CLI call
```bash
ds() {
  if [ "$DS_MODE" = "mock" ]; then
    python3 "$ROOT/tools/mock-datasphere/datasphere" "$@"     # simulator
  elif _needs_passcode "$@"; then
    local pc
    pc="$(get_passcode)" || return 1                            # fresh one-time code
    datasphere "$@" --passcode "$pc"
  else
    datasphere "$@"                                             # real CLI, OAuth session
  fi
}
```
`"$@"` = all arguments, passed on unchanged. So `ds objects views list --space X` becomes
`datasphere objects views list --space X` (+ `--passcode ...` in passcode mode).

### Three ways to log in (`ds_login`)
| Mode | Set in `.env` / CI variables | Used for |
|---|---|---|
| **Passcode** | `DS_AUTH=passcode` | Trial (no OAuth client). Every tenant call needs a new one-time code |
| **Technical User (OAuth client credentials)** | `DS_CLIENT_ID`, `DS_CLIENT_SECRET`, `DS_AUTH_URL`, `DS_TOKEN_URL` | **Production / GitLab.** No browser, no password |
| **Interactive OAuth** | `scripts/login-interactive.sh`, then `DS_SKIP_LOGIN=1` | Developer laptops on a real tenant |

For OAuth the secret goes into a temporary *options file* (`datasphere login --options-file f`),
not onto the command line (where `ps` and CI logs could show it); in CI the CLI's stored secrets
are wiped when the job ends. After login: `datasphere config cache init` downloads the tenant's
command list - `datasphere objects ...` does not exist before that.

### `.env` loading (`scripts/env.sh`)
Every script sources it. Locally it reads `KEY=VALUE` lines from `.env` and exports them, unless
the variable is already set in your shell (your shell wins). In CI it is never read - GitLab
variables are used instead.

---

## F. Passcode automation (trial only - `tools/passcode/`)

Why: the trial has no OAuth client, so the CLI needs `--passcode <code>` on every call, and each
code works once. A code comes from `https://<tenant>.authentication.<region>.hana.ondemand.com/passcode`
- every load of that page shows a new one (SAP's CLI README says so and suggests automating it).

```
make passcode-start  ──▶ chrome-session.sh: starts Chrome with its own profile and a local
                          DevTools port (127.0.0.1:9333); you sign in (or auto-login does)
ds ... (every CLI call)
 └─ get_passcode ──▶ node get-passcode.mjs <passcode-url>
                      1. ask Chrome (DevTools Protocol) for its cookies for the passcode host
                      2. fetch the passcode page from Node with those cookies   (no tab, no window)
                      3. read "Temporary Authentication Code <code>" from the HTML -> print it
                      if the session expired and DS_AUTO_LOGIN=1:
                      4. background tab -> fill DS_USER / DS_PASSWORD -> submit -> back to 1
```
The DevTools Protocol (CDP) is how tools like Puppeteer control Chrome: JSON messages over a
WebSocket. We use three commands: `Storage.getCookies`, `Target.createTarget` (background tab,
only for login) and `Runtime.evaluate` (run JS in that tab). No npm packages needed.

None of this exists in production: a Technical User OAuth client replaces it completely.

---

## G. Bash syntax used in this repo

| Syntax | Meaning | Example from the repo |
|---|---|---|
| `#!/usr/bin/env bash` | run this file with bash | first line of every script |
| `set -euo pipefail` | stop on any error (`-e`), on unset variables (`-u`), on a failure inside a pipe (`pipefail`) | top of `lib.sh` |
| `source file` | run another file **in this shell** (its functions/variables become available) | `source "$(dirname "$0")/lib.sh"` |
| `name() { ...; }` | define a function; call it like a command | `log() { printf ... >&2; }` |
| `local x` | variable visible only inside the function | `local t=$1 n=$2 f=$3` |
| `$1 $2 "$@"` | arguments; `"$@"` = all of them, each kept intact | `ds "$@"` |
| `$(cmd)` | run `cmd`, use its output as a value | `space="$(env_space "$env")"` |
| `${VAR:-x}` | value of VAR, or `x` if empty/unset | `"${DS_MODE:-mock}"` |
| `${VAR:?msg}` | value of VAR, or stop with `msg` | `"${DS_HOST:?DS_HOST is required}"` |
| `${VAR#pre}` `${VAR%%pat*}` | strip a prefix / cut at a pattern | `_key="${_line%%=*}"` (text before `=`, in `env.sh`) |
| `[ cond ]` | test: `-n` non-empty, `-z` empty, `-f` file exists, `=` equal, `-gt` greater | `[ -n "$only" ]` |
| `a && b` / `a \|\| b` | run b only if a succeeded / failed | `cmd \|\| die "msg"` |
| `if ...; then ...; else ...; fi` | condition on a command's success | `if grep -qxF ...; then` |
| `case "$x" in a) ... ;; *) ... ;; esac` | match a value against patterns | flows in `pipeline.sh` |
| `while IFS=$'\t' read -r a b c; do ...; done <file` | read a file line by line, split on tabs | deploy loop |
| `cmd >file` `>>file` `2>/dev/null` `>&2` | write / append / discard errors / send to stderr | logs go to stderr so `$(...)` captures only data |
| `cmd <<'PY' ... PY` | "heredoc": feed the following lines as input (here: inline Python) | `python3 - <<'PY'` |
| `trap '...' EXIT` | run cleanup when the script ends | delete temp files |
| `$?` | exit code of the last command (0 = success) | `exit $?` |
| `mktemp` | create a temporary file and print its name | `raw="$(mktemp)"` |

Exit codes are the language between scripts: `0` = success, anything else = failure. The pipeline
decides "passed/FAILED" purely from the exit code of each stage.

## H. Make syntax (`Makefile`)

```make
PYTHON ?= $(shell command -v python3 || command -v python)   # ?= : set only if not set already

pipeline:       ## THE ONE COMMAND ...        # target: the name after `make`; ## = help text
	bash scripts/pipeline.sh                    # recipe: must start with a TAB character

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'   # @ = don't echo the command
```
- `make <target>` runs that target's recipe in a shell. `$(VAR)` is a make variable; `$$` is a
  literal `$` for the shell (`"$$PWD"`). `.PHONY` = targets that are not files.
- Make adds nothing clever here: every target is one script line, so without make you can run
  the line yourself.

## I. GitLab CI YAML (`.gitlab-ci.yml`)

```yaml
workflow:                      # which events create a pipeline at all
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_TAG

stages: [validate, plan, test, prod, ops]     # columns in the pipeline graph, run left to right

variables:                     # environment variables for every job (CI/CD settings can override)
  DS_MODE: "mock"
  DS_CLI_VERSION: "2026.21.0"

default:
  image: $NODE_IMAGE           # every job runs in a fresh node:22-bookworm container

.cli:                          # a name starting with "." = template, not a job
  before_script:
    - bash scripts/install-cli.sh

deploy-prod:                   # a job
  extends: .cli                # inherit the template (install the CLI first)
  stage: prod
  needs: [deploy-test]         # start only after deploy-test succeeded
  environment:
    name: prod                 # shows in Deployments; variables can be scoped to it
  resource_group: datasphere-prod   # never two prod deployments at the same time
  rules:
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/   # only for tags like v1.2.3
      when: manual             # wait for someone to click "Run"
      allow_failure: false     # ...and the pipeline stays "blocked" until they do
  script:
    - bash scripts/pipeline.sh stage deploy-prod
  artifacts:
    paths: [reports/deploy-prod.tsv]   # files kept and downloadable after the job
```
- `$CI_PIPELINE_SOURCE`, `$CI_COMMIT_TAG`, `$CI_DEFAULT_BRANCH` are variables GitLab sets.
- Secrets (`DS_CLIENT_SECRET`, ...) are **not** in this file: Settings > CI/CD > Variables
  (masked, protected, environment-scoped).

---

## J. File-by-file reference

| File | Role |
|---|---|
| `Makefile` | entry points; `make help` lists them |
| `.gitlab-ci.yml` | GitLab jobs; each = `bash scripts/pipeline.sh stage <name>` |
| `.env` / `.env.example` | local settings (tenant, auth mode, POC credentials); `.env` is git-ignored |
| `config/environments.json` | env -> Datasphere space |
| `config/policy.json` | validation rules + objects excluded from export |
| `config/normalize.json` | keys stripped on export (`_meta`) |
| `definitions/<type>/<NAME>.json` | **the versioned content** - one Datasphere object per file |
| `scripts/pipeline.sh` | stages + local orchestration |
| `scripts/lib.sh` | `ds` wrapper, login modes, passcode hook, paging, retry, logging |
| `scripts/env.sh` | `.env` loading, cross-platform helpers (python, open URL) |
| `scripts/deploy.sh` | Git -> space, dependency order, create/update, audit TSV |
| `scripts/export.sh` | space -> Git, normalised |
| `scripts/drift-check.sh` | export to temp + diff with Git |
| `scripts/preflight.sh` | read-only connectivity check |
| `scripts/export-to-mr.sh` | CI only: commit export to a branch, open a merge request |
| `scripts/install-cli.sh` | install the pinned SAP Datasphere CLI, check Node version |
| `scripts/login-interactive.sh` | browser OAuth login for a real tenant (Interactive Usage client) |
| `scripts/create-spaces.sh` | spaces as code (admin only) |
| `scripts/demo-local.sh` | full self-test against the simulator |
| `scripts/py/dslib.py` | CSN loading, dependency detection, topological sort |
| `scripts/py/validate.py` / `order.py` | merge-request gate / deploy plan |
| `scripts/py/normalize.py` / `parse_list.py` | clean CLI output / read `list` output |
| `scripts/py/import_csn.py` | split a multi-object CSN export (e.g. SAP sample) into per-object files |
| `tools/passcode/chrome-session.sh` / `get-passcode.mjs` | passcode automation (trial only) |
| `tools/mock-datasphere/datasphere` | CLI simulator for offline runs and tests |
