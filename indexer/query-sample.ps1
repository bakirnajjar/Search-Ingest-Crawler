<#
.SYNOPSIS
  Run a hybrid (BM25 + vector) + semantic query against the index.
  Text is vectorized at query time by the index's Azure OpenAI vectorizer.
#>
param(
  [Parameter(Mandatory = $true)][string]$Query,
  [string]$ResourceGroup,          # RESOURCE_GROUP
  [string]$SearchService,          # SEARCH_SERVICE
  [string]$IndexName,              # INDEX_NAME
  [string]$ApiVersion,             # query API version
  [int]   $Top,
  [string]$Language                # optional filter: en | ar
)

$ErrorActionPreference = "Stop"

# ResourceGroup/SearchService/IndexName may be supplied on the CLI or via the repo-root .env.
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

if (-not $PSBoundParameters.ContainsKey('ResourceGroup')) { $ResourceGroup = $env:RESOURCE_GROUP }
if (-not $PSBoundParameters.ContainsKey('SearchService')) { $SearchService = $env:SEARCH_SERVICE }
if (-not $PSBoundParameters.ContainsKey('IndexName'))     { $IndexName     = if ($env:INDEX_NAME) { $env:INDEX_NAME } else { "content-index" } }
if (-not $PSBoundParameters.ContainsKey('ApiVersion'))    { $ApiVersion    = "2024-07-01" }
if (-not $PSBoundParameters.ContainsKey('Top'))           { $Top           = 5 }
if (-not $PSBoundParameters.ContainsKey('Language'))      { $Language      = "" }
if (-not $ResourceGroup) { throw "ResourceGroup is required: pass -ResourceGroup or set RESOURCE_GROUP in .env." }
if (-not $SearchService) { throw "SearchService is required: pass -SearchService or set SEARCH_SERVICE in .env." }

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
    title     = if ($_.title) { [System.Uri]::UnescapeDataString($_.title) } else { '' }
    sourceUrl = [System.Uri]::UnescapeDataString($_.sourceUrl)
    snippet   = ($_.chunk -replace '\s+', ' ').Substring(0, [Math]::Min(160, $_.chunk.Length))
  }
} | Format-List
