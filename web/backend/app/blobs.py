"""Snapshot blob access (Managed Identity) for the thumbnail proxy.

The snapshot blob name is derived from the page URL with the SAME algorithm the crawler
uses, so no extra index field is needed.
"""
import hashlib
import posixpath
from functools import lru_cache
from urllib.parse import urlparse, unquote

from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

from . import config


def _content_hash(data) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def _blob_name_for(url: str, suffix: str = "") -> str:
    parsed = urlparse(url)
    path = unquote(parsed.path).strip("/") or "index"
    safe = "".join(c if c.isalnum() or c in "-_/." else "-" for c in path)
    digest = _content_hash(url)[:10]
    base, ext = posixpath.splitext(safe)
    if suffix and not suffix.startswith("."):
        suffix = "." + suffix
    if suffix:
        return f"{base}-{digest}{suffix}"
    if not ext:
        return f"{base}-{digest}"
    return f"{base}-{digest}{ext}"


def snapshot_blob_name(url: str) -> str:
    base = _blob_name_for(url)
    for ext in (".html", ".htm"):
        if base.lower().endswith(ext):
            base = base[: -len(ext)]
            break
    return base + ".png"


@lru_cache(maxsize=1)
def _service() -> BlobServiceClient:
    credential = DefaultAzureCredential(managed_identity_client_id=config.AZURE_CLIENT_ID)
    return BlobServiceClient(account_url=config.STORAGE_ACCOUNT_URL, credential=credential)


def get_snapshot_png(url: str) -> bytes | None:
    if not config.STORAGE_ACCOUNT_URL:
        return None
    client = _service().get_blob_client(config.SNAPSHOTS_CONTAINER, snapshot_blob_name(url))
    try:
        return client.download_blob().readall()
    except ResourceNotFoundError:
        return None
