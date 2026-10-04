<#
Applies Unity Catalog grants to the Foundry identities from inside the VNet.

Needed because the workspace has publicNetworkAccess Disabled, so the workstation cannot
reach the Databricks API, and grant-databricks-identity.ps1 depends on the Azure CLI,
which is not installed on the jumpbox. Authenticates with the jumpbox managed identity,
which is a Databricks workspace admin.

Genie can start a conversation with only CAN_RUN, but the generated query then fails
unless the same principal also holds USE_CATALOG / USE_SCHEMA / SELECT.
#>
param(
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    # Client IDs of the Foundry account and project managed identities. Both appear as
    # callers depending on which stage of the request is running, so both need the grants.
    [Parameter(Mandatory)] [string] $FoundryAccountIdentityId,
    [Parameter(Mandatory)] [string] $FoundryProjectIdentityId
)

$ErrorActionPreference = 'Continue'

$workspace = $WorkspaceUrl
$catalog = 'food_analytics'
$schema = 'gold'

$principals = @($FoundryAccountIdentityId, $FoundryProjectIdentityId)

$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }

foreach ($p in $principals) {
    foreach ($target in @(
            @{ path = "catalog/$catalog"; privs = @('USE_CATALOG') },
            @{ path = "schema/$catalog.$schema"; privs = @('USE_SCHEMA', 'SELECT') }
        )) {
        $body = @{ changes = @(@{ principal = $p; add = $target.privs }) } | ConvertTo-Json -Depth 6
        try {
            Invoke-RestMethod -Method Patch -Uri "$workspace/api/2.1/unity-catalog/permissions/$($target.path)" `
                -Headers $h -ContentType 'application/json' -Body $body | Out-Null
            Write-Output "granted $($target.privs -join ',') on $($target.path) to $p"
        }
        catch {
            Write-Output "FAILED $($target.path) for $p : $($_.ErrorDetails.Message)"
        }
    }
}

Write-Output ''
Write-Output '== verification: catalog'
(Invoke-RestMethod -Method Get -Uri "$workspace/api/2.1/unity-catalog/permissions/catalog/$catalog" -Headers $h).privilege_assignments |
    ForEach-Object { "  $($_.principal) => $($_.privileges -join ',')" }

Write-Output '== verification: schema'
(Invoke-RestMethod -Method Get -Uri "$workspace/api/2.1/unity-catalog/permissions/schema/$catalog.$schema" -Headers $h).privilege_assignments |
    ForEach-Object { "  $($_.principal) => $($_.privileges -join ',')" }
