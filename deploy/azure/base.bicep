param location string = resourceGroup().location

var suffix = uniqueString(resourceGroup().id)

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'ploggr${suffix}'
  location: location
  sku: { name: 'Standard' }
  properties: { adminUserEnabled: false }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'ploggr${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storage
}

resource evidence 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blob
  name: 'evidence'
  properties: { publicAccess: 'None' }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  location: location
  name: 'ploggr-field'
}

var pullRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var blobRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource registryAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, identity.id, pullRole)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: pullRole
  }
}

resource evidenceAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: evidence
  name: guid(evidence.id, identity.id, blobRole)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobRole
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: 'ploggr-field'
  location: location
  properties: {
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
  }
}

output environmentId string = environment.id
output identityId string = identity.id
output identityClientId string = identity.properties.clientId
output registryHost string = registry.properties.loginServer
output registryName string = registry.name
output registryId string = registry.id
output evidenceUrl string = '${storage.properties.primaryEndpoints.blob}${evidence.name}'
