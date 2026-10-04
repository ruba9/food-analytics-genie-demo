<#
.SYNOPSIS
    Registers version-pinned public CA certificate secrets on an existing Foundry account.

.DESCRIPTION
    Updates only properties.trustedCertificates and preserves every existing vault group and
    certificate reference. Certificate secret values and private keys are never read or printed.

.EXAMPLE
    .\Set-PrivateCaTrust.ps1 `
      -SubscriptionId "<subscription-id>" `
      -ResourceGroup "<resource-group>" `
      -AccountName "<foundry-account>" `
      -KeyVaultResourceId "<key-vault-resource-id>" `
      -CertificateReference @(
        "private-root-ca-pem=0123456789abcdef0123456789abcdef",
        "private-intermediate-ca-pem=fedcba9876543210fedcba9876543210"
      )
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.KeyVault/vaults/[^/]+$")]
    [string]$KeyVaultResourceId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$CertificateReference,

    [string]$AccountApiVersion = "2026-07-15-preview",

    [string]$OutputPath = "$PSScriptRoot\.foundry-recovery\private-ca-trust.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$OutputPath =
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPath
    )

function Invoke-ArmJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "PATCH")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [object]$Body
    )

    $arguments = @(
        "rest", "--method", $Method.ToLowerInvariant(), "--url", $Url,
        "--only-show-errors", "--output", "json"
    )
    $temporaryFile = $null
    try {
        if ($null -ne $Body) {
            $temporaryFile = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllText(
                $temporaryFile,
                ($Body | ConvertTo-Json -Depth 30),
                [Text.UTF8Encoding]::new($false)
            )
            $arguments += @(
                "--headers", "Content-Type=application/json",
                "--body", "@$temporaryFile"
            )
        }
        $raw = & az @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "ARM $Method failed for $Url."
        }
        if ([string]::IsNullOrWhiteSpace(($raw -join ""))) {
            return $null
        }
        return ($raw -join "`n") | ConvertFrom-Json
    }
    finally {
        if ($temporaryFile -and (Test-Path -LiteralPath $temporaryFile)) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
}

$certificates = @()
$seenNames = @{}
foreach ($reference in $CertificateReference) {
    if ($reference -notmatch "^(?<name>[A-Za-z0-9-]{1,127})=(?<version>[A-Za-z0-9]+)$") {
        throw "Invalid certificate reference '$reference'. Use <secret-name>=<secret-version>."
    }
    $name = $Matches["name"]
    $version = $Matches["version"]
    if ($seenNames.ContainsKey($name)) {
        throw "Duplicate certificate secret name: $name."
    }
    $seenNames[$name] = $true
    $certificates += [ordered]@{ name = $name; version = $version }
}

$accountId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/" +
    "Microsoft.CognitiveServices/accounts/$AccountName"
$accountUrl = "https://management.azure.com${accountId}?api-version=$AccountApiVersion"
$account = Invoke-ArmJson -Method GET -Url $accountUrl
$existingGroups = @()
$trustProperty = $account.properties.PSObject.Properties["trustedCertificates"]
if ($null -ne $trustProperty -and $null -ne $trustProperty.Value) {
    $existingGroups = @($trustProperty.Value)
}

$updatedGroups = @()
$matchingCertificates = @()
foreach ($group in $existingGroups) {
    if ([string]$group.keyVaultId -ieq $KeyVaultResourceId) {
        $matchingCertificates += @($group.certificates)
    }
    else {
        $updatedGroups += $group
    }
}
$preserved = @(
    $matchingCertificates |
        Where-Object { -not $seenNames.ContainsKey([string]$_.name) }
)
$updatedGroups += [ordered]@{
    keyVaultId = $KeyVaultResourceId
    certificates = @($preserved) + @($certificates)
}

if (-not $PSCmdlet.ShouldProcess(
    $accountId,
    "Replace properties.trustedCertificates while preserving existing references"
)) {
    return
}

Invoke-ArmJson -Method PATCH -Url $accountUrl -Body @{
    properties = @{ trustedCertificates = $updatedGroups }
} | Out-Null

$stored = Invoke-ArmJson -Method GET -Url $accountUrl
$storedGroups = @($stored.properties.trustedCertificates)
foreach ($certificate in $certificates) {
    $match = @(
        $storedGroups |
            Where-Object { [string]$_.keyVaultId -ieq $KeyVaultResourceId } |
            ForEach-Object { @($_.certificates) } |
            Where-Object {
                [string]$_.name -eq $certificate.name -and
                [string]$_.version -eq $certificate.version
            }
    )
    if ($match.Count -ne 1) {
        throw "Foundry didn't persist $($certificate.name) at version $($certificate.version)."
    }
}

$report = [ordered]@{
    capturedAtUtc = [DateTime]::UtcNow.ToString("o")
    accountResourceId = $accountId
    accountApiVersion = $AccountApiVersion
    keyVaultResourceId = $KeyVaultResourceId
    certificates = $certificates
    trustedCertificates = $storedGroups
    nextStep = "Export agents, then recreate the project capability host with Recreate-CapabilityHostAndAgents.ps1."
}
$parent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
[IO.File]::WriteAllText(
    $OutputPath,
    ($report | ConvertTo-Json -Depth 30),
    [Text.UTF8Encoding]::new($false)
)
$report | ConvertTo-Json -Depth 30
