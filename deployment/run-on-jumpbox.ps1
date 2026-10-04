<#
.SYNOPSIS
    Copies the agent project to the jumpbox and runs the Foundry data-plane steps there.

.DESCRIPTION
    Toolbox creation and agent deployment are data-plane operations against the Foundry
    project, which has publicNetworkAccess Disabled. They only work from inside the VNet,
    so this script ships the project to the jumpbox and drives it through
    `az vm run-command`, avoiding an interactive RDP session.

    Connections are NOT created here: those are ARM resources and are handled by
    deployment/foundry-connections.bicep from anywhere.

    The jumpbox authenticates with its own managed identity, so no credential is passed.
    Environment values come from deployment/environment.json.
#>
[CmdletBinding()]
param(
    [string] $RemotePath = 'C:\food-analytics',

    # Skip the agent deployment and only refresh the toolbox.
    [switch] $ToolboxOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'DemoEnvironment.ps1')
$environment = Get-DemoEnvironment
$ResourceGroup = $environment.ResourceGroup
$VmName = $environment.JumpboxName
$ProjectEndpoint = $environment.ProjectEndpoint
$ProjectResourceId = $environment.ProjectResourceId
$ToolboxName = $environment.ToolboxName
$ModelDeploymentName = $environment.ModelDeploymentName
$SubscriptionId = $environment.SubscriptionId
$Location = $environment.Location

$repoRoot = Split-Path -Parent $PSScriptRoot

# Only the files azd needs. The virtualenv and caches must never be shipped.
$include = @(
    'azure.yaml',
    'agent/main.py',
    'agent/requirements.txt',
    'agent/.agentignore'
)

$staging = Join-Path ([System.IO.Path]::GetTempPath()) "jb-stage-$([guid]::NewGuid())"
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "jb-payload-$([guid]::NewGuid()).zip"
$remoteScript = Join-Path ([System.IO.Path]::GetTempPath()) "jb-run-$([guid]::NewGuid()).ps1"

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($relative in $include) {
        $source = Join-Path $repoRoot $relative
        if (-not (Test-Path $source)) { throw "Missing required file: $relative" }
        $destination = Join-Path $staging $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item $source $destination
    }

    $toolbox = Get-Content -Path (Join-Path $repoRoot 'agent/toolbox.yaml.example')
    if (($toolbox -join "`n") -match '<[A-Z_]+>') {
        throw 'Unreplaced placeholder remains in the toolbox spec.'
    }
    Set-Content -Path (Join-Path $staging 'toolbox.yaml') -Value $toolbox -Encoding utf8

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -Force
    $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipPath))
    Write-Host "Payload: $([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB"

    $deployLine = if ($ToolboxOnly) {
        '# agent deployment skipped'
    }
    else {
        '$deployLog = Join-Path $env:TEMP ''deploy.log''
& $azd deploy --no-prompt > $deployLog 2>&1
Write-Output ("deploy exit=" + $LASTEXITCODE)
Get-Content $deployLog | ForEach-Object { Write-Output $_ }'
    }

    $remote = @"
# azd writes progress to stderr; 'Stop' would turn that into a NativeCommandError
# and hide the real failure.
`$ErrorActionPreference = 'Continue'
`$azd = 'C:\Program Files\Azure Dev CLI\azd.exe'
if (-not (Test-Path `$azd)) { `$azd = "`$env:LOCALAPPDATA\Programs\Azure Dev CLI\azd.exe" }
if (-not (Test-Path `$azd)) { throw 'azd not found on the jumpbox.' }
# The azd ai extension resolves credentials by invoking azd from PATH.
`$env:PATH = (Split-Path -Parent `$azd) + ';' + `$env:PATH
`$root = '$RemotePath'

if (Test-Path `$root) { Remove-Item `$root -Recurse -Force }
New-Item -ItemType Directory -Path `$root -Force | Out-Null
`$zip = Join-Path `$env:TEMP 'payload.zip'
[IO.File]::WriteAllBytes(`$zip, [Convert]::FromBase64String('$payload'))
Expand-Archive -Path `$zip -DestinationPath `$root -Force
Remove-Item `$zip -Force
Set-Location `$root

& `$azd auth login --managed-identity
& `$azd extension install azure.ai.agents 2>&1 | Out-Null

`$env:AZURE_SUBSCRIPTION_ID = '$SubscriptionId'
if (-not (& `$azd env list 2>`$null | Select-String 'food-analytics')) {
    & `$azd env new food-analytics --subscription `$env:AZURE_SUBSCRIPTION_ID --location '$Location' --no-prompt
}
& `$azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME '$ModelDeploymentName'
& `$azd env set TOOLBOX_NAME '$ToolboxName'
& `$azd env set AZURE_AI_PROJECT_ID '$ProjectResourceId'
& `$azd env set FOUNDRY_PROJECT_ENDPOINT '$ProjectEndpoint'
& `$azd ai project set '$ProjectEndpoint'

Write-Output '--- toolbox ---'
`$toolboxLog = Join-Path `$env:TEMP 'toolbox.log'
`$existing = (& `$azd ai toolbox list --project-endpoint '$ProjectEndpoint' 2>&1 | Out-String)
if (`$existing -match '$ToolboxName') {
    Write-Output 'toolbox already exists; leaving the current version in place'
} else {
    & `$azd ai toolbox create '$ToolboxName' --from-file (Join-Path `$root 'toolbox.yaml') --project-endpoint '$ProjectEndpoint' > `$toolboxLog 2>&1
    Write-Output ("toolbox exit=" + `$LASTEXITCODE)
    Get-Content `$toolboxLog | ForEach-Object { Write-Output `$_ }
}

Write-Output '--- deploy ---'
$deployLine
"@

    Set-Content -Path $remoteScript -Value $remote -Encoding utf8

    Write-Host 'Running on the jumpbox (this can take several minutes)...'
    $result = az vm run-command invoke `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroup `
        --name $VmName `
        --command-id RunPowerShellScript `
        --scripts "@$remoteScript" `
        --query 'value[].message' -o json
    if ($LASTEXITCODE -ne 0) { throw 'run-command failed.' }
    ($result | ConvertFrom-Json) | ForEach-Object { Write-Host $_ }
}
finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $remoteScript -Force -ErrorAction SilentlyContinue
}
