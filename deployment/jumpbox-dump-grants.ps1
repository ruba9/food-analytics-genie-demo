<#
Dumps the Genie space, warehouse and Unity Catalog grants so identity problems can be
diagnosed without guessing. Runs on the jumpbox, which is a Databricks workspace admin.
#>
param(
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    [Parameter(Mandatory)] [string] $GenieSpaceId,
    [Parameter(Mandatory)] [string] $WarehouseId
)

$ErrorActionPreference = 'Continue'

$workspace = $WorkspaceUrl
$spaceId = $GenieSpaceId
$warehouseId = $WarehouseId

$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }

Write-Output '== genie space'
(Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/permissions/genie/$spaceId" -Headers $h).access_control_list |
    ForEach-Object { "  $($_.user_name)$($_.service_principal_name)$($_.group_name) => $(($_.all_permissions | ForEach-Object { $_.permission_level }) -join ',')" }

Write-Output '== warehouse'
(Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/permissions/warehouses/$warehouseId" -Headers $h).access_control_list |
    ForEach-Object { "  $($_.user_name)$($_.service_principal_name)$($_.group_name) => $(($_.all_permissions | ForEach-Object { $_.permission_level }) -join ',')" }

Write-Output '== catalog food_analytics'
(Invoke-RestMethod -Method Get -Uri "$workspace/api/2.1/unity-catalog/permissions/catalog/food_analytics" -Headers $h).privilege_assignments |
    ForEach-Object { "  $($_.principal) => $($_.privileges -join ',')" }

Write-Output '== schema food_analytics.gold'
(Invoke-RestMethod -Method Get -Uri "$workspace/api/2.1/unity-catalog/permissions/schema/food_analytics.gold" -Headers $h).privilege_assignments |
    ForEach-Object { "  $($_.principal) => $($_.privileges -join ',')" }

Write-Output '== service principals'
(Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/preview/scim/v2/ServicePrincipals" -Headers $h).Resources |
    ForEach-Object { "  $($_.displayName) [$($_.applicationId)] entitlements=$(($_.entitlements | ForEach-Object { $_.value }) -join ',')" }
