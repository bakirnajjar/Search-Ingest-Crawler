# Search Ingest Crawler

A configurable, sitemap-driven web crawler that lands cleaned page content,
images, documents, and full-page snapshots into **Azure Blob Storage** — ready
for ingestion by Azure AI Search (Blob indexer + skillset) or any downstream
pipeline. It runs locally or as a scheduled **Azure Container Apps Job**.

The target site is **fully configurable** — point it at any site's `robots.txt`
or sitemap URLs. Nothing is hardcoded to a specific domain.

## What it captures

| Blob container | Contents |
|----------------|----------|
| `pages`        | Per page: raw `.html`, cleaned `.md` (boilerplate removed via trafilatura), `.json` sidecar (metadata) |
| `images`       | Referenced images, including those lazy-loaded in the rendered DOM (incl. SVG) |
| `docs`         | Linked PDFs / Office documents |
| `snapshots`    | Full-page Playwright render per page (`.png` + `.pdf`) |

Every blob carries metadata (`sourceurl`, `crawledat`, `language`, `section`,
`contenthash`, `kind`) suitable for mapping to search index fields. The
`contenthash` drives **incremental crawls** — unchanged pages skip re-download,
snapshotting, and re-upload.

## Design notes

- **Sitemap-driven, not blind link-following** — seeds from `robots.txt` sitemap
  entries (or explicit sitemap URLs) and recurses into nested sitemap indexes.
- **`robots.txt` obeyed** (`ROBOTSTXT_OBEY = True`) with AutoThrottle for politeness.
- **Server-rendered HTML is parsed directly**; Playwright is used for snapshots
  and to harvest lazy-loaded images from the rendered DOM.
- **Language & section** are inferred from the URL path (`/en/…`, `/ar/…`).
- **Auth**: Managed Identity via `DefaultAzureCredential` (no keys). A connection
  string is honored only as a local fallback.

## Configure the target

Set the target via environment variables (see [`.env.example`](.env.example)):

| Variable | Purpose |
|----------|---------|
| `CRAWL_SITEMAP_URLS` | **Required.** Comma-separated `robots.txt`/sitemap URLs. |
| `CRAWL_ALLOWED_DOMAINS` | Optional. Defaults to the sitemap hostnames. |
| `CRAWL_ASSET_HOSTS` | Optional. Hosts whose images/docs may be downloaded. Defaults to allowed domains. |
| `STORAGE_ACCOUNT_URL` | Blob endpoint, e.g. `https://acct.blob.core.windows.net`. |

You can also override the seed per run: `-a sitemap_urls=... -a allowed_domains=...`.

## Local run

```powershell
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
playwright install chromium

Copy-Item .env.example .env   # then edit CRAWL_SITEMAP_URLS and STORAGE_ACCOUNT_URL
# Auth: `az login` (uses your identity) or set STORAGE_CONNECTION_STRING.

$env:CRAWL_SITEMAP_URLS = "https://www.example.com/robots.txt"
$env:STORAGE_ACCOUNT_URL = "https://YOURACCOUNT.blob.core.windows.net"

# Time-boxed smoke test:
scrapy crawl sitemap -s CLOSESPIDER_TIMEOUT=120

# Full crawl:
scrapy crawl sitemap
```

Verify output:

```powershell
az storage blob list --account-name YOURACCOUNT --container-name pages -o table
```

> Local tip: the pinned `Twisted==24.3.0` and `playwright==1.47.0` wheels require
> Python 3.10–3.13 (use `py -3.12`). Python 3.14 has no prebuilt wheels yet.

## Deploy with the Azure Developer CLI (azd)

A single `azd up` provisions a **fresh** environment (resource group, Container Registry,
Container Apps environment + scheduled **Job**, Storage + containers, Azure AI Search, and a
Foundry `text-embedding-3-large` deployment), builds the crawler image, points the Job at
it, and configures the AI Search index/skillset/indexers — all with Managed Identity.

```powershell
azd auth login
az login          # the postprovision hook uses the az CLI (image build + Search setup)
azd env new search-ingest-crawler
azd env set CRAWL_SITEMAP_URLS "https://www.example.com/robots.txt"
# Optional: azd env set CRAWL_ALLOWED_DOMAINS "example.com,www.example.com"
azd up    # choose subscription + region when prompted
```

The crawler Job runs on a daily schedule (`0 2 * * *`, 12h replica timeout). Trigger the
first crawl immediately:

```powershell
$job = azd env get-value CRAWLER_JOB_NAME
$rg  = azd env get-value AZURE_RESOURCE_GROUP
az containerapp job start --name $job --resource-group $rg
az containerapp job execution list --name $job --resource-group $rg -o table
```

Tear the environment down with `azd down`. Infrastructure is Bicep under [`infra/`](infra/);
the `postprovision` hook ([infra/hooks/postprovision.ps1](infra/hooks/postprovision.ps1))
builds the image and runs the Stage 2 indexer setup.

## Index into Azure AI Search (Stage 2)

The [`indexer/`](indexer/) folder turns the four Blob containers into a single
**hybrid + semantic + vector** Azure AI Search index — OCR for images/PDFs/snapshots,
integrated vectorization via Azure OpenAI, and one search document per content chunk.
`azd up` runs this automatically via the `postprovision` hook; the folder also supports
standalone use against existing resources. See [indexer/README.md](indexer/README.md).

## Configuration reference

All settings are environment variables (see [`.env.example`](.env.example)):
`CRAWL_SITEMAP_URLS`, `CRAWL_ALLOWED_DOMAINS`, `CRAWL_ASSET_HOSTS`,
`STORAGE_ACCOUNT_URL`, `AZURE_CLIENT_ID`, `BLOB_CONTAINER_*`,
`CAPTURE_SNAPSHOTS`, `SNAPSHOT_PDF`, `INCREMENTAL`, `HARVEST_RENDERED_IMAGES`,
`CRAWLER_CONCURRENCY`, `CRAWLER_DOWNLOAD_DELAY`, `LOG_LEVEL`.

Deployment parameters also live in `.env` for the **standalone scripts** — the AI Search
indexer ([indexer/deploy.ps1](indexer/deploy.ps1)): `RESOURCE_GROUP`, `SEARCH_SERVICE`,
`STORAGE_ACCOUNT`, `FOUNDRY_ACCOUNT`, `EMBED_*`, `INDEX_NAME`, `SKILLSET_NAME`,
`SEARCH_API_VERSION`. The `azd` path instead reads these from Bicep parameters / `azd env`.

## License

[MIT](LICENSE).
