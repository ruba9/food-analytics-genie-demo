<#
Prints the ODBC connection values of the SQL warehouse, for configuring Power BI.
#>
param(
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    [Parameter(Mandatory)] [string] $WarehouseId
)

$ErrorActionPreference = 'Continue'
$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$w = Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$WarehouseId" -Headers @{ Authorization = "Bearer $tok" }
Write-Output ("hostname: " + $w.odbc_params.hostname)
Write-Output ("path: " + $w.odbc_params.path)
Write-Output ("port: " + $w.odbc_params.port)
