# Deployment Plan — Search Ingest Crawler (azd)

**Status:** Validated

## Overview
Migrate the two-stage pipeline (Scrapy crawler → Blob; Blob → Azure AI Search) to an
`azd`-managed deployment in a **fresh** environment. A single `azd up` provisions all
infrastructure with Bicep and runs a `postprovision` hook that builds the crawler image,
wires it onto the Container Apps Job, and configures the AI Search index/skillset/indexers.

## Deployment tool
- **azd** (Azure Developer CLI) + **Bicep** (subscription-scoped `main.bicep` creates the RG).

## Architecture
- **Ingestion**: Azure Container Apps **Job** (Schedule trigger, daily cron, 12h replica
  timeout) runs the Scrapy crawler; lands `pages`/`images`/`docs`/`snapshots` in Blob.
- **Indexing**: Azure AI Search (index + shared skillset: OCR → Merge → Split → embed →
  index projections) over the four Blob containers; integrated vectorization + OCR via
  a Foundry (AIServices) account with a `text-embedding-3-large` deployment.
- **Auth**: Managed Identity end-to-end (Job UAMI for Blob + ACR pull; Search system MI
  for Blob read + Foundry). No keys in source; Search admin key fetched at hook time only.

## Resources (fresh, resource-token named)
| Resource | Purpose |
|----------|---------|
| Resource group `rg-<env>` | Container for all resources |
| Log Analytics + Container Apps environment | Job host + logs |
| Container Registry (Basic) | Crawler image |
| User-assigned identity | Job identity (Blob Data Contributor, AcrPull) |
| Storage (StorageV2) + 4 containers + lifecycle | Crawl output; snapshots expire after N days |
| Container Apps Job | Scheduled crawl |
| Azure AI Search (Standard/S1, semantic free) + system MI | Hybrid + semantic + vector index |
| Foundry / AIServices (S0) + `text-embedding-3-large` (GlobalStandard, 1M TPM) | Embeddings + OCR |

## RBAC (Bicep)
- Job UAMI → Storage Blob Data Contributor (storage), AcrPull (registry).
- Search MI → Storage Blob Data Reader (storage), Cognitive Services OpenAI User + Cognitive Services User (Foundry).

## Files
- `azure.yaml` — azd project + `postprovision` hook.
- `infra/main.bicep` (subscription scope) + `infra/resources.bicep` (RG scope) + `infra/main.parameters.json`.
- `infra/hooks/postprovision.ps1` — `az acr build` → `az containerapp job update` → run `indexer/deploy.ps1`.
- Reused: `Dockerfile`, `indexer/*.json`, `indexer/deploy.ps1`.
- Removed: `infra/deploy.ps1` (replaced by azd).

## Parameters (azd env)
`AZURE_ENV_NAME`, `AZURE_LOCATION`, `CRAWL_SITEMAP_URLS` (required at run), `CRAWL_ALLOWED_DOMAINS`,
`CRAWL_ASSET_HOSTS`, `EMBED_MODEL`, `EMBED_DEPLOYMENT`, `INDEX_NAME`, `SKILLSET_NAME`, `CRON`.

## Deploy
```powershell
azd auth login
azd env new search-ingest-crawler
azd env set CRAWL_SITEMAP_URLS "https://www.example.com/robots.txt"
azd up   # pick subscription + region when prompted
# First crawl (job is scheduled; trigger once manually):
az containerapp job start --name <job> --resource-group <rg>
```

## Considerations
- Region must offer `text-embedding-3-large`, AI Search, and ACA Jobs with quota.
- Fresh Search + Foundry are new billable resources (separate from any existing ones).

## Workflow
`azure-prepare` (this) → `azure-validate` → `azure-deploy`.

## 7. Validation Proof
Run 2026-08-10 (subscription `ME-MngEnvMCAP394065-banaj-1`, `ecad4d0c-...`).

| Check | Command | Result |
|-------|---------|--------|
| azd present | `azd version` | 1.29.0 (stable) ✅ |
| Azure auth | `az account show` | authenticated ✅ |
| Bicep compiles | `az bicep build --file infra/main.bicep` | exit 0 (only benign BCP334 name-length warnings) ✅ |
| Embedding model region | `az cognitiveservices model list` | `text-embedding-3-large` v1 available in uaenorth / swedencentral / eastus2 ✅ |
| ARM preflight | `az deployment sub validate --location uaenorth --template-file infra/main.bicep --parameters environmentName=valtest location=uaenorth crawlSitemapUrls=...` | provisioningState = Succeeded, error = null ✅ |
| Static RBAC | reviewed `infra/resources.bicep` | 5 role assignments correct (Job UAMI: Storage Blob Data Contributor + AcrPull; Search MI: Storage Blob Data Reader + Cognitive Services OpenAI User + Cognitive Services User) ✅ |

Notes:
- Container image is built at deploy time via `az acr build` (cloud build) in the postprovision hook; no local Docker required.
- Bicep pins embedding model version `1`, matching availability.
- BCP334 warnings are static-analysis only (ACR/storage names derive from a 13-char `uniqueString` token).
- Embedding capacity: 1M TPM via `GlobalStandard` (uaenorth `Standard` caps at 350K; `GlobalStandard` limit 6M, ~1.5M free). Re-validated after this change: `az bicep build` exit 0, `az deployment sub validate` = Succeeded.
- Post-fix additions: page `<title>` stored in blob metadata (index `title` field), and native blob soft-delete deletion detection (storage soft delete enabled in Bicep; auto-detected by the indexer).
