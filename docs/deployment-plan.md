# Deployment Plan

Work top to bottom; each gate must pass before the next step. **Any step that creates or exposes
resources requires explicit human approval.**

Target: the subscription, resource group and region in `deployment/environment.json`
(copy it from `deployment/environment.example.json`). The reference deployment used
`swedencentral`.

## 1. Inputs that must exist first

| Input | Needed by | Status |
|---|---|---|
| Databricks workspace ARM resource ID | `databricks-private-link.bicep` | **Done** — `dbw-food-analytics-swc` |
| Genie space ID | `foundry-connections.bicep`, `environment.json` | **Done** — created by `create-genie-space.ps1` |
| Databricks credential | — | **Not required** — managed identity throughout |
| In-VNet client | toolbox, agent deploy, demo | **Done** — `vm-jumpbox` |
| Databricks NSG resource ID | `food-analytics.bicepparam` via `DATABRICKS_NSG_ID` | Set before any template redeploy |

### Why there is no Databricks secret

Databricks OAuth M2M secrets can only be minted by an **account admin**, which requires Entra
Global Administrator. The signed-in user is Global Reader, so that route is closed. On-behalf-of
tokens for service principals are also disabled on this workspace.

Instead the Foundry account's system-assigned managed identity is registered in the Databricks
workspace as a service principal, and Foundry requests Entra tokens for the Databricks first-party
resource `2ff814a6-3304-4ab8-85cb-cd0e6f879c1d`. Nothing is stored or rotated.

Trade-off worth stating: a Databricks OAuth token can be scope-limited to `genie`, whereas an Entra
token is not scope-limited. Least privilege therefore rests entirely on Databricks object
permissions — grant the identity only CAN RUN on the Genie space, CAN USE on the warehouse, and
SELECT on `food_analytics.gold`. Do not make it a workspace admin.

### Which identity actually calls Databricks

Two Foundry identities appear as the caller depending on which stage of the request is running:
the **account** system-assigned identity and the **project** system-assigned identity. Granting
only one produces intermittent failures that look like caching. Grant both.

Databricks then enforces three independent authorities, and all three are required:

| Authority | Needed for | Symptom when missing |
|---|---|---|
| Workspace entitlements | Any API access | HTTP 403 |
| Object ACLs (Genie space, warehouse) | Starting a conversation | PERMISSION_DENIED on the space |
| Unity Catalog grants | Running the generated SQL | "the warehouse query is failing" |

The third failure is the dangerous one: the agent does not surface it as an error. It reports that
the query failed and then offers plausible SQL against **table names that do not exist**. Treat any
answer containing invented schema as a permissions failure, not a model error.

Use `deployment/grant-databricks-identity.ps1`, which applies all three and reads the Unity Catalog
grants back to confirm they landed.

Note that Unity Catalog only shows a caller its *own* grants unless the caller holds `MANAGE`, so a
grant dump taken from an unprivileged identity looks alarmingly empty.

## 2. Preflight gates

- `az account show` confirms the intended subscription.
- `azd auth login --tenant-id <tenant>` — azd defaults to a different tenant than `az` and fails
  confusingly later if they diverge.
- Deploying identity holds **Owner**, or **Contributor + User Access Administrator** — the
  templates create role assignments, which Contributor alone cannot do.
- Deploying identity also holds **Foundry Project Manager** on the Foundry account. Subscription
  Owner does not include Foundry data actions.
- Providers registered: `Microsoft.CognitiveServices`, `Microsoft.DocumentDB`, `Microsoft.Search`,
  `Microsoft.Network`, `Microsoft.App`, `Microsoft.ContainerRegistry`, `Microsoft.KeyVault`,
  `Microsoft.Databricks`, `Microsoft.Compute`.
- `az bicep build` is clean for `deployment/food-analytics.bicepparam`,
  `deployment/databricks-private-link.bicep`, `deployment/foundry-connections.bicep` and
  `deployment/jumpbox.bicep`.
  Two warnings from the vendored template (BCP037 on `capabilityHostKind`, BCP321 on the ACR DNS
  link) are upstream and expected.
- `python -m pytest agent/tests -q` passes.
- `az deployment group what-if` reviewed for every template, by a human.

## 3. Deployment order

Order matters — later steps consume outputs and DNS from earlier ones.

1. **Foundry + network** — `deployment/template-19/main.bicep` with `food-analytics.bicepparam`.
   **Done.** 57 resources, all 7 private endpoints Approved, `gpt-5.1` deployed.
2. **Databricks workspace + Unity Catalog** — `databricks-workspace.bicep` and
   `databricks-uc-storage.bicep`, then `seed-databricks-gold.ps1` and `create-genie-space.ps1`.
   **Done.** Verified: Genie answers questions over `food_analytics.gold` through a Pro warehouse
   reading private storage.
3. **Jumpbox** — `deployment/jumpbox.bicep`. **Done.** Required because toolboxes, agent
   deployment, agent invocation and the portal playground are all Foundry *data-plane* operations,
   and the account has `publicNetworkAccess: Disabled`. RDP is restricted to a single IP; update
   `allowedSourceIp` when your address changes. Deallocate the VM when idle.
4. **Genie connection** — `deployment/foundry-connections.bicep`. **Done.** Connections are ARM
   resources, so this deploys from anywhere without VNet access.
5. **Grant the Foundry account identity in Databricks** —
   `deployment/grant-databricks-identity.ps1`. **Done.**
6. **Toolbox and agent** — `deployment/run-on-jumpbox.ps1`. **Done.** Ships the agent source to the
   jumpbox and runs `azd ai toolbox create` and `azd deploy` from inside the VNet.
7. **Lock down Databricks** — redeploy `databricks-workspace.bicep` with
   `publicNetworkAccess=Disabled` and `requiredNsgRules=NoAzureDatabricksRules`, then deploy
   `databricks-private-link.bicep`. **Done.** Verified: the workstation gets HTTP 403, the jumpbox
   resolves the workspace to a private `10.19.1.x` address, and the agent answers correctly from
   inside the VNet.

### Operating the workspace once it is private

Everything below must run from the jumpbox. The workstation can still use ARM, but not the
Databricks API. Send each script with `deployment/Invoke-OnJumpbox.ps1`, which fills its
parameters from `deployment/environment.json`:

```powershell
./deployment/Invoke-OnJumpbox.ps1 ./deployment/jumpbox-demo-test.ps1
./deployment/Invoke-OnJumpbox.ps1 ./deployment/jumpbox-warehouse.ps1 -Parameters @{ Action = 'stop' }
```

- `jumpbox-warehouse.ps1` starts and stops the SQL warehouse.
- `jumpbox-demo-test.ps1` warms the warehouse and rehearses the demo questions.
- `jumpbox-verify-kpi-parity.ps1` compares the agent's headline answers with `sales_kpi`.
- `jumpbox-dump-grants.ps1` shows the current grants.
- `jumpbox-grant-unity-catalog.ps1` reapplies Unity Catalog grants.
- `jumpbox-verify-private-path.ps1` confirms private DNS resolution.
- `create-genie-space.ps1` creates or updates the Genie space. It is the only definition of
  the space; re-run it after changing descriptions, instructions or example SQL.

The jumpbox identity is a member of the Databricks `admins` group and holds `MANAGE` on the
catalog. Without both, the workspace becomes unadministrable the moment public access is
disabled — there would be no authorised identity able to reach it.

Anyone presenting the Genie space in the browser needs their **own** Unity Catalog grants:
`USE_CATALOG` on `food_analytics`, `USE_SCHEMA` and `SELECT` on `food_analytics.gold`. Genie
runs queries as the signed-in user, and workspace admin does not imply data access, so
without them the space shows "You are missing access to 3 tables". The Foundry agent is
unaffected because it uses its own identity. Grant each presenter individually rather than
granting the `users` group.

### Sequencing traps

- **Workspace updates fail while any compute is active.** Stop the warehouse first, and expect the
  control plane to lag behind the API's own `STOPPED` status by two to four minutes.
- **Network changes take effect asynchronously, in both directions.** After flipping
  `publicNetworkAccess`, expect two to four minutes before the new behaviour is enforced. Test,
  do not assume.
- **Grant every identity before locking down.** Re-opening access to fix a missed grant requires
  stopping the warehouse and two more workspace updates.

### Making the agent and the dashboard agree

The demo claim is that asking the agent for a number returns the same number the BI
dashboard shows. That only holds if both read one definition, so three views in
`food_analytics.gold` are the single source of truth:

| View | Purpose |
|---|---|
| `sales_analytics` | Daily grain sales, for any filtered or grouped question |
| `waste_analytics` | Daily grain waste, same role for waste questions |
| `sales_kpi` | All-time headline values as rows, one per metric |

`sales_kpi` is what guarantees agreement on the headline cards: both the dashboard and
the agent return a stored value rather than each deriving its own. Its COMMENT tells
Genie not to recalculate, and Genie reads COMMENT metadata as context.

The Genie space is pointed at these three views only. The raw fact and dimension tables
are deliberately excluded, because leaving them available lets Genie bypass the shared
definition.

Pointing Genie at `sales_kpi` was not enough on its own. Asked for the gross margin
percentage, Genie matched `metric_name LIKE '%gross margin%'` and sometimes returned
`Gross Margin` in SEK instead of `Gross Margin Percent`. `create-genie-space.ps1` now adds
entity matching on `metric_name`, text instructions that map each phrasing to one exact
metric name, and example SQL for every headline question. The metric names it lists must
match the `sales_kpi` view; a unit test enforces that.

Two agent behaviours had to be corrected for this to hold:

- It answered numeric questions from earlier conversation context instead of re-querying.
  The instructions now require a tool call for every numeric question, and the test
  scripts pass `--new-session --new-conversation`.
- It answered with a definition of the metric rather than its value.

Verified 2026-09-28: total net revenue, gross margin percentage and total waste cost all
matched `sales_kpi` exactly. Re-check with `jumpbox-verify-kpi-parity.ps1`.

**Still missing:** there is no Power BI report yet. The views are ready for one, but until
a report is built on them the parity claim rests on the view values rather than a rendered
dashboard.

**Ambiguous periods still shift the answer.** "Waste cost by product" without a year
returns all-time; the same question with "in 2025" returns the 2025 figure. Both are
correct. Pin the period in demo questions, or the audience sees two different numbers.

### The Power BI semantic model

`powerbi/FoodAnalytics.pbip` is a PBIP project that **imports** from the Databricks SQL
warehouse, which is the customer's standard rather than DirectQuery. The VertiPaq model
is hosted by Power BI / Fabric capacity; no OneLake or Lakehouse is involved.

The metric definitions live here as **DAX measures**, not in the Databricks views:

| Measure | Definition |
|---|---|
| `Net Revenue` | `SUM(net_revenue)` |
| `Gross Margin` | `SUM(gross_margin)` |
| `Gross Margin %` | `DIVIDE([Gross Margin], [Net Revenue])` |
| `Waste Cost` | `SUM(waste_cost)` |

The views supply additive columns; the model supplies the semantics. `Dashboard KPI`
imports `sales_kpi` purely so a demo can put the Databricks figure beside the Power BI
one.

`Sales Analytics` and `Waste Analytics` have **no relationship** and no shared date
table. A Sales column (the year slicer, a month axis) therefore cannot filter a Waste
measure: the waste card ignores the year slicer, and a waste series on the monthly chart
repeated the all-time total in every month, so it was removed. A unit test blocks visuals
that mix the two tables. A shared date dimension would fix this properly.

To open it: install Power BI Desktop **on the jumpbox** and open the `.pbip` there.
Databricks has no public endpoint, so Desktop on a workstation cannot refresh the model.
Sign in to the Databricks connector as a user with workspace access.

Three consequences worth stating to a customer:

- **Import means the dashboard is a snapshot.** It shows data as of the last refresh.
  An agent querying Databricks live can legitimately disagree between refreshes. That is
  a temporal gap, not a definition mismatch, and no shared SQL closes it.
- **Publishing needs a gateway.** Scheduled refresh from a private Databricks workspace
  requires an on-premises data gateway inside the VNet, or a VNet data gateway, which
  needs Fabric capacity.
- **DAX measures cannot be reproduced by Genie.** Time intelligence, calculation groups
  and model row-level security have no SQL equivalent. For a metric defined in Power BI,
  a Genie-only agent is an approximation, however close it looks.

### Where the agent should connect

The agent currently queries Genie, so it answers from the Databricks views. That is the
right answer when Databricks owns the metric. When Power BI owns the metric, the agent
should read the **semantic model** instead, through XMLA/DAX or the Fabric semantic model
MCP, and use Genie only for exploration beyond the model.

That second path is not built. It needs Fabric capacity or Premium Per User for XMLA,
`Microsoft.Fabric` registration, and tenant-admin consent for Fabric IQ. Note also that
Fabric Private Link is a tenant-wide setting, so it cannot be scoped to this demo.

## 4. Known blockers and accepted risks

- **Databricks is private.** `publicNetworkAccess` is Disabled with
  `requiredNsgRules: NoAzureDatabricksRules`, and front-end plus browser-authentication private
  endpoints are Approved. The workstation gets HTTP 403; administration happens from the jumpbox.
- **The demo cannot run from a workstation.** Every Foundry data-plane operation — playground,
  agent invocation, toolbox changes — must come from the jumpbox or another in-VNet client.
- **Every caller shares one identity.** Genie is queried with a single managed identity, so Unity
  Catalog sees the same principal for every user of the agent. Row- and column-level security is
  therefore **not** enforced per user. Scope the identity to the one Genie space to limit blast
  radius, and do not present this as per-user governance.
- **The classic Pro warehouse cold-starts in minutes.** Genie times out against a stopped warehouse
  and the agent reports that the query failed. `auto_stop_mins` is set to 60; pre-warm it with
  `jumpbox-demo-test.ps1` before a demo. Serverless would start faster but needs an account-level
  Network Connectivity Config to reach the private storage, which requires an account admin.
- **Model capacity is 100 (100K TPM).** At the original capacity of 10, a three-question rehearsal
  exhausted the token rate limit on the third question.
- **Genie visualisation download is unsupported on Private Link workspaces.** After step 7 the
  `download-visualization` endpoint stops working. The agent's text and SQL paths are unaffected.
- **The external location was registered with `skip_validation`.** Databricks' control plane cannot
  reach the private storage account to validate it. The path is proven instead by the warehouse
  successfully reading and writing `food_analytics.gold`.
- **The Genie space formats SEK as `$`.** Column comments say SEK; Genie still renders a dollar
  sign. Cosmetic, but visible in a demo.
- **Key Vault network posture differs from the template source.** `key-vault.bicep` specifies
  `publicNetworkAccess: 'Enabled'`, but the deployed vault reports **Disabled** with
  `defaultAction: Deny`. The cause was not determined — treat the deployed state, not the template,
  as authoritative, and re-check after any redeploy.
- **Owner does not grant data-plane access** on either Key Vault or Foundry. Both use RBAC, so
  subscription Owner permits control-plane operations only.
- **`metadata.json` in the vendored template is stale** — it claims `ai_services_access: public`,
  while `main.bicep` sets `publicNetworkAccess: 'Disabled'`. Trust the Bicep.
- **One failing tool source fails the whole toolbox.** If Databricks is unavailable during
  `tools/list`, every answer breaks. Expect a full-toolbox error, not a partial degrade.

## 5. Retry rule

If a deployment fails **after** the capability host step begins, a `legionservicelink` service
association stays attached to the agent subnet. The simplest recovery is redeploying with a **new
VNet name**. Reusing the same subnet requires purging the account, deleting the capability host, and
waiting for the link to clear.

## 6. Post-deployment verification

Run all of these from the jumpbox before calling the deployment good:

- Foundry account shows `publicNetworkAccess: Disabled`.
- Databricks shows `publicNetworkAccess: Disabled` and returns HTTP 403 from outside the VNet.
- Every private endpoint is **Approved**, not Pending — including both Databricks ones.
- From the jumpbox, the Databricks hostname resolves to a private `10.19.*` address.
- The SQL warehouse is `RUNNING` before the first question.
- `azd ai toolbox show food-analytics-tools --output json` enumerates the Genie tool source.
- `jumpbox-demo-test.ps1` answers all three questions with figures that match a direct Genie query.
  Verified 2026-09-28 under full lockdown: category revenue, waste cost by product and reason, and
  gross margin by region all returned governed data.
  Re-verified 2026-10-04 against direct SQL on the gold views: every figure matched exactly. The
  waste question previously had no year, and two runs returned different single-month figures;
  it now asks for 2025 and was stable across runs.
