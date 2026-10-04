<#
.SYNOPSIS
    Loads the per-environment values that every deployment script needs.

.DESCRIPTION
    Environment identifiers (subscription, workspace URL, warehouse and Genie space IDs,
    managed identity IDs) live only in deployment/environment.json, which is git-ignored.
    The repository carries deployment/environment.example.json with placeholders.

    Dot-source this file, then call Get-DemoEnvironment.
#>

function Get-DemoEnvironment {
    [CmdletBinding()]
    param(
        [string] $Path = (Join-Path $PSScriptRoot 'environment.json')
    )

    if (-not (Test-Path $Path)) {
        throw "Missing $Path. Copy deployment/environment.example.json to deployment/environment.json and fill in your values."
    }

    $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
    $unset = $config.PSObject.Properties | Where-Object { "$($_.Value)" -match '<[^>]+>' } | ForEach-Object Name
    if ($unset) {
        throw "Placeholders remain in ${Path}: $($unset -join ', ')"
    }

    $config | Add-Member -NotePropertyName ProjectEndpoint -Force -NotePropertyValue `
        "https://$($config.FoundryAccountName).services.ai.azure.com/api/projects/$($config.FoundryProjectName)"
    $config | Add-Member -NotePropertyName ProjectResourceId -Force -NotePropertyValue `
        "/subscriptions/$($config.SubscriptionId)/resourceGroups/$($config.ResourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($config.FoundryAccountName)/projects/$($config.FoundryProjectName)"
    return $config
}
