using 'main.bicep'

param location = 'westeurope'
param vnetName = 'vnet-foundry-we'

// VERIFY BEFORE DEPLOY: must not overlap the North Europe Databricks network
// (10.200.0.0/16) or any on-premises range, because the two VNets are peered.
param vnetAddressPrefix = '10.100.0.0/16'
param agentSubnetPrefix = '10.100.0.0/24'
param peSubnetPrefix = '10.100.1.0/24'
param mcpSubnetPrefix = '10.100.2.0/24'
param bastionSubnetPrefix = '10.100.3.0/26'
param jumpboxSubnetPrefix = '10.100.4.0/24'

// Bastion and the jump box are the only way in: every endpoint in this environment
// has public network access disabled.
param deployJumpbox = true

// Developer SKU is free but does not support virtual network peering, which this
// topology depends on to reach North Europe.
param bastionSku = 'Basic'

// Prompted by deploy.ps1 and passed through the environment, so it never lands
// in this file, on disk, or in the command line.
param jumpboxAdminPassword = readEnvironmentVariable('JUMPBOX_ADMIN_PASSWORD', '')
