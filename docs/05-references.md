# 5. References

Marked **[read]** = I opened or saw its content while building this; **[not opened]** = standard location from memory, search the title if a link has moved.

## SAP Datasphere CLI
- **[read]** npm package page / README (install, login, secrets file, options, env vars): https://www.npmjs.com/package/@sap/datasphere-cli
- **[read]** SAP Help - Accessing SAP Datasphere via the Command Line (document version 2026.18): https://help.sap.com/doc/23bac77aef50453f8dbe772f67d0ce89/cloud/en-US/507babe9acf94d1dacd81376429d4c1d.pdf
- **[read]** Same guide, HTML index: https://help.sap.com/doc/d0ecd6f297ac40249072a44df0549c1a/cloud/en-US/index.html
  - chapters to read: *Installing and Configuring*, *Log into the CLI via an OAuth Client*, *Managing Modeling Objects via the Command Line*, *Managing Spaces*
- **[read]** SAP blog - CRUD operations on objects with the CLI (create/read/update/delete, space-to-space copy): https://blogs.sap.com/t5/technology-blogs-by-sap/use-crud-opreations-with-sap-datasphere-command-line-interface/ba-p/13682690
- **[read]** SAP blog - generating views with Python and the CLI, secrets-file login: https://community.sap.com/t5/technology-blog-posts-by-sap/sap-datasphere-view-generation-with-python-and-the-command-line-interface/ba-p/13558181
- **[read]** SAP blog (2022) - CLI and table/view definitions: https://blogs.sap.com/2022/01/13/sap-dwc-cli-sap-data-warehouse-cloud-data-builder-crud-operations-on-tables-views/
- **[read]** Overview of external access (APIs, CLI, SQL): https://community.sap.com/t5/technology-blog-posts-by-sap/sap-datasphere-external-access-overview-apis-cli-and-sql/ba-p/14078591
- **[read]** Community write-ups on automating the CLI (task chains; deployment): https://www.zpartner.eu/?p=10208 and https://www.zpartner.eu/?p=14804
- Support: SAP Community tag `datasphere-cli`; incident component `DS-API-CLI` (per the npm README)
- REST APIs (alternative to the CLI): https://api.sap.com/package/sapdatasphere/rest **[not opened]**

## Getting a tenant
- **[read]** BTP trial vs free tier explained: https://help.sap.com/docs/btp/sap-business-technology-platform/trial-accounts-and-free-tier
- **[read]** "How to try SAP BTP for free" (SAP product manager overview): https://blogs.sap.com/t5/technology-blogs-by-sap/how-to-try-sap-btp-for-free-a-comprehensive-overview/ba-p/13577391
- **[read]** Datasphere 30-day Basic Trial (shared tenant, no admin rights): https://www.sap.com/products/data-cloud/datasphere/trial.html
- **[read]** Datasphere free-tier mission + sample CSVs (Best Run Bikes): https://developers.sap.com/tutorials/data-warehouse-cloud-1-begin-trial.html
- **[read]** BTP free-tier account tutorial: https://developers.sap.com/tutorials/btp-free-tier-account/
- **[read]** Discovery Center - SAP Datasphere service plans/regions: https://discovery-center.cloud.sap/serviceCatalog/sap-datasphere
- **[read]** Community thread: "can't add Datasphere in a BTP trial account": https://groups.community.sap.com/t5/technology-blogs-by-sap/sap-datasphere-getting-started-with-sap-datasphere-for-free/bc-p/13550517
- SAP Note 3227267 - free tier restrictions **[not opened]**
- SAP Datasphere product documentation portal: https://help.sap.com/docs/SAP_DATASPHERE **[not opened]**

## GitLab (all **[not opened]** - search by title if moved)
- CI/CD YAML reference: https://docs.gitlab.com/ci/yaml/
- CI/CD variables (masked, protected, environment scope, File type): https://docs.gitlab.com/ci/variables/
- Environments and deployments; protected environments: https://docs.gitlab.com/ci/environments/
- Protected tags: https://docs.gitlab.com/user/project/protected_tags/
- Pipeline schedules: https://docs.gitlab.com/ci/pipelines/schedules/
- Push options (`merge_request.create` etc.): https://docs.gitlab.com/user/project/push_options/
- Project access tokens: https://docs.gitlab.com/user/project/settings/project_access_tokens/
- `resource_group` (serialise deployments): https://docs.gitlab.com/ci/resource_groups/

## Related community tooling (optional reading)
- Unofficial Python tools that drive Datasphere's internal APIs for task chains, persistence and statistics (interactive OAuth): https://pypi.org/project/Datasphere-CLI/ and https://pypi.org/project/datasphere-api/
- MCP/assistant wrappers around the CLI (shows the object-type names the CLI uses): https://glama.ai/mcp/servers/stkim3/datasphere_mcp
