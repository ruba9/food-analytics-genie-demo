/*
Azure Databricks workspace for the food analytics demo.

Deployed VNet-injected into the existing VNet with secure cluster connectivity (no public IPs on
cluster nodes). Premium SKU is required for Private Link, Unity Catalog, and service principal
OAuth — all three are needed by this design.

ORDERING MATTERS. `publicNetworkAccess` defaults to Enabled so the workspace REST API is reachable
while Unity Catalog, sample data, the Genie space, and the service principal are configured from
outside the VNet. Creating it private first locks you out of the very API needed to set it up.
Flip to Disabled (and set requiredNsgRules to NoAzureDatabricksRules) after configuration, then
deploy databricks-private-link.bicep for the private endpoint.
*/

@description('Azure region. Must match the VNet region.')
param location string

@description('Name of the existing VNet created by template-19/main.bicep.')
param vnetName string

@description('Name of the Databricks workspace.')
param workspaceName string = 'dbw-food-analytics-swc'

@description('Managed resource group for Databricks-managed resources.')
param managedResourceGroupName string = 'rg-dbw-food-analytics-managed'

@description('Workspace REST API reachability. Keep Enabled during setup; set Disabled to lock down.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('NSG rule set. AllRules suits front-end public access; NoAzureDatabricksRules pairs with full private isolation.')
@allowed([
  'AllRules'
  'NoAzureDatabricksRules'
])
param requiredNsgRules string = 'AllRules'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource workspace 'Microsoft.Databricks/workspaces@2024-05-01' = {
  name: workspaceName
  location: location
  sku: {
    name: 'premium'
  }
  properties: {
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', managedResourceGroupName)
    publicNetworkAccess: publicNetworkAccess
    requiredNsgRules: requiredNsgRules
    parameters: {
      customVirtualNetworkId: {
        value: virtualNetwork.id
      }
      customPublicSubnetName: {
        value: 'snet-databricks-host'
      }
      customPrivateSubnetName: {
        value: 'snet-databricks-container'
      }
      enableNoPublicIp: {
        value: true
      }
    }
  }
}

output workspaceResourceId string = workspace.id
output workspaceUrl string = workspace.properties.workspaceUrl
