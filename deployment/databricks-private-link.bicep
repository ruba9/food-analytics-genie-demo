/*
Private inbound connectivity from the Foundry VNet to an existing Azure Databricks workspace.

Deploy AFTER template-19/main.bicep, into the same resource group and VNet. This creates the
front-end (databricks_ui_api) private endpoint plus the private DNS zone, so callers inside the
VNet resolve the workspace hostname to a private IP. The Genie MCP endpoint lives on that same
hostname, so agent traffic follows the private path.

Deploy this BEFORE setting publicNetworkAccess to Disabled on the workspace. Doing it the other
way round leaves a window with neither a public nor a private path.

The browser_authentication endpoint is separate because it is only needed for interactive SSO
logins to the workspace UI. Machine-to-machine traffic does not use it, but a jumpbox browser
does, so it defaults to on.
*/

@description('Azure region for the private endpoint. Must match the VNet region.')
param location string

@description('Name of the existing VNet created by template-19/main.bicep.')
param vnetName string

@description('Name of the existing private endpoint subnet within that VNet.')
param peSubnetName string

@description('Full ARM resource ID of the existing Azure Databricks workspace. Required — there is no public fallback.')
@minLength(1)
param databricksWorkspaceResourceId string

@description('Create the browser_authentication endpoint so the workspace UI is reachable from inside the VNet.')
param enableBrowserAuthentication bool = true

@description('Name of the private endpoint resource.')
param privateEndpointName string = 'pe-databricks-ui-api'

var databricksDnsZoneName = 'privatelink.azuredatabricks.net'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName

  resource peSubnet 'subnets' existing = {
    name: peSubnetName
  }
}

resource databricksDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: databricksDnsZoneName
  location: 'global'
}

resource databricksDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: databricksDnsZone
  name: '${vnetName}-databricks-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource databricksPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'databricks-ui-api'
        properties: {
          privateLinkServiceId: databricksWorkspaceResourceId
          groupIds: [
            'databricks_ui_api'
          ]
        }
      }
    ]
  }
}

resource databricksDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: databricksPrivateEndpoint
  name: 'databricks-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'databricks'
        properties: {
          privateDnsZoneId: databricksDnsZone.id
        }
      }
    ]
  }
}

resource browserAuthPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (enableBrowserAuthentication) {
  name: '${privateEndpointName}-browser-auth'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'databricks-browser-auth'
        properties: {
          privateLinkServiceId: databricksWorkspaceResourceId
          groupIds: [
            'browser_authentication'
          ]
        }
      }
    ]
  }
}

resource browserAuthDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (enableBrowserAuthentication) {
  parent: browserAuthPrivateEndpoint
  name: 'databricks-browser-auth-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'databricks'
        properties: {
          privateDnsZoneId: databricksDnsZone.id
        }
      }
    ]
  }
}

output databricksPrivateEndpointId string = databricksPrivateEndpoint.id
output databricksPrivateDnsZoneName string = databricksDnsZone.name
