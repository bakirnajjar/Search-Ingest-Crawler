"""Content hashing and URL-to-blob-name helpers."""
import hashlib
import posixpath
from urllib.parse import urlparse, unquote


def content_hash(data) -> str:
    """SHA-256 hex digest of bytes or str, used for change detection."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def language_from_url(url: str) -> str:
    """Infer a 2-letter language from a leading /xx/ path segment (e.g. /en/, /ar/)."""
    path = urlparse(url).path.lower()
    segments = [s for s in path.split("/") if s]
    if segments and len(segments[0]) == 2 and segments[0].isalpha():
        return segments[0]
    return "unknown"


def section_from_url(url: str) -> str:
    """First path segment after an optional language prefix (a coarse content group)."""
    path = urlparse(url).path.lower()
    segments = [s for s in path.split("/") if s]
    if segments and len(segments[0]) == 2 and segments[0].isalpha():
        segments = segments[1:]
    return segments[0] if segments else "unknown"


def blob_name_for(url: str, suffix: str = "") -> str:
    """Deterministic, filesystem-safe blob name derived from the URL path.

    Keeps a readable path prefix and appends a short hash to avoid collisions.
    """
    parsed = urlparse(url)
    path = unquote(parsed.path).strip("/")
    if not path:
        path = "index"
    safe = "".join(c if c.isalnum() or c in "-_/." else "-" for c in path)
    digest = content_hash(url)[:10]
    base, ext = posixpath.splitext(safe)
    if suffix and not suffix.startswith("."):
        suffix = "." + suffix
    if suffix:
        return f"{base}-{digest}{suffix}"
    if not ext:
        return f"{base}-{digest}"
    return f"{base}-{digest}{ext}"


def page_base_name(url: str) -> str:
    """Base blob name for a page (no extension); page files append .html/.md/.json."""
    base = blob_name_for(url)
    for ext in (".html", ".htm"):
        if base.lower().endswith(ext):
            return base[: -len(ext)]
    return base
