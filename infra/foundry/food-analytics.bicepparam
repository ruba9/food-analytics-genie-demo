using 'main.bicep'

// Foundry and its injected VNet must share a region, so this is pinned to West Europe.
// The Databricks workspace stays in North Europe.
param location = 'westeurope'

param aiServices = 'foodanalytics'
param firstProjectName = 'foodanalytics'
param displayName = 'Contoso Foods analytics agent'
param projectDescription = 'Network-isolated Foundry agent calling the Databricks Genie MCP endpoint'

// The network stage owns the VNet. Passing the subnets as existing IDs makes this
// template reference them rather than rewrite the VNet's inline subnet list, which
// would otherwise drop the Bastion and jump box subnets on every redeploy.
// deploy.ps1 populates these from the network deployment outputs.
param existingVnetResourceId = readEnvironmentVariable('AZURE_VNET_RESOURCE_ID', '')
param existingAgentSubnetResourceId = readEnvironmentVariable('AZURE_AGENT_SUBNET_ID', '')
param existingPeSubnetResourceId = readEnvironmentVariable('AZURE_PE_SUBNET_ID', '')
param existingMcpSubnetResourceId = readEnvironmentVariable('AZURE_MCP_SUBNET_ID', '')

// Cosmos has no capacity in West Europe, North Europe or East US on this subscription,
// but does in Sweden Central. Its data region is independent of the Foundry region,
// which must stay co-located with the VNet.
param existingAzureCosmosDBAccountResourceId = readEnvironmentVariable('AZURE_COSMOSDB_ACCOUNT_RESOURCE_ID', '')

// gpt-4o-mini is flagged deprecating and rejected for new deployments, despite its
// listed retirement date still being in the future.
param modelName = 'gpt-4.1-mini'
param modelFormat = 'OpenAI'
param modelVersion = '2025-04-14'
param modelSkuName = 'GlobalStandard'
param modelCapacity = 30

// Holds the public CA chain for the Databricks TLS certificate if the agent runtime
// needs to trust it explicitly; harmless to keep enabled otherwise.
param enableKeyVault = true

// Not needed for a prompt agent calling a remote MCP endpoint, and Premium ACR is
// the single largest line item in this stack.
param enableContainerRegistry = false

param projectCapHost = 'caphostproj'
