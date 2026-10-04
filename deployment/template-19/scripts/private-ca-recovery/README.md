# Private CA capability-host and agent recovery

Use these scripts when you add or rotate `trustedCertificates` on an existing
Foundry account and need the project runtime to load the updated CA trust.

> [!CAUTION]
> Deleting a project capability host is a destructive reset. Existing agent,
> conversation, file, and vector-store state can become permanently orphaned.
> Export the recovery manifest first, keep normal source-controlled deployment
> assets, and use this workflow only when capability-host recreation is required.

## What the scripts preserve

| Surface | Recovery source | Behavior |
| --- | --- | --- |
| Capability host | ARM resource | Saves the writable host properties and verifies every referenced project connection before deletion. |
| Prompt Agent | Cosmos-backed Foundry Agent API | Exports the materialized Prompt Agent definition through the supported API before deletion, then creates a new version. The script never reads or edits Cosmos DB containers directly. |
| Hosted Agent | Existing container image | Exports the container image, protocol, compute, telemetry, environment, metadata, and endpoint configuration, then creates a new version from that image. |
| Agent endpoint | Foundry Agent API | Preserves the endpoint/card configuration, remaps routed versions, and restores the enabled or disabled state. |
| Agent identity | Azure RBAC | Captures direct role assignments in the selected subscriptions and reapplies them to each new version identity before endpoint routing is restored. |

The default export retains every version definition but restores only the latest
version and any version referenced by endpoint routing. Use
`-RestoreAllAgentVersions` when version history is required.

Container-based Hosted Agents are supported. If a selected Hosted Agent was
deployed from source code instead of `container_configuration.image`, export
stops before any destructive action. Redeploy that agent from its original
source or agent manifest.

## Reproducibility and customer portability

The workflow is customer-neutral: it contains no fixed tenant, subscription,
region, resource name, network, or certificate assumptions. Every environment
value is supplied through parameters or discovered from the selected Foundry
account and project, so customers can run the same export, trust update,
validation, recreation, and resume steps in their own environment.

Reproducibility safeguards include:

- exact top-level Python dependency pins in `requirements.txt`;
- versioned ARM and Foundry API usage recorded in the recovery artifacts;
- one protected recovery directory per snapshot, with no silent overwrite;
- definition hashes and pre-destructive validation;
- deterministic version ordering and one-to-one version replay, including safe
  reuse after a partial retry;
- immutable container image digests as the recommended Hosted Agent source.

The scripts are usable by any customer whose subscription, region, and Foundry
account support the referenced features. They don't bypass service availability:
`trustedCertificates` and Hosted Agents can be preview or allowlist-gated, and
private networking, Key Vault RBAC, regional support, quotas, and agent API
availability must already be satisfied for that customer.

For non-default layouts, use the provided parameters instead of changing the
scripts: `-ProjectEndpoint` overrides endpoint discovery,
`-ProjectCapabilityHostName` and `-AccountCapabilityHostName` disambiguate
multiple hosts, the API-version parameters support an explicitly approved
service version, and `-RoleAssignmentSubscriptionId` can be repeated for
cross-subscription dependencies.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 or later.
- Azure CLI authenticated to the tenant that contains the Foundry resource.
- Python 3.10 or later.
- Network access to the project endpoint. For a private Foundry account, run
  from a VPN, ExpressRoute-connected machine, or jump host in the VNet.
- Permissions to read/write capability hosts and agent versions.
- The Foundry account identity has **Key Vault Secrets User** on the vault that
  stores the public CA PEM secrets.
- **Role Based Access Control Administrator**, **User Access Administrator**, or
  **Owner** when agent identity role assignments are copied.

Install the pinned Python dependencies:

```powershell
cd .\scripts\private-ca-recovery
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

On Linux or macOS, use `.venv/bin/python` in the commands below.

## 1. Export before deletion

This step is non-destructive:

```powershell
$recovery = ".\.foundry-recovery\private-ca-rotation-001"

.\Recreate-CapabilityHostAndAgents.ps1 `
  -Mode Export `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<resource-group>" `
  -AccountName "<foundry-account>" `
  -ProjectName "<project>" `
  -RecoveryDirectory $recovery `
  -PythonExecutable ".\.venv\Scripts\python.exe"
```

The export fails safely if it finds a selected agent kind it can't replay. To
inventory unsupported agents without backing them up, add
`-SkipUnsupportedAgents`; don't proceed with deletion until those agents have a
separate source-controlled deployment path. Recreate still refuses to delete
the host while any selected version is unsupported.

Export mode doesn't overwrite existing manifests. Use a new recovery directory
for each snapshot so a failed or stale export can't be mixed with another run.

Validate the saved artifacts without changing Azure resources:

```powershell
.\Recreate-CapabilityHostAndAgents.ps1 `
  -Mode Validate `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<resource-group>" `
  -AccountName "<foundry-account>" `
  -ProjectName "<project>" `
  -RecoveryDirectory $recovery `
  -PythonExecutable ".\.venv\Scripts\python.exe"
```

The recovery directory contains:

- `capability-hosts.json` - preserved host properties and connection names.
- `agents.json` - agent definitions, routing, identities, and role assignments.

`agents.json` can contain Prompt Agent tool/authentication configuration and
Hosted Agent environment-variable values. Keep the directory protected and
don't commit it. Store durable non-secret configuration in source control and
credentials in the normal secure configuration store. The included `.gitignore`
excludes the default `.foundry-recovery` directory.

## 2. Register the private CA references

Upload each public root or intermediate CA PEM as a separate, versioned Key
Vault secret. Then register the exact versions while preserving existing
certificate references:

```powershell
.\Set-PrivateCaTrust.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<resource-group>" `
  -AccountName "<foundry-account>" `
  -KeyVaultResourceId "<key-vault-resource-id>" `
  -CertificateReference @(
    "private-root-ca-pem=<secret-version>",
    "private-intermediate-ca-pem=<secret-version>"
  )
```

The script never reads or prints certificate secret values. It updates only the
account's `trustedCertificates` property and verifies the stored references.

## 3. Recreate the host and redeploy agents

Review both manifests, then run:

```powershell
.\Recreate-CapabilityHostAndAgents.ps1 `
  -Mode Recreate `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<resource-group>" `
  -AccountName "<foundry-account>" `
  -ProjectName "<project>" `
  -RecoveryDirectory $recovery `
  -PythonExecutable ".\.venv\Scripts\python.exe" `
  -AcknowledgeDataLoss
```

Before deleting anything, the workflow validates manifest hashes, confirms that
all selected versions are recoverable, and rechecks every saved project
connection. It then:

1. Deletes the project capability host and waits for deletion.
2. Recreates it with the same Cosmos DB, Storage, AI Search, subnet, and other
   connection references.
3. Reuses an already-present identical version or creates a new agent version.
4. Reapplies captured RBAC to each new agent-version identity.
5. Restores endpoint routing with old-to-new version mapping.
6. Restores the original enabled or disabled state. Each recovered agent is
   disabled as soon as it exists and stays disabled while versions, RBAC, and
   routing are incomplete.

The account capability host normally doesn't need recreation for a
`trustedCertificates` change. If your recovery procedure explicitly requires
it, add `-RecreateAccountCapabilityHost`; the script deletes project scope
first and recreates account scope before project scope.

If host recreation succeeds but agent replay fails, don't repeat the destructive
step. Resume from the existing manifest:

```powershell
.\Recreate-CapabilityHostAndAgents.ps1 `
  -Mode RestoreAgents `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<resource-group>" `
  -AccountName "<foundry-account>" `
  -ProjectName "<project>" `
  -RecoveryDirectory $recovery `
  -PythonExecutable ".\.venv\Scripts\python.exe"
```

## Recovery boundaries

- A destructive capability-host reset isn't a Cosmos DB restore. Reusing the
  same Cosmos DB connection doesn't make orphaned agent or thread records
  reachable through a supported API.
- Prompt Agent definitions are captured before deletion through Foundry, then
  replayed as new versions. Keep canonical definitions, non-secret tool setup,
  and knowledge files in source control, with credentials in the normal secure
  configuration store.
- Hosted Agents are replayed from the recorded container image. Prefer immutable
  image digests over mutable tags.
- File and vector-store IDs can refer to state that a reset or dependency loss
  orphaned. The export reports these references; restore the source files and
  knowledge configuration separately.
- New agent versions can receive new IDs and managed identities. Use the restore
  report to update clients and verify role assignments.
- Role assignments are captured only in `-RoleAssignmentSubscriptionId`
  subscriptions. The current Foundry subscription is included by default; pass
  the switch repeatedly for cross-subscription dependencies such as ACR.

See:

- [Capability hosts](https://learn.microsoft.com/azure/foundry/agents/concepts/capability-hosts)
- [Foundry Agent Service resource and data loss recovery](https://learn.microsoft.com/azure/foundry/how-to/agent-service-operator-disaster-recovery)
- [Manage Hosted Agents](https://learn.microsoft.com/azure/foundry/agents/how-to/manage-hosted-agent)
