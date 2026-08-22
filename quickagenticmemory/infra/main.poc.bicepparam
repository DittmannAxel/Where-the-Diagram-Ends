using './main.bicep'

// Public PoC baseline. Replace placeholder values at deployment time.
param location = 'westeurope'
param workloadName = 'qam'
param environmentName = 'dev'
param imageRepository = 'qam-mcp'
param imageDigest = ''
param deployContainerApp = false
param deployRoleAssignments = false
param externalIngress = true
param enablePrivateNetworking = false
param enableEntraAuthentication = true
param mcpApiClientId = '<mcp-api-application-client-id>'
param allowedClientApplicationIds = [
  '<allowed-caller-application-client-id>'
]
param allowedPrincipalIds = [
  '<allowed-caller-service-principal-object-id>'
]
param fabricWorkspaceId = '<fabric-workspace-id>'
param fabricGraphModelId = '<fabric-graph-model-id>'
param githubRepository = '<github-owner>/<github-repository>'
param githubAuthenticationMode = 'none'
param githubAppId = ''
param githubInstallationId = ''
param githubPrivateKeySecretUri = ''
param githubTokenSecretUri = ''
param deploymentPrincipalId = ''
param minReplicas = 0
param maxReplicas = 2
param logRetentionDays = 30
param logDailyQuotaGb = 1
param tags = {
  dataClassification: 'internal'
  owner: 'replace-with-owner'
}
