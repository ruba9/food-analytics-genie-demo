<#
.SYNOPSIS
    Creates a serverless SQL warehouse and loads the Genie sample dataset.

.DESCRIPTION
    MUST be run from inside the virtual network (jump box, Bastion, or VPN).
    The workspace is deployed with public network access disabled, so its REST API
    resolves to a private IP that is unreachable from a normal workstation.

    Prerequisites:
      winget install Databricks.CLI
      databricks configure --host https://<workspace-url>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceUrl,
    [string]$ProfileName = 'DEFAULT',
    [string]$CatalogName = '',
    [string]$WarehouseName = 'genie-warehouse',
    [ValidateSet('2X-Small', 'X-Small', 'Small', 'Medium')][string]$WarehouseSize = '2X-Small'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) {
    throw 'Databricks CLI not found. Install with: winget install Databricks.CLI'
}

# Resolve credentials from the named profile rather than DATABRICKS_HOST, which
# selects host-based auth and fails when no matching credentials are cached.
$dbx = @('--profile', $ProfileName)

$me = databricks current-user me @dbx 2>&1 | ConvertFrom-Json
if (-not $me.userName) {
    throw "Not authenticated. Run: databricks auth login --host $WorkspaceUrl --profile $ProfileName"
}
Write-Host "Authenticated as $($me.userName)"

function Invoke-DbxApi {
    param([string]$Method, [string]$Path, [hashtable]$Body)

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # Windows PowerShell 5.1 emits a BOM for -Encoding utf8, which the CLI rejects
        # as an invalid leading character. PowerShell 7 does not, so this only bites on 5.1.
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
        $raw = databricks api $Method $Path --json "@$tmp" @dbx 2>&1
        if ($LASTEXITCODE -ne 0) { throw "API $Method $Path failed: $raw" }
        return $raw | ConvertFrom-Json
    }
    finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# --- Warehouse -------------------------------------------------------------
$existing = (databricks warehouses list -o json @dbx | ConvertFrom-Json) |
    Where-Object { $_.name -eq $WarehouseName } | Select-Object -First 1

if ($existing) {
    $warehouseId = $existing.id
    Write-Host "Reusing warehouse '$WarehouseName' ($warehouseId)"
}
else {
    # Genie requires a Pro or Serverless warehouse; Classic is not supported.
    $created = Invoke-DbxApi -Method post -Path '/api/2.0/sql/warehouses' -Body @{
        name                      = $WarehouseName
        cluster_size              = $WarehouseSize
        max_num_clusters          = 1
        auto_stop_mins            = 10
        enable_serverless_compute = $true
        warehouse_type            = 'PRO'
    }
    $warehouseId = $created.id
    Write-Host "Created warehouse '$WarehouseName' ($warehouseId)"
}

# --- Catalog ---------------------------------------------------------------
# Classic (non-serverless) workspaces cannot create catalogs on default storage,
# so the dataset lands in an existing catalog instead of a purpose-made one.
if (-not $CatalogName) {
    $catalogs = databricks catalogs list -o json @dbx | ConvertFrom-Json
    $candidate = $catalogs |
        Where-Object { $_.name -notin @('system', 'samples', 'hive_metastore', '__databricks_internal') } |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No usable catalog found. Create one in Catalog Explorer, then re-run with -CatalogName <name>."
    }
    $CatalogName = $candidate.name
}
Write-Host "Using catalog '$CatalogName'"

# --- Dataset ---------------------------------------------------------------
$sqlFile = Join-Path $root 'sql/01_genie_dataset.sql'
$sqlText = (Get-Content $sqlFile -Raw) -replace 'food_analytics\.', "$CatalogName."

$statements = $sqlText -split ';\s*\r?\n' |
    ForEach-Object {
        # Drop comment-only fragments so they are not sent as empty statements.
        ($_ -split '\r?\n' | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
    } |
    Where-Object { $_.Trim() -ne '' -and $_ -notmatch '(?i)^\s*CREATE\s+CATALOG' }

Write-Host "Executing $($statements.Count) statements..."

$i = 0
foreach ($stmt in $statements) {
    $i++
    $label = ($stmt.Trim() -split '\r?\n')[0]
    if ($label.Length -gt 70) { $label = $label.Substring(0, 70) + '...' }

    # No default catalog is set; every object in the SQL file is fully qualified.
    $result = Invoke-DbxApi -Method post -Path '/api/2.0/sql/statements' -Body @{
        statement    = $stmt
        warehouse_id = $warehouseId
        wait_timeout = '50s'
    }

    # wait_timeout caps at 50s; longer statements finish asynchronously.
    while ($result.status.state -in @('PENDING', 'RUNNING')) {
        Start-Sleep -Seconds 5
        $result = databricks api get "/api/2.0/sql/statements/$($result.statement_id)" @dbx | ConvertFrom-Json
    }

    if ($result.status.state -ne 'SUCCEEDED') {
        throw "Statement $i failed ($label): $($result.status.error.message)"
    }
    Write-Host ("  [{0}/{1}] {2}" -f $i, $statements.Count, $label)
}

Write-Host "`nDataset loaded." -ForegroundColor Green
Write-Host "Warehouse ID: $warehouseId"
Write-Host @"

Next, create the Genie space in the Databricks UI:
  1. SQL > Genie > New space, attached to warehouse '$WarehouseName'.
  2. Add views: $CatalogName.sales.sales_kpi and $CatalogName.sales.sales_analytics.
      These views are the shared metric contract for Genie and Power BI.
  3. Copy the space ID from the URL (/genie/rooms/<space-id>).

Then set GENIE_MCP_URL for the agent:
  $WorkspaceUrl/api/2.0/mcp/genie/<space-id>
"@
