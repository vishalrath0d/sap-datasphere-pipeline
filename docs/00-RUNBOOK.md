# 0. Runbook - run it for real (Datasphere 30-day trial + GitLab)

Do the phases in order. Each ends with a check, so you know where you stand when something fails.
Commands are from SAP's *Accessing SAP Datasphere via the Command Line* guide (version 2026.21,
7 Oct 2026) and the `@sap/datasphere-cli` 2026.21.0 help output.

| Phase | Time | Result |
|---|---|---|
| 0. Check what the trial lets you do | 5 min | You know if CI against the trial is possible |
| 1. Laptop setup + mock demo | 10 min | Pipeline logic proven locally |
| 2. Spaces DEV / TEST / PROD | 10 min | Three "environments" in one tenant |
| 3. Build real content in DEV (UI) | 30 min | Tables + views you made yourself |
| 4. Two OAuth clients | 10 min | One for you (browser), one for CI (technical user) |
| 5. Real export + deploy from the laptop | 20 min | Real CSN in Git, objects appear in TEST |
| 6. GitLab pipeline | 30 min | MR gate, auto TEST, tag + approval to PROD |
| 7. Rehearse the interview story | 15 min | The loop end to end, in your words |

**Which track?** On the SAP trial tenant (`academydatasphere-1...`, user `GE...@sapexperienceacademy.com`)
there is no *System > Administration*, so no OAuth client and one fixed space. Use **Track T** right
below. Phases 0-7 are for a tenant where you are administrator (BTP free tier, or a client sandbox).

---

## Track T - the trial tenant, for real (passcode mode)

What is real here: the SAP Datasphere CLI, your tenant, your space `SPACE_00031222`, real CSN in Git,
real deploys back into the space. What is not: unattended CI login and DEV->TEST->PROD across spaces
(the trial has one space and no OAuth) - those stay in mock mode.

**How the automation works:** without an OAuth login, every CLI call that reaches the tenant needs a
new one-time passcode (SAP CLI guide 2.4). Each load of your tenant's passcode page issues a new one.
`tools/passcode/` keeps a separate Chrome window signed in and reads a fresh code for every call - the
headless-browser approach SAP's CLI README itself suggests. You sign in once; then it is hands-free.

**T1. Laptop (10 min)**
```bash
cd ~/Documents/projects/datasphere-cicd
brew install node@24 && export PATH="/opt/homebrew/opt/node@24/bin:$PATH"   # CLI supports Node 20-24
make install-cli                       # @sap/datasphere-cli 2026.21.0
cp .env.example .env                   # section A is already filled for your trial tenant (scripts read it themselves)
make demo                              # simulator self-test, must end "all expectations met"
```

**T2. Passcode browser (2 min)**
```bash
make passcode-start                    # a separate Chrome window opens on the passcode page
# sign in there (SAP Experience Academy login) until you see "Temporary Authentication Code"
make passcode-test                     # prints a code -> automation works. Run again: different code.
```
Leave that window open while you work. `make passcode-stop` when done.

**T3. What gets deployed - real SAP content, already in the repo**

| Objects | Source |
|---|---|
| 9 local tables: `Addresses`, `BusinessPartners`, `Employees`, `ProductCategories`, `ProductCategoryText`, `Products`, `ProductTexts`, `SalesOrderItems`, `SalesOrders` (with associations between them) | SAP's official "Bike Sales" sample (`SAP-samples/datasphere-content`, Apache 2.0) - original file in `sample-data/sap-bike-sales/`, split into one CLI file per object by `scripts/py/import_csn.py` |
| 3 SQL views: `V_SALES_BY_CATEGORY`, `V_SALES_BY_COUNTRY`, `V_TOP_COUNTRIES` (view on a view) | This repo, on top of SAP's tables |

`python3 scripts/py/order.py --plan` shows the order the pipeline will use: tables whose
associations point at other tables come after them, views after their sources. You build
nothing by hand - the pipeline creates all 12 objects in `SPACE_00031222`.

**T4. Connect**
```bash
make passcode-test                     # a code -> automation works
bash scripts/preflight.sh dev          # logs in, lists the space (first run also caches the CLI commands)
```

**T5. First real run: bootstrap (once)**
```bash
git add -A && git commit -m "SAP Bike Sales content + pipeline"    # bootstrap needs a clean definitions/
make bootstrap         # validate -> plan -> deploy-test (creates the 12 objects) -> canonicalize
git diff definitions   # what Datasphere added to the definitions when it stored them
git commit -am "Canonical CSN from the tenant"
```
Why: Datasphere stores what you deploy in its own canonical form. Committing that form once
means later drift checks only flag real changes. Open the Data Builder now - the 12 objects are there.

**T6. The whole pipeline, one command**
```bash
make pipeline          # = bash scripts/pipeline.sh  (reads .env itself)
```
Runs, against the real tenant, exactly the jobs GitLab runs - `.gitlab-ci.yml` calls the same
`scripts/pipeline.sh stage <name>`: preflight -> validate -> plan -> deploy-test -> *approve?* ->
deploy-prod -> drift-test -> drift-prod -> export-dev, stopping at the first failure, then a summary.
On the trial all three environments are `SPACE_00031222` (one space), so "promotion" re-deploys the
same objects - every call is still real. With 12 objects a full run uses about 75 passcodes,
all automatic (a few minutes). Smaller flows: `make pipeline-mr`, `make pipeline-main`,
`make pipeline-tag`, `bash scripts/pipeline.sh --flow export|drift`; `--yes` approves deploy-prod.

Then try the change loop:
```bash
# 1. change in Git: definitions/views/V_SALES_BY_COUNTRY.json -> "@EndUserText.label": "Sales by Country (from Git)"
git commit -am "Rename view" && make pipeline-main         # deployed; refresh the Data Builder
# 2. change in the UI: rename it by hand, deploy it there
bash scripts/pipeline.sh --flow drift                      # FAILS and shows the diff
make pipeline-main                                         # Git wins again
# 3. extraction: change something in the UI, then
bash scripts/pipeline.sh --flow export && git diff         # UI change arrives as a diff (in CI: a merge request)
```

**Optional - data for Data Preview.** The pipeline moves definitions, never data (as in any real
project). To see numbers: Data Builder > open a table, e.g. `SalesOrders` > *Upload Data from CSV* >
`sample-data/sap-bike-sales/SalesOrders.csv` (dates are `yyyyMMdd`). Then *Data Preview* on
`V_SALES_BY_COUNTRY`.

**If a create is rejected** (the tables are SAP's own, the views' CSN is hand-written): the error
names the object. Create that view once in the UI with the SQL from its file
(`@DataWarehouse.sqlEditor.query`), then `bash scripts/export.sh dev --objects views:<NAME>` and commit -
Git then holds the tenant's exact form.

**T7. GitLab**
Push as in Phase 6 (no CI variables needed). The pipeline runs `validate` and `plan` on **your real
exported CSN**; the deploy jobs run against the simulator. Interview line: *"Extraction and deployment
run against a real Datasphere tenant with the CLI; the trial has no OAuth client, so the unattended
GitLab login is the one piece I proved against a simulator - with a technical user it is four CI
variables."*

| Passcode problem | Fix |
|---|---|
| `get-passcode: no Chrome session` | `make passcode-start` |
| `get-passcode: not signed in` | session expired - sign in again in that window |
| `passcode page loaded but no code found` | `DS_PASSCODE_DEBUG=1 make passcode-test` and check the page text |
| Want to do it by hand | `DS_PASSCODE_SOURCE=prompt` - the page opens, you paste each code |

---

## Phase 0 - what can the trial do? (5 min)

Log in to the trial tenant. Copy its URL from the browser up to `.cloud.sap` - that is `DS_HOST`
(looks like `https://<tenant>.<region>.hcs.cloud.sap`). Then check three things in the left menu:

| Check | Where | If it is there | If it is missing |
|---|---|---|---|
| A | **System > Administration > App Integration** | You can create OAuth clients: full path below | Use the fallback at the bottom (passcode) |
| B | **Space Management > Create** button | You can create TEST and PROD spaces | Use any spaces you have; map them in `config/environments.json` |
| C | **Security > Roles** | You can make a scoped role for the CI user | Interactive login only (Phase 5); skip Phase 6's real mode |

Note your answers - they decide how far you go. **The trial's limits are not documented anywhere I
could check, so this five-minute look is the only way to know.**

---

## Phase 1 - laptop (10 min)

```bash
cd ~/Documents/projects/datasphere-cicd
make demo                       # whole loop against the built-in simulator; must end "all expectations met"
```

Install the real CLI. It supports **Node 20-24**; your Mac has Node 26 (works, but warns on every
command). Cleanest fix:

```bash
brew install node@24
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"     # add to ~/.zshrc to keep it
node -v                                               # v24.x
make install-cli                                      # npm install -g @sap/datasphere-cli@2026.21.0
datasphere --version                                  # 2026.21.0
```

Check: `datasphere -h` lists only `config`, `login`, `logout`. That is normal - `objects`,
`spaces`, ... appear only after the CLI has downloaded the command list from your tenant
(`config cache init`, done by the scripts after login).

---

## Phase 2 - spaces (10 min)

Spaces are the environments. One tenant, three spaces, matching `config/environments.json`:
`DEV_SALES`, `TEST_SALES`, `PROD_SALES` (space IDs: max 20 chars, uppercase, digits, `_`).

**UI (simplest):** Space Management > Create > Space ID `DEV_SALES` > small storage (0.5 GB is
plenty) > Create > add yourself as a member/space administrator > Deploy. Repeat for TEST and PROD.

**Or as code** after Phase 4's interactive login (needs DW Administrator):

```bash
bash scripts/create-spaces.sh --dry-run    # shows the space definition JSON it will send
DS_MODE=real DS_SKIP_LOGIN=1 DS_HOST=$DS_HOST bash scripts/create-spaces.sh
```

Then add yourself to each space in Space Management.

---

## Phase 3 - real content in DEV (30 min)

This is the part interviewers can't fake: you know what Datasphere looks like.

1. Open `DEV_SALES` > **Data Builder** > **Import CSV File** > `sample-data/customers.csv`.
   Technical name `CUSTOMERS`, make `CUSTOMER_ID` the key > **Deploy**.
2. Same for `sample-data/sales_orders.csv` as `SALES_ORDERS` (key `ORDER_ID`; set `NET_AMOUNT`
   to Decimal(15,2), `QUANTITY` Integer, `ORDER_DATE` Date) > Deploy.
3. **New SQL View** `V_SALES_BY_REGION` > paste > Deploy > **Data Preview**:

   ```sql
   SELECT C."REGION"            AS "REGION",
          SUM(S."NET_AMOUNT")   AS "TOTAL_NET_AMOUNT",
          COUNT(S."ORDER_ID")   AS "ORDER_COUNT"
   FROM "SALES_ORDERS" AS S
   INNER JOIN "CUSTOMERS" AS C ON S."CUSTOMER_ID" = C."CUSTOMER_ID"
   GROUP BY C."REGION"
   ```

4. **New SQL View** `V_REGION_LEADERBOARD`:
   `SELECT "REGION", "TOTAL_NET_AMOUNT" FROM "V_SALES_BY_REGION" WHERE "TOTAL_NET_AMOUNT" > 0` > Deploy.
5. Look around while you are here (interview vocabulary): object **status** (Deployed / Changes to
   deploy), the **impact & lineage** view of `V_REGION_LEADERBOARD`, **Data Integration Monitor**.

Check: four objects, all *Deployed*, in `DEV_SALES`.

---

## Phase 4 - two OAuth clients (10 min)

**System > Administration > App Integration**. Copy the **Authorization URL** and **Token URL** at
the top of the page into `.env` (`cp .env.example .env`).

**Client 1 - you, from the laptop.** *Add a New OAuth Client*:
Purpose **Interactive Usage**, Redirect URI `http://localhost:8080` > Add.
Copy ID and **secret now** (shown once) into `DS_UI_CLIENT_ID` / `DS_UI_CLIENT_SECRET`.

**Client 2 - the pipeline.** First give it permissions:

1. **Security > Roles** > create a **scoped role** from the **DW Modeler** template, e.g. `CICD_MODELER`;
   add scopes `DEV_SALES`, `TEST_SALES`, `PROD_SALES`. (Modeling objects via the CLI needs Space Files
   CRUD + Data Builder CRUD on the space - that is what DW Modeler grants.)
2. App Integration > *Add a New OAuth Client*: Purpose **Technical User**, User ID `CICD_BOT`
   (uppercase/digits/_), Roles: select `CICD_MODELER`. Grant type is fixed to **Client Credentials**.
   Expiry: default 3 months is fine for a demo.
3. Copy ID and secret into `DS_CLIENT_ID` / `DS_CLIENT_SECRET`.
4. Back in the scoped role, check that `CICD_BOT` is assigned to all three spaces.

Why two clients: an Interactive client logs in *as you* through a browser - fine on a laptop,
impossible in CI. A Technical User needs no browser and has only the roles you gave it. SAP lists
`datasphere objects` and `datasphere tasks` among the commands a technical user can run - exactly
what export and deploy need - but **not** `datasphere spaces` (so `create-spaces.sh` stays manual).

> In a real project: one technical user **per environment** (the TEST client can't touch PROD),
> GitLab variables scoped per environment, secrets from a vault.

---

## Phase 5 - real export and deploy from the laptop (20 min)

```bash
set -a; source .env; set +a          # DS_MODE=real, DS_HOST, URLs, client IDs

bash scripts/login-interactive.sh    # browser opens, sign in; stores the session in ~/.@sap
export DS_SKIP_LOGIN=1               # scripts reuse that session

bash scripts/preflight.sh dev        # OK dev -> DEV_SALES: 2 local table(s) visible ...
datasphere objects views list --space DEV_SALES --select "technicalName,status"
```

**Replace the illustrative definitions with your tenant's real CSN** - the most valuable step:

```bash
cp -r definitions /tmp/definitions-sample          # keep the samples to compare
bash scripts/export.sh dev --objects local-tables:CUSTOMERS,local-tables:SALES_ORDERS,views:V_SALES_BY_REGION,views:V_REGION_LEADERBOARD
diff -ru /tmp/definitions-sample definitions | less   # real CSN vs the guesses: learn from the differences
python3 scripts/py/validate.py                     # must pass; if a rule is too strict for real CSN, adjust policy.json
python3 scripts/py/order.py --plan                 # tables first, then views, then view-on-view
```

Deploy Git to TEST, then prove idempotency and drift detection:

```bash
bash scripts/deploy.sh test --dry-run
bash scripts/deploy.sh test          # 4 created   -> look at TEST_SALES in the Data Builder
bash scripts/deploy.sh test          # 4 updated   -> safe to re-run
bash scripts/drift-check.sh test     # "no drift: test matches Git"
cat reports/deploy-test.tsv          # audit trail: timestamp, version, env, space, object, action
```

Notes worth saying in the interview:
- Only **definitions** move. TEST/PROD tables are created empty; data comes from flows/loads per
  environment, never from Git.
- The CLI **deploys on create/update** by default (`--no-deploy` to only save) and **refuses to
  create an object whose sources are missing** - hence the dependency order.
- If `drift-check` reports a difference right after a deploy, the tenant adds or reorders fields on
  save. Add that key to `strip_keys` in `config/normalize.json`, re-export, commit.

Now test the **CI login** from the laptop (exactly what the pipeline will do):

```bash
unset DS_SKIP_LOGIN
bash scripts/preflight.sh dev        # logs in as CICD_BOT with client credentials
```

If this fails while the interactive path works, the technical user's scoped role is the cause.

---

## Phase 6 - GitLab (30 min)

```bash
git init -b main && git add -A && git commit -m "Datasphere GitOps pipeline"
# GitLab: New project > Create blank project (no README) > copy its URL
git remote add origin git@gitlab.com:<you>/datasphere-cicd.git
git push -u origin main
```

First pipeline runs in **mock mode** and is green. (New gitlab.com accounts may need identity
verification before shared runners pick up jobs.)

**Settings > CI/CD > Variables** - then switch to real mode:

| Key | Value | Masked | Notes |
|---|---|---|---|
| `DS_MODE` | `real` | no | delete it to go back to mock |
| `DS_HOST` | tenant URL | no | |
| `DS_AUTH_URL` | Authorization URL | no | required even for client credentials |
| `DS_TOKEN_URL` | Token URL | no | |
| `DS_CLIENT_ID` | CICD_BOT client ID | no | contains `!` and `|` - masking may refuse it; it is not the secret |
| `DS_CLIENT_SECRET` | CICD_BOT secret | **yes** | **untick "Expand variable reference"** - secrets often contain `$` |
| `GL_PUSH_TOKEN` | token with `write_repository` | yes | only for the export-to-MR schedule |

Protect production:
- **Settings > Repository > Protected tags**: `v*`, allowed to create: Maintainers.
- Mark `DS_CLIENT_SECRET` **Protected** once tags are protected (then only `main` and tags see it).
- *Protected environments* with approvers is a Premium feature; on Free, protected tags + the
  manual `deploy-prod` job are your gate.

Run it:
1. **Build > Pipelines > Run pipeline > Run** on `main`, then trigger the manual **preflight** job.
   It must log in and list the spaces.
2. Push any commit to `main` -> `validate` -> `plan` -> `deploy-test` (real).
3. `git tag v0.1.0 && git push origin v0.1.0` -> pipeline waits at **deploy-prod** -> click Run ->
   check `PROD_SALES` in the UI.
4. **Build > Pipeline schedules**: `SCHEDULE_JOB=export-dev` (nightly) and `SCHEDULE_JOB=drift-check`.

---

## Phase 7 - rehearse (15 min)

The story the role describes, live:

1. In the **DEV UI**, add a column to `V_SALES_BY_REGION` (e.g. `AVG(S."NET_AMOUNT") AS "AVG_ORDER"`), deploy.
2. **Automated extraction:** run the `export-dev` schedule (*Run* button) - or locally
   `bash scripts/export.sh dev && git diff`. The change appears as a JSON diff / merge request.
3. **Version control:** MR -> `validate` gate -> review -> merge.
4. **CI/CD deployment:** merge deploys TEST automatically; tag `v0.2.0` + approval deploys PROD.
5. **Control:** change something by hand in PROD -> run drift-check -> it fails and shows the diff ->
   redeploy from Git -> clean.

Then read `docs/04-interview-cheatsheet.md` once.

---

## Troubleshooting (messages seen with CLI 2026.21.0)

| Message | Cause / fix |
|---|---|
| `error: unknown command 'objects'` | CLI has no command list for this tenant yet: `datasphere config cache init --host "$DS_HOST"` (the scripts do this after login) |
| `The auto-generated OAuth URLs are not reachable ... --authorization-url` | `DS_AUTH_URL` / `DS_TOKEN_URL` missing or wrong - copy them from App Integration |
| `WARNING: the current node version ... does not satisfy ...` | Node outside 20-24 (Phase 1). Harmless for reads because the scripts use `--output`, but fix it |
| Login hangs / browser shows redirect error | Redirect URI must be exactly `http://localhost:8080` and the port free (or set `CLI_HTTP_PORT` and change the URI) |
| Preflight `FAIL test -> TEST_SALES` with the technical user only | `CICD_BOT` is not assigned to that space in the scoped role |
| `HTTP 429 Too Many Requests` | API limit ~300 requests/user/minute; the scripts retry with back-off |
| Create of a view fails: source not found | Deploy order problem, or the source lives in another space (list it in `policy.json` `external_sources`) |
| Deep trace for SAP support | `--verbose` on any command |

## Fallback - no App Integration in the trial

Without an OAuth client, the CLI still works with a **one-time passcode per command**:

```bash
datasphere config passcode-url --host "$DS_HOST"     # open it, sign in, copy the passcode
datasphere objects views read --space DEV_SALES --technical-name V_SALES_BY_REGION \
  --host "$DS_HOST" --passcode <code> --output V_SALES_BY_REGION.json
```

That lets you show real extraction and a real create in another space by hand, but not an
unattended pipeline. Run the pipeline in mock mode, and say exactly that in the interview: *"the
trial gave me no OAuth client, so I proved the CLI calls by hand with passcodes and the
orchestration against a simulator; with a technical user the same pipeline runs unattended."*
