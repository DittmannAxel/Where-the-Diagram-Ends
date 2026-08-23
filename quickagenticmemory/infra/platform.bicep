targetScope = 'resourceGroup'

@description('Azure region for Fabric capacity and Microsoft Foundry resources.')
param location string = resourceGroup().location

@description('Short workload prefix used in globally unique names.')
@minLength(2)
@maxLength(10)
param workloadName string = 'qam'

@description('Deployment stage.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string = 'test'

@description('User principal names that administer the Fabric capacity. Supply at deployment time; do not hard-code tenant identities.')
@minLength(1)
param fabricAdminMembers string[]

@description('Smallest Fabric capacity suitable for the Graph proof.')
@allowed([
  'F2'
  'F4'
  'F8'
  'F16'
  'F32'
  'F64'
])
param fabricSkuName string = 'F2'

@description('Operator Entra object ID that receives Foundry Project Manager on the Foundry account so Agent Applications can be published. Supply at deployment time.')
param operatorPrincipalId string = ''

@description('Chat model selected only after live catalog and quota discovery.')
param chatModelName string = 'gpt-5.4-mini'

@description('Pinned chat model version selected from the regional catalog.')
param chatModelVersion string = '2026-03-17'

@description('GlobalStandard deployment quota in thousands of tokens per minute.')
@minValue(1)
param chatModelCapacity int = 50

@description('Optional resource tags merged with the required workload tags.')
param tags object = {}

var suffix = take(uniqueString(subscription().subscriptionId, resourceGroup().id), 6)
var compactPrefix = toLower(replace('${workloadName}${environmentName}${suffix}', '-', ''))
var commonTags = union(tags, {
  application: 'quick-agentic-memory'
  dataClassification: 'public-synthetic'
  environment: environmentName
  managedBy: 'bicep'
  repository: 'Where-the-Diagram-Ends'
})
var names = {
  fabricCapacity: take('${compactPrefix}fabric', 63)
  foundryAccount: take('${compactPrefix}foundry', 64)
  foundryProject: take('${workloadName}-${environmentName}-industrial', 64)
  chatDeployment: take('${chatModelName}-${environmentName}', 64)
}
var foundryProjectManagerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'eadc314b-1a2d-4efa-be10-5d325db5065e'
)

resource fabricCapacity 'Microsoft.Fabric/capacities@2023-11-01' = {
  name: names.fabricCapacity
  location: location
  tags: commonTags
  sku: {
    name: fabricSkuName
    tier: 'Fabric'
  }
  properties: {
    administration: {
      members: fabricAdminMembers
    }
  }
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: names.foundryAccount
  location: location
  tags: commonTags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: names.foundryAccount
    disableLocalAuth: true
    dynamicThrottlingEnabled: true
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: false
  }
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  name: names.foundryProject
  parent: foundryAccount
  location: location
  tags: commonTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Synthetic industrial component-obsolescence proof for Quick Agentic Memory.'
    displayName: 'QAM industrial evidence test'
  }
}

resource chatModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  name: names.chatDeployment
  parent: foundryAccount
  sku: {
    name: 'GlobalStandard'
    capacity: chatModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: chatModelVersion
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource operatorProjectManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorPrincipalId)) {
  name: guid(foundryAccount.id, operatorPrincipalId, foundryProjectManagerRoleId)
  scope: foundryAccount
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: foundryProjectManagerRoleId
  }
}

output fabricCapacityId string = fabricCapacity.id
output fabricCapacityName string = fabricCapacity.name
output fabricCapacitySku string = fabricCapacity.sku.name
output foundryAccountName string = foundryAccount.name
output foundryProjectId string = foundryProject.id
output foundryProjectName string = foundryProject.name
output foundryProjectEndpoint string = 'https://${foundryAccount.name}.services.ai.azure.com/api/projects/${foundryProject.name}'
output foundryModelDeploymentName string = chatModelDeployment.name
output foundryModelName string = chatModelName
output foundryModelVersion string = chatModelVersion
