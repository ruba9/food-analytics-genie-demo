<#
.SYNOPSIS
    Verifies the private path from the Foundry agent subnet to the Databricks workspace.

.DESCRIPTION
    Control-plane checks run from anywhere. The DNS resolution check must run from
    inside the VNet (jump box / Bastion / VPN) because that is the only place where
    the agent's view of DNS can be observed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$FoundryResourceGroup,
    [string]$FoundryVnetName = 'vnet-foundry-we',
    [Parameter(Mandatory)][string]$DatabricksWorkspaceHost
)

$ErrorActionPreference = 'Stop'
az account set --subscription $SubscriptionId

$pass = $true
function Check($label, $ok, $detail) {
    $mark = if ($ok) { '[PASS]' } else { '[FAIL]'; }
    if (-not $ok) { $script:pass = $false }
    Write-Host "$mark $label -> $detail"
}

Write-Host "`n--- Peering ---" -ForegroundColor Cyan
$peerings = az network vnet peering list --resource-group $FoundryResourceGroup --vnet-name $FoundryVnetName | ConvertFrom-Json
if (-not $peerings) {
    Check 'Outbound peering exists' $false 'none found'
}
foreach ($p in $peerings) {
    # 'Initiated' means only one half exists; traffic does not flow until both sides are Connected.
    Check "Peering $($p.name)" ($p.peeringState -eq 'Connected') $p.peeringState
}

Write-Host "`n--- Private DNS link ---" -ForegroundColor Cyan
$zoneId = az network private-dns zone list --query "[?name=='privatelink.azuredatabricks.net'].id | [0]" -o tsv
if (-not $zoneId) {
    Check 'privatelink.azuredatabricks.net zone' $false 'zone not found in subscription'
}
else {
    $zoneRg = $zoneId.Split('/')[4]
    $links = az network private-dns link vnet list --resource-group $zoneRg --zone-name 'privatelink.azuredatabricks.net' | ConvertFrom-Json
    $linked = $links | Where-Object { $_.virtualNetwork.id -match "/$FoundryVnetName$" }
    Check 'Foundry VNet linked to Databricks zone' ([bool]$linked) $(if ($linked) { $linked.name } else { 'no link for ' + $FoundryVnetName })
}

Write-Host "`n--- Foundry account ---" -ForegroundColor Cyan
$acct = az cognitiveservices account list --resource-group $FoundryResourceGroup | ConvertFrom-Json | Select-Object -First 1
if ($acct) {
    Check 'Public network access disabled' ($acct.properties.publicNetworkAccess -eq 'Disabled') $acct.properties.publicNetworkAccess
    Check 'Provisioning state' ($acct.properties.provisioningState -eq 'Succeeded') $acct.properties.provisioningState
}
else {
    Check 'Foundry account found' $false 'none in resource group'
}

Write-Host "`n--- Run from INSIDE the VNet ---" -ForegroundColor Yellow
Write-Host "  nslookup $DatabricksWorkspaceHost"
Write-Host "  Expected: a private RFC1918 address from the North Europe PE subnet."
Write-Host "  A public IP here means DNS is still resolving publicly and the agent call will fail."

Write-Host ""
if ($pass) { Write-Host 'Control-plane checks passed.' -ForegroundColor Green }
else { Write-Host 'One or more control-plane checks FAILED.' -ForegroundColor Red; exit 1 }
