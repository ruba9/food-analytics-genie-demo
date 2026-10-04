using './template-19/main.bicep'

param location = 'swedencentral'
// Derived names append a 4-char suffix plus a resource word; storage caps at 24 chars.
param aiServices = 'foodgenie'
param firstProjectName = 'food-analytics-genie'
param projectDescription = 'Private food analytics agent over governed Databricks Genie data'
param displayName = 'Food Analytics Genie'

param modelName = 'gpt-5.1'
param modelFormat = 'OpenAI'
param modelVersion = '2025-11-13'
param modelSkuName = 'Standard'
param modelCapacity = 100

param vnetName = 'vnet-food-analytics-genie-swc'
param agentSubnetName = 'snet-foundry-agent'
param peSubnetName = 'snet-private-endpoints'
param mcpSubnetName = 'snet-mcp-tools'
param vnetAddressPrefix = '10.19.0.0/16'
param agentSubnetPrefix = '10.19.0.0/24'
param peSubnetPrefix = '10.19.1.0/24'
param mcpSubnetPrefix = '10.19.2.0/24'

// Databricks VNet injection. Both subnets are permanent for the life of the workspace.
param databricksHostSubnetPrefix = '10.19.3.0/24'
param databricksContainerSubnetPrefix = '10.19.4.0/24'
// Required, with no default: an empty value would detach the NSG from the Databricks
// subnets on redeploy. Set DATABRICKS_NSG_ID to the NSG's full resource ID first.
param databricksNsgId = readEnvironmentVariable('DATABRICKS_NSG_ID')

// Required by the vendored template. Left empty: no Fabric workspace is in scope.
param existingFabricWorkspaceResourceId = ''
param enableKeyVault = true
param enableContainerRegistry = true
param developerIpCidr = ''
