<#
.SYNOPSIS
    Deploys the network-isolated Foundry agent and connects it to a North Europe
    Databricks workspace.

.DESCRIPTION
    Stage 'network'      - VNet, subnets, Bastion, and jump box (West Europe).
    Stage 'foundry'      - Foundry account with VNet injection + BYO data resources.
    Stage 'connectivity' - Databricks workspace (North Europe) + peering + private DNS.

    Run the stages in that order. Each one feeds the next.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = 'westeurope',
    [ValidateSet('network', 'foundry', 'connectivity', 'all')][string]$Stage = 'network',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

az account set --subscription $SubscriptionId

# Microsoft.App and Microsoft.ContainerService are mandatory for network injection.
# If either is unregistered the failure surfaces AFTER the Foundry account is accepted,
# leaving it provisioningState=Failed and requiring a delete+purge before retry.
function Assert-ProvidersRegistered {
    $required = @(
        'Microsoft.KeyVault', 'Microsoft.CognitiveServices', 'Microsoft.Storage',
        'Microsoft.Search', 'Microsoft.Network', 'Microsoft.App', 'Microsoft.ContainerService',
        'Microsoft.Databricks', 'Microsoft.Compute'
    )

    foreach ($ns in $required) {
        $state = az provider show --namespace $ns --query registrationState -o tsv
        if ($state -ne 'Registered') {
            Write-Host "Registering $ns (currently $state)..."
            az provider register --namespace $ns | Out-Null
        }
    }

    foreach ($ns in $required) {
        for ($i = 0; $i -lt 60; $i++) {
            $state = az provider show --namespace $ns --query registrationState -o tsv
            if ($state -eq 'Registered') { break }
            Start-Sleep -Seconds 10
        }
        if ($state -ne 'Registered') {
            throw "Provider $ns is still '$state'. Deployment would fail mid-flight and leave an account needing purge. Resolve before retrying."
        }
        Write-Host "  $ns : Registered"
    }
}

function Invoke-NetworkStage {
    Write-Host "`n=== Stage: network (West Europe) ===" -ForegroundColor Cyan
    Assert-ProvidersRegistered

    az group create --name $ResourceGroup --location $Location | Out-Null

    $paramFile = Join-Path $root 'network/food-analytics.bicepparam'
    $needsPassword = (Get-Content $paramFile -Raw) -match '(?m)^\s*param\s+deployJumpbox\s*=\s*true'

    if ($needsPassword -and -not $env:JUMPBOX_ADMIN_PASSWORD) {
        $secure = Read-Host -Prompt 'Jump box local admin password (min 12 chars, not stored on disk)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $env:JUMPBOX_ADMIN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    $cmd = if ($WhatIf) { 'what-if' } else { 'create' }

    try {
        az deployment group $cmd `
            --resource-group $ResourceGroup `
            --name 'network' `
            --template-file (Join-Path $root 'network/main.bicep') `
            --parameters $paramFile
    }
    finally {
        Remove-Item Env:\JUMPBOX_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    }
}

# The Foundry template reads these as existing*SubnetResourceId so it references the
# subnets instead of rewriting the VNet.
function Import-NetworkOutputs {
    $o = az deployment group show --resource-group $ResourceGroup --name 'network' --query properties.outputs 2>$null | ConvertFrom-Json
    if (-not $o) {
        throw "No 'network' deployment found in $ResourceGroup. Run -Stage network first."
    }
    $env:AZURE_VNET_RESOURCE_ID = $o.vnetResourceId.value
    $env:AZURE_AGENT_SUBNET_ID = $o.agentSubnetResourceId.value
    $env:AZURE_PE_SUBNET_ID = $o.peSubnetResourceId.value
    $env:AZURE_MCP_SUBNET_ID = $o.mcpSubnetResourceId.value
    Write-Host "Using VNet: $($env:AZURE_VNET_RESOURCE_ID)"
}

function Invoke-FoundryStage {
    Write-Host "`n=== Stage: foundry (West Europe) ===" -ForegroundColor Cyan
    Assert-ProvidersRegistered
    Import-NetworkOutputs

    $cmd = if ($WhatIf) { 'what-if' } else { 'create' }

    # Capability-host creation on an injected account can take 30-35 minutes. Do not cancel.
    az deployment group $cmd `
        --resource-group $ResourceGroup `
        --name 'foundry-private' `
        --template-file (Join-Path $root 'foundry/main.bicep') `
        --parameters (Join-Path $root 'foundry/food-analytics.bicepparam')
}

function Invoke-ConnectivityStage {
    Write-Host "`n=== Stage: connectivity (Databricks North Europe + peering) ===" -ForegroundColor Cyan
    Assert-ProvidersRegistered
    Import-NetworkOutputs

    $cmd = if ($WhatIf) { 'what-if' } else { 'create' }

    az deployment sub $cmd `
        --location $Location `
        --name 'databricks-connectivity' `
        --template-file (Join-Path $root 'databricks/main.bicep') `
        --parameters (Join-Path $root 'databricks/food-analytics.bicepparam')
}

switch ($Stage) {
    'network' { Invoke-NetworkStage }
    'foundry' { Invoke-FoundryStage }
    'connectivity' { Invoke-ConnectivityStage }
    'all' { Invoke-NetworkStage; Invoke-FoundryStage; Invoke-ConnectivityStage }
}
