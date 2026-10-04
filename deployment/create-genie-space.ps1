<#
.SYNOPSIS
    Creates or updates the Food Analytics Genie space. This is the only definition of it.

.DESCRIPTION
    The demo claim is that the agent returns the same number as the BI dashboard. That
    holds only if Genie reads the shared views that also back the dashboard, so the space
    is pointed at sales_analytics, waste_analytics and sales_kpi only. The raw fact and
    dimension tables are deliberately excluded: leaving them available lets Genie bypass
    the shared definition.

    Table descriptions alone were not enough. Genie searched sales_kpi with a loose
    LIKE '%gross margin%' match and returned "Gross Margin" (SEK) when asked for the
    percentage. Three things make headline answers deterministic:

      - a value dictionary on sales_kpi.metric_name, so Genie knows the exact names
      - text instructions that map each phrasing to one metric_name
      - example SQL for each headline question

    Reuses an existing space with the same title via PATCH, so it is safe to re-run.

    Databricks has no public endpoint, so run this on the jumpbox, which authenticates
    with its managed identity:

        ./deployment/Invoke-OnJumpbox.ps1 ./deployment/create-genie-space.ps1

    Outside Azure it falls back to `az account get-access-token`, which only works while
    the workspace still allows public access.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string] $WorkspaceUrl,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $WarehouseId,

    [string] $Title = 'Food Analytics',

    [string] $Catalog = 'food_analytics',

    [string] $Schema = 'gold'
)

$ErrorActionPreference = 'Stop'

$databricksResourceId = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'

function Get-DatabricksToken {
    try {
        $imds = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$databricksResourceId"
        return (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' } -TimeoutSec 5).access_token
    }
    catch {
        $token = az account get-access-token --resource $databricksResourceId --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            throw 'No managed identity and no az login. Run this on the jumpbox.'
        }
        return $token
    }
}

$headers = @{ Authorization = "Bearer $(Get-DatabricksToken)" }

# IDs must be 32 hex characters.
function New-SpaceId { [guid]::NewGuid().ToString('N') }

$views = "$Catalog.$Schema"

# Must match the metric_name values in deployment/jumpbox-create-shared-views.ps1.
$kpiNames = @(
    'Gross Margin',
    'Gross Margin Percent',
    'Total Cost of Goods',
    'Total Net Revenue',
    'Total Waste Cost',
    'Units Sold',
    'Units Wasted'
)
$kpiList = ($kpiNames | ForEach-Object { "'$_'" }) -join ', '

function Get-KpiSql([string] $MetricName) {
    "SELECT metric_name, metric_value, metric_unit FROM $views.sales_kpi WHERE metric_name = '$MetricName'"
}

$sampleQuestions = @(
    'What is total net revenue?',
    'What is the gross margin percentage?',
    'What is the total food waste cost?',
    'Show monthly net revenue for 2025.',
    'Which product categories generated the most net revenue in 2025?',
    'Which ten products have the highest waste cost in 2025, and why were they wasted?',
    'Compare gross margin percentage by store region for 2025.'
) | ForEach-Object { @{ id = New-SpaceId; question = @($_) } }

$exampleSql = @(
    @{ q = 'What is total net revenue?'; sql = Get-KpiSql 'Total Net Revenue' },
    @{ q = 'What is the gross margin?'; sql = Get-KpiSql 'Gross Margin' },
    @{ q = 'What is the gross margin percentage?'; sql = Get-KpiSql 'Gross Margin Percent' },
    @{ q = 'What is the total food waste cost?'; sql = Get-KpiSql 'Total Waste Cost' },
    @{ q = 'How many units were sold in total?'; sql = Get-KpiSql 'Units Sold' },
    @{ q = 'How many units were wasted in total?'; sql = Get-KpiSql 'Units Wasted' },
    @{ q = 'Compare gross margin percentage by store region for 2025.'
       # Percent rounded to 2 places matches the dashboard's 0.00% format.
       sql = "SELECT region, ROUND(100 * SUM(gross_margin) / NULLIF(SUM(net_revenue), 0), 2) AS gross_margin_percent FROM $views.sales_analytics WHERE calendar_year = 2025 GROUP BY region ORDER BY gross_margin_percent DESC" }
) | ForEach-Object { @{ id = New-SpaceId; question = @($_.q); sql = @($_.sql) } }

$instructions = @"
Amounts are in SEK, never dollars.
For an unfiltered, all-time headline figure, return metric_value and metric_unit from $views.sales_kpi, filtered on metric_name with an exact equality match. Never use LIKE on metric_name and never recalculate these figures from the other views. The only metric_name values are: $kpiList.
"Gross margin percentage", "gross margin %", "margin %" and "margin rate" mean metric_name 'Gross Margin Percent'. "Gross margin" without a percentage means 'Gross Margin', in SEK. "Net revenue", "revenue" and "sales" mean 'Total Net Revenue'. "Waste cost" and "food waste cost" mean 'Total Waste Cost'.
For any question filtered or grouped by date, product, category, store, region or waste reason, use $views.sales_analytics or $views.waste_analytics. Express gross margin percentage there as ROUND(100 * SUM(gross_margin) / SUM(net_revenue), 2), never as an average of per-row percentages.
"@

# The API rejects the payload unless tables are sorted by identifier.
$tables = @(
    @{ identifier  = "$views.sales_analytics"
       description = @('Canonical daily sales metrics shared with the BI dashboard. Use for any sales question filtered or grouped by date, product, category, store or region. Sum the additive measures; gross margin percentage is 100 * SUM(gross_margin) / SUM(net_revenue).') },
    @{ identifier     = "$views.sales_kpi"
       description    = @("Canonical all-time headline KPI values shown on the BI dashboard cards, one row per metric. Return metric_value as it is, selected by exact metric_name. metric_name is one of: $kpiList.")
       column_configs = @(
           # Version 2 names for v1's get_example_values / build_value_dictionary.
           @{ column_name = 'metric_name'; enable_format_assistance = $true; enable_entity_matching = $true }
       ) },
    @{ identifier  = "$views.waste_analytics"
       description = @('Canonical daily food waste metrics shared with the BI dashboard. Use for any waste question filtered or grouped by date, product, category, store, region or waste reason.') }
) | Sort-Object -Property { $_.identifier }

$serializedSpace = @{
    version      = 2
    config       = @{ sample_questions = @($sampleQuestions | Sort-Object -Property { $_.id }) }
    data_sources = @{ tables = @($tables) }
    instructions = @{
        text_instructions     = @(@{ id = New-SpaceId; content = @($instructions) })
        example_question_sqls = @($exampleSql | Sort-Object -Property { $_.id })
    }
} | ConvertTo-Json -Depth 10 -Compress

$description = 'Governed analytics over the shared food_analytics.gold views that also back the BI dashboard.'

$body = @{
    serialized_space = $serializedSpace
    title            = $Title
    description      = $description
    warehouse_id     = $WarehouseId
} | ConvertTo-Json -Depth 10

$existing = $null
$list = Invoke-RestMethod -Method Get -Uri "$WorkspaceUrl/api/2.0/genie/spaces" -Headers $headers
if ($list.PSObject.Properties.Name -contains 'spaces' -and $list.spaces) {
    $existing = $list.spaces | Where-Object { $_.title -eq $Title } | Select-Object -First 1
}

try {
    if ($existing) {
        Write-Output "Updating Genie space '$Title' ($($existing.space_id))"
        $space = Invoke-RestMethod -Method Patch -Uri "$WorkspaceUrl/api/2.0/genie/spaces/$($existing.space_id)" `
            -Headers $headers -ContentType 'application/json' -Body $body
    }
    else {
        Write-Output "Creating Genie space '$Title'"
        $space = Invoke-RestMethod -Method Post -Uri "$WorkspaceUrl/api/2.0/genie/spaces" `
            -Headers $headers -ContentType 'application/json' -Body $body
    }
}
catch {
    throw ("Genie space request failed: " + $_.ErrorDetails.Message)
}

$current = Invoke-RestMethod -Method Get `
    -Uri "$WorkspaceUrl/api/2.0/genie/spaces/$($space.space_id)?include_serialized_space=true" -Headers $headers
$parsed = $current.serialized_space | ConvertFrom-Json

Write-Output ''
Write-Output "space_id          : $($space.space_id)"
Write-Output "MCP endpoint      : $WorkspaceUrl/api/2.0/mcp/genie/$($space.space_id)"
Write-Output "data sources      : $(($parsed.data_sources.tables | ForEach-Object { $_.identifier }) -join ', ')"
Write-Output "example SQL       : $(@($parsed.instructions.example_question_sqls).Count)"
Write-Output "text instructions : $(@($parsed.instructions.text_instructions).Count)"
Write-Output ''
Write-Output 'A new space_id must also be set as genieSpaceId in deployment/foundry-connections.bicep.'
