@description('Name of the jump box virtual machine.')
param vmName string = 'vm-jump-we'

@description('Region for the jump box and Bastion host.')
param location string

@description('Resource ID of the subnet that hosts the jump box NIC.')
param jumpboxSubnetId string

@description('Resource ID of the AzureBastionSubnet.')
param bastionSubnetId string

@description('Bastion SKU. Developer is free but does not support virtual network peering, which this topology uses.')
@allowed(['Basic', 'Standard'])
param bastionSku string = 'Basic'

@description('Local administrator name for the jump box.')
param adminUsername string = 'azureuser'

@description('Local administrator password. Supplied at deploy time, never stored in a parameter file.')
@secure()
param adminPassword string

@description('Virtual machine size. D-series v5 sizes are restricted on this subscription in West Europe; v6 AMD sizes are available.')
param vmSize string = 'Standard_D2as_v6'

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-bastion-${vmName}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'bas-${vmName}'
  location: location
  sku: {
    name: bastionSku
  }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${vmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: jumpboxSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// System-assigned identity so you can 'az login --identity' on the box instead of
// carrying credentials into the private network.
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
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
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: take(vmName, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output vmName string = vm.name
output bastionName string = bastion.name
output vmPrincipalId string = vm.identity.principalId
