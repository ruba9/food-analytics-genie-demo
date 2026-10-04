<#
Asks the Genie space a question directly from inside the VNet and prints the raw status
and error, bypassing the agent. Use this to tell "Genie is broken" apart from "the agent
or the model is broken".
#>
param(
    [string] $Question = 'Which product categories generated the most net revenue in 2025?',
    [Parameter(Mandatory)] [string] $WorkspaceUrl,
    [Parameter(Mandatory)] [string] $GenieSpaceId,
    [Parameter(Mandatory)] [string] $WarehouseId
)

$ErrorActionPreference = 'Continue'

$workspace = $WorkspaceUrl
$spaceId = $GenieSpaceId

$imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$tok = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }

$state = (Invoke-RestMethod -Method Get -Uri "$workspace/api/2.0/sql/warehouses/$WarehouseId" -Headers $h).state
Write-Output "warehouse: $state"

$body = @{ content = $Question } | ConvertTo-Json
$c = Invoke-RestMethod -Method Post -Uri "$workspace/api/2.0/genie/spaces/$spaceId/start-conversation" `
    -Headers $h -ContentType 'application/json' -Body $body

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 6
    $m = Invoke-RestMethod -Method Get `
        -Uri "$workspace/api/2.0/genie/spaces/$spaceId/conversations/$($c.conversation_id)/messages/$($c.message_id)" `
        -Headers $h
} while ($m.status -notin @('COMPLETED', 'FAILED', 'QUERY_RESULT_EXPIRED') -and (Get-Date) -lt $deadline)

Write-Output "genie status: $($m.status)"
if ($m.error) { Write-Output ("genie error: " + ($m.error | ConvertTo-Json -Depth 5 -Compress)) }

foreach ($a in $m.attachments) {
    if ($a.text) { Write-Output ("TEXT: " + $a.text.content) }
    if ($a.query) {
        Write-Output ("SQL: " + $a.query.query)
        if ($a.query.error) { Write-Output ("SQL ERROR: " + ($a.query.error | ConvertTo-Json -Depth 5 -Compress)) }
    }
}
