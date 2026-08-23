targetScope = 'resourceGroup'

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Short workload prefix used in resource names.')
@minLength(2)
@maxLength(10)
param workloadName string = 'qam'

@description('Deployment stage.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string = 'dev'

@description('OCI repository in Azure Container Registry.')
param imageRepository string = 'qam-mcp'

@description('Immutable OCI image manifest digest in sha256:<64-lowercase-hex> form. Required when the Container App is deployed.')
param imageDigest string = ''

@description('Deploy the Container App. Set false for the first phase before the image exists.')
param deployContainerApp bool = true

@description('Expose the Container App through its environment ingress. In private mode this is reachable only through Private Link.')
param externalIngress bool = true

@description('Enable VNet integration and Private Endpoints for ACR, Key Vault, and Container Apps ingress.')
param enablePrivateNetworking bool = false

@description('Enable Container Apps built-in Microsoft Entra token validation. The cloud template requires this to prevent spoofed trusted identity headers.')
@allowed([
  true
])
param enableEntraAuthentication bool = true

@description('Application (client) ID that represents the MCP API. Required when Entra authentication is enabled.')
param mcpApiClientId string = ''

@description('Accepted MCP API audience. Defaults to api://<mcpApiClientId>.')
param mcpApiAudience string = ''

@description('Allowed caller application/client IDs. Both this list and allowedPrincipalIds are enforced by Container Apps authentication.')
@minLength(1)
param allowedClientApplicationIds string[]

@description('Allowed caller service-principal or managed-identity object IDs. Both this list and allowedClientApplicationIds are enforced by Container Apps authentication.')
@minLength(1)
param allowedPrincipalIds string[]

@description('Existing Microsoft Fabric workspace ID that contains the Graph Model.')
param fabricWorkspaceId string = ''

@description('Existing Microsoft Fabric Graph Model ID. The model and its OneLake mappings are created outside this deployment.')
param fabricGraphModelId string = ''

@description('GitHub repository in owner/name form used as the authoritative Markdown content source.')
param githubRepository string = ''

@description('GitHub runtime authentication. app is recommended for private repositories; token is an explicit PoC fallback; none supports public repositories only.')
@allowed([
  'app'
  'token'
  'none'
])
param githubAuthenticationMode string = 'none'

@description('Decimal GitHub App ID. Required only in app mode.')
param githubAppId string = ''

@description('Decimal GitHub App installation ID. Required only in app mode.')
param githubInstallationId string = ''

@description('GitHub REST API origin. Override for GitHub Enterprise Server.')
param githubApiUrl string = 'https://api.github.com'

@description('GitHub web origin used to construct permalinks. Override for GitHub Enterprise Server.')
param githubWebUrl string = 'https://github.com'

@secure()
@description('Versionless Key Vault secret URI containing the GitHub App PEM private key. Required only in app mode; the value never enters ARM.')
param githubPrivateKeySecretUri string = ''

@secure()
@description('Versionless Key Vault secret URI for a read-only GitHub token. Required only in token mode; the token value never enters ARM.')
param githubTokenSecretUri string = ''

@description('Optional ingress allow-list. Each object must contain name, ipAddressRange (CIDR), description, and action=Allow.')
param allowedIngressCidrs array = []

@description('Container CPU cores.')
@allowed([
  '0.25'
  '0.5'
  '0.75'
  '1.0'
  '1.25'
  '1.5'
  '1.75'
  '2.0'
])
param containerCpu string = '0.5'

@description('Container memory allocation.')
@allowed([
  '0.5Gi'
  '1Gi'
  '1.5Gi'
  '2Gi'
  '3.5Gi'
  '4Gi'
])
param containerMemory string = '1Gi'

@description('Minimum number of replicas. Zero enables scale-to-zero for the PoC.')
@minValue(0)
@maxValue(10)
param minReplicas int = 0

@description('Maximum number of replicas.')
@minValue(1)
@maxValue(30)
param maxReplicas int = 2

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Daily Log Analytics ingestion cap in GB. Use -1 for no cap.')
param logDailyQuotaGb int = 1

@description('Optional resource tags merged with the required workload tags.')
param tags object = {}

var suffix = take(uniqueString(subscription().subscriptionId, resourceGroup().id), 6)
var compactPrefix = toLower(replace('${workloadName}${environmentName}${suffix}', '-', ''))
var prefix = toLower('${workloadName}-${environmentName}-${suffix}')
var commonTags = union(tags, {
  application: 'quick-agentic-memory'
  environment: environmentName
  managedBy: 'bicep'
  repository: 'Where-the-Diagram-Ends'
})
var names = {
  app: take('${prefix}-mcp', 32)
  appEnvironment: take('${prefix}-cae', 60)
  appInsights: take('${prefix}-appi', 255)
  keyVault: take(compactPrefix, 24)
  logAnalytics: take('${prefix}-law', 63)
  privateEndpointPrefix: take('${prefix}-pe', 50)
  pullIdentity: take('${prefix}-pull-id', 128)
  registry: take(compactPrefix, 50)
  runtimeIdentity: take('${prefix}-runtime-id', 128)
  virtualNetwork: take('${prefix}-vnet', 64)
}

module identities 'modules/identities.bicep' = {
  name: 'identities-${suffix}'
  params: {
    location: location
    pullIdentityName: names.pullIdentity
    runtimeIdentityName: names.runtimeIdentity
    tags: commonTags
  }
}

module observability 'modules/observability.bicep' = {
  name: 'observability-${suffix}'
  params: {
    appInsightsName: names.appInsights
    dailyQuotaGb: logDailyQuotaGb
    location: location
    logAnalyticsName: names.logAnalytics
    retentionDays: logRetentionDays
    tags: commonTags
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry-${suffix}'
  params: {
    enablePrivateNetworking: enablePrivateNetworking
    registryName: names.registry
    tags: commonTags
  }
}

module keyVault 'modules/key-vault.bicep' = {
  name: 'key-vault-${suffix}'
  params: {
    enablePrivateNetworking: enablePrivateNetworking
    keyVaultName: names.keyVault
    location: location
    tags: commonTags
  }
}

module network 'modules/network.bicep' = if (enablePrivateNetworking) {
  name: 'network-${suffix}'
  params: {
    location: location
    tags: commonTags
    virtualNetworkName: names.virtualNetwork
  }
}

module containerEnvironment 'modules/container-environment.bicep' = {
  name: 'container-environment-${suffix}'
  params: {
    enablePrivateNetworking: enablePrivateNetworking
    environmentName: names.appEnvironment
    infrastructureSubnetId: enablePrivateNetworking ? network!.outputs.infrastructureSubnetId : ''
    location: location
    logAnalyticsId: observability.outputs.logAnalyticsId
    tags: commonTags
  }
}

module privateEndpoints 'modules/private-endpoints.bicep' = if (enablePrivateNetworking) {
  name: 'private-endpoints-${suffix}'
  params: {
    acrPrivateDnsZoneId: network!.outputs.acrPrivateDnsZoneId
    acaPrivateDnsZoneId: network!.outputs.acaPrivateDnsZoneId
    containerEnvironmentId: containerEnvironment.outputs.environmentId
    keyVaultId: keyVault.outputs.keyVaultId
    keyVaultPrivateDnsZoneId: network!.outputs.keyVaultPrivateDnsZoneId
    location: location
    privateEndpointPrefix: names.privateEndpointPrefix
    privateEndpointSubnetId: network!.outputs.privateEndpointSubnetId
    registryId: registry.outputs.registryId
    tags: commonTags
  }
}

module containerApp 'modules/container-app.bicep' = if (deployContainerApp) {
  name: 'container-app-${suffix}'
  params: {
    allowedIngressCidrs: allowedIngressCidrs
    appInsightsAuthenticationString: 'Authorization=AAD;ClientId=${identities.outputs.runtimeClientId}'
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
    appName: names.app
    appFqdn: '${names.app}.${containerEnvironment.outputs.defaultDomain}'
    containerCpu: containerCpu
    containerMemory: containerMemory
    enableEntraAuthentication: enableEntraAuthentication
    environmentId: containerEnvironment.outputs.environmentId
    externalIngress: externalIngress
    fabricGraphModelId: fabricGraphModelId
    fabricWorkspaceId: fabricWorkspaceId
    githubAuthenticationMode: githubAuthenticationMode
    githubApiUrl: githubApiUrl
    githubAppId: githubAppId
    githubInstallationId: githubInstallationId
    githubPrivateKeySecretUri: githubPrivateKeySecretUri
    githubRepository: githubRepository
    githubTokenSecretUri: githubTokenSecretUri
    githubWebUrl: githubWebUrl
    image: '${registry.outputs.loginServer}/${imageRepository}@${imageDigest}'
    keyVaultUri: keyVault.outputs.keyVaultUri
    location: location
    maxReplicas: maxReplicas
    mcpApiAudience: empty(mcpApiAudience) ? 'api://${mcpApiClientId}' : mcpApiAudience
    mcpApiClientId: mcpApiClientId
    allowedClientApplicationIds: allowedClientApplicationIds
    allowedPrincipalIds: allowedPrincipalIds
    minReplicas: minReplicas
    pullIdentityId: identities.outputs.pullIdentityId
    runtimeClientId: identities.outputs.runtimeClientId
    runtimeIdentityId: identities.outputs.runtimeIdentityId
    tags: commonTags
  }
}

output acrLoginServer string = registry.outputs.loginServer
output acrName string = registry.outputs.registryName
output appName string = deployContainerApp ? containerApp!.outputs.appName : ''
output appUrl string = deployContainerApp ? containerApp!.outputs.appUrl : ''
@description('Deterministic future Container App ARM resource ID used to bind the Foundry access receipt before the app exists.')
output plannedAppResourceId string = resourceId('Microsoft.App/containerApps', names.app)
@description('Deterministic future Container App ingress FQDN. An output value does not prove that the app exists or is reachable.')
output plannedAppFqdn string = externalIngress ? '${names.app}.${containerEnvironment.outputs.defaultDomain}' : ''
@description('Deterministic future Container App base URL used during two-phase caller bootstrap. Append /mcp for the Foundry RemoteTool target. An output value does not prove reachability.')
output plannedAppUrl string = externalIngress ? 'https://${names.app}.${containerEnvironment.outputs.defaultDomain}' : ''
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output runtimeIdentityClientId string = identities.outputs.runtimeClientId
output runtimeIdentityPrincipalId string = identities.outputs.runtimePrincipalId
output runtimeIdentityName string = names.runtimeIdentity
output privateNetworkingEnabled bool = enablePrivateNetworking
