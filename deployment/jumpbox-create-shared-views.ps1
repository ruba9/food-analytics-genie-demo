<#
.SYNOPSIS
    Creates the shared views that both Power BI and Genie read, and repoints the Genie
    space at them. Runs on the jumpbox.

.DESCRIPTION
    The demo claim is that the agent returns the same number as the BI dashboard. That
    only holds if both read one definition, so two views are created:

      sales_analytics  daily grain with dimensions and additive measures, for any
                       filtered or grouped question
      sales_kpi        all-time headline values as rows, so dashboard cards and KPI
                       answers read the same precomputed number instead of each
                       re-deriving it

    Genie reads COMMENT metadata as context, so the comments below are functional.
    They are what stops Genie recalculating a KPI from the fact table.

    Authenticates with the jumpbox managed identity, which holds MANAGE on the catalog.
    Run through deployment/Invoke-OnJumpbox.ps1, which supplies the parameters.
#>
param(
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    [Parameter(Mandatory)] [string] $WarehouseId,
    [Parameter(Mandatory)] [string] $GenieSpaceId,
    # Client ID of the jumpbox managed identity as registered in Databricks.
    [Parameter(Mandatory)] [string] $JumpboxIdentityId
)

$ErrorActionPreference = 'Continue'

$workspace = $WorkspaceUrl
$warehouseId = $WarehouseId
$spaceId = $GenieSpaceId
$catalog = 'food_analytics'
$schema = 'gold'

$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }

# MANAGE on the catalog allows granting, but creating a view additionally needs
# CREATE TABLE on the schema.
$jumpbox = $JumpboxIdentityId
try {
    Invoke-RestMethod -Method Patch -Uri "$workspace/api/2.1/unity-catalog/permissions/schema/$catalog.$schema" `
        -Headers $h -ContentType 'application/json' `
        -Body (@{ changes = @(@{ principal = $jumpbox; add = @('CREATE_TABLE', 'MANAGE') }) } | ConvertTo-Json -Depth 6) | Out-Null
    Write-Host 'granted CREATE_TABLE + MANAGE on the schema'
}
catch {
    Write-Host ("schema grant failed: " + $_.ErrorDetails.Message)
}

function Invoke-Sql {
    param([string] $Statement, [string] $Label)

    $body = @{
        statement       = $Statement
        warehouse_id    = $warehouseId
        catalog         = $catalog
        schema          = $schema
        wait_timeout    = '50s'
        on_wait_timeout = 'CONTINUE'
    } | ConvertTo-Json -Depth 5

    $r = Invoke-RestMethod -Method Post -Uri "$workspace/api/2.0/sql/statements" -Headers $h `
        -ContentType 'application/json' -Body $body
    $deadline = (Get-Date).AddMinutes(10)
    while ($r.status.state -in @('PENDING', 'RUNNING') -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $r = Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/sql/statements/$($r.statement_id)" -Headers $h
    }
    if ($r.status.state -ne 'SUCCEEDED') {
        Write-Host "[FAIL] $Label : $($r.status.error.message)"
        return $null
    }
    Write-Host "[ok] $Label"
    return $r
}

$salesAnalytics = @"
CREATE OR REPLACE VIEW $catalog.$schema.sales_analytics
COMMENT 'Canonical daily sales metrics shared by Power BI and Genie. One row per date, product and store. Aggregate only the additive measure columns: units_sold, gross_revenue, discount_amount, net_revenue, cost_of_goods and gross_margin. Gross margin percentage is gross_margin divided by net_revenue, never an average of per-row percentages. Amounts are in SEK. Use this view for any question filtered or grouped by date, product, category, store or region.'
AS
SELECT
  d.calendar_date                                    AS sale_date,
  d.calendar_year,
  d.calendar_quarter,
  CONCAT(d.calendar_year, '-Q', d.calendar_quarter)  AS year_quarter,
  DATE_FORMAT(d.calendar_date, 'yyyy-MM')            AS year_month,
  d.month_name,
  d.is_weekend,
  p.product_id,
  p.product_name,
  p.category,
  p.subcategory,
  p.brand,
  p.is_organic,
  p.shelf_life_days,
  s.store_id,
  s.store_name,
  s.city,
  s.region,
  s.store_format,
  f.units_sold,
  f.gross_revenue,
  f.discount_amount,
  f.net_revenue,
  f.cost_of_goods,
  f.gross_margin
FROM $catalog.$schema.fact_sales f
JOIN $catalog.$schema.dim_date d    ON f.date_key = d.date_key
JOIN $catalog.$schema.dim_product p ON f.product_id = p.product_id
JOIN $catalog.$schema.dim_store s   ON f.store_id = s.store_id
"@

$wasteAnalytics = @"
CREATE OR REPLACE VIEW $catalog.$schema.waste_analytics
COMMENT 'Canonical daily food waste metrics shared by Power BI and Genie. One row per date, product and store. Aggregate only units_wasted and waste_cost. Amounts are in SEK. Use this view for any waste question filtered or grouped by date, product, category, store, region or waste reason.'
AS
SELECT
  d.calendar_date                                    AS waste_date,
  d.calendar_year,
  d.calendar_quarter,
  CONCAT(d.calendar_year, '-Q', d.calendar_quarter)  AS year_quarter,
  DATE_FORMAT(d.calendar_date, 'yyyy-MM')            AS year_month,
  p.product_id,
  p.product_name,
  p.category,
  p.subcategory,
  p.brand,
  p.is_organic,
  p.shelf_life_days,
  s.store_id,
  s.store_name,
  s.city,
  s.region,
  s.store_format,
  w.waste_reason,
  w.units_wasted,
  w.waste_cost
FROM $catalog.$schema.fact_food_waste w
JOIN $catalog.$schema.dim_date d    ON w.date_key = d.date_key
JOIN $catalog.$schema.dim_product p ON w.product_id = p.product_id
JOIN $catalog.$schema.dim_store s   ON w.store_id = s.store_id
"@

# DECIMAL(18,2) keeps the values inside the precision Power BI fixed-decimal columns accept.
$kpi = @"
CREATE OR REPLACE VIEW $catalog.$schema.sales_kpi
COMMENT 'Canonical all-time dashboard KPI values, unfiltered by date. Power BI cards and Genie KPI answers must return these rows as they are and must not recalculate the measures from the fact tables. For any date-filtered or grouped question use sales_analytics or waste_analytics instead.'
AS
SELECT 'Total Net Revenue' AS metric_name, CAST(ROUND(SUM(net_revenue), 2) AS DECIMAL(18,2)) AS metric_value, 'SEK' AS metric_unit
FROM $catalog.$schema.sales_analytics
UNION ALL
SELECT 'Total Cost of Goods', CAST(ROUND(SUM(cost_of_goods), 2) AS DECIMAL(18,2)), 'SEK'
FROM $catalog.$schema.sales_analytics
UNION ALL
SELECT 'Gross Margin', CAST(ROUND(SUM(gross_margin), 2) AS DECIMAL(18,2)), 'SEK'
FROM $catalog.$schema.sales_analytics
UNION ALL
SELECT 'Gross Margin Percent', CAST(ROUND(SUM(gross_margin) / NULLIF(SUM(net_revenue), 0) * 100, 2) AS DECIMAL(18,2)), 'percent'
FROM $catalog.$schema.sales_analytics
UNION ALL
SELECT 'Units Sold', CAST(ROUND(SUM(units_sold), 2) AS DECIMAL(18,2)), 'units'
FROM $catalog.$schema.sales_analytics
UNION ALL
SELECT 'Total Waste Cost', CAST(ROUND(SUM(waste_cost), 2) AS DECIMAL(18,2)), 'SEK'
FROM $catalog.$schema.waste_analytics
UNION ALL
SELECT 'Units Wasted', CAST(ROUND(SUM(units_wasted), 2) AS DECIMAL(18,2)), 'units'
FROM $catalog.$schema.waste_analytics
"@

Invoke-Sql -Statement $salesAnalytics -Label 'sales_analytics' | Out-Null
Invoke-Sql -Statement $wasteAnalytics -Label 'waste_analytics' | Out-Null
Invoke-Sql -Statement $kpi -Label 'sales_kpi' | Out-Null

Write-Host ''
Write-Host '== KPI values (what the dashboard cards must show)'
$r = Invoke-Sql -Statement "SELECT metric_name, metric_value, metric_unit FROM $catalog.$schema.sales_kpi ORDER BY metric_name" -Label 'read sales_kpi'
if ($null -ne $r -and $null -ne $r.result -and $null -ne $r.result.data_array) {
    $r.result.data_array | ForEach-Object { Write-Host ("  {0,-22} {1,16} {2}" -f $_[0], $_[1], $_[2]) }
}
else {
    Write-Host '  no rows returned'
}
