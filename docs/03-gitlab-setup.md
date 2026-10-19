# 3. GitLab: repo, variables, approvals, schedules

> **Note (2026-10-20):** written before the project ran on a real tenant. Current, verified flow:
> [00-RUNBOOK.md](00-RUNBOOK.md) and [06-how-it-works.md](06-how-it-works.md). CI login = OAuth *Technical User*
> (`DS_CLIENT_ID`/`DS_CLIENT_SECRET`/`DS_AUTH_URL`/`DS_TOKEN_URL`), not a refresh token.


## 1. Create the project and push

```bash
cd datasphere-cicd
git init -b main                      # skip if already a repo
git add .
git commit -m "Datasphere GitOps pipeline"
# GitLab -> New project -> Create blank project (no README), then:
git remote add origin git@gitlab.com:<your-user>/datasphere-cicd.git
git push -u origin main
```

The first pipeline runs in **mock mode** and should be green: `validate` -> `plan` -> `deploy-test`. Look at *Pipelines*, the JUnit tab on `validate`, and `reports/plan.txt` / `reports/deploy-test.tsv` in the job artifacts.

Note: GitLab.com may ask you to verify your account before shared runners will run jobs on a new free account. If that blocks you, register a runner on your own machine (Settings -> CI/CD -> Runners) - the jobs only need Docker and an `image` with bash/git/python3.

## 2. See the guard rails working (mock mode, 10 minutes)

1. **Bad change is blocked.** Branch, rename `definitions/views/V_SALES_BY_REGION.json` to `SALES_BY_REGION.json`, open an MR -> `validate` fails (prefix policy + name mismatch). Fix or close.
2. **Dependency problem is caught.** Edit a view so it selects `FROM MISSING_TABLE` (structured ref) -> `validate` fails: reference not in repo.
3. **Release flow.** After merging to `main`, `deploy-test` runs automatically. Then:
   ```bash
   git tag v0.1.0 && git push origin v0.1.0
   ```
   The tag pipeline pauses at `deploy-prod` - click **Run** to approve.

## 3. Protect production

- **Protected tags:** Settings -> Repository -> Protected tags -> `v*`, *Allowed to create:* Maintainers. Only they can start a prod-capable pipeline.
- **Protected variables:** mark production credentials *Protected* so they are only exposed to pipelines on protected branches/tags.
- **Protected environments** (Settings -> CI/CD -> Protected environments) add "who may deploy" and approval rules to `prod`. As far as I know this is a Premium-tier feature - check your plan; on Free, protected tags + protected variables give you the equivalent gate.

## 4. Switch to the real CLI

Settings -> CI/CD -> Variables. For a one-tenant demo, use scope `*`; for anything real, use separate OAuth clients and set the **Environment scope** to `dev`, `test`, `prod` so each job only sees its own credentials.

| Variable | Value | Masked | Protected | Env scope |
|---|---|---|---|---|
| `DS_MODE` | `real` | no | no | `*` |
| `DS_HOST` | `https://<tenant>.<region>.hcs.cloud.sap` | no | no | `*` (or per env) |
| `DS_CLIENT_ID` | from App Integration | yes | prod: yes | per env |
| `DS_CLIENT_SECRET` | from App Integration | yes* | prod: yes | per env |
| `DS_AUTH_URL` | Authorization URL | no | no | per env |
| `DS_TOKEN_URL` | Token URL | no | no | per env |
| `DS_REFRESH_TOKEN` | from `datasphere secrets show` (docs/02 step 6) | yes* | prod: yes | per env |
| `DS_SECRETS_FILE` | *alternative*: type **File**, content = the whole secrets.json | n/a | prod: yes | per env |
| `DS_CLI_VERSION` | e.g. `2025.16.0` once it works | no | no | `*` |
| `GL_PUSH_TOKEN` | project access token (role Developer, scope `write_repository`) for the export-to-MR job | yes | yes | `*` |

\* GitLab only masks values that are a single line, at least 8 characters, using a limited character set (roughly Base64 characters plus `@ : . ~`). If masking is rejected for your secret, use the **File**-type variable instead.

Then run the pipeline again: `deploy-test` now creates objects in `TEST_SALES`. Check them in the Datasphere UI (Data Builder). Tag `v0.1.1`, approve `deploy-prod`, check `PROD_SALES`.

Run the same scripts from your laptop to debug (after exporting the variables):

```bash
export DS_MODE=real DS_HOST=https://<tenant>.<region>.hcs.cloud.sap DS_SECRETS_FILE=$PWD/secrets.json   # secrets.json is git-ignored
bash scripts/deploy.sh dev --dry-run
bash scripts/deploy.sh dev
bash scripts/drift-check.sh dev
```

## 5. Schedules (automatic extraction and drift detection)

CI/CD -> Schedules -> **New schedule**, target branch `main`, and add a variable on each:

| Description | Interval | Variable |
|---|---|---|
| Nightly export of DEV | `0 2 * * *` | `SCHEDULE_JOB = export-dev` |
| Drift check TEST+PROD | `0 */6 * * *` | `SCHEDULE_JOB = drift-check` |

`export-dev` runs `export.sh dev --discover`, commits any difference to `export/dev-<timestamp>` and opens a merge request with push options, so every change made by modelers in the UI becomes a reviewable diff. `drift-check` fails the pipeline (and notifies per your GitLab notification settings) if TEST or PROD no longer match Git.

## 6. Rollback

Roll **forward**: `git revert <bad commit>`, merge, tag `v0.1.2`, approve prod. You can also re-run `deploy-prod` from an older tag's pipeline. Note that deploys never delete: an object added in a bad release stays until someone removes it deliberately (`datasphere objects <type> delete ...`). That is a design decision, not an omission - say so if asked.

## 7. Enterprise realities to mention

- Runners need network access to the tenant. If the tenant restricts source IPs, use a self-hosted runner on an allow-listed address.
- Credentials should come from a secret store (you can bridge from a vault into GitLab variables or fetch at job start) rather than live in GitLab variables forever.
- Use separate technical users/OAuth clients per environment so a leaked TEST credential cannot touch PROD.
