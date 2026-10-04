# Manual setup steps

Most of this deployment is scripted. The steps below are not: they were done by hand in
the Azure portal, the Databricks workspace or with one-off commands. This page describes each
one in the order you need it, and shows where it fits in the [README's
step-by-step deployment](../README.md#step-by-step-deployment).

Throughout, `<placeholders>` refer to values in `deployment/environment.json`. Commands are
PowerShell 7 with the Azure CLI signed in to the target tenant.

| # | Manual step | Needed before README step |
|---|---|---|
| A | [Create the Databricks NSG](#a-create-the-databricks-nsg) | 2 |
| B | [Confirm the Unity Catalog metastore](#b-confirm-the-unity-catalog-metastore) | 3 |
| C | [Create the storage credential and external location](#c-create-the-storage-credential-and-external-location) | 3 |
| D | [Create the Pro SQL warehouse](#d-create-the-pro-sql-warehouse) | 3 |
| E | [Create the catalog and schema](#e-create-the-catalog-and-schema) | 4 |
| F | [Look up managed identity client IDs](#f-look-up-managed-identity-client-ids) | 5 and 7 |
| G | [Give the jumpbox its Azure roles and tools](#g-give-the-jumpbox-its-azure-roles-and-tools) | 5 |
| H | [Make the jumpbox a Databricks administrator](#h-make-the-jumpbox-a-databricks-administrator) | 5, **before** lockdown |
| I | [Grant presenters access](#i-grant-presenters-access) | 11 |
| J | [Open and close RDP for a session](#j-open-and-close-rdp-for-a-session) | any time |

Steps C to H call the Databricks API or UI from your workstation, so they **must be
finished while the workspace still has public network access enabled** (README step 3).
After lockdown (step 9), only the jumpbox can reach the workspace.

A helper used by several steps below. It gets an Entra token for Azure Databricks and calls the
workspace REST API:

```powershell
$workspace = '<WorkspaceUrl>'   # e.g. https://adb-<id>.<n>.azuredatabricks.net
$token = az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv
$h = @{ Authorization = "Bearer $token" }
function Invoke-Db($Method, $Path, $Body) {
    $request = @{ Method = $Method; Uri = "$workspace$Path"; Headers = $h }
    if ($Body) { $request.ContentType = 'application/json'; $request.Body = ($Body | ConvertTo-Json -Depth 8) }
    Invoke-RestMethod @request
}
```

`2ff814a6-3304-4ab8-85cb-cd0e6f879c1d` is the fixed application ID of the AzureDatabricks
first-party app, so it is the same in every tenant.

---

## A. Create the Databricks NSG

Template 19 attaches an **existing** network security group to the two Databricks subnets.
It does not create one, so create an empty NSG first. Databricks adds the rules it needs
when the workspace is deployed.

```powershell
az group create -n <ResourceGroup> -l <Location>
az network nsg create -g <ResourceGroup> -n nsg-databricks -l <Location>
$env:DATABRICKS_NSG_ID = az network nsg show -g <ResourceGroup> -n nsg-databricks --query id -o tsv
```

`deployment/food-analytics.bicepparam` reads `DATABRICKS_NSG_ID` and fails if it is missing.
That is deliberate: an empty value would detach the NSG from the Databricks subnets on a
redeploy. Set the variable in every shell you deploy Template 19 from.

## B. Confirm the Unity Catalog metastore

New Azure Databricks workspaces are attached automatically to the regional Unity Catalog
metastore. The reference deployment was attached to the `swedencentral` metastore, with no
metastore-level default storage.

1. Open the workspace URL and select **Catalog** in the left menu.
2. If Catalog Explorer opens and lists catalogs, the workspace is attached. Continue to C.
3. If it asks you to enable Unity Catalog, a **Databricks account admin** must assign a
   metastore at <https://accounts.azuredatabricks.net> → **Catalog**. That role needs
   Entra Global Administrator to bootstrap, so arrange it early.

For workspaces created after 9 November 2023 and enabled for Unity Catalog automatically,
workspace admins can create storage credentials, external locations and catalogs, so no
account admin is needed for steps C to E. Older workspaces need a metastore admin to grant
those privileges first.

## C. Create the storage credential and external location

`databricks-uc-storage.bicep` created a private ADLS Gen2 account, a `unity-catalog`
container and an Access Connector with **Storage Blob Data Contributor** on it. Unity
Catalog now needs to be told about them.

Get the IDs from the deployment outputs:

```powershell
$uc = az deployment group show -g <ResourceGroup> -n databricks-uc-storage --query properties.outputs -o json | ConvertFrom-Json
$accessConnectorId = $uc.accessConnectorId.value
$location          = $uc.managedLocationUrl.value     # abfss://unity-catalog@<storage>.dfs.core.windows.net/
```

**Using the API (recommended).** The Databricks control plane cannot reach a storage account
whose public access is disabled, so validation must be skipped. The SQL warehouse reading
the data later proves that the path works.

```powershell
Invoke-Db POST /api/2.1/unity-catalog/storage-credentials @{
    name                   = 'food_analytics_uc'
    azure_managed_identity = @{ access_connector_id = $accessConnectorId }
    skip_validation        = $true
}
Invoke-Db POST /api/2.1/unity-catalog/external-locations @{
    name            = 'food_analytics_uc'
    url             = $location
    credential_name = 'food_analytics_uc'
    skip_validation = $true
}
```

**Using the UI instead.** Go to **Catalog** → **External data** → **Credentials** →
**Create credential**. Choose type *Azure Managed Identity* and paste the Access Connector
resource ID. Then, under **External locations** → **Create external location**, enter the
`abfss://` URL and choose the credential. If the connection test fails because the storage
is private, use the API above, which can skip validation.

## D. Create the Pro SQL warehouse

The reference warehouse settings:

| Setting | Value | Why |
|---|---|---|
| Type | **Pro** | Serverless would need a Network Connectivity Config to reach private storage, which needs an account admin |
| Size | 2X-Small | Enough for the demo data |
| Scaling | min 1, max 1 | |
| Auto stop | 60 minutes | Long enough to survive a demo; a cold start takes about 6 minutes |
| Photon | On | |
| Spot policy | Cost optimized | |

**UI:** **SQL Warehouses** → **Create SQL warehouse**. Set the name to `wh-food-analytics`,
apply the settings above, and choose type **Pro** under **Advanced options**.

**API:**

```powershell
$wh = Invoke-Db POST /api/2.0/sql/warehouses @{
    name                      = 'wh-food-analytics'
    cluster_size              = '2X-Small'
    min_num_clusters          = 1
    max_num_clusters          = 1
    auto_stop_mins            = 60
    warehouse_type            = 'PRO'
    enable_serverless_compute = $false
    enable_photon             = $true
    spot_instance_policy      = 'COST_OPTIMIZED'
}
$wh.id   # record as WarehouseId in environment.json
```

The warehouse ID is also the last part of its HTTP path, `/sql/1.0/warehouses/<id>`, on the
warehouse's **Connection details** tab.

## E. Create the catalog and schema

Run this in **SQL Editor** on the new warehouse, using the `abfss://` URL from step C:

```sql
CREATE CATALOG IF NOT EXISTS food_analytics
  MANAGED LOCATION 'abfss://unity-catalog@<storage>.dfs.core.windows.net/';

CREATE SCHEMA IF NOT EXISTS food_analytics.gold;
```

The first statement fails with a permissions or location error if step C is missing. Then
continue with README step 4, `seed-databricks-gold.ps1`, which creates and comments the
tables.

## F. Look up managed identity client IDs

Databricks registers Entra managed identities by their **application (client) ID**, not by
the object ID that Azure shows on the resource. Each lookup is two hops: resource →
principal ID → application ID.

```powershell
# Foundry account (system-assigned)
$p = az cognitiveservices account show -g <ResourceGroup> -n <FoundryAccountName> --query identity.principalId -o tsv
az ad sp show --id $p --query appId -o tsv            # FoundryAccountIdentityId

# Foundry project (system-assigned)
$p = az rest --method get --query identity.principalId -o tsv --url `
  "https://management.azure.com/subscriptions/<SubscriptionId>/resourceGroups/<ResourceGroup>/providers/Microsoft.CognitiveServices/accounts/<FoundryAccountName>/projects/<FoundryProjectName>?api-version=2025-06-01"
az ad sp show --id $p --query appId -o tsv            # FoundryProjectIdentityId

# Jumpbox VM (system-assigned)
$p = az vm show -g <ResourceGroup> -n <JumpboxName> --query identity.principalId -o tsv
az ad sp show --id $p --query appId -o tsv            # JumpboxIdentityId
```

Record all three in `environment.json`. If `az ad sp show` is denied, ask someone with
Directory Readers to run it, or read **Application ID** from **Microsoft Entra ID** →
**Enterprise applications**, filtered to *Managed Identities*.

## G. Give the jumpbox its Azure roles and tools

The jumpbox deploys the agent with its own managed identity, so it needs Azure roles, and
it needs `azd` installed.

**Roles.** Assign them in the portal (**Access control (IAM)** → **Add role assignment** →
*Managed identity* → *Virtual machine*), or with the CLI:

| Role | Scope | Why |
|---|---|---|
| Foundry Project Manager | Foundry account | Create the toolbox, deploy and invoke the hosted agent (data plane) |
| Contributor | Resource group | `azd deploy` creates the agent's supporting resources |
| Contributor | Databricks workspace | Lets the identity sign in to the workspace and be made an administrator in step H |

```powershell
$jb = az vm show -g <ResourceGroup> -n <JumpboxName> --query identity.principalId -o tsv
$foundry = az cognitiveservices account show -g <ResourceGroup> -n <FoundryAccountName> --query id -o tsv
$dbw = az databricks workspace show -g <ResourceGroup> -n dbw-food-analytics-swc --query id -o tsv
az role assignment create --assignee-object-id $jb --assignee-principal-type ServicePrincipal --role 'Foundry Project Manager' --scope $foundry
az role assignment create --assignee-object-id $jb --assignee-principal-type ServicePrincipal --role Contributor --scope (az group show -n <ResourceGroup> --query id -o tsv)
az role assignment create --assignee-object-id $jb --assignee-principal-type ServicePrincipal --role Contributor --scope $dbw
```

**Azure Developer CLI.** Install it on the jumpbox through run-command. `run-on-jumpbox.ps1`
then adds the `azure.ai.agents` extension and signs in with the managed identity:

```powershell
az vm run-command invoke -g <ResourceGroup> -n <JumpboxName> --command-id RunPowerShellScript `
  --scripts "Invoke-RestMethod 'https://aka.ms/install-azd.ps1' -OutFile `$env:TEMP\install-azd.ps1; & `$env:TEMP\install-azd.ps1"
```

Power BI Desktop is installed by `deployment/jumpbox-install-powerbi.ps1` (README step 11).

## H. Make the jumpbox a Databricks administrator

Once the workspace is private, the jumpbox is the **only** client that can reach it, so its
identity must be able to administer the workspace and the catalog. Do this **before**
lockdown, or nobody will be authorised to fix it afterwards.

**UI:**

1. In the workspace, open your user menu → **Settings** → **Identity and access** →
   **Service principals** → **Manage** → **Add service principal**.
2. Choose **Microsoft Entra ID managed**, paste `JumpboxIdentityId` as the application ID,
   and name it `vm-jumpbox`.
3. Open it, and on **Configurations** tick **Workspace access** and
   **Databricks SQL access**.
4. Go to **Groups** → **admins** → **Add members**, and add `vm-jumpbox`.
5. In **Catalog** → `food_analytics` → **Permissions** → **Grant**, give `vm-jumpbox`
   **USE CATALOG** and **MANAGE**.

**API equivalent:**

```powershell
$appId = '<JumpboxIdentityId>'
$sp = Invoke-Db POST /api/2.0/preview/scim/v2/ServicePrincipals @{
    schemas       = @('urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal')
    applicationId = $appId
    displayName   = 'vm-jumpbox'
    entitlements  = @(@{ value = 'workspace-access' }, @{ value = 'databricks-sql-access' })
}
$admins = (Invoke-Db GET "/api/2.0/preview/scim/v2/Groups?filter=$([uri]::EscapeDataString('displayName eq "admins"'))").Resources[0]
Invoke-Db PATCH "/api/2.0/preview/scim/v2/Groups/$($admins.id)" @{
    schemas    = @('urn:ietf:params:scim:api:messages:2.0:PatchOp')
    Operations = @(@{ op = 'add'; value = @{ members = @(@{ value = $sp.id }) } })
}
Invoke-Db PATCH /api/2.1/unity-catalog/permissions/catalog/food_analytics @{
    changes = @(@{ principal = $appId; add = @('USE_CATALOG', 'MANAGE') })
}
```

`jumpbox-create-shared-views.ps1` then gives the jumpbox `CREATE_TABLE` and `MANAGE` on
`food_analytics.gold` itself.

The Foundry identities are registered by `grant-databricks-identity.ps1` (README step 7).
They are **not** made admins.

## I. Grant presenters access

Genie in the browser and the Power BI connector both run as the **signed-in person**, not
as a managed identity. Being a workspace admin does **not** grant data access in Unity
Catalog, so each presenter needs read access, or the Genie space shows *"You are missing
access to 3 tables"*.

Run this from the jumpbox (SQL Editor) once the workspace is private:

```sql
GRANT USE CATALOG ON CATALOG food_analytics TO `presenter@contoso.com`;
GRANT USE SCHEMA, SELECT ON SCHEMA food_analytics.gold TO `presenter@contoso.com`;
```

A presenter who is **not** a workspace admin also needs:

- **SQL Warehouses** → `wh-food-analytics` → **Permissions** → **Can use**.
- The Genie space → **Share** → **Can run**.

Grant each person individually rather than the `users` group, so the demo data stays
limited to named people.

## J. Open and close RDP for a session

`jumpbox.bicep` creates the `AllowRdpFromOperator` rule for one source address. Security
automation in some subscriptions deletes inbound RDP rules within about an hour, and your
public IP may change. Recreate the rule at the start of each session, and remove it when
you finish:

```powershell
$ip = Invoke-RestMethod https://api.ipify.org
az network nsg rule create -g <ResourceGroup> --nsg-name nsg-jumpbox -n AllowRdpFromOperator `
  --priority 100 --direction Inbound --access Allow --protocol Tcp `
  --source-address-prefixes "$ip/32" --destination-port-ranges 3389
az vm start -g <ResourceGroup> -n <JumpboxName>

# ... session ...

az network nsg rule delete -g <ResourceGroup> --nsg-name nsg-jumpbox -n AllowRdpFromOperator
az vm deallocate -g <ResourceGroup> -n <JumpboxName>
```

Sign in as `.\<adminUsername>` (`foodadmin` by default). The leading `.\` selects the local
account instead of your work account. If the password is lost, reset it with
`az vm user update -g <ResourceGroup> -n <JumpboxName> -u foodadmin -p <new-password>`.

For production, prefer Azure Bastion or just-in-time VM access to a public RDP rule.
