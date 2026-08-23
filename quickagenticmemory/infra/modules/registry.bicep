targetScope = 'resourceGroup'

param registryName string
param enablePrivateNetworking bool
param tags object

resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: registryName
  location: resourceGroup().location
  tags: tags
  sku: {
    name: enablePrivateNetworking ? 'Premium' : 'Standard'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    dataEndpointEnabled: enablePrivateNetworking
    networkRuleBypassOptions: 'AzureServices'
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    roleAssignmentMode: 'AbacRepositoryPermissions'
    zoneRedundancy: 'Disabled'
  }
}

output registryId string = registry.id
output registryName string = registry.name
output loginServer string = registry.properties.loginServer
