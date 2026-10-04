/*
Jumpbox for reaching the private Foundry data plane.

The Foundry account has publicNetworkAccess Disabled, so `azd ai connection`, `azd ai toolbox`,
`azd deploy`, the portal playground and any agent invocation are unreachable from outside the
VNet. This VM sits inside the VNet, resolves the privatelink DNS zones through Azure DNS, and is
the supported way to operate and demo the agent without weakening the network posture.

RDP is restricted to a single source IP by NSG. There is no Bastion here: it would remove the
public IP entirely but costs roughly $140/month. Swap to Bastion if the exposure matters more
than the cost.

Deallocate the VM when idle; it is billed per hour while running.
*/

@description('Azure region. Must match the VNet region.')
param location string

@description('Name of the existing VNet.')
@minLength(1)
param vnetName string

@description('Address prefix for the new jumpbox subnet. Must not overlap existing subnets.')
param jumpboxSubnetPrefix string = '10.19.5.0/24'

@description('Single public IP allowed to reach RDP, without a CIDR suffix.')
@minLength(7)
param allowedSourceIp string

@description('Local administrator name. Avoid reserved names such as admin or administrator.')
param adminUsername string = 'foodadmin'

@description('Local administrator password. Never commit this; pass it at deploy time.')
@secure()
param adminPassword string

@description('VM size. D2s_v5 is 2 vCPU / 8 GiB, enough for a browser and the CLIs.')
param vmSize string = 'Standard_D2s_v5'

param jumpboxName string = 'vm-jumpbox'
param subnetName string = 'snet-jumpbox'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-jumpbox'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromOperator'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedSourceIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        // Defence in depth: the default rules already deny this, but an explicit
        // deny keeps intent obvious and survives rule reordering.
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource jumpboxSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: subnetName
  properties: {
    addressPrefix: jumpboxSubnetPrefix
    networkSecurityGroup: {
      id: jumpboxNsg.id
    }
  }
}

resource jumpboxPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${jumpboxName}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource jumpboxNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${jumpboxName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: jumpboxSubnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: jumpboxPublicIp.id
          }
        }
      }
    ]
  }
}

resource jumpbox 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: jumpboxName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: jumpboxName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: jumpboxNic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

output jumpboxPublicIpAddress string = jumpboxPublicIp.properties.ipAddress
output jumpboxPrincipalId string = jumpbox.identity.principalId
output jumpboxSubnetId string = jumpboxSubnet.id
