<#
.SYNOPSIS
    Runs a jumpbox-*.ps1 script on the jumpbox with values from environment.json.

.DESCRIPTION
    Databricks and Foundry have no public endpoints, so their data-plane calls must come
    from inside the VNet. This sends the script through `az vm run-command` and fills each
    parameter the script declares from deployment/environment.json, so no environment
    identifier is hard-coded in the script itself.

    Explicit -Parameters override values from the file.

.EXAMPLE
    ./deployment/Invoke-OnJumpbox.ps1 ./deployment/jumpbox-demo-test.ps1

.EXAMPLE
    ./deployment/Invoke-OnJumpbox.ps1 ./deployment/jumpbox-warehouse.ps1 -Parameters @{ Action = 'stop' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path $_ })]
    [string] $Script,

    [hashtable] $Parameters = @{}
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DemoEnvironment.ps1')
$environment = Get-DemoEnvironment

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script).Path, [ref]$null, [ref]$null)
$declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

$arguments = foreach ($name in $declared) {
    if ($Parameters.ContainsKey($name)) {
        "$name=$($Parameters[$name])"
    }
    elseif ($environment.PSObject.Properties.Name -contains $name) {
        "$name=$($environment.$name)"
    }
}

$command = @(
    'vm', 'run-command', 'invoke',
    '--subscription', $environment.SubscriptionId,
    '--resource-group', $environment.ResourceGroup,
    '--name', $environment.JumpboxName,
    '--command-id', 'RunPowerShellScript',
    '--scripts', "@$Script",
    '--query', 'value[].message', '-o', 'json'
)
if ($arguments) { $command += @('--parameters') + @($arguments) }

Write-Host "Running $(Split-Path $Script -Leaf) on $($environment.JumpboxName)..."
$result = az @command
if ($LASTEXITCODE -ne 0) { throw 'run-command failed.' }

$messages = @($result | ConvertFrom-Json)
Write-Output $messages[0]
if ($messages.Count -gt 1 -and $messages[1].Trim()) {
    Write-Warning $messages[1]
}
