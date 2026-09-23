// Creates the North Europe Databricks workspace behind Private Link and joins it to the
// West Europe Foundry network. Private endpoints are regional but reachable across a
// peering, so the cross-region work is peering plus DNS -- not a second endpoint.
targetScope = 'subscription'

@description('ARM resource ID of the Foundry (West Europe) virtual network created by infra/foundry.')
param foundryVnetResourceId string

@description('Resource group to hold the Databricks workspace and its network.')
param databricksResourceGroupName string = 'rg-databricks-ne'

@description('Region for the Databricks workspace.')
param location string = 'northeurope'

@description('Azure Databricks workspace name.')
param workspaceName string = 'dbx-food-analytics-ne'

@description('Address space for the Databricks virtual network. Must not overlap the Foundry network.')
param databricksVnetAddressPrefix string = '10.200.0.0/16'

@description('Disable public access to the workspace.')
param disablePublicNetworkAccess bool = true

@description('Set true when either side sits behind a hub gateway or firewall that forwards traffic.')
param allowForwardedTraffic bool = true

var foundryVnetParts = split(foundryVnetResourceId, '/')
var foundryVnetRg = foundryVnetParts[4]
var foundryVnetName = last(foundryVnetParts)

resource databricksRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: databricksResourceGroupName
  location: location
}

module databricks 'workspace.bicep' = {
  name: 'databricks-workspace'
  scope: databricksRg
  params: {
    workspaceName: workspaceName
    location: location
    vnetAddressPrefix: databricksVnetAddressPrefix
    hostSubnetPrefix: cidrSubnet(databricksVnetAddressPrefix, 24, 0)
    containerSubnetPrefix: cidrSubnet(databricksVnetAddressPrefix, 24, 1)
    peSubnetPrefix: cidrSubnet(databricksVnetAddressPrefix, 24, 2)
    disablePublicNetworkAccess: disablePublicNetworkAccess
  }
}

module peeringFoundryToDatabricks 'modules/vnet-peering.bicep' = {
  name: 'peer-foundry-to-databricks'
  scope: resourceGroup(foundryVnetRg)
  params: {
    localVnetName: foundryVnetName
    peeringName: 'to-databricks-ne'
    remoteVnetResourceId: databricks.outputs.vnetResourceId
    allowForwardedTraffic: allowForwardedTraffic
  }
}

// A peering is only usable once both halves exist; one direction alone stays Initiated.
module peeringDatabricksToFoundry 'modules/vnet-peering.bicep' = {
  name: 'peer-databricks-to-foundry'
  scope: databricksRg
  params: {
    localVnetName: last(split(databricks.outputs.vnetResourceId, '/'))
    peeringName: 'to-foundry-we'
    remoteVnetResourceId: foundryVnetResourceId
    allowForwardedTraffic: allowForwardedTraffic
  }
}

// Without this link the agent subnet resolves the Databricks public IP and the
// call leaves the VNet, which a disabled-public-access workspace then rejects.
module databricksDnsLink 'modules/dns-zone-link.bicep' = {
  name: 'link-foundry-vnet-to-databricks-dns'
  scope: databricksRg
  params: {
    zoneName: last(split(databricks.outputs.privateDnsZoneResourceId, '/'))
    linkName: 'link-${foundryVnetName}'
    vnetResourceId: foundryVnetResourceId
  }
}

output workspaceUrl string = databricks.outputs.workspaceUrl
output databricksVnetResourceId string = databricks.outputs.vnetResourceId
output foundryToDatabricksPeeringState string = peeringFoundryToDatabricks.outputs.peeringState
output databricksToFoundryPeeringState string = peeringDatabricksToFoundry.outputs.peeringState
