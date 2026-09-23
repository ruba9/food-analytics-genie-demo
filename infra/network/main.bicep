// Owns the West Europe virtual network outright.
//
// The Foundry template declares its subnets inline on the VNet resource, so any
// redeploy would rewrite the subnet list and drop the Bastion and jump box subnets.
// Creating the network here and passing existing*SubnetResourceId into that template
// makes it reference the subnets instead of rewriting them -- which is also what the
// upstream README recommends for a shared VNet.

@description('Region for the network. Must match the Foundry region; injection requires them to be the same.')
param location string = 'westeurope'

@description('Name of the virtual network.')
param vnetName string = 'vnet-foundry-we'

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.100.0.0/16'

@description('Delegated to Microsoft.App/environments for the Foundry agent runtime.')
param agentSubnetPrefix string = '10.100.0.0/24'

@description('Hosts the private endpoints for Foundry and its data resources.')
param peSubnetPrefix string = '10.100.1.0/24'

@description('Hosts user-deployed Container Apps such as MCP servers.')
param mcpSubnetPrefix string = '10.100.2.0/24'

@description('Bastion requires this subnet to be named AzureBastionSubnet and be /26 or larger.')
param bastionSubnetPrefix string = '10.100.3.0/26'

@description('Hosts the jump box NIC.')
param jumpboxSubnetPrefix string = '10.100.4.0/24'

@description('Deploy the Bastion host and jump box.')
param deployJumpbox bool = true

@description('Bastion SKU.')
@allowed(['Basic', 'Standard'])
param bastionSku string = 'Basic'

@description('Local administrator password for the jump box.')
@secure()
param jumpboxAdminPassword string = ''

resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-jumpbox'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromBastion'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'agent-subnet'
        properties: {
          addressPrefix: agentSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.app/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'pe-subnet'
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'mcp-subnet'
        properties: {
          addressPrefix: mcpSubnetPrefix
        }
      }
      {
        // Bastion manages its own traffic rules; attaching an NSG here needs a
        // specific rule set, so this subnet is intentionally left without one.
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
      {
        name: 'jumpbox-subnet'
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          networkSecurityGroup: {
            id: jumpboxNsg.id
          }
        }
      }
    ]
  }
}

module jumpbox 'jumpbox.bicep' = if (deployJumpbox) {
  name: 'jumpbox-deployment'
  params: {
    location: location
    jumpboxSubnetId: '${vnet.id}/subnets/jumpbox-subnet'
    bastionSubnetId: '${vnet.id}/subnets/AzureBastionSubnet'
    bastionSku: bastionSku
    adminPassword: jumpboxAdminPassword
  }
}

output vnetResourceId string = vnet.id
output agentSubnetResourceId string = '${vnet.id}/subnets/agent-subnet'
output peSubnetResourceId string = '${vnet.id}/subnets/pe-subnet'
output mcpSubnetResourceId string = '${vnet.id}/subnets/mcp-subnet'
