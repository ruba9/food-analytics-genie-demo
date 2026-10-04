<#
.SYNOPSIS
    Seeds the food_analytics.gold schema in Unity Catalog with demo tables for Genie.

.DESCRIPTION
    Runs a fixed, ordered list of SQL statements against a Databricks SQL warehouse
    using the SQL Statement Execution API. Every statement is CREATE OR REPLACE or a
    comment mutation, so the script is idempotent and safe to re-run.

    Table and column comments are not decoration: Genie uses them as the primary
    semantic signal when translating natural language into SQL. Removing them
    measurably degrades answer quality.

.NOTES
    Requires the caller to be a Databricks workspace admin (or to have USE CATALOG /
    CREATE TABLE on food_analytics.gold) and to be signed in with `az login`.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string] $WorkspaceUrl,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $WarehouseId,

    [string] $Catalog = 'food_analytics',

    [string] $Schema = 'gold',

    # A cold classic (Pro) warehouse can take several minutes to start.
    [int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'

# Databricks' first-party Entra application ID. Tokens for this resource are
# accepted by the workspace REST API.
$databricksResourceId = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'

function Get-DatabricksHeaders {
    $token = az account get-access-token --resource $databricksResourceId --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Failed to acquire a Databricks access token. Run `az login` and retry.'
    }
    return @{ Authorization = "Bearer $token" }
}

function Invoke-DatabricksSql {
    param(
        [Parameter(Mandatory = $true)][string] $Statement,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $headers = Get-DatabricksHeaders
    $body = @{
        statement     = $Statement
        warehouse_id  = $WarehouseId
        catalog       = $Catalog
        schema        = $Schema
        wait_timeout  = '50s'
        on_wait_timeout = 'CONTINUE'
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$WorkspaceUrl/api/2.0/sql/statements" `
            -Headers $headers -ContentType 'application/json' -Body $body
    }
    catch {
        throw "[$Label] submit failed: $($_.ErrorDetails.Message)"
    }

    $statementId = $response.statement_id
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ($response.status.state -in @('PENDING', 'RUNNING')) {
        if ((Get-Date) -gt $deadline) {
            throw "[$Label] timed out after $TimeoutSeconds seconds (statement_id=$statementId)."
        }
        Start-Sleep -Seconds 5
        # Re-acquire headers each poll: a cold warehouse start can outlive the token.
        $response = Invoke-RestMethod -Method Get `
            -Uri "$WorkspaceUrl/api/2.0/sql/statements/$statementId" -Headers (Get-DatabricksHeaders)
    }

    if ($response.status.state -ne 'SUCCEEDED') {
        throw "[$Label] $($response.status.state): $($response.status.error.message)"
    }

    Write-Host "  [ok] $Label"
    return $response
}

# --- Statements, in dependency order -----------------------------------------
# Dimensions must exist before the facts that cross-join them.

$statements = [ordered]@{

    'dim_date' = @"
CREATE OR REPLACE TABLE $Catalog.$Schema.dim_date
COMMENT 'Calendar date dimension covering 2023-01-01 through 2025-12-31. Join to any fact table on date_key.'
AS
SELECT
  CAST(date_format(d, 'yyyyMMdd') AS INT) AS date_key,
  d                                       AS calendar_date,
  YEAR(d)                                 AS calendar_year,
  QUARTER(d)                              AS calendar_quarter,
  MONTH(d)                                AS calendar_month,
  date_format(d, 'MMMM')                  AS month_name,
  WEEKOFYEAR(d)                           AS week_of_year,
  date_format(d, 'EEEE')                  AS day_of_week,
  CASE WHEN date_format(d, 'EEEE') IN ('Saturday', 'Sunday') THEN TRUE ELSE FALSE END AS is_weekend
FROM (SELECT explode(sequence(DATE'2023-01-01', DATE'2025-12-31', INTERVAL 1 DAY)) AS d)
"@

    'dim_product' = @"
CREATE OR REPLACE TABLE $Catalog.$Schema.dim_product
COMMENT 'Food product master data. One row per sellable product (SKU).'
AS
SELECT * FROM VALUES
  (1,  'Organic Whole Milk 1L',      'Dairy',      'Milk',        'Nordgard',   1.85, TRUE,  10),
  (2,  'Whole Milk 1L',              'Dairy',      'Milk',        'Valbrook',   1.25, FALSE, 10),
  (3,  'Greek Yogurt 500g',          'Dairy',      'Yogurt',      'Nordgard',   2.40, FALSE, 21),
  (4,  'Aged Cheddar 200g',          'Dairy',      'Cheese',      'Hillmoor',   4.60, FALSE, 90),
  (5,  'Sourdough Loaf',             'Bakery',     'Bread',       'Stonemill',  3.20, FALSE, 4),
  (6,  'Wholegrain Rolls 6pk',       'Bakery',     'Bread',       'Stonemill',  2.10, FALSE, 3),
  (7,  'Cinnamon Buns 4pk',          'Bakery',     'Pastry',      'Stonemill',  3.75, FALSE, 3),
  (8,  'Bananas 1kg',                'Produce',    'Fruit',       'FreshPick',  1.95, FALSE, 7),
  (9,  'Organic Bananas 1kg',        'Produce',    'Fruit',       'FreshPick',  2.75, TRUE,  7),
  (10, 'Baby Spinach 200g',          'Produce',    'Vegetable',   'FreshPick',  2.30, TRUE,  5),
  (11, 'Vine Tomatoes 500g',         'Produce',    'Vegetable',   'FreshPick',  2.60, FALSE, 8),
  (12, 'Avocado 2pk',                'Produce',    'Fruit',       'FreshPick',  3.40, FALSE, 6),
  (13, 'Chicken Breast 500g',        'Meat',       'Poultry',     'Farmstead',  6.90, FALSE, 5),
  (14, 'Beef Mince 500g',            'Meat',       'Beef',        'Farmstead',  7.50, FALSE, 4),
  (15, 'Salmon Fillet 300g',         'Seafood',    'Fish',        'Coastline',  8.95, FALSE, 3),
  (16, 'Cold Smoked Salmon 150g',    'Seafood',    'Fish',        'Coastline',  6.25, FALSE, 14),
  (17, 'Oat Drink 1L',               'Beverages',  'Plant Drink', 'Grainfield', 2.15, TRUE,  30),
  (18, 'Sparkling Water 1.5L',       'Beverages',  'Water',       'Klarvik',    0.95, FALSE, 365),
  (19, 'Dark Roast Coffee 500g',     'Beverages',  'Coffee',      'Brygga',     7.80, TRUE,  180),
  (20, 'Sea Salt Crisps 150g',       'Snacks',     'Crisps',      'Krispa',     2.45, FALSE, 120)
AS t(product_id, product_name, category, subcategory, brand, unit_price, is_organic, shelf_life_days)
"@

    'dim_store' = @"
CREATE OR REPLACE TABLE $Catalog.$Schema.dim_store
COMMENT 'Retail store dimension. One row per physical store location.'
AS
SELECT * FROM VALUES
  (1, 'Stockholm Central',  'Stockholm',  'Svealand',  'Sweden',  'Urban',    1.35),
  (2, 'Stockholm Sodermalm','Stockholm',  'Svealand',  'Sweden',  'Urban',    1.10),
  (3, 'Goteborg Nordstan',  'Goteborg',   'Gotaland',  'Sweden',  'Urban',    1.20),
  (4, 'Malmo Triangeln',    'Malmo',      'Gotaland',  'Sweden',  'Urban',    1.05),
  (5, 'Uppsala Gransbro',   'Uppsala',    'Svealand',  'Sweden',  'Suburban', 0.85),
  (6, 'Vasteras Hallby',    'Vasteras',   'Svealand',  'Sweden',  'Suburban', 0.75),
  (7, 'Umea Ersboda',       'Umea',       'Norrland',  'Sweden',  'Suburban', 0.65),
  (8, 'Lulea Storheden',    'Lulea',      'Norrland',  'Sweden',  'Rural',    0.55)
AS t(store_id, store_name, city, region, country, store_format, traffic_index)
"@

    'fact_sales' = @"
CREATE OR REPLACE TABLE $Catalog.$Schema.fact_sales
COMMENT 'Daily product sales by store. Grain: one row per date, product and store. Revenue and cost are in SEK. Use net_revenue for reported sales and gross_margin for profitability.'
AS
WITH base AS (
  SELECT
    d.date_key,
    d.calendar_date,
    p.product_id,
    p.unit_price,
    s.store_id,
    s.traffic_index,
    CAST(GREATEST(1, ROUND(
      (8 + rand() * 30)
      * s.traffic_index
      * (1 + 0.25 * SIN(2 * PI() * MONTH(d.calendar_date) / 12))
      * (CASE WHEN d.is_weekend THEN 1.3 ELSE 1.0 END)
    )) AS INT) AS units_sold
  FROM $Catalog.$Schema.dim_date d
  CROSS JOIN $Catalog.$Schema.dim_product p
  CROSS JOIN $Catalog.$Schema.dim_store s
  WHERE rand() < 0.25
)
SELECT
  date_key,
  product_id,
  store_id,
  units_sold,
  CAST(units_sold * unit_price AS DECIMAL(12,2))                                AS gross_revenue,
  CAST(units_sold * unit_price * (rand() * 0.15) AS DECIMAL(12,2))              AS discount_amount,
  CAST(units_sold * unit_price * (1 - (rand() * 0.15)) AS DECIMAL(12,2))        AS net_revenue,
  CAST(units_sold * unit_price * (0.55 + rand() * 0.15) AS DECIMAL(12,2))       AS cost_of_goods,
  CAST(units_sold * unit_price * (0.30 - rand() * 0.15) AS DECIMAL(12,2))       AS gross_margin
FROM base
"@

    'fact_food_waste' = @"
CREATE OR REPLACE TABLE $Catalog.$Schema.fact_food_waste
COMMENT 'Daily recorded food waste by store and product. Grain: one row per date, product and store. waste_cost is the unrecovered cost in SEK. Short shelf-life products waste more.'
AS
WITH base AS (
  SELECT
    d.date_key,
    p.product_id,
    p.unit_price,
    p.shelf_life_days,
    s.store_id,
    CAST(GREATEST(1, ROUND(
      (1 + rand() * 6) * (CASE WHEN p.shelf_life_days <= 7 THEN 2.5 ELSE 1.0 END)
    )) AS INT) AS units_wasted,
    rand() AS reason_draw
  FROM $Catalog.$Schema.dim_date d
  CROSS JOIN $Catalog.$Schema.dim_product p
  CROSS JOIN $Catalog.$Schema.dim_store s
  WHERE rand() < 0.06
)
SELECT
  date_key,
  product_id,
  store_id,
  units_wasted,
  CAST(units_wasted * unit_price * (0.55 + rand() * 0.15) AS DECIMAL(12,2)) AS waste_cost,
  CASE
    WHEN reason_draw < 0.55 THEN 'Expired'
    WHEN reason_draw < 0.75 THEN 'Damaged'
    WHEN reason_draw < 0.90 THEN 'Overstock'
    ELSE 'Quality Reject'
  END AS waste_reason
FROM base
"@
}

# Column comments. Genie leans on these heavily, so they are applied explicitly
# rather than relying on the table-level comment alone.
$columnComments = [ordered]@{
    "$Catalog.$Schema.fact_sales.units_sold"       = 'Number of units sold on this date, for this product, at this store.'
    "$Catalog.$Schema.fact_sales.gross_revenue"    = 'Revenue before discounts, in SEK.'
    "$Catalog.$Schema.fact_sales.discount_amount"  = 'Total discount applied, in SEK.'
    "$Catalog.$Schema.fact_sales.net_revenue"      = 'Revenue after discounts, in SEK. This is the headline sales measure.'
    "$Catalog.$Schema.fact_sales.cost_of_goods"    = 'Cost of goods sold, in SEK.'
    "$Catalog.$Schema.fact_sales.gross_margin"     = 'Net revenue minus cost of goods, in SEK. Use for profitability questions.'
    "$Catalog.$Schema.fact_food_waste.units_wasted" = 'Number of units written off as waste.'
    "$Catalog.$Schema.fact_food_waste.waste_cost"   = 'Unrecovered cost of the wasted units, in SEK.'
    "$Catalog.$Schema.fact_food_waste.waste_reason" = 'Why the stock was written off: Expired, Damaged, Overstock or Quality Reject.'
    "$Catalog.$Schema.dim_product.category"         = 'Top-level food category, for example Dairy, Bakery, Produce, Meat, Seafood, Beverages or Snacks.'
    "$Catalog.$Schema.dim_product.is_organic"       = 'True when the product is certified organic.'
    "$Catalog.$Schema.dim_product.shelf_life_days"  = 'Expected shelf life in days. Low values correlate with higher waste.'
    "$Catalog.$Schema.dim_store.region"             = 'Swedish region: Svealand, Gotaland or Norrland.'
    "$Catalog.$Schema.dim_store.store_format"       = 'Store format: Urban, Suburban or Rural.'
    "$Catalog.$Schema.dim_store.traffic_index"      = 'Relative footfall multiplier. 1.0 is an average store.'
}

Write-Host "Seeding $Catalog.$Schema via warehouse $WarehouseId ..."
Write-Host 'The first statement may take several minutes while the warehouse starts.'

foreach ($entry in $statements.GetEnumerator()) {
    Invoke-DatabricksSql -Statement $entry.Value -Label $entry.Key | Out-Null
}

foreach ($entry in $columnComments.GetEnumerator()) {
    $escaped = $entry.Value -replace "'", "''"
    Invoke-DatabricksSql -Statement "COMMENT ON COLUMN $($entry.Key) IS '$escaped'" `
        -Label "comment $($entry.Key)" | Out-Null
}

Write-Host ''
Write-Host "Done. $Catalog.$Schema now contains dim_date, dim_product, dim_store, fact_sales and fact_food_waste."
