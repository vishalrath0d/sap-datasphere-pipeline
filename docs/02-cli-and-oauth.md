# 2. SAP Datasphere CLI and OAuth - commands you can run

> **Note (2026-10-20):** written before the project ran on a real tenant. Current, verified flow:
> [00-RUNBOOK.md](00-RUNBOOK.md) and [06-how-it-works.md](06-how-it-works.md). CI login = OAuth *Technical User*
> (`DS_CLIENT_ID`/`DS_CLIENT_SECRET`/`DS_AUTH_URL`/`DS_TOKEN_URL`), not a refresh token.


Everything below is from SAP's published CLI README/help unless marked **(verify)**. Run `-h` at every level of the command tree - the CLI builds its command list from your tenant, so `-h` is the source of truth.

## 1. Install

```bash
node --version                      # Node.js is required; see the npm page for supported versions
npm install -g @sap/datasphere-cli  # or @<version> to pin
datasphere --version                # the version follows the Datasphere release train
```

If a command warns `Your local CLI installation is outdated`, run `npm install -g @sap/datasphere-cli@latest`. If it warns `Your local CLI cache is outdated`, run `datasphere config cache init` again.

## 2. Create an OAuth client in the tenant

In Datasphere: **System -> Administration -> App Integration -> OAuth Clients -> Add a New OAuth Client** (needs an administrator role).

- **Purpose:** *Interactive Usage*
- **Redirect URI:** `http://localhost:8080` (the CLI starts a local listener on port 8080 during login; change the port with the `CLI_HTTP_PORT` environment variable and make the redirect URI match)
- Save, then copy **Client ID** and **Secret** (the secret is shown once).
- On the same App Integration page copy the **Authorization URL** and **Token URL**.

## 3. Point the CLI at the tenant and log in

```bash
datasphere config host set "https://<tenant>.<region>.hcs.cloud.sap"   # (verify) see `datasphere config -h`
datasphere login
# prompts: client ID, client secret, authorization URL, token URL
# -> a browser opens; approve; the CLI stores the tokens locally
```

Per the README, after one interactive login you can run many commands for the next **720 hours** without logging in again. `datasphere logout` removes the stored data.

## 4. Smoke tests and command discovery

```bash
datasphere -h
datasphere objects -h
datasphere objects local-tables -h
datasphere objects local-tables create -h        # shows the exact options your CLI version supports
datasphere spaces -h

datasphere objects local-tables list --space DEV_SALES
datasphere objects views list --space DEV_SALES   # (verify) type name for views
LOG_LEVEL=6 datasphere objects local-tables list --space DEV_SALES   # trace logging when something fails
```

If `datasphere objects` says *unknown command*, the CLI has not been initialised for your tenant yet (host not set / cache not initialised) - one write-up observed that the `objects` commands only appear after the tenant is configured.

## 5. Automated extraction - read objects as definitions

The pattern from SAP's CRUD blog (shown for local tables; other object types follow the same shape):

```bash
datasphere objects local-tables read   --space DEV_SALES --technical-name CUSTOMERS > raw.json
datasphere objects local-tables create --space TEST_SALES --technical-name CUSTOMERS --file-path raw.json
datasphere objects local-tables update --space TEST_SALES --technical-name CUSTOMERS --file-path raw.json
datasphere objects local-tables delete --space TEST_SALES --technical-name CUSTOMERS
```

That "read it from one space, create it in another" move is the whole idea of this project. Our scripts add normalisation, ordering, idempotency, validation and CI around it:

```bash
export DS_MODE=real
bash scripts/export.sh dev --objects local-tables:CUSTOMERS,local-tables:SALES_ORDERS,views:V_SALES_BY_REGION
python3 scripts/py/validate.py
bash scripts/deploy.sh test --dry-run     # prints what would happen, no tenant calls
bash scripts/deploy.sh test
```

In real mode the scripts log in from the same variables the pipeline uses (step 6). For a quick local run after an interactive `datasphere login`, set `DS_SKIP_LOGIN=1` and the scripts will reuse your existing CLI session instead.

## 6. Non-interactive login for CI (the hard part)

The CLI documents a **secrets file** for this. After an interactive login, print what it stored:

```bash
datasphere secrets show     # DO NOT paste this output anywhere shared - it contains secrets
```

A secrets.json must contain at least `access_token`, **or** `refresh_token` + `client_id` + `client_secret`; plus `tenantUrl`, **or** `authorization_url` + `token_url`:

```json
{
  "tenantUrl": "https://<tenant>.<region>.hcs.cloud.sap",
  "client_id": "...",
  "client_secret": "...",
  "authorization_url": "https://<tenant>.authentication.<region>.hana.ondemand.com/oauth/authorize",
  "token_url": "https://<tenant>.authentication.<region>.hana.ondemand.com/oauth/token",
  "refresh_token": "..."
}
```

Then `datasphere config cache init --host <tenantUrl> --secrets-file secrets.json`. This is exactly what `ds_login` in `scripts/lib.sh` does from CI/CD variables (`DS_CLIENT_ID`, `DS_CLIENT_SECRET`, `DS_AUTH_URL`, `DS_TOKEN_URL`, `DS_REFRESH_TOKEN`, `DS_HOST`) or from a GitLab *File* variable named `DS_SECRETS_FILE`.

**Limitation you should understand and be able to explain:** a refresh token created by an interactive login expires (the README's 720 h; the OAuth client's refresh-token lifetime also matters), so a pipeline seeded this way needs the token re-seeded periodically. Options for a real project:

1. Use an OAuth client/flow intended for unattended use. The README lists `datasphere login --authorization-flow client_credentials|authorization_code`, so check `datasphere login -h` and your tenant's App Integration page for a technical-user/client-credentials client, and use that in CI. **(verify on your tenant)**
2. Keep the refresh token in a secret store (e.g. a vault, or GitLab variable updated via API) and have a small job rotate it before expiry.
3. Accept a manual monthly re-seed for a demo.

## 7. Optional exercise: spaces as code

```bash
datasphere spaces read --space DEV_SALES > space-DEV_SALES.json       # (verify flags with `datasphere spaces read -h`)
datasphere spaces create --file-path space-TEST_SALES.json             # creates or updates a space from a definition file
```

The README describes `spaces create` as "creates or updates space details based on an import file". Extending the repo with a `spaces/` folder is a natural next step.

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Login hangs or browser shows a redirect error | Redirect URI must be exactly `http://localhost:8080` (or your `CLI_HTTP_PORT`); port must be free |
| `unknown command 'objects'` | Tenant host not configured / cache not initialised |
| `Your local CLI cache is outdated` | `datasphere config cache init` again |
| `Your local CLI installation is outdated` | `npm install -g @sap/datasphere-cli@latest` |
| `list` returns something `parse_list.py` can't read | Run the list command by hand; adapt `scripts/py/parse_list.py` (the only place that guesses) |
| Need SAP support | Incident component `DS-API-CLI`, attach a `LOG_LEVEL=6` trace (per the README) |
