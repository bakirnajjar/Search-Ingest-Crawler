# Indexer — Blob → Azure AI Search

Turns the crawler's four Blob containers into a single **hybrid + semantic + vector**
Azure AI Search index, with AI enrichment (OCR for images/PDFs/snapshots) and
integrated vectorization via Azure OpenAI.

## Design

```
pages/*.md ───┐
docs/*.pdf ───┤   4 data sources        1 shared skillset                1 index
images/*  ────┼─► (one per container) ─► OCR → Merge → Split → Embed ─► (per-chunk docs)
snapshots/* ──┘        4 indexers          + index projections
```

- **One shared skillset** runs OCR → merge (blob text + OCR text) → text split
  (chunking) → Azure OpenAI embeddings, then **index projections** emit one search
  document per chunk. OCR is a no-op for the already-clean `pages/*.md`.
- **Four indexers** (one per container) reuse the same skillset + index; they differ
  only in the file-extension filter. All use `imageAction=generateNormalizedImages`
  so the shared OCR skill always has normalized images to read (for `pages/*.md`
  there are none, so OCR is a no-op).
- **Managed Identity** end-to-end — the Search service's system-assigned identity
  reads Blob (Storage Blob Data Reader) and calls the model / OCR
  (Cognitive Services OpenAI User + Cognitive Services User). No keys in the repo.

## Files

| File | Purpose |
|------|---------|
| `index.json` | Index schema: `chunk`, `vector` (HNSW + AOAI vectorizer), metadata fields, semantic config |
| `skillset.json` | OCR + Merge + Split + AzureOpenAIEmbedding + index projections |
| `datasource.template.json` | Blob data source (Managed Identity), templated per container |
| `indexer.template.json` | Indexer, templated per container (extensions + imageAction) |
| `deploy.ps1` | Enables identity, assigns RBAC, PUTs all definitions via REST, runs indexers |
| `query-sample.ps1` | Hybrid + semantic query helper |

## Deploy

```powershell
az login
az account set --subscription "<subscription-id>"

cd indexer
./deploy.ps1 `
  -ResourceGroup  "<resource-group>" `
  -SearchService  "<search-service>" `
  -StorageAccount "<storage-account>" `
  -Foundry        "<aoai-or-foundry-account>"
```

All parameters can instead be set in the repo-root [`.env`](../.env.example)
(`RESOURCE_GROUP`, `SEARCH_SERVICE`, `STORAGE_ACCOUNT`, `FOUNDRY_ACCOUNT`, and the
optional `EMBED_*` / `INDEX_NAME` / `SKILLSET_NAME` / `SEARCH_API_VERSION`). With
`.env` populated, run `./deploy.ps1` with no arguments; CLI args override `.env`.

Optional overrides: `-IndexName my-index -SkillsetName my-skillset -EmbedDeployment my-embed -EmbedModel my-model -Dimensions 1536`.

## Verify

```powershell
# Indexer status (repeat per indexer: ix-pages, ix-docs, ix-images, ix-snapshots)
$key = az search admin-key show --service-name <search-service> --resource-group <resource-group> --query primaryKey -o tsv
Invoke-RestMethod -Uri "https://<search-service>.search.windows.net/indexers/ix-pages/status?api-version=2024-07-01" -Headers @{ "api-key"=$key } | Select -Expand lastResult

# Query
./query-sample.ps1 -Query "how do I upgrade my plan" -ResourceGroup "<resource-group>" -SearchService "<search-service>" -Top 5
./query-sample.ps1 -Query "الترقية" -ResourceGroup "<resource-group>" -SearchService "<search-service>" -Language ar
```

## Index fields

`id` (key), `parent_id`, `chunk`, `vector` (3072-d), `title`, `sourceUrl`,
`language`, `section`, `kind`, `crawledAt`, `contentHash`.

## Notes

- **Prerequisite**: the crawler must have populated the Blob containers first.
- **Cost drivers**: image extraction (metered by AI Search), OCR/embeddings (Foundry).
  The enrichment cache and the crawler's content-hash change detection limit reprocessing.
- **Scheduled daily**: every indexer carries a `schedule` (interval `P1D`, 04:00 UTC)
  and picks up new/changed blobs incrementally. Trigger an out-of-band refresh any
  time with `POST /indexers/<name>/run`.
- **Deletion detection**: when the storage account has blob soft delete enabled, the
  data sources use `NativeBlobSoftDeleteDeletionDetectionPolicy` (added automatically by
  `deploy.ps1`) so blobs removed from storage drop out of the index on the next run.
