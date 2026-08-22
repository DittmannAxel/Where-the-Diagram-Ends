targetScope = 'resourceGroup'

param location string
param privateEndpointPrefix string
param privateEndpointSubnetId string
param registryId string
param keyVaultId string
param containerEnvironmentId string
param acrPrivateDnsZoneId string
param keyVaultPrivateDnsZoneId string
param acaPrivateDnsZoneId string
param tags object

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-01-01' = {
  name: '${privateEndpointPrefix}-acr'
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'registry'
        properties: {
          groupIds: [
            'registry'
          ]
          privateLinkServiceId: registryId
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
  }
}

resource acrDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-01-01' = {
  parent: acrPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'acr'
        properties: {
          privateDnsZoneId: acrPrivateDnsZoneId
        }
      }
    ]
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-01-01' = {
  name: '${privateEndpointPrefix}-kv'
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          groupIds: [
            'vault'
          ]
          privateLinkServiceId: keyVaultId
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
  }
}

resource keyVaultDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-01-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'key-vault'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZoneId
        }
      }
    ]
  }
}

resource acaPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-01-01' = {
  name: '${privateEndpointPrefix}-aca'
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'managed-environment'
        properties: {
          groupIds: [
            'managedEnvironment'
          ]
          privateLinkServiceId: containerEnvironmentId
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
  }
}

resource acaDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-01-01' = {
  parent: acaPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'container-apps'
        properties: {
          privateDnsZoneId: acaPrivateDnsZoneId
        }
      }
    ]
  }
}
