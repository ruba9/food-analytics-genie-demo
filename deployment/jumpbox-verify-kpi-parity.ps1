<#
.SYNOPSIS
    Checks that the agent's answers match the shared views the BI dashboard reads.

.DESCRIPTION
    Reads each headline figure straight from sales_kpi, then asks the agent the same
    question and prints both side by side. Any divergence means the agent is deriving
    its own number instead of returning the governed one.
#>
param(
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    [Parameter(Mandatory)] [string] $WarehouseId
)

$ErrorActionPreference = 'Continue'

$workspace = $WorkspaceUrl
$warehouseId = $WarehouseId

$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }

$state = (Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/sql/warehouses/$warehouseId" -Headers $h).state
if ($state -ne 'RUNNING') {
    Write-Output "warehouse is $state; start it before running this check"
    exit 1
}

$body = @{
    statement    = 'SELECT metric_name, metric_value, metric_unit FROM food_analytics.gold.sales_kpi ORDER BY metric_name'
    warehouse_id = $warehouseId
    wait_timeout = '50s'
} | ConvertTo-Json
$r = Invoke-RestMethod -Method Post -Uri "$workspace/api/2.0/sql/statements" -Headers $h -ContentType 'application/json' -Body $body

Write-Output '== dashboard values (from sales_kpi)'
$r.result.data_array | ForEach-Object { Write-Output ("  {0,-22} {1,16} {2}" -f $_[0], $_[1], $_[2]) }

$azd = 'C:\Program Files\Azure Dev CLI\azd.exe'
if (-not (Test-Path $azd)) { $azd = "$env:LOCALAPPDATA\Programs\Azure Dev CLI\azd.exe" }
$env:PATH = (Split-Path -Parent $azd) + ';' + $env:PATH
Set-Location 'C:\food-analytics'

$questions = @(
    'What is total net revenue?',
    'What is the gross margin percentage?',
    'What is the total food waste cost?'
)

foreach ($q in $questions) {
    Write-Output ''
    Write-Output "== agent: $q"
    $log = Join-Path $env:TEMP 'parity.log'
    # Each question must stand alone, or the agent answers from conversation context
    # instead of re-querying.
    & $azd ai agent invoke food-analytics-genie $q --new-session --new-conversation > $log 2>&1
    Get-Content $log |
        Where-Object { $_ -notmatch '^(Agent|Message|Session|Conversation|Trace ID|Response|Client elapsed|Platform latency|  preprocess):' -and $_.Trim() } |
        ForEach-Object { Write-Output $_ }
}
