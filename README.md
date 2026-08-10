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

## Deploy to Azure Container Apps (scheduled job)

```powershell
az login
az account set --subscription "<subscription-id>"
az extension add --name containerapp   # if not already installed

./infra/deploy.ps1 `
  -StorageAccount "<existing-storage-account>" `
  -SitemapUrls "https://www.example.com/robots.txt" `
  -ResourceGroup "rg-search-ingest-crawler" -Location "uaenorth"
```

The script builds the image in ACR, creates a user-assigned Managed Identity,
grants it **Storage Blob Data Contributor** + **AcrPull**, applies a storage
**lifecycle policy** (snapshots expire after `-SnapshotRetentionDays`, default 30),
and creates a Container Apps Job scheduled daily at `0 2 * * *` (02:00 UTC, 12h
replica timeout).

Trigger an immediate run:

```powershell
az containerapp job start --name search-ingest-crawler-job --resource-group rg-search-ingest-crawler
az containerapp job execution list --name search-ingest-crawler-job --resource-group rg-search-ingest-crawler -o table
```

## Configuration reference

All settings are environment variables (see [`.env.example`](.env.example)):
`CRAWL_SITEMAP_URLS`, `CRAWL_ALLOWED_DOMAINS`, `CRAWL_ASSET_HOSTS`,
`STORAGE_ACCOUNT_URL`, `AZURE_CLIENT_ID`, `BLOB_CONTAINER_*`,
`CAPTURE_SNAPSHOTS`, `SNAPSHOT_PDF`, `INCREMENTAL`, `HARVEST_RENDERED_IMAGES`,
`CRAWLER_CONCURRENCY`, `CRAWLER_DOWNLOAD_DELAY`, `LOG_LEVEL`.

## License

[MIT](LICENSE).
