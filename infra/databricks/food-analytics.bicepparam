using 'main.bicep'

// Populated by deploy.ps1 from the network deployment outputs.
param foundryVnetResourceId = readEnvironmentVariable('AZURE_VNET_RESOURCE_ID', '')

param databricksResourceGroupName = 'rg-databricks-ne'
param location = 'northeurope'
param workspaceName = 'dbx-food-analytics-ne'

// Must not overlap the Foundry network (10.100.0.0/16); the two are peered.
param databricksVnetAddressPrefix = '10.200.0.0/16'

param disablePublicNetworkAccess = true
param allowForwardedTraffic = true
