<#
.SYNOPSIS
  Provision the Azure AI Search index, skillset, data sources, and indexers that
  turn the crawler's Blob containers (pages/docs/images/snapshots) into one
  hybrid + semantic + vector index.

.DESCRIPTION
  Reuses existing resources in the resource group (no new services created):
    - Azure AI Search service (index + skillset + indexers, via REST).
    - Azure OpenAI / Foundry embedding deployment (integrated vectorization + OCR).
    - Storage account with the crawler's containers.

  Auth uses the Search service's system-assigned Managed Identity:
    - Storage Blob Data Reader        (read blobs)
    - Cognitive Services OpenAI User  (embeddings + query-time vectorizer)
    - Cognitive Services User         (OCR / image enrichment)

  Run `az login` and `az account set --subscription <id>` first.
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroup,                          # resource group holding Search/Storage/Foundry
  [Parameter(Mandatory = $true)]
  [string]$SearchService,                          # existing Azure AI Search service name
  [Parameter(Mandatory = $true)]
  [string]$StorageAccount,                         # existing storage account with the crawler's containers
  [Parameter(Mandatory = $true)]
  [string]$Foundry,                                # existing Azure OpenAI / Foundry (AIServices) account
  [string]$EmbedDeployment  = "text-embedding-3-large",
  [string]$EmbedModel       = "text-embedding-3-large",
  [int]   $Dimensions       = 3072,
  [string]$IndexName        = "content-index",
  [string]$SkillsetName     = "content-skillset",
  [string]$ApiVersion       = "2024-11-01-Preview"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Per-container indexer config: extension filter + whether to extract images for OCR.
$sources = @(
  @{ ds = "ds-pages";     ix = "ix-pages";     container = "pages";     imageAction = "generateNormalizedImages"; ext = ".md" },
  @{ ds = "ds-docs";      ix = "ix-docs";      container = "docs";      imageAction = "generateNormalizedImages"; ext = ".pdf" },
  @{ ds = "ds-images";    ix = "ix-images";    container = "images";    imageAction = "generateNormalizedImages"; ext = ".png,.jpg,.jpeg,.bmp,.tiff,.gif" },
  @{ ds = "ds-snapshots"; ix = "ix-snapshots"; container = "snapshots"; imageAction = "generateNormalizedImages"; ext = ".png,.pdf" }
)

Write-Host "==> Resolving resource ids"
$storageId  = az storage account show --name $StorageAccount --resource-group $ResourceGroup --query id -o tsv
$foundryId  = az cognitiveservices account show --name $Foundry --resource-group $ResourceGroup --query id -o tsv
$foundryUrl = az cognitiveservices account show --name $Foundry --resource-group $ResourceGroup --query "properties.endpoint" -o tsv
if (-not $storageId -or -not $foundryId) { throw "Storage or Foundry account not found in $ResourceGroup." }

Write-Host "==> Enabling system-assigned identity on '$SearchService'"
az search service update --name $SearchService --resource-group $ResourceGroup --identity-type SystemAssigned --output none
$principalId = az search service show --name $SearchService --resource-group $ResourceGroup --query "identity.principalId" -o tsv
if (-not $principalId) { throw "Could not obtain the search service managed identity principalId." }

Write-Host "==> Assigning RBAC to the search identity"
foreach ($r in @(
    @{ role = "Storage Blob Data Reader";       scope = $storageId },
    @{ role = "Cognitive Services OpenAI User"; scope = $foundryId },
    @{ role = "Cognitive Services User";        scope = $foundryId }
)) {
  az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
    --role $r.role --scope $r.scope --output none 2>$null
}

Write-Host "==> Fetching search admin key"
$adminKey = az search admin-key show --service-name $SearchService --resource-group $ResourceGroup --query primaryKey -o tsv
$base = "https://$SearchService.search.windows.net"
$headers = @{ "api-key" = $adminKey; "Content-Type" = "application/json" }

function Invoke-Put([string]$path, [string]$json) {
  Invoke-RestMethod -Method Put -Uri "$base/$path`?api-version=$ApiVersion" -Headers $headers -Body $json | Out-Null
}
function Expand-Template([string]$file, [hashtable]$map) {
  $t = Get-Content -Raw -Path (Join-Path $here $file)
  foreach ($k in $map.Keys) { $t = $t.Replace($k, [string]$map[$k]) }
  return $t
}

$common = @{
  "__INDEX_NAME__"      = $IndexName
  "__SKILLSET__"        = $SkillsetName
  "__DIMENSIONS__"      = $Dimensions
  "__FOUNDRY_ENDPOINT__"= $foundryUrl
  "__EMBED_DEPLOYMENT__"= $EmbedDeployment
  "__EMBED_MODEL__"     = $EmbedModel
}

Write-Host "==> PUT index '$IndexName'"
Invoke-Put "indexes/$IndexName" (Expand-Template "index.json" $common)

Write-Host "==> PUT skillset '$SkillsetName'"
Invoke-Put "skillsets/$SkillsetName" (Expand-Template "skillset.json" $common)

foreach ($s in $sources) {
  Write-Host "==> PUT data source '$($s.ds)' -> container '$($s.container)'"
  Invoke-Put "datasources/$($s.ds)" (Expand-Template "datasource.template.json" @{
    "__DS_NAME__"      = $s.ds
    "__STORAGE_RESID__"= $storageId
    "__CONTAINER__"    = $s.container
  })
  Write-Host "==> PUT indexer '$($s.ix)'"
  Invoke-Put "indexers/$($s.ix)" (Expand-Template "indexer.template.json" @{
    "__IX_NAME__"      = $s.ix
    "__DS_NAME__"      = $s.ds
    "__SKILLSET__"     = $SkillsetName
    "__INDEX_NAME__"   = $IndexName
    "__IMAGE_ACTION__" = $s.imageAction
    "__EXTENSIONS__"   = $s.ext
  })
}

# RBAC can take a minute to propagate before the indexers can read blobs / call the model.
Write-Host "==> Waiting for RBAC propagation..."
Start-Sleep -Seconds 60

foreach ($s in $sources) {
  Write-Host "==> Running indexer '$($s.ix)'"
  try {
    Invoke-RestMethod -Method Post -Uri "$base/indexers/$($s.ix)/run`?api-version=$ApiVersion" -Headers $headers | Out-Null
  } catch {
    # Newly created indexers auto-run once; a concurrent-invocation error here is expected and safe.
    Write-Host "    (already running — skipped)"
  }
}

Write-Host ""
Write-Host "Done. Check status with:"
foreach ($s in $sources) {
  Write-Host "  Invoke-RestMethod -Uri '$base/indexers/$($s.ix)/status?api-version=$ApiVersion' -Headers @{ 'api-key'='<admin-key>' } | Select -Expand lastResult"
}
