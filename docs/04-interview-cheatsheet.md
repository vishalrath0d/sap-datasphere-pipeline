# 4. Interview cheat-sheet - map the job profile to what you built

## The three bullets, in your words

**Automated extraction** - "Artifacts in a Datasphere space are stored as CSN definitions, which are JSON. The CLI can read them (`datasphere objects <type> read --space ... --technical-name ...`). I wrapped that in `export.sh`: it reads each tracked object, strips CLI noise, preserves key order (in CSN, `elements` order is column order, so I don't sort), and writes one file per object. A nightly schedule exports DEV and opens a merge request if modelers changed something in the UI."

**Version control** - "One GitLab repo: `definitions/<type>/<NAME>.json`, the scripts, the pipeline. A merge-request gate runs `validate`: JSON/CSN shape, naming policy, no secrets, every referenced table or view exists in the repo, no dependency cycles. Prod only ever gets a tagged version, so every deployed state maps to a commit and an audit TSV."

**CI/CD deployment** - "Merge to main deploys to TEST automatically. A `vX.Y.Z` tag adds a manual `deploy-prod` job behind protected tags and protected variables. `deploy.sh` computes a dependency order - tables, then views, then views on views - and for each object does update-if-exists-else-create via the CLI. It's idempotent, retries transient failures, stops at the first failure, and never deletes."

## 30-second pitch

"Datasphere objects are CSN text, so they can be treated like code. I built a GitLab pipeline that extracts definitions with the Datasphere CLI, versions them, gates changes with validation in merge requests, and promotes tagged versions DEV -> TEST -> PROD with a manual approval, plus scheduled drift detection. It's the same GitOps pattern I've used with GitLab CI, environment-scoped secrets and approvals - applied to Datasphere."

## Likely questions - answer shapes

| Question | Answer in one breath |
|---|---|
| Walk me through the pipeline | validate -> plan -> deploy-test (auto) -> deploy-prod (manual, tag only). Export + drift on schedules. |
| How do you authenticate the CLI in CI? | OAuth client in the tenant; secrets.json (`client_id`, `client_secret`, URLs, `refresh_token`) built at job start from masked, environment-scoped variables or a File variable; `config cache init --secrets-file`; file deleted after the job. Caveat: an interactively-obtained refresh token expires, so for real use I'd prefer a technical-user/client-credentials client and a secret store. |
| Where do secrets live? | Never in the repo (validator scans for them, `.gitignore` covers secrets.json). GitLab protected + environment-scoped variables, ideally sourced from a vault. Separate client per environment. |
| How do you handle dependencies? | Parse CSN: structured `from` refs plus SQL text; topological sort; tables before views before views-on-views. Cycle = pipeline fails in validate. |
| What if a deploy fails halfway? | Fail fast, audit TSV shows what went through, fix forward and re-run - deploys are idempotent. Prod is blocked behind test, so test usually catches it first. |
| Rollback? | Roll forward with a revert + new tag, or re-run an older tag's deploy. Deploys never delete, so removals are explicit. |
| How do you detect manual changes in PROD? | Scheduled drift-check: export from the environment, normalise, diff against Git; fail on any difference. |
| Why Git + CLI and not SAP's own transport tooling? | Git gives review, diff, blame, tags, approvals and one audit trail across tools; the CLI is the automation surface. Native content transport has its place, but this gives pipeline control. (Be ready to discuss trade-offs; don't trash the native option.) |
| Multiple tenants? | Same scripts; `DS_HOST` and credentials scoped per GitLab environment; space names in `config/environments.json`. |
| CLI version changes? | Pinned with `DS_CLI_VERSION`; the CLI follows Datasphere's release train and warns when outdated, so bump deliberately and re-run validation in a non-prod tenant first. |
| What can't the CLI do? | Be honest: coverage varies by object type and version; one write-up reports objects are imported one at a time (so ordering matters) and that imports can land as design-time definitions that need activation. Check `datasphere objects <type> -h` for what your version supports. |

## Honesty lines (use them - they make you more credible)

- "I built and rehearsed the pipeline against a simulator of the CLI to prove the orchestration, ordering, idempotency and drift logic, and I based the commands on SAP's published CLI documentation. I haven't run it at production scale against your tenant."
- If you did get a real tenant: "I validated the export/deploy against a free-tier tenant; here are the differences I found between my assumptions and the real CSN."
- Never claim hands-on Datasphere production experience you don't have; do claim - truthfully - the GitLab CI, environment promotion, secrets handling and approval-gate experience that transfers directly.

## Questions to ask them

1. How many tenants and spaces are in scope, and what does promotion look like today?
2. Which object types need to be deployed: tables, views, flows, task chains, analytic models, access controls?
3. How are credentials issued for automation - technical users, OAuth clients, a vault?
4. Are runners self-hosted, and does the tenant restrict source IPs?
5. Who approves production deployments, and what evidence do they need (diffs, test results, audit trail)?
6. Is there existing content (transport, manual exports) that needs onboarding into the repo first?

## Vocabulary to use correctly

Space, tenant, technical name vs business name, CSN, design-time vs deployed, local table vs remote table, SQL view vs graphical view, analytic model, task chain, OAuth client (interactive vs technical), refresh token, idempotent deploy, drift, protected environment / protected tag.
