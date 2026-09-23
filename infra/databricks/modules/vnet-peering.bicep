@description('Name of the local virtual network that owns this peering.')
param localVnetName string

@description('Name given to the peering resource on the local virtual network.')
param peeringName string

@description('ARM resource ID of the remote virtual network.')
param remoteVnetResourceId string

@description('Allow traffic forwarded by an NVA in the remote network. Required for hub-spoke topologies with a firewall.')
param allowForwardedTraffic bool = true

@description('Allow the remote network to use this network gateway. Leave false unless this network hosts the shared gateway.')
param allowGatewayTransit bool = false

@description('Use the remote network gateway for transit. Leave false unless the remote network hosts the shared gateway.')
param useRemoteGateways bool = false

resource localVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: localVnet
  name: peeringName
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
    remoteVirtualNetwork: {
      id: remoteVnetResourceId
    }
  }
}

output peeringState string = peering.properties.peeringState
