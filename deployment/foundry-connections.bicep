/*
Foundry project connection to the Databricks Genie MCP endpoint.

Connections are ARM resources, so this deploys from anywhere even though the Foundry
project has publicNetworkAccess Disabled. Toolboxes and agents are data-plane only and
still require an in-VNet client; see deployment/run-on-jumpbox.ps1.

Two details are load-bearing and were both found the hard way:

  1. `audience` must be the Databricks application ID GUID. The alternative identifier
     https://azuredatabricks.net/ is a valid Entra identifier, but Databricks validates
     the `aud` claim against the GUID and rejects the URI form with HTTP 400.

  2. ProjectManagedIdentity resolves to the Foundry *account* system-assigned identity,
     not the project identity. That account identity is what must be registered in
     Databricks; see deployment/grant-databricks-identity.ps1.
*/

@description('Name of the existing Foundry (Cognitive Services) account.')
@minLength(1)
param foundryAccountName string

@description('Name of the existing Foundry project.')
@minLength(1)
param foundryProjectName string

@description('Per-workspace Databricks URL, for example https://adb-1234567890123456.7.azuredatabricks.net')
@minLength(1)
param databricksHost string

@description('Genie space ID the agent queries.')
@minLength(1)
param genieSpaceId string

param connectionName string = 'databricks-genie'

// Entra application ID of the first-party AzureDatabricks service.
var databricksResourceId = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName

  resource project 'projects' existing = {
    name: foundryProjectName
  }
}

resource genieConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: foundryAccount::project
  name: connectionName
  properties: {
    category: 'RemoteTool'
    authType: 'ProjectManagedIdentity'
    target: '${databricksHost}/api/2.0/mcp/genie/${genieSpaceId}'
    // The service stores false regardless of what is sent; kept aligned so repeat
    // deployments do not report a spurious change.
    isSharedToAll: false
    audience: databricksResourceId
    metadata: {
      ApiType: 'Azure'
    }
  }
}

output connectionId string = genieConnection.id
output genieMcpTarget string = genieConnection.properties.target
