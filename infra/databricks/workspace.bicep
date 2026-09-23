@description('Azure Databricks workspace name.')
param workspaceName string

@description('Region for the workspace and its virtual network.')
param location string = 'northeurope'

@description('Virtual network name for the injected workspace.')
param vnetName string = 'vnet-databricks-ne'

@description('Address space for the Databricks virtual network. Must not overlap the Foundry network.')
param vnetAddressPrefix string = '10.200.0.0/16'

@description('Host ("public") subnet prefix. Delegated to Microsoft.Databricks/workspaces.')
param hostSubnetPrefix string = '10.200.0.0/24'

@description('Container ("private") subnet prefix. Delegated to Microsoft.Databricks/workspaces.')
param containerSubnetPrefix string = '10.200.1.0/24'

@description('Subnet that hosts the workspace private endpoints.')
param peSubnetPrefix string = '10.200.2.0/24'

@description('Disable public access to the workspace. Requires NoAzureDatabricksRules, which assumes serverless SQL warehouses for Genie.')
param disablePublicNetworkAccess bool = true

var hostSubnetName = 'host-subnet'
var containerSubnetName = 'container-subnet'
var peSubnetName = 'pe-subnet'
var dnsZoneName = 'privatelink.azuredatabricks.net'

// Databricks provisions and manages its own rules here through subnet delegation.
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${workspaceName}'
  location: location
  properties: {}
}

var databricksDelegation = [
  {
    name: 'databricks-delegation'
    properties: {
      serviceName: 'Microsoft.Databricks/workspaces'
    }
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: hostSubnetName
        properties: {
          addressPrefix: hostSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
          delegations: databricksDelegation
        }
      }
      {
        name: containerSubnetName
        properties: {
          addressPrefix: containerSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
          delegations: databricksDelegation
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// Private Link requires the premium plan; standard cannot host private endpoints.
resource workspace 'Microsoft.Databricks/workspaces@2024-05-01' = {
  name: workspaceName
  location: location
  sku: {
    name: 'premium'
  }
  properties: {
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', 'mrg-${workspaceName}')
    publicNetworkAccess: disablePublicNetworkAccess ? 'Disabled' : 'Enabled'
    requiredNsgRules: disablePublicNetworkAccess ? 'NoAzureDatabricksRules' : 'AllRules'
    parameters: {
      customVirtualNetworkId: {
        value: vnet.id
      }
      customPublicSubnetName: {
        value: hostSubnetName
      }
      customPrivateSubnetName: {
        value: containerSubnetName
      }
      // Secure cluster connectivity is a prerequisite for Private Link.
      enableNoPublicIp: {
        value: true
      }
    }
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
}

resource dnsZoneLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZone
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

// Carries the REST/API traffic the Genie MCP endpoint is served over.
resource uiApiPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${workspaceName}-ui-api'
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'ui-api'
        properties: {
          privateLinkServiceId: workspace.id
          groupIds: ['databricks_ui_api']
        }
      }
    ]
  }
}

resource uiApiDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: uiApiPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'databricks'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

// Only needed so humans can sign in to the workspace UI over the private path.
resource browserAuthPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${workspaceName}-browser-auth'
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'browser-auth'
        properties: {
          privateLinkServiceId: workspace.id
          groupIds: ['browser_authentication']
        }
      }
    ]
  }
  dependsOn: [uiApiPrivateEndpoint]
}

resource browserAuthDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: browserAuthPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'databricks'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

output vnetResourceId string = vnet.id
output privateDnsZoneResourceId string = dnsZone.id
output workspaceUrl string = workspace.properties.workspaceUrl
output workspaceResourceId string = workspace.id
