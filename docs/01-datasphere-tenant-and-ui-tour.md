# 1. Getting a Datasphere tenant, and what to click once you have one

## 0. Which tenant can you actually get? (2-minute check first)

You said you have a BTP trial account. Check whether it can host Datasphere before planning around it:

> BTP cockpit -> your trial subaccount -> **Entitlements** -> **Configure Entitlements** -> **Add Service Plans** -> search `Datasphere`

| Option | How | Cost / limits | Can you run this repo in `real` mode? |
|---|---|---|---|
| **A. Trial subaccount** | Only if "SAP Datasphere" shows up in the check above | Free; 90-day trial account, which can be deleted if you don't log in for 30 days | Yes, if listed. I could not confirm it is offered, and a community thread reports it can't be added in a trial account. |
| **B. Datasphere free plan in a free-tier (Pay-As-You-Go) BTP account** | Sign up for a free-tier account (needs a payment card for identity/billing), add the *free* plan entitlement for SAP Datasphere, create the instance | Free plan is time-limited (Discovery Center says 90 days, then deleted), community support only, limited regions, restrictions in SAP Note 3227267. Paid plans bill - pick **Free** deliberately. | **Yes** - you are the tenant admin, so you can create OAuth clients and use the CLI. |
| **C. 30-day Basic Trial** | sap.com Datasphere trial page, shared tenant with sample data | Free | **UI tour only.** SAP states admin rights for customization/integration are not offered, so expect no OAuth client and therefore no CLI. Good for seeing the product today. |
| **D. A sandbox from the client/EY project team** | Ask for a DEV space + a technical OAuth client | - | Best of all: point this repo at it. Ask before the interview if you can get one. |

**My suggestion:** do **C today** for 30 minutes (so you can describe the product from having used it), run `scripts/demo-local.sh` for the pipeline, and do **B** only if you are comfortable entering a card for a free-tier account. Whatever you choose, be straightforward in the interview about which parts you ran against a real tenant (see docs/04).

Links: [docs/05-references.md](05-references.md) (trial pages, free-tier tutorial, Discovery Center).

## 1. Create the instance (options A and B)

1. BTP cockpit -> global account -> **Create subaccount** in a region where Datasphere's free plan is offered (check [SAP Discovery Center - SAP Datasphere](https://discovery-center.cloud.sap/serviceCatalog/sap-datasphere) -> Service Plans; not every region has it).
2. Subaccount -> **Entitlements** -> add **SAP Datasphere**, plan **free**.
3. Enable the **Cloud Foundry** environment in the subaccount (free/trial plan) and create a space, e.g. `dev`. SAP's creation procedure asks you to pick the space the instance lives in.
4. **Service Marketplace** -> SAP Datasphere -> **Create** -> plan **Free** -> fill in the first administrator (name, e-mail) -> Create.
5. Wait for the confirmation e-mail with the tenant link, open it and sign in. Your tenant URL looks like `https://<tenant>.<region>.hcs.cloud.sap` - that is your `DS_HOST`.

Step-by-step with screenshots: SAP Community blog "SAP Datasphere: Getting Started with SAP Datasphere for Free" and the developers.sap.com free-tier tutorial (links in docs/05). Labels shift between releases; the concepts don't.

## 2. Guided tour - what to look at (about 45 minutes)

Concepts first, because the interview vocabulary comes from here:

- **Tenant -> Spaces.** A *space* is an isolated workspace with its own storage, members and objects. Our pipeline treats spaces as environments: `DEV_SALES`, `TEST_SALES`, `PROD_SALES`.
- **Objects** (local tables, views, flows, analytic models, task chains) have a **technical name** (unique per space) and a business name.
- Every modeling object is stored as a text definition called **CSN** (CDS schema notation, JSON). That JSON is what the CLI reads and writes - and what we version in Git.
- Objects have a **design-time** definition (saved) and a **deployed** runtime. Nothing is usable until it is *deployed*. The CLI deploys on create/update.

Click-path:

1. **Space Management** -> **Create** -> name `DEV_SALES` -> give it a small amount of storage -> add yourself as a member -> **Deploy**. Repeat for `TEST_SALES` and `PROD_SALES`.
2. Open `DEV_SALES` -> **Data Builder** -> **Import CSV File** (or **New Table**) -> load `sample-data/customers.csv`, then `sample-data/sales_orders.csv`. Name the tables `CUSTOMERS` and `SALES_ORDERS` so they match `definitions/`. **Deploy** each.
3. Data Builder -> **New SQL View** -> paste, set technical name `V_SALES_BY_REGION`, **Deploy**, then open **Data Preview**:

   ```sql
   SELECT C."REGION" AS "REGION",
          SUM(S."NET_AMOUNT")   AS "TOTAL_NET_AMOUNT",
          COUNT(S."ORDER_ID")   AS "ORDER_COUNT"
   FROM "SALES_ORDERS" AS S
   INNER JOIN "CUSTOMERS" AS C ON S."CUSTOMER_ID" = C."CUSTOMER_ID"
   GROUP BY C."REGION"
   ```

4. New SQL View `V_REGION_LEADERBOARD` on top of it: `SELECT "REGION","TOTAL_NET_AMOUNT" FROM "V_SALES_BY_REGION" WHERE "TOTAL_NET_AMOUNT" > 0`. Deploy.
5. Look at the **Data Builder file list** (your objects), the **dependency/impact view** of an object, and **System -> Monitor / Data Integration Monitor** to see what a deployment and a data load look like.
6. **System -> Administration -> App Integration** - this is where OAuth clients are created (docs/02). If you can't see it, your role/tenant type can't drive the CLI.

## 3. The most valuable step: capture real definitions

After step 2 you have real objects. Once the CLI works (docs/02), export them and **replace the illustrative files in `definitions/`**:

```bash
DS_MODE=real bash scripts/export.sh dev --objects local-tables:CUSTOMERS,local-tables:SALES_ORDERS,views:V_SALES_BY_REGION,views:V_REGION_LEADERBOARD
git diff --stat
```

Open the exported files and compare with my samples. That comparison is the fastest way to learn real CSN - and if your tenant returns a different shape (for example a different type folder name for views), adjust `dslib.py`/`validate.py` accordingly. That is exactly the kind of detail worth mentioning in the interview.
