param location string = resourceGroup().location
param environmentId string
param identityId string
param identityClientId string
param registryHost string
param evidenceUrl string
param databaseHost string
param databaseName string = 'ploggr_field'
param databaseUser string = 'ploggr_field'
param geminiModel string
@secure()
param databasePassword string
@secure()
param scalerConnection string
@secure()
param authSecret string
@secure()
param geminiKey string
@secure()
param fieldEmail string

var placeholder = 'docker.io/nginxinc/nginx-unprivileged:stable-alpine'
var registry = { server: registryHost, identity: identityId }
var databaseVariables = [
  { name: 'DB_HOST', value: databaseHost }
  { name: 'DB_NAME', value: databaseName }
  { name: 'DB_USER', value: databaseUser }
  { name: 'DB_PASSWORD', secretRef: 'database-password' }
  { name: 'DB_TLS', value: 'true' }
]
var databaseSecret = { name: 'database-password', value: databasePassword }

resource api 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'ploggr-field-api'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      maxInactiveRevisions: 5
      ingress: { external: true, targetPort: 8080, allowInsecure: false, transport: 'auto' }
      registries: [registry]
      secrets: [
        databaseSecret
        { name: 'scaler-connection', value: scalerConnection }
        { name: 'auth-secret', value: authSecret }
        { name: 'gemini-key', value: geminiKey }
        { name: 'field-email', value: fieldEmail }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: placeholder
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(databaseVariables, [
            { name: 'AUTH_SECRET', secretRef: 'auth-secret' }
            { name: 'AUTH_FIELD_TEST_EMAIL', secretRef: 'field-email' }
            { name: 'GEMINI_API_KEY', secretRef: 'gemini-key' }
            { name: 'GEMINI_MODEL', value: geminiModel }
            { name: 'GEMINI_FALLBACK_MODELS', value: '' }
            { name: 'EVIDENCE_AZURE_CONTAINER_URL', value: evidenceUrl }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
          ])
        }
      ]
      scale: { minReplicas: 0, maxReplicas: 1 }
    }
  }
}

resource migration 'Microsoft.App/jobs@2025-07-01' = {
  name: 'ploggr-field-migrate'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 300
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: [registry]
      secrets: [databaseSecret]
    }
    template: {
      containers: [
        {
          name: 'migration'
          image: placeholder
          command: ['npm']
          args: ['run', 'migration:run:prod']
          env: databaseVariables
          resources: { cpu: json('0.5'), memory: '1Gi' }
        }
      ]
    }
  }
}

output apiUrl string = 'https://${api.properties.configuration.ingress.fqdn}/api/'
output apiId string = api.id
output migrationId string = migration.id
output outboundIps array = api.properties.outboundIpAddresses
