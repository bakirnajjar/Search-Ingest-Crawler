"""Item pipeline that lands crawled content in Azure Blob Storage.

Routing by item kind:
  page     -> pages     (raw .html + cleaned .md + .json sidecar)
  image    -> images
  doc      -> docs
  snapshot -> snapshots (.png / .pdf)

Content-hash metadata enables incremental daily crawls: unchanged blobs are skipped.
"""
import json
import logging
from urllib.parse import quote

from azure.core.exceptions import ResourceNotFoundError
from azure.storage.blob import ContentSettings
from itemadapter import ItemAdapter

from sitemap_crawler.utils.blob import ensure_container, get_blob_service_client
from sitemap_crawler.utils.hashing import blob_name_for, page_base_name

logger = logging.getLogger(__name__)


def _ascii(value: str) -> str:
    """Blob metadata must be ASCII; percent-encode anything else (e.g. Arabic)."""
    return quote(str(value or ""), safe="")


def _meta(value: str) -> str:
    """Header-safe metadata value: collapse whitespace; keep printable ASCII, else percent-encode."""
    s = " ".join(str(value or "").split())
    return s if s.isascii() else quote(s, safe="")


class BlobStoragePipeline:
    def __init__(self, settings):
        self.account_url = settings.get("STORAGE_ACCOUNT_URL", "")
        self.connection_string = settings.get("STORAGE_CONNECTION_STRING", "")
        self.containers = {
            "page": settings.get("BLOB_CONTAINER_PAGES", "pages"),
            "image": settings.get("BLOB_CONTAINER_IMAGES", "images"),
            "doc": settings.get("BLOB_CONTAINER_DOCS", "docs"),
            "snapshot": settings.get("BLOB_CONTAINER_SNAPSHOTS", "snapshots"),
        }
        self.service = None
        self.uploaded = 0
        self.skipped = 0

    @classmethod
    def from_crawler(cls, crawler):
        return cls(crawler.settings)

    def open_spider(self, spider):
        self.service = get_blob_service_client(self.account_url, self.connection_string)
        for name in set(self.containers.values()):
            ensure_container(self.service, name)

    def close_spider(self, spider):
        spider.logger.info(
            "Blob pipeline done: %d uploaded, %d unchanged/skipped.",
            self.uploaded,
            self.skipped,
        )

    def process_item(self, item, spider):
        adapter = ItemAdapter(item)
        kind = adapter.get("kind")
        if kind == "page":
            self._handle_page(adapter)
        else:
            self._handle_binary(adapter, kind)
        return item

    # --- Page: html + markdown + json sidecar ------------------------------
    def _handle_page(self, adapter):
        url = adapter["url"]
        base = page_base_name(url)  # e.g. "en/consumer-ab12cd34ef"
        chash = adapter["content_hash"]
        meta = {
            "sourceurl": _ascii(url),
            "title": _meta(adapter.get("title")),
            "crawledat": _ascii(adapter["crawled_at"]),
            "language": _ascii(adapter.get("language", "unknown")),
            "section": _ascii(adapter.get("section", "unknown")),
            "contenthash": chash,
            "kind": "page",
        }
        container = self.containers["page"]

        if self._unchanged(container, f"{base}.html", chash):
            self.skipped += 1
            return

        self._upload(
            container, f"{base}.html", adapter["raw_html"].encode("utf-8"),
            "text/html; charset=utf-8", meta,
        )
        self._upload(
            container, f"{base}.md",
            (adapter.get("clean_markdown") or "").encode("utf-8"),
            "text/markdown; charset=utf-8", meta,
        )
        sidecar = {
            "sourceUrl": url,
            "title": adapter.get("title"),
            "language": adapter.get("language"),
            "section": adapter.get("section"),
            "contentHash": chash,
            "crawledAt": adapter.get("crawled_at"),
            "lastmod": adapter.get("lastmod"),
        }
        self._upload(
            container, f"{base}.json",
            json.dumps(sidecar, ensure_ascii=False, indent=2).encode("utf-8"),
            "application/json; charset=utf-8", meta,
        )
        self.uploaded += 1

    # --- Binary: image / doc / snapshot ------------------------------------
    def _handle_binary(self, adapter, kind):
        url = adapter["url"]
        content_type = adapter.get("content_type") or "application/octet-stream"
        chash = adapter["content_hash"]
        if kind == "snapshot":
            suffix = "pdf" if "pdf" in content_type else "png"
            name = blob_name_for(url, suffix=suffix)
        else:
            name = blob_name_for(url)
        container = self.containers.get(kind, self.containers["doc"])

        if self._unchanged(container, name, chash):
            self.skipped += 1
            return

        meta = {
            "sourceurl": _ascii(url),
            "title": _meta(name.split("/")[-1]),
            "sourcepage": _ascii(adapter.get("source_page", "")),
            "crawledat": _ascii(adapter["crawled_at"]),
            "language": _ascii(adapter.get("language", "unknown")),
            "contenthash": chash,
            "kind": _ascii(kind),
        }
        self._upload(container, name, bytes(adapter["body"]), content_type.split(";")[0], meta)
        self.uploaded += 1

    # --- Helpers -----------------------------------------------------------
    def _unchanged(self, container, name, chash) -> bool:
        try:
            props = self.service.get_blob_client(container, name).get_blob_properties()
        except ResourceNotFoundError:
            return False
        return (props.metadata or {}).get("contenthash") == chash

    def _upload(self, container, name, data, content_type, metadata):
        self.service.get_blob_client(container, name).upload_blob(
            data,
            overwrite=True,
            metadata=metadata,
            content_settings=ContentSettings(content_type=content_type),
        )
        logger.debug("Uploaded %s/%s (%d bytes)", container, name, len(data))
