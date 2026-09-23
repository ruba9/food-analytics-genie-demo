<#
.SYNOPSIS
    Renames the Unity Catalog catalog and creates the shared metric views.

.DESCRIPTION
    MUST be run from inside the virtual network (jump box, Bastion, or VPN).
    The workspace has public network access disabled, so its REST API resolves to a
    private IP that is unreachable from a normal workstation.

    The view definitions are read from sql/01_genie_dataset.sql so this script and the
    bootstrap script cannot drift apart on the metric definitions.

.EXAMPLE
    ./setup-metric-views.ps1 -WorkspaceUrl 'https://adb-123.19.azuredatabricks.net' -CurrentCatalogName 'dbx_vdm_ne'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceUrl,
    [string]$ProfileName = 'DEFAULT',

    # Leave empty to skip the rename and create the views in -CatalogName as it is today.
    [string]$CurrentCatalogName = '',

    [string]$CatalogName = 'food_analytics',
    [string]$WarehouseName = 'genie-warehouse'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) {
    throw 'Databricks CLI not found. Install with: winget install Databricks.CLI'
}

$dbx = @('--profile', $ProfileName)

$me = databricks current-user me @dbx 2>&1 | ConvertFrom-Json
if (-not $me.userName) {
    throw "Not authenticated. Run: databricks auth login --host $WorkspaceUrl --profile $ProfileName"
}
Write-Host "Authenticated as $($me.userName)"

$warehouse = (databricks warehouses list -o json @dbx | ConvertFrom-Json) |
    Where-Object { $_.name -eq $WarehouseName } | Select-Object -First 1
if (-not $warehouse) {
    throw "SQL warehouse '$WarehouseName' not found. Create it first or pass -WarehouseName."
}
Write-Host "Using warehouse '$WarehouseName' ($($warehouse.id))"

function Invoke-Sql {
    param([string]$Statement, [switch]$ReturnRows)

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # Windows PowerShell 5.1 writes a BOM for -Encoding utf8, which the CLI rejects.
        $json = @{ statement = $Statement; warehouse_id = $warehouse.id; wait_timeout = '50s' } |
            ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
        $result = databricks api post '/api/2.0/sql/statements' --json "@$tmp" @dbx 2>&1 | ConvertFrom-Json
    }
    finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }

    # wait_timeout caps at 50s; longer statements finish asynchronously.
    while ($result.status.state -in @('PENDING', 'RUNNING')) {
        Start-Sleep -Seconds 5
        $result = databricks api get "/api/2.0/sql/statements/$($result.statement_id)" @dbx | ConvertFrom-Json
    }

    if ($result.status.state -ne 'SUCCEEDED') {
        throw "Statement failed: $($result.status.error.message)"
    }
    if ($ReturnRows) { return $result.result.data_array }
}

# --- Rename ----------------------------------------------------------------
if ($CurrentCatalogName -and $CurrentCatalogName -ne $CatalogName) {
    $catalogs = (databricks catalogs list -o json @dbx | ConvertFrom-Json).name

    if ($catalogs -contains $CatalogName) {
        Write-Host "Catalog '$CatalogName' already exists; skipping rename." -ForegroundColor Yellow
    }
    elseif ($catalogs -notcontains $CurrentCatalogName) {
        throw "Catalog '$CurrentCatalogName' not found. Available: $($catalogs -join ', ')"
    }
    else {
        Write-Host "Renaming catalog '$CurrentCatalogName' to '$CatalogName'..."
        Invoke-Sql "ALTER CATALOG ``$CurrentCatalogName`` RENAME TO ``$CatalogName``"
        Write-Host "Renamed. Existing references to '$CurrentCatalogName' must be repointed." -ForegroundColor Yellow
    }
}

# --- Views -----------------------------------------------------------------
# Single source of truth: take the view DDL straight from the dataset script.
$sqlFile = Join-Path $root 'sql/01_genie_dataset.sql'
$sqlText = (Get-Content $sqlFile -Raw) -replace 'food_analytics\.', "$CatalogName."

$viewStatements = $sqlText -split ';\s*\r?\n' |
    ForEach-Object { ($_ -split '\r?\n' | Where-Object { $_ -notmatch '^\s*--' }) -join "`n" } |
    Where-Object { $_ -match '(?i)CREATE\s+OR\s+REPLACE\s+VIEW' }

if ($viewStatements.Count -ne 2) {
    throw "Expected 2 view definitions in $sqlFile, found $($viewStatements.Count)."
}

foreach ($stmt in $viewStatements) {
    $name = ([regex]::Match($stmt, '(?i)CREATE\s+OR\s+REPLACE\s+VIEW\s+(\S+)')).Groups[1].Value
    Write-Host "Creating view $name ..."
    Invoke-Sql $stmt
}

# --- Ground truth ----------------------------------------------------------
Write-Host "`nCanonical KPI values ($CatalogName.sales.sales_kpi):" -ForegroundColor Green
$rows = Invoke-Sql "SELECT metric_name, metric_value, metric_unit FROM $CatalogName.sales.sales_kpi ORDER BY metric_name" -ReturnRows

$rows | ForEach-Object {
    [pscustomobject]@{ Metric = $_[0]; Value = $_[1]; Unit = $_[2] }
} | Format-Table -AutoSize

Write-Host @"
These are the values the Power BI KPI cards and the agent must both return.
Screenshot this table before comparing.

Remaining manual steps (no API available):
  1. Genie space  - remove the four raw tables, add only:
                      $CatalogName.sales.sales_analytics
                      $CatalogName.sales.sales_kpi
  2. Databricks   - generate a new access token.
  3. Foundry      - update the 'databricks-genie-mcp' connection to 'Bearer <token>'.
  4. Agent        - run src/genie_agent.py to create a new agent version.
  5. Power BI     - open powerbi/FoodAnalytics.pbip and set CatalogName = $CatalogName
"@
