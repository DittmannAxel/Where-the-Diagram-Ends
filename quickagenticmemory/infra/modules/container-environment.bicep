targetScope = 'resourceGroup'

param location string
param environmentName string
param enablePrivateNetworking bool
param infrastructureSubnetId string
param logAnalyticsId string
param tags object

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    vnetConfiguration: enablePrivateNetworking ? {
      infrastructureSubnetId: infrastructureSubnetId
      internal: false
    } : {}
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

// Azure Monitor routing avoids a Log Analytics shared key in the deployment.
#disable-next-line use-recent-api-versions // Latest diagnostic-settings API; still preview despite its date.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: environment
  name: 'send-to-log-analytics'
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsId
  }
}

output environmentId string = environment.id
output defaultDomain string = environment.properties.defaultDomain
