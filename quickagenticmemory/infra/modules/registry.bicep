targetScope = 'resourceGroup'

param registryName string
param pullPrincipalId string
param deploymentPrincipalId string
param deployRoleAssignments bool
param enablePrivateNetworking bool
param tags object

var repositoryReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b93aa761-3e63-49ed-ac28-beffa264f7ac'
)
var repositoryWriterRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a1e307c-b015-4ebd-883e-5b7698a07328'
)

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

resource pullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(registry.id, pullPrincipalId, repositoryReaderRoleId)
  scope: registry
  properties: {
    principalId: pullPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryReaderRoleId
  }
}

resource pushRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments && !empty(deploymentPrincipalId)) {
  name: guid(registry.id, deploymentPrincipalId, repositoryWriterRoleId)
  scope: registry
  properties: {
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryWriterRoleId
  }
}

output registryId string = registry.id
output registryName string = registry.name
output loginServer string = registry.properties.loginServer
