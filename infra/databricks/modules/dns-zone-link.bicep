@description('Name of the existing private DNS zone, e.g. privatelink.azuredatabricks.net.')
param zoneName string

@description('Name for the virtual network link record.')
param linkName string

@description('ARM resource ID of the virtual network to link to the zone.')
param vnetResourceId string

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: zoneName
}

// Resolution only; the agent subnet must never register its own records in this zone.
resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetResourceId
    }
  }
}

output linkResourceId string = link.id
