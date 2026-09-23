targetScope = 'resourceGroup'

@description('Name of the Key Vault.')
param keyVaultName string

@description('Principal ID of the Foundry account system-assigned managed identity.')
param accountPrincipalId string

var keyVaultSecretsUserRoleGuid = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource keyVaultSecretsUserRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  scope: subscription()
  name: keyVaultSecretsUserRoleGuid
}

resource keyVaultSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, accountPrincipalId, keyVaultSecretsUserRoleDefinition.id)
  properties: {
    principalId: accountPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleDefinition.id
  }
}
