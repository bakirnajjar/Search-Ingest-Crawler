targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment; used to derive resource names.')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string

@description('Comma-separated robots.txt/sitemap URLs to crawl (azd env set CRAWL_SITEMAP_URLS ...).')
param crawlSitemapUrls string = ''

@description('Comma-separated allowed domains; empty = derived from sitemap hosts.')
param crawlAllowedDomains string = ''

@description('Comma-separated asset hosts; empty = allowed domains.')
param crawlAssetHosts string = ''

param embedModel string = 'text-embedding-3-large'
param embedDeployment string = 'text-embedding-3-large'
param embedDimensions int = 3072
param embedCapacity int = 1000
param embedSku string = 'GlobalStandard'
param cron string = '0 2 * * *'
param replicaTimeout int = 43200
param snapshotRetentionDays int = 30
param indexName string = 'content-index'
param skillsetName string = 'content-skillset'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    crawlSitemapUrls: crawlSitemapUrls
    crawlAllowedDomains: crawlAllowedDomains
    crawlAssetHosts: crawlAssetHosts
    embedModel: embedModel
    embedDeployment: embedDeployment
    embedCapacity: embedCapacity
    embedSku: embedSku
    cron: cron
    replicaTimeout: replicaTimeout
    snapshotRetentionDays: snapshotRetentionDays
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.registryName
output CRAWLER_JOB_NAME string = resources.outputs.jobName
output STORAGE_ACCOUNT_NAME string = resources.outputs.storageAccountName
output STORAGE_ACCOUNT_ID string = resources.outputs.storageAccountId
output STORAGE_ACCOUNT_URL string = resources.outputs.storageAccountUrl
output SEARCH_SERVICE_NAME string = resources.outputs.searchServiceName
output SEARCH_ENDPOINT string = resources.outputs.searchEndpoint
output FOUNDRY_NAME string = resources.outputs.foundryName
output FOUNDRY_ENDPOINT string = resources.outputs.foundryEndpoint
output EMBED_DEPLOYMENT string = embedDeployment
output EMBED_MODEL string = embedModel
output EMBED_DIMENSIONS int = embedDimensions
output INDEX_NAME string = indexName
output SKILLSET_NAME string = skillsetName
