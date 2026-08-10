#!/usr/bin/env pwsh
# azd postprovision hook:
#   1. Build/refresh the crawler image (stable :latest tag) in ACR.
#   2. Configure the Azure AI Search index/skillset/data sources/indexers.
# The Container Apps Job references <acr>/search-ingest-crawler:latest directly in Bicep,
# so no job-image update is needed and re-provisioning never resets it to a placeholder.
# Reads Bicep outputs exposed by azd as environment variables.
$ErrorActionPreference = "Stop"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$acrName   = $env:AZURE_CONTAINER_REGISTRY_NAME
$acrServer = $env:AZURE_CONTAINER_REGISTRY_ENDPOINT
$rg        = $env:AZURE_RESOURCE_GROUP
$jobName   = $env:CRAWLER_JOB_NAME
$dims      = if ($env:EMBED_DIMENSIONS) { [int]$env:EMBED_DIMENSIONS } else { 3072 }
$image     = "$acrServer/search-ingest-crawler:latest"

Write-Host "==> Building crawler image '$image' in ACR '$acrName'"
az acr build --registry $acrName --image "search-ingest-crawler:latest" --file Dockerfile . --output none

Write-Host "==> Configuring Azure AI Search (index + skillset + indexers)"
& (Join-Path $here "..\..\indexer\deploy.ps1") `
  -ResourceGroup   $rg `
  -SearchService   $env:SEARCH_SERVICE_NAME `
  -StorageAccount  $env:STORAGE_ACCOUNT_NAME `
  -Foundry         $env:FOUNDRY_NAME `
  -EmbedDeployment $env:EMBED_DEPLOYMENT `
  -EmbedModel      $env:EMBED_MODEL `
  -Dimensions      $dims `
  -IndexName       $env:INDEX_NAME `
  -SkillsetName    $env:SKILLSET_NAME

Write-Host ""
Write-Host "postprovision complete."
Write-Host "Trigger the first crawl with:"
Write-Host "  az containerapp job start --name $jobName --resource-group $rg"
