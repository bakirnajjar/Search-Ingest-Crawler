<#
.SYNOPSIS
  Run a hybrid (BM25 + vector) + semantic query against the index.
  Text is vectorized at query time by the index's Azure OpenAI vectorizer.
#>
param(
  [Parameter(Mandatory = $true)][string]$Query,
  [string]$ResourceGroup = "RG-eand-Search",
  [string]$SearchService = "eandsearchbanaj",
  [string]$IndexName     = "eand-content",
  [string]$ApiVersion    = "2024-07-01",
  [int]   $Top           = 5,
  [string]$Language      = ""   # optional filter: en | ar
)

$ErrorActionPreference = "Stop"
$adminKey = az search admin-key show --service-name $SearchService --resource-group $ResourceGroup --query primaryKey -o tsv
$uri = "https://$SearchService.search.windows.net/indexes/$IndexName/docs/search?api-version=$ApiVersion"

$body = @{
  search                = $Query
  top                   = $Top
  queryType             = "semantic"
  semanticConfiguration = "semcfg"
  select                = "title,sourceUrl,language,section,kind,chunk"
  vectorQueries         = @(@{
    kind   = "text"
    text   = $Query
    fields = "vector"
    k      = $Top
  })
}
if ($Language) { $body.filter = "language eq '$Language'" }

$resp = Invoke-RestMethod -Method Post -Uri $uri `
  -Headers @{ "api-key" = $adminKey; "Content-Type" = "application/json" } `
  -Body ($body | ConvertTo-Json -Depth 6)

$resp.value | ForEach-Object {
  [PSCustomObject]@{
    reranker  = $_.'@search.rerankerScore'
    score     = $_.'@search.score'
    language  = $_.language
    kind      = $_.kind
    sourceUrl = [System.Uri]::UnescapeDataString($_.sourceUrl)
    snippet   = ($_.chunk -replace '\s+', ' ').Substring(0, [Math]::Min(160, $_.chunk.Length))
  }
} | Format-List
