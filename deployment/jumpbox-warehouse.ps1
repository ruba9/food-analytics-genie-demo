<#
Starts or stops the demo SQL warehouse from inside the VNet.

The workspace has publicNetworkAccess Disabled, so the warehouse can only be controlled
from an in-VNet client. Authenticates with the jumpbox managed identity.

Usage: ./deployment/Invoke-OnJumpbox.ps1 ./deployment/jumpbox-warehouse.ps1 -Parameters @{ Action = 'stop' }
#>
param(
    [ValidateSet('start', 'stop')]
    [string] $Action = 'start',
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    [Parameter(Mandatory)] [string] $WarehouseId
)

$ErrorActionPreference = 'Continue'

$warehouseId = $WarehouseId
$workspace = $WorkspaceUrl

$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }

try {
    Invoke-RestMethod -Method Post -Uri "$workspace/api/2.0/sql/warehouses/$warehouseId/$Action" `
        -Headers $h -ContentType 'application/json' -Body '{}' | Out-Null
    Write-Output "$Action requested"
}
catch {
    Write-Output ("request failed: " + $_.ErrorDetails.Message)
}

$target = if ($Action -eq 'start') { 'RUNNING' } else { 'STOPPED' }
$deadline = (Get-Date).AddMinutes(10)
do {
    Start-Sleep -Seconds 20
    $state = (Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/sql/warehouses/$warehouseId" -Headers $h).state
    Write-Output "state: $state"
} while ($state -ne $target -and (Get-Date) -lt $deadline)
