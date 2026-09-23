<#
.SYNOPSIS
    Safely exports agents, recreates a project capability host, and redeploys agents.

.DESCRIPTION
    A project capability-host deletion is destructive. This script first captures:
      - the writable capability-host properties and connection references;
      - Prompt Agent definitions through the supported Foundry Agent API;
      - container-based Hosted Agent definitions and image references;
      - direct role assignments for version identities in selected subscriptions;
      - agent endpoint routing.

    It can then delete/recreate the host and replay the selected agent versions. It never
    reads or writes the Agent Service Cosmos DB containers directly.

.EXAMPLE
    # Non-destructive backup and preflight.
    .\Recreate-CapabilityHostAndAgents.ps1 `
      -Mode Export `
      -SubscriptionId "<subscription-id>" `
      -ResourceGroup "<resource-group>" `
      -AccountName "<foundry-account>" `
      -ProjectName "<project>"

.EXAMPLE
    # Destructive recreate using an existing export.
    .\Recreate-CapabilityHostAndAgents.ps1 `
      -Mode Recreate `
      -SubscriptionId "<subscription-id>" `
      -ResourceGroup "<resource-group>" `
      -AccountName "<foundry-account>" `
      -ProjectName "<project>" `
      -RecoveryDirectory ".\.foundry-recovery\20260914T180000Z" `
      -AcknowledgeDataLoss
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Export", "Recreate", "RestoreAgents", "Validate")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [string]$ProjectCapabilityHostName = "",

    [switch]$RecreateAccountCapabilityHost,

    [string]$AccountCapabilityHostName = "",

    [string]$ProjectEndpoint = "",

    [string]$RecoveryDirectory = "",

    [switch]$AcknowledgeDataLoss,

    [switch]$RestoreAllAgentVersions,

    [switch]$SkipAgentRoleAssignments,

    [switch]$SkipUnsupportedAgents,

    [string[]]$RoleAssignmentSubscriptionId = @(),

    [ValidateRange(5, 90)]
    [int]$TimeoutMinutes = 30,

    [string]$CapabilityHostApiVersion = "2025-06-01",

    [string]$ProjectConnectionApiVersion = "2025-04-01-preview",

    [string]$PythonExecutable = "python"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$agentTool = Join-Path $PSScriptRoot "agent_recovery.py"
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
if ([string]::IsNullOrWhiteSpace($RecoveryDirectory)) {
    $RecoveryDirectory = Join-Path (Join-Path $PSScriptRoot ".foundry-recovery") $timestamp
}
$RecoveryDirectory =
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $RecoveryDirectory
    )
$capabilityManifestPath = Join-Path $RecoveryDirectory "capability-hosts.json"
$agentManifestPath = Join-Path $RecoveryDirectory "agents.json"
$agentRestoreReportPath = Join-Path $RecoveryDirectory "agent-restore-report.json"
$recoveryReportPath = Join-Path $RecoveryDirectory "recovery-report.json"

function Write-JsonFile {
    param([string]$Path, [object]$Value)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 40),
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-CapabilityManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedAccountId,
        [Parameter(Mandatory = $true)][string]$ExpectedProjectId,
        [Parameter(Mandatory = $true)][string]$ExpectedProjectEndpoint,
        [Parameter(Mandatory = $true)][string]$ExpectedCapabilityHostApiVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedConnectionApiVersion
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Capability-host recovery manifest not found: $Path"
    }
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $schemaProperty = $manifest.PSObject.Properties["schemaVersion"]
    if ($null -eq $schemaProperty -or [int]$schemaProperty.Value -ne 1) {
        throw "Unsupported capability-host recovery manifest schema."
    }
    if (
        [string]$manifest.accountResourceId -ne $ExpectedAccountId -or
        [string]$manifest.projectResourceId -ne $ExpectedProjectId -or
        [string]$manifest.projectEndpoint -ne $ExpectedProjectEndpoint
    ) {
        throw "Capability-host manifest doesn't match the requested account and project."
    }
    if (
        [string]$manifest.capabilityHostApiVersion -ne
        $ExpectedCapabilityHostApiVersion
    ) {
        throw (
            "Capability-host manifest API version doesn't match " +
            "-CapabilityHostApiVersion."
        )
    }
    if (
        [string]$manifest.projectConnectionApiVersion -ne
        $ExpectedConnectionApiVersion
    ) {
        throw (
            "Capability-host manifest connection API version doesn't match " +
            "-ProjectConnectionApiVersion."
        )
    }
    $projectHostProperty = $manifest.PSObject.Properties["projectCapabilityHost"]
    if (
        $null -eq $projectHostProperty -or
        [string]::IsNullOrWhiteSpace([string]$projectHostProperty.Value.name) -or
        $null -eq $projectHostProperty.Value.properties
    ) {
        throw "Capability-host manifest is missing the project host definition."
    }
    return $manifest
}

function Invoke-AzJson {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $raw = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
    if ([string]::IsNullOrWhiteSpace(($raw -join ""))) {
        return $null
    }
    return ($raw -join "`n") | ConvertFrom-Json
}

function Invoke-ArmJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "PUT", "DELETE")]
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
                ($Body | ConvertTo-Json -Depth 40),
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

function Get-ArmJsonOrNull {
    param([Parameter(Mandatory = $true)][string]$Url)

    $raw = & az rest --method get --url $Url --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -eq 0) {
        return ($raw -join "`n") | ConvertFrom-Json
    }
    $message = $raw -join "`n"
    if ($message -match "(?i)(ResourceNotFound|NotFound|status code 404|\(404\))") {
        return $null
    }
    throw "ARM GET failed for $Url. $message"
}

function Get-ArmCollection {
    param([Parameter(Mandatory = $true)][string]$Url)

    $items = @()
    $next = $Url
    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $page = Invoke-ArmJson -Method GET -Url $next
        $items += @($page.value)
        $nextProperty = $page.PSObject.Properties["nextLink"]
        $next = if ($null -eq $nextProperty) { "" } else { [string]$nextProperty.Value }
    }
    return $items
}

function Get-WritableCapabilityHostProperties {
    param([Parameter(Mandatory = $true)][object]$CapabilityHost)

    $result = [ordered]@{}
    foreach ($name in @(
        "capabilityHostKind",
        "vectorStoreConnections",
        "storageConnections",
        "threadStorageConnections",
        "customerSubnet",
        "acaEnvironmentConnections",
        "aiServicesConnections",
        "enablePublicHostingEnvironment"
    )) {
        $property = $CapabilityHost.properties.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $result[$name] = $property.Value
        }
    }
    if (-not $result.Contains("capabilityHostKind")) {
        $result["capabilityHostKind"] = "Agents"
    }
    return $result
}

function Select-CapabilityHost {
    param(
        [Parameter(Mandatory = $true)][object[]]$Hosts,
        [string]$RequestedName,
        [Parameter(Mandatory = $true)][string]$ScopeLabel
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedName)) {
        $matches = @($Hosts | Where-Object { [string]$_.name -eq $RequestedName })
        if ($matches.Count -ne 1) {
            throw "$ScopeLabel capability host '$RequestedName' wasn't found."
        }
        return $matches[0]
    }
    if ($Hosts.Count -ne 1) {
        throw "$ScopeLabel must contain exactly one capability host or you must specify its name. Found: $($Hosts.Count)."
    }
    return $Hosts[0]
}

function Test-CapabilityHostConnections {
    param(
        [Parameter(Mandatory = $true)][object]$Properties,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ConnectionNames
    )

    $required = @()
    foreach ($name in @(
        "vectorStoreConnections",
        "storageConnections",
        "threadStorageConnections",
        "acaEnvironmentConnections",
        "aiServicesConnections"
    )) {
        if ($Properties.Contains($name)) {
            $required += @($Properties[$name])
        }
    }
    $missing = @(
        $required |
            Where-Object { $_ -and [string]$_ -notin $ConnectionNames } |
            Select-Object -Unique
    )
    if ($missing.Count -gt 0) {
        throw "Capability host references missing project connections: $($missing -join ', ')."
    }
}

function Remove-CapabilityHost {
    param([Parameter(Mandatory = $true)][string]$Url, [string]$Label)

    $existing = Get-ArmJsonOrNull -Url $Url
    if ($null -eq $existing) {
        Write-Host "$Label capability host is already absent."
        return
    }
    Invoke-ArmJson -Method DELETE -Url $Url | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 10
        if ($null -eq (Get-ArmJsonOrNull -Url $Url)) {
            Write-Host "$Label capability host deleted."
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Label capability host deletion didn't finish within $TimeoutMinutes minutes."
}

function New-CapabilityHost {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][object]$Properties,
        [string]$Label
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        try {
            Invoke-ArmJson -Method PUT -Url $Url -Body @{ properties = $Properties } |
                Out-Null
            break
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw
            }
            Write-Host "$Label capability host isn't ready to recreate; retrying in 15 seconds."
            Start-Sleep -Seconds 15
        }
    } while ($true)

    do {
        $hostResource = Get-ArmJsonOrNull -Url $Url
        $state = if ($null -eq $hostResource) {
            "NotFound"
        }
        else {
            [string]$hostResource.properties.provisioningState
        }
        if ($state -eq "Succeeded") {
            Write-Host "$Label capability host recreated."
            return $hostResource
        }
        if ($state -in @("Failed", "Canceled")) {
            throw "$Label capability host recreation failed with state $state."
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "$Label capability host recreation didn't succeed within $TimeoutMinutes minutes. Last state: $state."
        }
        Write-Host "$Label capability host state: $state"
        Start-Sleep -Seconds 10
    } while ($true)
}

function Invoke-AgentRecovery {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("export", "restore", "validate")]
        [string]$Action,

        [switch]$RequireRecoverable
    )

    if (-not (Test-Path -LiteralPath $agentTool)) {
        throw "Agent recovery helper is missing: $agentTool"
    }
    & $PythonExecutable -c "import azure.ai.projects, azure.identity, httpx" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Install dependencies first: $PythonExecutable -m pip install -r `"$PSScriptRoot\requirements.txt`""
    }
    if ($Action -eq "export") {
        $arguments = @(
            $agentTool, "export",
            "--project-endpoint", $ProjectEndpoint,
            "--output", $agentManifestPath
        )
        foreach ($subscription in $RoleAssignmentSubscriptionId) {
            $arguments += @("--role-subscription-id", $subscription)
        }
        if ($RestoreAllAgentVersions) {
            $arguments += "--restore-all-versions"
        }
        if ($SkipAgentRoleAssignments) {
            $arguments += "--skip-role-assignments"
        }
        if ($SkipUnsupportedAgents) {
            $arguments += "--skip-unsupported-agents"
        }
    }
    elseif ($Action -eq "restore") {
        $arguments = @(
            $agentTool, "restore",
            "--project-endpoint", $ProjectEndpoint,
            "--manifest", $agentManifestPath,
            "--output", $agentRestoreReportPath,
            "--version-timeout-seconds", [string]($TimeoutMinutes * 60)
        )
        if ($RestoreAllAgentVersions) {
            $arguments += "--restore-all-versions"
        }
        if ($SkipAgentRoleAssignments) {
            $arguments += "--skip-role-assignments"
        }
    }
    else {
        $arguments = @($agentTool, "validate", "--manifest", $agentManifestPath)
        if ($RequireRecoverable) {
            $arguments += "--require-recoverable"
            if ($RestoreAllAgentVersions) {
                $arguments += "--restore-all-versions"
            }
        }
    }
    & $PythonExecutable @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Agent recovery helper action '$Action' failed."
    }
}

$null = Invoke-AzJson account show --subscription $SubscriptionId
if ($RoleAssignmentSubscriptionId.Count -eq 0) {
    $RoleAssignmentSubscriptionId = @($SubscriptionId)
}

$accountId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/" +
    "Microsoft.CognitiveServices/accounts/$AccountName"
$projectId = "$accountId/projects/$ProjectName"
if ([string]::IsNullOrWhiteSpace($ProjectEndpoint)) {
    $account = Invoke-AzJson cognitiveservices account show `
        --subscription $SubscriptionId --resource-group $ResourceGroup --name $AccountName
    $endpointProperty = $account.properties.endpoints.PSObject.Properties["AI Foundry API"]
    if ($null -eq $endpointProperty -or [string]::IsNullOrWhiteSpace([string]$endpointProperty.Value)) {
        throw "The account doesn't expose an AI Foundry API endpoint."
    }
    $ProjectEndpoint = ([string]$endpointProperty.Value).TrimEnd("/") +
        "/api/projects/$ProjectName"
}
$ProjectEndpoint = $ProjectEndpoint.TrimEnd("/")

if ($Mode -eq "Validate") {
    $null = Read-CapabilityManifest `
        -Path $capabilityManifestPath `
        -ExpectedAccountId $accountId `
        -ExpectedProjectId $projectId `
        -ExpectedProjectEndpoint $ProjectEndpoint `
        -ExpectedCapabilityHostApiVersion $CapabilityHostApiVersion `
        -ExpectedConnectionApiVersion $ProjectConnectionApiVersion
    Invoke-AgentRecovery -Action validate -RequireRecoverable
    return
}

if ($Mode -eq "RestoreAgents") {
    if (-not (Test-Path -LiteralPath $agentManifestPath)) {
        throw "Agent recovery manifest not found: $agentManifestPath"
    }
    Invoke-AgentRecovery -Action restore
    return
}

New-Item -ItemType Directory -Path $RecoveryDirectory -Force | Out-Null
$hasCapabilityManifest = Test-Path -LiteralPath $capabilityManifestPath
$hasAgentManifest = Test-Path -LiteralPath $agentManifestPath
if ($Mode -eq "Export" -and ($hasCapabilityManifest -or $hasAgentManifest)) {
    throw "Export won't overwrite recovery manifests. Use a new recovery directory."
}
$useExistingExport = (
    $Mode -eq "Recreate" -and
    $hasCapabilityManifest -and
    $hasAgentManifest
)
if ($useExistingExport) {
    $capabilityManifest = Read-CapabilityManifest `
        -Path $capabilityManifestPath `
        -ExpectedAccountId $accountId `
        -ExpectedProjectId $projectId `
        -ExpectedProjectEndpoint $ProjectEndpoint `
        -ExpectedCapabilityHostApiVersion $CapabilityHostApiVersion `
        -ExpectedConnectionApiVersion $ProjectConnectionApiVersion
    $ProjectCapabilityHostName =
        [string]$capabilityManifest.projectCapabilityHost.name
    $projectProperties = [ordered]@{}
    foreach ($property in $capabilityManifest.projectCapabilityHost.properties.PSObject.Properties) {
        $projectProperties[$property.Name] = $property.Value
    }
    $accountRecord = $capabilityManifest.accountCapabilityHost
    if ($RecreateAccountCapabilityHost -and $null -eq $accountRecord) {
        throw "The existing export doesn't contain an account capability host."
    }
    if ($null -ne $accountRecord) {
        $AccountCapabilityHostName = [string]$accountRecord.name
    }
    Invoke-AgentRecovery -Action validate
    Write-Host "Using existing recovery export: $RecoveryDirectory"
}
else {
    if ($hasCapabilityManifest -xor $hasAgentManifest) {
        throw "Recovery directory contains only one manifest. Use a new directory or restore the missing file."
    }
    $projectListUrl = "https://management.azure.com$projectId/capabilityHosts" +
        "?api-version=$CapabilityHostApiVersion"
    $projectHosts = @(Get-ArmCollection -Url $projectListUrl)
    $projectHost = Select-CapabilityHost -Hosts $projectHosts `
        -RequestedName $ProjectCapabilityHostName -ScopeLabel "Project"
    $ProjectCapabilityHostName = [string]$projectHost.name
    $projectProperties = Get-WritableCapabilityHostProperties -CapabilityHost $projectHost

    $connectionUrl = "https://management.azure.com$projectId/connections" +
        "?api-version=$ProjectConnectionApiVersion"
    $connections = @(Get-ArmCollection -Url $connectionUrl)
    $connectionNames = @($connections | ForEach-Object { [string]$_.name })
    Test-CapabilityHostConnections `
        -Properties $projectProperties -ConnectionNames $connectionNames

    $accountRecord = $null
    if ($RecreateAccountCapabilityHost) {
        $accountListUrl = "https://management.azure.com$accountId/capabilityHosts" +
            "?api-version=$CapabilityHostApiVersion"
        $accountHosts = @(Get-ArmCollection -Url $accountListUrl)
        $accountHost = Select-CapabilityHost -Hosts $accountHosts `
            -RequestedName $AccountCapabilityHostName -ScopeLabel "Account"
        $AccountCapabilityHostName = [string]$accountHost.name
        $accountRecord = [ordered]@{
            name = $AccountCapabilityHostName
            properties = Get-WritableCapabilityHostProperties -CapabilityHost $accountHost
        }
    }

    $capabilityManifest = [ordered]@{
        schemaVersion = 1
        capturedAtUtc = [DateTime]::UtcNow.ToString("o")
        accountResourceId = $accountId
        projectResourceId = $projectId
        projectEndpoint = $ProjectEndpoint
        capabilityHostApiVersion = $CapabilityHostApiVersion
        projectConnectionApiVersion = $ProjectConnectionApiVersion
        accountCapabilityHost = $accountRecord
        projectCapabilityHost = [ordered]@{
            name = $ProjectCapabilityHostName
            properties = $projectProperties
        }
        validatedProjectConnections = $connectionNames
    }
    Write-JsonFile -Path $capabilityManifestPath -Value $capabilityManifest
    Invoke-AgentRecovery -Action export
    Invoke-AgentRecovery -Action validate
}

$currentConnectionsUrl = "https://management.azure.com$projectId/connections" +
    "?api-version=$ProjectConnectionApiVersion"
$currentConnections = @(Get-ArmCollection -Url $currentConnectionsUrl)
$currentConnectionNames = @($currentConnections | ForEach-Object { [string]$_.name })
Test-CapabilityHostConnections `
    -Properties $projectProperties -ConnectionNames $currentConnectionNames

Write-Host "Recovery export completed: $RecoveryDirectory"
if ($Mode -eq "Export") {
    return
}
Invoke-AgentRecovery -Action validate -RequireRecoverable

if (-not $AcknowledgeDataLoss) {
    throw (
        "Recreate is destructive and permanently orphans existing agent/thread state. " +
        "Review the exported manifests, then rerun with -AcknowledgeDataLoss."
    )
}
if (-not $PSCmdlet.ShouldProcess(
    "$AccountName/$ProjectName",
    "Delete/recreate capability host and redeploy exported agent definitions"
)) {
    return
}

$projectHostUrl = "https://management.azure.com$projectId/capabilityHosts/" +
    "${ProjectCapabilityHostName}?api-version=$CapabilityHostApiVersion"
$accountHostUrl = if ($RecreateAccountCapabilityHost) {
    "https://management.azure.com$accountId/capabilityHosts/" +
        "${AccountCapabilityHostName}?api-version=$CapabilityHostApiVersion"
}
else {
    $null
}

Remove-CapabilityHost -Url $projectHostUrl -Label "Project"
if ($RecreateAccountCapabilityHost) {
    Remove-CapabilityHost -Url $accountHostUrl -Label "Account"
    $null = New-CapabilityHost -Url $accountHostUrl `
        -Properties $accountRecord.properties -Label "Account"
}
$restoredProjectHost = New-CapabilityHost -Url $projectHostUrl `
    -Properties $projectProperties -Label "Project"

Invoke-AgentRecovery -Action restore
$agentReport = Get-Content -LiteralPath $agentRestoreReportPath -Raw | ConvertFrom-Json
$report = [ordered]@{
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    accountResourceId = $accountId
    projectResourceId = $projectId
    projectEndpoint = $ProjectEndpoint
    recoveryDirectory = $RecoveryDirectory
    capabilityHostApiVersion = $CapabilityHostApiVersion
    projectConnectionApiVersion = $ProjectConnectionApiVersion
    projectCapabilityHost = [ordered]@{
        name = $ProjectCapabilityHostName
        provisioningState = $restoredProjectHost.properties.provisioningState
        properties = $projectProperties
    }
    accountCapabilityHostRecreated = [bool]$RecreateAccountCapabilityHost
    agentRestoreState = $agentReport.state
    agentRestoreReport = $agentRestoreReportPath
}
Write-JsonFile -Path $recoveryReportPath -Value $report
$report | ConvertTo-Json -Depth 30
