/*
Unity Catalog managed storage for the Databricks demo.

The auto-provisioned metastore has no storage root, so catalogs need an explicit managed location.
This creates an ADLS Gen2 account (hierarchical namespace is required for UC external locations),
an Access Connector whose managed identity holds Storage Blob Data Contributor, and private
endpoints for both the blob and dfs sub-resources.

Reached privately from the VNet-injected Databricks data plane, so the storage account keeps
public network access disabled. This is why the SQL warehouse must be Pro rather than serverless:
serverless compute runs outside the VNet and would need account-level NCC private endpoints.
*/

@description('Azure region. Must match the VNet region.')
param location string

@description('Name of the existing VNet created by template-19/main.bicep.')
param vnetName string

@description('Name of the existing private endpoint subnet.')
param peSubnetName string = 'snet-private-endpoints'

@description('Storage account for Unity Catalog managed tables. 3-24 lowercase alphanumeric characters.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'ucfoodanalyticsswc'

@description('Container holding the catalog managed location.')
param containerName string = 'unity-catalog'

@description('Name of the Databricks Access Connector.')
param accessConnectorName string = 'ac-food-analytics-swc'

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var dfsDnsZoneName = 'privatelink.dfs.${environment().suffixes.storage}'
var blobDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName

  resource peSubnet 'subnets' existing = {
    name: peSubnetName
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }

  resource blobServices 'blobServices' = {
    name: 'default'

    resource container 'containers' = {
      name: containerName
    }
  }
}

resource accessConnector 'Microsoft.Databricks/accessConnectors@2024-05-01' = {
  name: accessConnectorName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, accessConnector.id, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: accessConnector.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Unity Catalog refuses to register the credential unless the identity can read its own connector.
resource accessConnectorSelfReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: accessConnector
  name: guid(accessConnector.id, readerRoleId, 'self')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: accessConnector.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// The blob zone already exists from template-19; only the dfs zone is new.
resource dfsDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: dfsDnsZoneName
  location: 'global'
}

resource dfsDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dfsDnsZone
  name: '${vnetName}-dfs-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${storageAccountName}-dfs-pe'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'dfs'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'dfs'
          ]
        }
      }
    ]
  }
}

resource storageDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: 'dfs-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'dfs'
        properties: {
          privateDnsZoneId: dfsDnsZone.id
        }
      }
    ]
  }
}

output storageAccountName string = storage.name
output accessConnectorId string = accessConnector.id
output managedLocationUrl string = 'abfss://${containerName}@${storage.name}.dfs.${environment().suffixes.storage}/'
output blobDnsZoneName string = blobDnsZoneName
