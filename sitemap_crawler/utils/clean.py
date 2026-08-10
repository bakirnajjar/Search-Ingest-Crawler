"""HTML boilerplate removal producing clean Markdown for indexing."""
import trafilatura


def extract_clean_markdown(html: str, url: str) -> str:
    """Extract main content as Markdown; returns empty string on failure.

    trafilatura handles both English and Arabic (RTL) boilerplate removal.
    """
    if not html:
        return ""
    try:
        result = trafilatura.extract(
            html,
            url=url,
            output_format="markdown",
            include_links=True,
            include_images=True,
            include_tables=True,
            favor_recall=True,
        )
    except Exception:
        return ""
    return result or ""
