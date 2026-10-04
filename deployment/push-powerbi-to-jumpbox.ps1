<#
.SYNOPSIS
    Copies the Power BI project to the jumpbox.

.DESCRIPTION
    The model imports from a Databricks workspace with no public endpoint, so Power BI
    Desktop has to open the project from inside the VNet. This ships the PBIP folder to
    C:\powerbi on the jumpbox; opening and refreshing it is an interactive step over RDP.

    The committed model carries placeholder connection parameters. They are filled from
    deployment/environment.json in a staging copy, so the repository never holds the
    workspace hostname or warehouse ID.

    This replaces C:\powerbi on the jumpbox, including any unsaved or locally saved edits
    and the imported data cache, so refresh the model after running it.
#>
[CmdletBinding()]
param(
    [string] $RemotePath = 'C:\powerbi'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'DemoEnvironment.ps1')
$environment = Get-DemoEnvironment

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot 'powerbi'
if (-not (Test-Path $source)) { throw "Power BI project not found at $source" }

$staging = Join-Path ([System.IO.Path]::GetTempPath()) "pbi-stage-$([guid]::NewGuid())"
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "pbi-$([guid]::NewGuid()).zip"
$remoteScript = Join-Path ([System.IO.Path]::GetTempPath()) "pbi-push-$([guid]::NewGuid()).ps1"

try {
    Copy-Item -Path $source -Destination $staging -Recurse

    $expressions = Join-Path $staging 'FoodAnalytics.SemanticModel\definition\expressions.tmdl'
    $text = [IO.File]::ReadAllText($expressions)
    $text = $text.Replace('<databricks-host>', ([uri]$environment.WorkspaceUrl).Host)
    $text = $text.Replace('<sql-warehouse-id>', $environment.WarehouseId)
    if ($text -match '<[a-z-]+>') { throw 'Unreplaced placeholder remains in expressions.tmdl.' }
    [IO.File]::WriteAllText($expressions, $text, [Text.UTF8Encoding]::new($false))

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -Force
    $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipPath))
    Write-Host "Payload: $([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB"

    $remote = @"
`$ErrorActionPreference = 'Continue'
`$root = '$RemotePath'
if (Test-Path `$root) { Remove-Item `$root -Recurse -Force }
New-Item -ItemType Directory -Path `$root -Force | Out-Null
`$zip = Join-Path `$env:TEMP 'pbi.zip'
[IO.File]::WriteAllBytes(`$zip, [Convert]::FromBase64String('$payload'))
Expand-Archive -Path `$zip -DestinationPath `$root -Force
Remove-Item `$zip -Force
Get-ChildItem `$root -Recurse -File | ForEach-Object { Write-Output (`$_.FullName.Replace(`$root, '')) }
"@

    Set-Content -Path $remoteScript -Value $remote -Encoding utf8

    $result = az vm run-command invoke `
        --subscription $environment.SubscriptionId `
        --resource-group $environment.ResourceGroup `
        --name $environment.JumpboxName `
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
