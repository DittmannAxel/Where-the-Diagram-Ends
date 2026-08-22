targetScope = 'resourceGroup'

param location string
param appName string
param appFqdn string
param environmentId string
param image string
param runtimeIdentityId string
param runtimeClientId string
param pullIdentityId string
param keyVaultUri string
param appInsightsConnectionString string
param appInsightsAuthenticationString string
param fabricWorkspaceId string
param fabricGraphModelId string
param githubRepository string
param githubAuthenticationMode string
param githubAppId string
param githubInstallationId string
param githubApiUrl string
param githubWebUrl string
@secure()
param githubPrivateKeySecretUri string
@secure()
param githubTokenSecretUri string
param externalIngress bool
param allowedIngressCidrs array
param enableEntraAuthentication bool
param mcpApiClientId string
param mcpApiAudience string
param allowedClientApplicationIds string[]
param allowedPrincipalIds string[]
param containerCpu string
param containerMemory string
param minReplicas int
param maxReplicas int
param tags object

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${runtimeIdentityId}': {}
      '${pullIdentityId}': {}
    }
  }
  properties: {
    configuration: {
      activeRevisionsMode: 'Single'
      identitySettings: [
        {
          identity: runtimeIdentityId
          lifecycle: 'Main'
        }
        {
          identity: pullIdentityId
          lifecycle: 'None'
        }
      ]
      ingress: {
        allowInsecure: false
        external: externalIngress
        ipSecurityRestrictions: allowedIngressCidrs
        targetPort: 3000
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
        transport: 'auto'
      }
      maxInactiveRevisions: 3
      registries: [
        {
          identity: pullIdentityId
          server: split(image, '/')[0]
        }
      ]
      secrets: githubAuthenticationMode == 'app' ? [
          {
            name: 'github-private-key'
            keyVaultUrl: githubPrivateKeySecretUri
            identity: runtimeIdentityId
          }
        ] : githubAuthenticationMode == 'token' ? [
          {
            name: 'github-token'
            keyVaultUrl: githubTokenSecretUri
            identity: runtimeIdentityId
          }
        ] : []
    }
    environmentId: environmentId
    template: {
      containers: [
        {
          name: 'mcp'
          image: image
          env: concat([
            {
              name: 'PORT'
              value: '3000'
            }
            {
              name: 'QAM_TRANSPORT'
              value: 'http'
            }
            {
              name: 'QAM_HTTP_HOST'
              value: '0.0.0.0'
            }
            {
              name: 'QAM_HTTP_PORT'
              value: '3000'
            }
            {
              name: 'QAM_HTTP_AUTH_MODE'
              value: 'trusted-header'
            }
            {
              name: 'QAM_TRUSTED_IDENTITY_HEADER'
              value: 'x-ms-client-principal-id'
            }
            {
              name: 'QAM_HTTP_ALLOWED_HOSTS'
              value: '${appFqdn},localhost,127.0.0.1'
            }
            {
              name: 'QAM_HTTP_ALLOWED_ORIGINS'
              value: appFqdn
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: runtimeClientId
            }
            {
              name: 'QAM_AZURE_CLIENT_ID'
              value: runtimeClientId
            }
            {
              name: 'QAM_GRAPH_ADAPTER'
              value: 'fabric-gql'
            }
            {
              name: 'QAM_FABRIC_WORKSPACE_ID'
              value: fabricWorkspaceId
            }
            {
              name: 'QAM_FABRIC_GRAPH_MODEL_ID'
              value: fabricGraphModelId
            }
            {
              name: 'QAM_FABRIC_API_URL'
              value: 'https://api.fabric.microsoft.com'
            }
            {
              name: 'QAM_FABRIC_TOKEN_SCOPE'
              value: 'https://api.fabric.microsoft.com/.default'
            }
            {
              name: 'QAM_CONTENT_ADAPTER'
              value: 'github'
            }
            {
              name: 'QAM_GITHUB_REPOSITORY'
              value: githubRepository
            }
            {
              name: 'QAM_SOURCE_REPOSITORY'
              value: '${githubWebUrl}/${githubRepository}'
            }
            {
              name: 'QAM_GITHUB_AUTH_MODE'
              value: githubAuthenticationMode
            }
            {
              name: 'QAM_GITHUB_API_URL'
              value: githubApiUrl
            }
            {
              name: 'QAM_GITHUB_WEB_URL'
              value: githubWebUrl
            }
            {
              name: 'AZURE_KEY_VAULT_URL'
              value: keyVaultUri
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsightsConnectionString
            }
            {
              name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
              value: appInsightsAuthenticationString
            }
          ], githubAuthenticationMode == 'app' ? [
            {
              name: 'QAM_GITHUB_APP_ID'
              value: githubAppId
            }
            {
              name: 'QAM_GITHUB_INSTALLATION_ID'
              value: githubInstallationId
            }
            {
              name: 'QAM_GITHUB_PRIVATE_KEY'
              secretRef: 'github-private-key'
            }
          ] : githubAuthenticationMode == 'token' ? [
            {
              name: 'QAM_GITHUB_TOKEN'
              secretRef: 'github-token'
            }
          ] : [])
          probes: [
            {
              type: 'Startup'
              httpGet: {
                path: '/healthz'
                port: 3000
                scheme: 'HTTP'
              }
              failureThreshold: 10
              periodSeconds: 5
              timeoutSeconds: 3
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 3000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              failureThreshold: 3
              periodSeconds: 30
              timeoutSeconds: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 3000
                scheme: 'HTTP'
              }
              failureThreshold: 3
              periodSeconds: 10
              successThreshold: 1
              timeoutSeconds: 3
            }
          ]
          resources: {
            cpu: json(containerCpu)
            memory: containerMemory
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: {
              metadata: {
                concurrentRequests: '20'
              }
            }
          }
        ]
      }
      terminationGracePeriodSeconds: 30
    }
    workloadProfileName: 'Consumption'
  }
}

resource authConfig 'Microsoft.App/containerApps/authConfigs@2025-01-01' = if (enableEntraAuthentication) {
  parent: app
  name: 'current'
  properties: {
    globalValidation: {
      excludedPaths: [
        '/healthz'
      ]
      unauthenticatedClientAction: 'Return401'
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: mcpApiClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            mcpApiAudience
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: allowedClientApplicationIds
            allowedPrincipals: {
              groups: []
              identities: allowedPrincipalIds
            }
          }
        }
      }
    }
    platform: {
      enabled: true
    }
  }
}

output appName string = app.name
output appUrl string = externalIngress ? 'https://${app.properties.configuration.ingress.fqdn}' : ''
