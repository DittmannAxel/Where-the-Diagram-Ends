targetScope = 'resourceGroup'

@description('Short workload prefix used by the existing QAM foundation resources.')
@minLength(2)
@maxLength(10)
param workloadName string = 'qam'

@description('Deployment stage of the existing QAM foundation resources.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string

@description('Object ID of the GitHub OIDC deployment identity. It receives Container Registry Repository Writer on the existing registry only.')
@minLength(36)
@maxLength(36)
param deploymentPrincipalId string

var suffix = take(uniqueString(subscription().subscriptionId, resourceGroup().id), 6)
var compactPrefix = toLower(replace('${workloadName}${environmentName}${suffix}', '-', ''))
var prefix = toLower('${workloadName}-${environmentName}-${suffix}')
var names = {
  appInsights: take('${prefix}-appi', 255)
  keyVault: take(compactPrefix, 24)
  pullIdentity: take('${prefix}-pull-id', 128)
  registry: take(compactPrefix, 50)
  runtimeIdentity: take('${prefix}-runtime-id', 128)
}

var repositoryReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b93aa761-3e63-49ed-ac28-beffa264f7ac'
)
var repositoryWriterRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a1e307c-b015-4ebd-883e-5b7698a07328'
)
var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)
var monitoringMetricsPublisherRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)
var keyVaultRbacPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '12d4fa5e-1f9f-4c21-97a9-b99b3c6611b5'
)

// Every workload resource is an existing reference. This administrator template
// cannot create or reconcile the QAM foundation or application configuration.
resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  #disable-next-line BCP334 // workloadName + environmentName + six-character suffix always exceeds the ACR minimum.
  name: names.registry
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: names.keyVault
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.appInsights
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: names.pullIdentity
}

resource runtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: names.runtimeIdentity
}

resource registryReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, pullIdentity.id, repositoryReaderRoleId)
  scope: registry
  properties: {
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryReaderRoleId
  }
}

resource registryWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, toLower(deploymentPrincipalId), repositoryWriterRoleId)
  scope: registry
  properties: {
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryWriterRoleId
  }
}

resource keyVaultSecretsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, runtimeIdentity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: runtimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

resource telemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, runtimeIdentity.id, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    principalId: runtimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringMetricsPublisherRoleId
  }
}

// Contributor can otherwise switch Key Vault back to legacy access policies and
// grant itself data-plane access. The assignment is deliberately resource-group
// scoped and is reconciled only through this separately governed template.
resource enforceKeyVaultRbac 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
  name: guid(resourceGroup().id, keyVaultRbacPolicyDefinitionId)
  properties: {
    description: 'Prevent QAM resource-group contributors from disabling the Key Vault RBAC permission model.'
    displayName: 'QAM requires the Key Vault RBAC permission model'
    enforcementMode: 'Default'
    nonComplianceMessages: [
      {
        message: 'QAM Key Vaults must keep enableRbacAuthorization=true; legacy access policies are prohibited.'
      }
    ]
    parameters: {
      effect: {
        value: 'Deny'
      }
    }
    policyDefinitionId: keyVaultRbacPolicyDefinitionId
  }
  dependsOn: [
    registryReader
    registryWriter
    keyVaultSecretsReader
    telemetryPublisher
  ]
}

output roleAssignmentIds array = [
  registryReader.id
  registryWriter.id
  keyVaultSecretsReader.id
  telemetryPublisher.id
]
output keyVaultRbacPolicyAssignmentId string = enforceKeyVaultRbac.id
