@description('Location for all resources.')
param location string
param tags object = {}
param resourceToken string

param crawlSitemapUrls string
param crawlAllowedDomains string
param crawlAssetHosts string

@description('Initial Job image; replaced by the postprovision hook after the real image is built.')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart-jobs:latest'

param cron string
param replicaTimeout int
param snapshotRetentionDays int
param embedModel string
param embedDeployment string
param embedCapacity int
param embedSku string
param indexName string

@description('Initial web image; replaced by azd deploy after the real image is built.')
param webImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

var blobContainers = [ 'pages', 'images', 'docs', 'snapshots' ]

// Built-in role definition IDs.
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleStorageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var roleAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var roleOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var roleSearchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${resourceToken}'
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: 'acr${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${resourceToken}'
  location: location
  tags: tags
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for name in blobContainers: {
  parent: blobService
  name: name
}]

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'expire-snapshots'
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: [ 'blockBlob' ], prefixMatch: [ 'snapshots/' ] }
            actions: { baseBlob: { delete: { daysAfterModificationGreaterThan: snapshotRetentionDays } } }
          }
        }
      ]
    }
  }
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: 'crawler-job-${resourceToken}'
  location: location
  tags: union(tags, { 'azd-service-name': 'crawler' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    environmentId: acaEnv.id
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: replicaTimeout
      replicaRetryLimit: 1
      scheduleTriggerConfig: {
        cronExpression: cron
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: uami.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'crawler'
          image: containerImage
          resources: {
            cpu: json('2.0')
            memory: '4Gi'
          }
          env: [
            { name: 'STORAGE_ACCOUNT_URL', value: 'https://${storage.name}.blob.${environment().suffixes.storage}' }
            { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
            { name: 'CRAWL_SITEMAP_URLS', value: crawlSitemapUrls }
            { name: 'CRAWL_ALLOWED_DOMAINS', value: crawlAllowedDomains }
            { name: 'CRAWL_ASSET_HOSTS', value: crawlAssetHosts }
            { name: 'CAPTURE_SNAPSHOTS', value: 'true' }
            { name: 'SNAPSHOT_PDF', value: 'true' }
            { name: 'INCREMENTAL', value: 'true' }
            { name: 'HARVEST_RENDERED_IMAGES', value: 'true' }
          ]
        }
      ]
    }
  }
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: 'srch-${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'standard' }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'free'
    publicNetworkAccess: 'enabled'
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'aif-${resourceToken}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: 'aif-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource embed 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: embedDeployment
  sku: {
    name: embedSku
    capacity: embedCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embedModel
      version: '1'
    }
  }
}

resource raJobStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uami.id, roleStorageBlobDataContributor)
  scope: storage
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource raJobAcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uami.id, roleAcrPull)
  scope: acr
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPull)
    principalType: 'ServicePrincipal'
  }
}

resource raSearchStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, search.id, roleStorageBlobDataReader)
  scope: storage
  properties: {
    principalId: search.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataReader)
    principalType: 'ServicePrincipal'
  }
}

resource raSearchOpenAI 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, search.id, roleOpenAIUser)
  scope: foundry
  properties: {
    principalId: search.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleOpenAIUser)
    principalType: 'ServicePrincipal'
  }
}

resource raSearchCognitive 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, search.id, roleCognitiveServicesUser)
  scope: foundry
  properties: {
    principalId: search.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    principalType: 'ServicePrincipal'
  }
}

// --- Search website (Container App) ---
resource webIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-web-${resourceToken}'
  location: location
  tags: tags
}

resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'web-${resourceToken}'
  location: location
  tags: union(tags, { 'azd-service-name': 'web' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${webIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: webIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'web'
          image: webImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'SEARCH_ENDPOINT', value: 'https://${search.name}.search.windows.net' }
            { name: 'SEARCH_INDEX_NAME', value: indexName }
            { name: 'AZURE_CLIENT_ID', value: webIdentity.properties.clientId }
            { name: 'STORAGE_ACCOUNT_URL', value: 'https://${storage.name}.blob.${environment().suffixes.storage}' }
            { name: 'SNAPSHOTS_CONTAINER', value: 'snapshots' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

resource raWebAcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, webIdentity.id, roleAcrPull)
  scope: acr
  properties: {
    principalId: webIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPull)
    principalType: 'ServicePrincipal'
  }
}

resource raWebSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, webIdentity.id, roleSearchIndexDataReader)
  scope: search
  properties: {
    principalId: webIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    principalType: 'ServicePrincipal'
  }
}

resource raWebStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, webIdentity.id, roleStorageBlobDataReader)
  scope: storage
  properties: {
    principalId: webIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataReader)
    principalType: 'ServicePrincipal'
  }
}

output registryLoginServer string = acr.properties.loginServer
output registryName string = acr.name
output jobName string = job.name
output storageAccountName string = storage.name
output storageAccountId string = storage.id
output storageAccountUrl string = 'https://${storage.name}.blob.${environment().suffixes.storage}'
output searchServiceName string = search.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output foundryName string = foundry.name
output foundryEndpoint string = foundry.properties.endpoint
output webUri string = 'https://${webApp.properties.configuration.ingress.fqdn}'
