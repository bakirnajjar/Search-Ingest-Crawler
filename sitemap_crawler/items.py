"""Scrapy item definitions for crawled e& content."""
import scrapy


class PageItem(scrapy.Item):
    """A crawled HTML page plus its cleaned text and metadata."""

    kind = scrapy.Field()  # "page"
    url = scrapy.Field()
    title = scrapy.Field()
    language = scrapy.Field()  # "en" | "ar" | ... | "unknown"
    section = scrapy.Field()  # first path segment after the language, or "unknown"
    raw_html = scrapy.Field()
    clean_markdown = scrapy.Field()
    content_hash = scrapy.Field()
    crawled_at = scrapy.Field()
    lastmod = scrapy.Field()  # from sitemap, if present


class BinaryItem(scrapy.Item):
    """A binary asset (image or document) downloaded from the site."""

    kind = scrapy.Field()  # "image" | "doc"
    url = scrapy.Field()
    source_page = scrapy.Field()
    content_type = scrapy.Field()
    body = scrapy.Field()  # raw bytes
    content_hash = scrapy.Field()
    crawled_at = scrapy.Field()
    language = scrapy.Field()
