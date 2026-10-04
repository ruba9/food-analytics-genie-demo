<#
.SYNOPSIS
    Registers an Entra identity in Databricks and grants it least-privilege access to
    the Genie space, SQL warehouse and gold schema.

.DESCRIPTION
    Foundry calls Databricks with a managed identity. Databricks rejects an unknown or
    unentitled principal with HTTP 403 even when object permissions exist, so all four
    steps below are required:

      1. SCIM registration of the Entra application (client) ID
      2. workspace-access and databricks-sql-access entitlements
      3. CAN_RUN on the Genie space and CAN_USE on the warehouse
      4. USE CATALOG / USE SCHEMA / SELECT in Unity Catalog

    Deliberately does not grant workspace admin.

    Workspace, Genie space and warehouse default to deployment/environment.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $ApplicationId,

    [Parameter(Mandatory)]
    [string] $DisplayName,

    [string] $WorkspaceUrl,
    [string] $GenieSpaceId,
    [string] $WarehouseId,
    [string] $Catalog = 'food_analytics',
    [string] $Schema = 'gold'
)

$ErrorActionPreference = 'Stop'

if (-not ($WorkspaceUrl -and $GenieSpaceId -and $WarehouseId)) {
    . (Join-Path $PSScriptRoot 'DemoEnvironment.ps1')
    $environment = Get-DemoEnvironment
    if (-not $WorkspaceUrl) { $WorkspaceUrl = $environment.WorkspaceUrl }
    if (-not $GenieSpaceId) { $GenieSpaceId = $environment.GenieSpaceId }
    if (-not $WarehouseId) { $WarehouseId = $environment.WarehouseId }
}

$databricksResourceId = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$token = az account get-access-token --resource $databricksResourceId --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'Failed to acquire a Databricks access token. Run `az login` and retry.'
}
$headers = @{ Authorization = "Bearer $token" }

function Invoke-Db {
    param([string] $Method, [string] $Path, $Body)
    $uri = "$WorkspaceUrl$Path"
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 8)
}

# 1. Register, or reuse an existing registration.
$filter = [uri]::EscapeDataString("applicationId eq `"$ApplicationId`"")
$found = Invoke-Db GET "/api/2.0/preview/scim/v2/ServicePrincipals?filter=$filter"
if ($found.Resources -and $found.Resources.Count -gt 0) {
    $spId = $found.Resources[0].id
    Write-Host "Service principal already registered (id=$spId)"
}
else {
    $created = Invoke-Db POST '/api/2.0/preview/scim/v2/ServicePrincipals' @{
        schemas       = @('urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal')
        applicationId = $ApplicationId
        displayName   = $DisplayName
        active        = $true
    }
    $spId = $created.id
    Write-Host "Registered service principal (id=$spId)"
}

# 2. Entitlements. Without these Databricks returns 403 regardless of object grants.
Invoke-Db PATCH "/api/2.0/preview/scim/v2/ServicePrincipals/$spId" @{
    schemas    = @('urn:ietf:params:scim:api:messages:2.0:PatchOp')
    Operations = @(@{
            op    = 'add'
            path  = 'entitlements'
            value = @(@{ value = 'workspace-access' }, @{ value = 'databricks-sql-access' })
        })
} | Out-Null
Write-Host 'Entitlements: workspace-access, databricks-sql-access'

# 3. Object permissions.
Invoke-Db PATCH "/api/2.0/permissions/genie/$GenieSpaceId" @{
    access_control_list = @(@{ service_principal_name = $ApplicationId; permission_level = 'CAN_RUN' })
} | Out-Null
Write-Host 'Genie space: CAN_RUN'

Invoke-Db PATCH "/api/2.0/permissions/warehouses/$WarehouseId" @{
    access_control_list = @(@{ service_principal_name = $ApplicationId; permission_level = 'CAN_USE' })
} | Out-Null
Write-Host 'Warehouse: CAN_USE'

# 4. Unity Catalog grants.
Invoke-Db PATCH "/api/2.1/unity-catalog/permissions/catalog/$Catalog" @{
    changes = @(@{ principal = $ApplicationId; add = @('USE_CATALOG') })
} | Out-Null
Invoke-Db PATCH "/api/2.1/unity-catalog/permissions/schema/$Catalog.$Schema" @{
    changes = @(@{ principal = $ApplicationId; add = @('USE_SCHEMA', 'SELECT') })
} | Out-Null

# Unity Catalog returns 200 but silently drops the change when the principal was only
# just created, so the result is read back rather than assumed.
$catalogGrants = (Invoke-Db GET "/api/2.1/unity-catalog/permissions/catalog/$Catalog").privilege_assignments |
    Where-Object { $_.principal -eq $ApplicationId }
$schemaGrants = (Invoke-Db GET "/api/2.1/unity-catalog/permissions/schema/$Catalog.$Schema").privilege_assignments |
    Where-Object { $_.principal -eq $ApplicationId }

if (-not $catalogGrants -or -not $schemaGrants) {
    throw "Unity Catalog grants did not apply for $ApplicationId. Re-run this script; the principal may not have been visible to Unity Catalog yet."
}
Write-Host "Unity Catalog: $($catalogGrants.privileges -join ',') on $Catalog, $($schemaGrants.privileges -join ',') on $Catalog.$Schema"

Write-Host ''
Write-Host "$DisplayName ($ApplicationId) is ready."
