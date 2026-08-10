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
  [string]$ResourceGroup,          # RESOURCE_GROUP
  [string]$Location,               # LOCATION
  [string]$StorageAccount,         # STORAGE_ACCOUNT (existing storage account name)
  [string]$SitemapUrls,            # CRAWL_SITEMAP_URLS (comma-separated robots.txt/sitemap URLs)
  [string]$AllowedDomains,         # CRAWL_ALLOWED_DOMAINS
  [string]$AssetHosts,             # CRAWL_ASSET_HOSTS
  [string]$Acr,                    # ACR_NAME (globally unique, alphanumeric)
  [string]$Environment,            # ACA_ENVIRONMENT
  [string]$Identity,               # ACA_IDENTITY
  [string]$JobName,                # ACA_JOB_NAME
  [string]$ImageTag,               # IMAGE_TAG (blank = timestamp tag)
  [string]$Cron,                   # CRON (daily at 02:00 UTC by default)
  [int]   $ReplicaTimeout,         # REPLICA_TIMEOUT (12h cap for a full crawl)
  [int]   $ReplicaRetry,           # REPLICA_RETRY
  [int]   $SnapshotRetentionDays   # SNAPSHOT_RETENTION_DAYS
)

$ErrorActionPreference = "Stop"

# Parameters may be supplied on the CLI or via the repo-root .env.
# Precedence: explicit CLI arg > existing shell env var > .env value > built-in default.
function Import-DotEnv([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  foreach ($line in Get-Content -LiteralPath $path) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    $i = $t.IndexOf("=")
    if ($i -lt 1) { continue }
    $k = $t.Substring(0, $i).Trim()
    $v = $t.Substring($i + 1).Trim()
    if (-not [Environment]::GetEnvironmentVariable($k)) { [Environment]::SetEnvironmentVariable($k, $v) }
  }
}
Import-DotEnv (Join-Path $PSScriptRoot "..\.env")

if (-not $PSBoundParameters.ContainsKey('ResourceGroup'))        { $ResourceGroup   = if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-search-ingest-crawler" } }
if (-not $PSBoundParameters.ContainsKey('Location'))             { $Location        = if ($env:LOCATION) { $env:LOCATION } else { "uaenorth" } }
if (-not $PSBoundParameters.ContainsKey('StorageAccount'))       { $StorageAccount  = $env:STORAGE_ACCOUNT }
if (-not $PSBoundParameters.ContainsKey('SitemapUrls'))          { $SitemapUrls     = $env:CRAWL_SITEMAP_URLS }
if (-not $PSBoundParameters.ContainsKey('AllowedDomains'))       { $AllowedDomains  = $env:CRAWL_ALLOWED_DOMAINS }
if (-not $PSBoundParameters.ContainsKey('AssetHosts'))           { $AssetHosts      = $env:CRAWL_ASSET_HOSTS }
if (-not $PSBoundParameters.ContainsKey('Acr'))                  { $Acr             = if ($env:ACR_NAME) { $env:ACR_NAME } else { "searchingestcrawleracr" } }
if (-not $PSBoundParameters.ContainsKey('Environment'))          { $Environment     = if ($env:ACA_ENVIRONMENT) { $env:ACA_ENVIRONMENT } else { "search-ingest-crawler-env" } }
if (-not $PSBoundParameters.ContainsKey('Identity'))             { $Identity        = if ($env:ACA_IDENTITY) { $env:ACA_IDENTITY } else { "id-search-ingest-crawler" } }
if (-not $PSBoundParameters.ContainsKey('JobName'))              { $JobName         = if ($env:ACA_JOB_NAME) { $env:ACA_JOB_NAME } else { "search-ingest-crawler-job" } }
if (-not $PSBoundParameters.ContainsKey('ImageTag'))             { $ImageTag        = $env:IMAGE_TAG }
if (-not $PSBoundParameters.ContainsKey('Cron'))                 { $Cron            = if ($env:CRON) { $env:CRON } else { "0 2 * * *" } }
if (-not $PSBoundParameters.ContainsKey('ReplicaTimeout'))       { $ReplicaTimeout  = if ($env:REPLICA_TIMEOUT) { [int]$env:REPLICA_TIMEOUT } else { 43200 } }
if (-not $PSBoundParameters.ContainsKey('ReplicaRetry'))         { $ReplicaRetry    = if ($env:REPLICA_RETRY) { [int]$env:REPLICA_RETRY } else { 1 } }
if (-not $PSBoundParameters.ContainsKey('SnapshotRetentionDays')){ $SnapshotRetentionDays = if ($env:SNAPSHOT_RETENTION_DAYS) { [int]$env:SNAPSHOT_RETENTION_DAYS } else { 30 } }

if (-not $StorageAccount) { throw "StorageAccount is required: pass -StorageAccount or set STORAGE_ACCOUNT in .env." }
if (-not $SitemapUrls)    { throw "SitemapUrls is required: pass -SitemapUrls or set CRAWL_SITEMAP_URLS in .env." }

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
