targetScope = 'resourceGroup'

param location string
param pullIdentityName string
param runtimeIdentityName string
param tags object

resource runtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: runtimeIdentityName
  location: location
  tags: tags
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: pullIdentityName
  location: location
  tags: tags
}

output runtimeIdentityId string = runtimeIdentity.id
output runtimePrincipalId string = runtimeIdentity.properties.principalId
output runtimeClientId string = runtimeIdentity.properties.clientId
output pullIdentityId string = pullIdentity.id
output pullPrincipalId string = pullIdentity.properties.principalId
