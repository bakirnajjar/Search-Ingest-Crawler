<#
.SYNOPSIS
  Build the crawler image and deploy it as a scheduled Azure Container Apps Job.

.DESCRIPTION
  End-to-end provisioning:
    1. Resource group + Azure Container Registry (build image with `az acr build`).
    2. User-assigned Managed Identity (UAMI).
    3. RBAC: Storage Blob Data Contributor (data plane) + AcrPull (image pull).
    4. Container Apps environment + scheduled Job (daily cron) running the crawl.

  Auth to Blob Storage uses the UAMI via DefaultAzureCredential (no keys/secrets).
  Run `az login` and `az account set --subscription <id>` first.

.NOTES
  Requires: Azure CLI with the containerapp extension
            (az extension add --name containerapp).
#>

param(
  [string]$ResourceGroup   = "rg-search-ingest-crawler",
  [string]$Location        = "uaenorth",
  [Parameter(Mandatory = $true)]
  [string]$StorageAccount,                        # existing storage account name
  [Parameter(Mandatory = $true)]
  [string]$SitemapUrls,                           # comma-separated robots.txt/sitemap URLs
  [string]$AllowedDomains  = "",                  # comma-separated; default: derived from sitemaps
  [string]$AssetHosts      = "",                  # comma-separated; default: allowed domains
  [string]$Acr             = "searchingestcrawleracr", # must be globally unique, alphanumeric
  [string]$Environment     = "search-ingest-crawler-env",
  [string]$Identity        = "id-search-ingest-crawler",
  [string]$JobName         = "search-ingest-crawler-job",
  [string]$ImageTag        = "",                    # default: timestamp tag for reliable rollouts
  [string]$Cron            = "0 2 * * *",          # daily at 02:00 UTC
  [int]   $ReplicaTimeout  = 43200,                # 12h cap for a full crawl
  [int]   $ReplicaRetry    = 1,
  [int]   $SnapshotRetentionDays = 30              # lifecycle expiry for snapshots
)

$ErrorActionPreference = "Stop"
# Force UTF-8 so `az acr build` log streaming doesn't crash on non-ASCII (cp1252) consoles.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
if (-not $ImageTag) { $ImageTag = Get-Date -Format "yyyyMMddHHmmss" }
$Image = "$Acr.azurecr.io/search-ingest-crawler:$ImageTag"

Write-Host "==> Ensuring resource group '$ResourceGroup' in '$Location'"
az group create --name $ResourceGroup --location $Location --output none

Write-Host "==> Ensuring container registry '$Acr'"
az acr show --name $Acr --resource-group $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
  az acr create --name $Acr --resource-group $ResourceGroup --sku Basic --output none
}

Write-Host "==> Building image '$Image' in ACR (cloud build)"
az acr build --registry $Acr --image "search-ingest-crawler:$ImageTag" --file Dockerfile . --output none

# `az acr build` log streaming can crash on Windows without failing the build; verify the tag exists.
Write-Host "==> Verifying image tag '$ImageTag' exists in ACR"
$found = $false
foreach ($attempt in 1..6) {
  $builtTags = az acr repository show-tags --name $Acr --repository search-ingest-crawler -o tsv 2>$null
  if ($builtTags -contains $ImageTag) { $found = $true; break }
  Start-Sleep -Seconds 10
}
if (-not $found) { throw "ACR image tag '$ImageTag' not found after build." }

Write-Host "==> Ensuring user-assigned managed identity '$Identity'"
az identity show --name $Identity --resource-group $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
  az identity create --name $Identity --resource-group $ResourceGroup --location $Location --output none
}
$identityId       = az identity show --name $Identity --resource-group $ResourceGroup --query id -o tsv
$identityClientId = az identity show --name $Identity --resource-group $ResourceGroup --query clientId -o tsv
$identityPrincipal = az identity show --name $Identity --resource-group $ResourceGroup --query principalId -o tsv

Write-Host "==> Assigning 'Storage Blob Data Contributor' on '$StorageAccount'"
$storageId = az storage account show --name $StorageAccount --resource-group $ResourceGroup --query id -o tsv 2>$null
if (-not $storageId) {
  # Storage account may live in another resource group; look it up by name.
  $storageId = az storage account list --query "[?name=='$StorageAccount'].id | [0]" -o tsv
}
if (-not $storageId) { throw "Storage account '$StorageAccount' not found." }
$storageUrl = az storage account show --ids $storageId --query "primaryEndpoints.blob" -o tsv
az role assignment create `
  --assignee-object-id $identityPrincipal `
  --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" `
  --scope $storageId --output none

Write-Host "==> Applying lifecycle policy (expire snapshots after $SnapshotRetentionDays days)"
$lifecycle = @{
  rules = @(@{
    enabled = $true
    name    = "expire-snapshots"
    type    = "Lifecycle"
    definition = @{
      filters = @{ blobTypes = @("blockBlob"); prefixMatch = @("snapshots/") }
      actions = @{ baseBlob = @{ delete = @{ daysAfterModificationGreaterThan = $SnapshotRetentionDays } } }
    }
  })
} | ConvertTo-Json -Depth 10 -Compress
$lifecycleFile = New-TemporaryFile
$lifecycle | Set-Content -Path $lifecycleFile -Encoding utf8
az storage account management-policy create --account-name $StorageAccount --policy "@$lifecycleFile" --output none 2>$null
Remove-Item $lifecycleFile -Force

Write-Host "==> Assigning 'AcrPull' on '$Acr'"
$acrId = az acr show --name $Acr --resource-group $ResourceGroup --query id -o tsv
az role assignment create `
  --assignee-object-id $identityPrincipal `
  --assignee-principal-type ServicePrincipal `
  --role "AcrPull" `
  --scope $acrId --output none

Write-Host "==> Ensuring Container Apps environment '$Environment'"
az containerapp env show --name $Environment --resource-group $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
  az containerapp env create --name $Environment --resource-group $ResourceGroup --location $Location --output none
}

$envVars = @(
  "STORAGE_ACCOUNT_URL=$storageUrl",
  "AZURE_CLIENT_ID=$identityClientId",
  "CRAWL_SITEMAP_URLS=$SitemapUrls",
  "CAPTURE_SNAPSHOTS=true",
  "SNAPSHOT_PDF=true",
  "INCREMENTAL=true",
  "HARVEST_RENDERED_IMAGES=true"
)
# Only pass optional target overrides when provided (empty KEY= is rejected by some az versions).
if ($AllowedDomains) { $envVars += "CRAWL_ALLOWED_DOMAINS=$AllowedDomains" }
if ($AssetHosts)     { $envVars += "CRAWL_ASSET_HOSTS=$AssetHosts" }

Write-Host "==> Creating/updating scheduled job '$JobName' (cron '$Cron')"
az containerapp job show --name $JobName --resource-group $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
  az containerapp job create `
    --name $JobName `
    --resource-group $ResourceGroup `
    --environment $Environment `
    --trigger-type Schedule `
    --cron-expression "$Cron" `
    --replica-timeout $ReplicaTimeout `
    --replica-retry-limit $ReplicaRetry `
    --replica-completion-count 1 `
    --parallelism 1 `
    --image $Image `
    --cpu 2.0 --memory 4.0Gi `
    --mi-user-assigned $identityId `
    --registry-server "$Acr.azurecr.io" `
    --registry-identity $identityId `
    --env-vars $envVars `
    --output none
} else {
  az containerapp job update `
    --name $JobName `
    --resource-group $ResourceGroup `
    --image $Image `
    --replica-timeout $ReplicaTimeout `
    --replica-retry-limit $ReplicaRetry `
    --cron-expression "$Cron" `
    --set-env-vars $envVars `
    --output none
}

Write-Host ""
Write-Host "Done. Trigger an immediate run with:"
Write-Host "  az containerapp job start --name $JobName --resource-group $ResourceGroup"
Write-Host "Tail logs with:"
Write-Host "  az containerapp job execution list --name $JobName --resource-group $ResourceGroup -o table"
