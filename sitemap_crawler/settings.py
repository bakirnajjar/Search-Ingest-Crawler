"""Scrapy settings for the sitemap-to-blob crawler."""
import logging
import os

from dotenv import load_dotenv

# Load a local .env if present; real env vars (e.g. ACA-injected) always take precedence.
load_dotenv(override=False)

BOT_NAME = "sitemap_crawler"

# Azure SDK logs every HTTP request at INFO; keep the crawl log readable.
logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)
logging.getLogger("azure.identity").setLevel(logging.WARNING)

SPIDER_MODULES = ["sitemap_crawler.spiders"]
NEWSPIDER_MODULE = "sitemap_crawler.spiders"

# --- Target site (configure per deployment) --------------------------------
# Comma-separated robots.txt or sitemap URLs to seed the crawl from.
CRAWL_SITEMAP_URLS = os.getenv("CRAWL_SITEMAP_URLS", "")
# Comma-separated allowed domains. If empty, derived from the sitemap hostnames.
CRAWL_ALLOWED_DOMAINS = os.getenv("CRAWL_ALLOWED_DOMAINS", "")
# Comma-separated hosts whose images/docs may be downloaded. If empty, uses allowed domains.
CRAWL_ASSET_HOSTS = os.getenv("CRAWL_ASSET_HOSTS", "")

# --- Politeness / robots ---------------------------------------------------
ROBOTSTXT_OBEY = True
USER_AGENT = os.getenv(
    "CRAWLER_USER_AGENT",
    "search-ingest-crawler/1.0 (+https://github.com/; content ingestion)",
)

CONCURRENT_REQUESTS = int(os.getenv("CRAWLER_CONCURRENCY", "8"))
CONCURRENT_REQUESTS_PER_DOMAIN = int(os.getenv("CRAWLER_CONCURRENCY_PER_DOMAIN", "4"))
DOWNLOAD_DELAY = float(os.getenv("CRAWLER_DOWNLOAD_DELAY", "0.5"))
DOWNLOAD_TIMEOUT = int(os.getenv("CRAWLER_DOWNLOAD_TIMEOUT", "60"))

AUTOTHROTTLE_ENABLED = True
AUTOTHROTTLE_START_DELAY = 0.5
AUTOTHROTTLE_MAX_DELAY = 15.0
AUTOTHROTTLE_TARGET_CONCURRENCY = 4.0

# --- Retries / HTTP cache --------------------------------------------------
RETRY_ENABLED = True
RETRY_TIMES = 3
RETRY_HTTP_CODES = [429, 500, 502, 503, 504, 522, 524, 408]

# --- Pipelines -------------------------------------------------------------
ITEM_PIPELINES = {
    "sitemap_crawler.pipelines.blob_pipeline.BlobStoragePipeline": 300,
}

# --- Playwright (used only for full-page snapshots) ------------------------
DOWNLOAD_HANDLERS = {
    "http": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
    "https": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
}
TWISTED_REACTOR = "twisted.internet.asyncioreactor.AsyncioSelectorReactor"
PLAYWRIGHT_BROWSER_TYPE = "chromium"
PLAYWRIGHT_LAUNCH_OPTIONS = {"headless": True}
PLAYWRIGHT_DEFAULT_NAVIGATION_TIMEOUT = int(
    os.getenv("PLAYWRIGHT_NAV_TIMEOUT_MS", "60000")
)
PLAYWRIGHT_MAX_CONTEXTS = int(os.getenv("PLAYWRIGHT_MAX_CONTEXTS", "2"))
PLAYWRIGHT_MAX_PAGES_PER_CONTEXT = int(os.getenv("PLAYWRIGHT_MAX_PAGES", "4"))

# --- Feature flags ---------------------------------------------------------
# Full-page snapshot (PNG + PDF) for every page. Enabled per project decision.
CAPTURE_SNAPSHOTS = os.getenv("CAPTURE_SNAPSHOTS", "true").lower() == "true"
SNAPSHOT_PDF = os.getenv("SNAPSHOT_PDF", "true").lower() == "true"
# Skip the expensive snapshot + asset re-download when a page's content is unchanged.
INCREMENTAL = os.getenv("INCREMENTAL", "true").lower() == "true"
# Harvest images from the rendered (JS-executed) DOM during snapshot capture.
HARVEST_RENDERED_IMAGES = os.getenv("HARVEST_RENDERED_IMAGES", "true").lower() == "true"

# --- Blob storage ----------------------------------------------------------
# Managed Identity via DefaultAzureCredential (az login locally, UAMI in ACA).
STORAGE_ACCOUNT_URL = os.getenv("STORAGE_ACCOUNT_URL", "")
# Optional connection-string fallback for quick local testing only.
STORAGE_CONNECTION_STRING = os.getenv("STORAGE_CONNECTION_STRING", "")
BLOB_CONTAINER_PAGES = os.getenv("BLOB_CONTAINER_PAGES", "pages")
BLOB_CONTAINER_IMAGES = os.getenv("BLOB_CONTAINER_IMAGES", "images")
BLOB_CONTAINER_DOCS = os.getenv("BLOB_CONTAINER_DOCS", "docs")
BLOB_CONTAINER_SNAPSHOTS = os.getenv("BLOB_CONTAINER_SNAPSHOTS", "snapshots")

# --- Misc ------------------------------------------------------------------
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
REQUEST_FINGERPRINTER_IMPLEMENTATION = "2.7"
FEED_EXPORT_ENCODING = "utf-8"

# Arabic pages emit benign trafilatura link warnings; keep them out of the log.
logging.getLogger("trafilatura").setLevel(logging.ERROR)
