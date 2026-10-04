<#
Full demo rehearsal, run on the jumpbox.

Starts the SQL warehouse, waits for it to be RUNNING, then asks the deployed agent a
series of questions. Run this before a demo: a cold classic warehouse takes minutes to
start and Genie times out against it, which surfaces as the agent saying the query failed.

Authenticates with the jumpbox managed identity, which is registered in Databricks as
jumpbox-operations with CAN_USE on the warehouse.
#>
param(
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    [Parameter(Mandatory)] [string] $WarehouseId
)

$ErrorActionPreference = 'Continue'

$warehouseId = $WarehouseId
$workspace = $WorkspaceUrl

Clear-DnsClientCache
$resolved = (Resolve-DnsName ([uri]$workspace).Host -Type A -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }) -join ', '
Write-Output "== workspace resolves to: $resolved"

$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }

$state = (Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/sql/warehouses/$warehouseId" -Headers $h).state
Write-Output "== warehouse state: $state"

if ($state -ne 'RUNNING') {
    Write-Output '== starting warehouse'
    try { Invoke-RestMethod -Method Post -Uri "$workspace/api/2.0/sql/warehouses/$warehouseId/start" -Headers $h -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 20
        $state = (Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/sql/warehouses/$warehouseId" -Headers $h).state
    } while ($state -ne 'RUNNING' -and (Get-Date) -lt $deadline)
    Write-Output "== warehouse state: $state"
}

if ($state -ne 'RUNNING') {
    Write-Output '== ABORT: warehouse did not reach RUNNING'
    exit 1
}

$azd = 'C:\Program Files\Azure Dev CLI\azd.exe'
if (-not (Test-Path $azd)) { $azd = "$env:LOCALAPPDATA\Programs\Azure Dev CLI\azd.exe" }
$env:PATH = (Split-Path -Parent $azd) + ';' + $env:PATH
Set-Location 'C:\food-analytics'

$questions = @(
    'Which product categories generated the most net revenue in 2025?',
    # Without a year Genie picks an arbitrary single month, so the answer changes between runs.
    'Which ten products had the highest food waste cost in 2025, and what were the main waste reasons?',
    'Compare gross margin percentage by store region for 2025.'
)

foreach ($q in $questions) {
    Write-Output ''
    Write-Output "== Q: $q"
    $log = Join-Path $env:TEMP 'demo.log'
    & $azd ai agent invoke food-analytics-genie $q --new-session --new-conversation > $log 2>&1
    Write-Output ("exit=" + $LASTEXITCODE)
    Get-Content $log | Where-Object { $_ -notmatch '^(Agent|Message|Session|Conversation|Trace ID|Response):' } | ForEach-Object { Write-Output $_ }
}
