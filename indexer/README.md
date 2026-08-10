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
  only in file-extension filter and `imageAction` (`none` for pages, extract images
  for the rest).
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
./deploy.ps1     # uses RG-eand-Search / eandsearchbanaj / banaj-eand-foundry / banajeandstr by default
```

Override any resource via parameters, e.g. `-IndexName my-index -EmbedDeployment my-embed`.

## Verify

```powershell
# Indexer status (repeat per indexer: ix-pages, ix-docs, ix-images, ix-snapshots)
$key = az search admin-key show --service-name eandsearchbanaj --resource-group RG-eand-Search --query primaryKey -o tsv
Invoke-RestMethod -Uri "https://eandsearchbanaj.search.windows.net/indexers/ix-pages/status?api-version=2024-07-01" -Headers @{ "api-key"=$key } | Select -Expand lastResult

# Query
./query-sample.ps1 -Query "how do I upgrade my plan" -Top 5
./query-sample.ps1 -Query "الترقية" -Language ar
```

## Index fields

`id` (key), `parent_id`, `chunk`, `vector` (3072-d), `title`, `sourceUrl`,
`language`, `section`, `kind`, `crawledAt`, `contentHash`.

## Notes

- **Prerequisite**: the crawler must have populated the Blob containers first.
- **Cost drivers**: image extraction (metered by AI Search), OCR/embeddings (Foundry).
  The enrichment cache and the crawler's content-hash change detection limit reprocessing.
- **Re-run** on a schedule by adding a `schedule` block to the indexers, or trigger
  `POST /indexers/<name>/run` after each crawl.
