"""Sitemap-driven crawler that lands site content in Azure Blob Storage.

Reads the sitemaps advertised in a site's robots.txt (or explicit sitemap URLs),
extracts cleaned page content, downloads referenced images and linked documents,
and optionally captures a full-page snapshot (PNG/PDF) via Playwright.

The target site is fully configurable (see CRAWL_* settings) — nothing here is
hardcoded to a specific domain.
"""
from datetime import datetime, timezone
from urllib.parse import urlparse

import scrapy
from scrapy import signals
from scrapy.spiders import SitemapSpider

from sitemap_crawler.items import BinaryItem, PageItem
from sitemap_crawler.utils.blob import get_blob_service_client
from sitemap_crawler.utils.clean import extract_clean_markdown
from sitemap_crawler.utils.hashing import (
    content_hash,
    language_from_url,
    page_base_name,
    section_from_url,
)

DOC_EXTENSIONS = (
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".csv", ".txt",
)
IMAGE_EXTENSIONS = (
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".ico", ".tiff",
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _csv(value: str):
    return [v.strip() for v in (value or "").split(",") if v.strip()]


class SitemapBlobSpider(SitemapSpider):
    name = "sitemap"

    # Target is configured at runtime (from_crawler) via CRAWL_* settings.
    sitemap_rules = [("", "parse")]
    sitemap_follow = [""]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._seen_assets = set()
        self._known_page_hashes = {}
        self._skipped_unchanged = 0
        self._asset_hosts = []

    @classmethod
    def from_crawler(cls, crawler, *args, **kwargs):
        spider = super().from_crawler(crawler, *args, **kwargs)
        s = crawler.settings
        # Spider args (-a sitemap_urls=...) override settings/env.
        sitemaps = _csv(kwargs.get("sitemap_urls") or s.get("CRAWL_SITEMAP_URLS", ""))
        if not sitemaps:
            raise ValueError(
                "No sitemap URLs configured. Set CRAWL_SITEMAP_URLS "
                "(comma-separated) or pass -a sitemap_urls=..."
            )
        spider.sitemap_urls = sitemaps
        domains = _csv(kwargs.get("allowed_domains") or s.get("CRAWL_ALLOWED_DOMAINS", ""))
        if not domains:
            domains = [urlparse(u).hostname for u in sitemaps if urlparse(u).hostname]
        spider.allowed_domains = domains
        spider._asset_hosts = _csv(s.get("CRAWL_ASSET_HOSTS", "")) or domains
        crawler.signals.connect(spider._on_opened, signal=signals.spider_opened)
        return spider

    def _on_opened(self):
        """Preload existing page content hashes so unchanged pages can be skipped."""
        if not self.settings.getbool("INCREMENTAL"):
            return
        try:
            svc = get_blob_service_client(
                self.settings.get("STORAGE_ACCOUNT_URL", ""),
                self.settings.get("STORAGE_CONNECTION_STRING", ""),
            )
            container = self.settings.get("BLOB_CONTAINER_PAGES", "pages")
            for b in svc.get_container_client(container).list_blobs(include=["metadata"]):
                if b.name.endswith(".html"):
                    h = (b.metadata or {}).get("contenthash")
                    if h:
                        self._known_page_hashes[b.name[:-5]] = h
            self.logger.info(
                "Incremental mode: loaded %d known page hashes.",
                len(self._known_page_hashes),
            )
        except Exception as exc:  # first run / no container yet -> full crawl
            self.logger.warning("Incremental preload skipped: %s", exc)

    # --- Page handling -----------------------------------------------------
    def parse(self, response):
        ctype = response.headers.get("Content-Type", b"").decode("latin-1").lower()
        if "text/html" not in ctype:
            # Non-HTML entry found in the sitemap (e.g. a direct PDF link).
            yield from self._maybe_binary(response.url, response.url, response)
            return

        html = response.text
        chash = content_hash(html)
        if self._known_page_hashes.get(page_base_name(response.url)) == chash:
            # Unchanged since last crawl: skip re-upload, assets, and snapshot.
            self._skipped_unchanged += 1
            return

        item = PageItem(
            kind="page",
            url=response.url,
            title=(response.css("title::text").get() or "").strip(),
            language=language_from_url(response.url),
            section=section_from_url(response.url),
            raw_html=html,
            clean_markdown=extract_clean_markdown(html, response.url),
            content_hash=chash,
            crawled_at=_now(),
            lastmod=response.meta.get("lastmod"),
        )
        yield item

        yield from self._follow_assets(response)

        if self.settings.getbool("CAPTURE_SNAPSHOTS"):
            yield scrapy.Request(
                response.url,
                callback=self.parse_snapshot,
                dont_filter=True,
                priority=20,  # highest: capture the snapshot while the page is fresh
                meta={
                    "playwright": True,
                    "playwright_include_page": True,
                    "language": language_from_url(response.url),
                },
                errback=self.errback_close_page,
            )

    # --- Asset discovery ---------------------------------------------------
    def _follow_assets(self, response):
        img_urls = set(response.css("img::attr(src)").getall())
        img_urls.update(response.css("img::attr(data-src)").getall())
        img_urls.update(response.css("source::attr(srcset)").getall())
        for raw in img_urls:
            url = response.urljoin(raw.split(" ")[0].split("?")[0])
            if self._is_asset(url, IMAGE_EXTENSIONS) and url not in self._seen_assets:
                self._seen_assets.add(url)
                yield scrapy.Request(
                    url,
                    callback=self.parse_binary,
                    priority=10,  # fetch a page's assets before crawling more pages
                    meta={"kind": "image", "source_page": response.url},
                    errback=self._log_asset_error,
                )

        for raw in response.css("a::attr(href)").getall():
            url = response.urljoin(raw.split("?")[0])
            if self._is_asset(url, DOC_EXTENSIONS) and url not in self._seen_assets:
                self._seen_assets.add(url)
                yield scrapy.Request(
                    url,
                    callback=self.parse_binary,
                    priority=10,
                    meta={"kind": "doc", "source_page": response.url},
                    errback=self._log_asset_error,
                )

    def _is_asset(self, url: str, extensions) -> bool:
        parsed = urlparse(url.split("#")[0].lower())
        if not parsed.path.endswith(extensions):
            return False
        host = parsed.hostname or ""
        return any(host == h or host.endswith("." + h) for h in self._asset_hosts)

    def _maybe_binary(self, url, source_page, response):
        ctype = response.headers.get("Content-Type", b"").decode("latin-1").lower()
        kind = "image" if ctype.startswith("image/") else "doc"
        yield BinaryItem(
            kind=kind,
            url=url,
            source_page=source_page,
            content_type=ctype,
            body=response.body,
            content_hash=content_hash(response.body),
            crawled_at=_now(),
            language=language_from_url(source_page),
        )

    def parse_binary(self, response):
        ctype = response.headers.get("Content-Type", b"").decode("latin-1").lower()
        yield BinaryItem(
            kind=response.meta.get("kind", "doc"),
            url=response.url,
            source_page=response.meta.get("source_page", ""),
            content_type=ctype,
            body=response.body,
            content_hash=content_hash(response.body),
            crawled_at=_now(),
            language=language_from_url(response.meta.get("source_page", response.url)),
        )

    # --- Snapshot handling -------------------------------------------------
    async def parse_snapshot(self, response):
        page = response.meta["playwright_page"]
        try:
            if self.settings.getbool("HARVEST_RENDERED_IMAGES"):
                for req in self._harvest_rendered_images(await self._rendered_img_urls(page), response.url):
                    yield req
            png = await page.screenshot(full_page=True, type="png")
            yield BinaryItem(
                kind="snapshot",
                url=response.url,
                source_page=response.url,
                content_type="image/png",
                body=png,
                content_hash=content_hash(png),
                crawled_at=_now(),
                language=response.meta.get("language", "unknown"),
            )
            if self.settings.getbool("SNAPSHOT_PDF"):
                pdf = await page.pdf(print_background=True)
                yield BinaryItem(
                    kind="snapshot",
                    url=response.url,
                    source_page=response.url,
                    content_type="application/pdf",
                    body=pdf,
                    content_hash=content_hash(pdf),
                    crawled_at=_now(),
                    language=response.meta.get("language", "unknown"),
                )
        finally:
            await page.close()

    async def _rendered_img_urls(self, page):
        """Resolved <img> URLs from the JS-executed DOM (captures lazy-loaded images)."""
        try:
            return await page.eval_on_selector_all(
                "img", "els => els.map(e => e.currentSrc || e.src).filter(Boolean)"
            )
        except Exception:
            return []

    def _harvest_rendered_images(self, urls, source_page):
        for raw in set(urls):
            url = raw.split("?")[0]
            if self._is_asset(url, IMAGE_EXTENSIONS) and url not in self._seen_assets:
                self._seen_assets.add(url)
                yield scrapy.Request(
                    url,
                    callback=self.parse_binary,
                    priority=10,
                    meta={"kind": "image", "source_page": source_page},
                    errback=self._log_asset_error,
                )

    async def errback_close_page(self, failure):
        page = failure.request.meta.get("playwright_page")
        if page:
            await page.close()
        self.logger.warning("Snapshot failed for %s: %s", failure.request.url, failure.value)

    def _log_asset_error(self, failure):
        self.logger.warning("Asset download failed: %s", failure.value)

    def closed(self, reason):
        self.logger.info(
            "Crawl closed (%s): skipped %d unchanged pages.",
            reason,
            self._skipped_unchanged,
        )
