"""Azure AI Search query layer (hybrid + semantic + integrated vectorization)."""
from functools import lru_cache
from urllib.parse import unquote

from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizableTextQuery

from . import config

# Only these fields may be filtered on, and values are OData-escaped (injection guard).
_ALLOWED_FILTERS = ("language", "section", "kind")

_SELECT = [
    "parent_id", "title", "sourceUrl", "language",
    "section", "kind", "crawledAt", "chunk",
]


def _escape(value: str) -> str:
    return str(value).replace("'", "''")


@lru_cache(maxsize=1)
def _client() -> SearchClient:
    credential = DefaultAzureCredential(managed_identity_client_id=config.AZURE_CLIENT_ID)
    return SearchClient(config.SEARCH_ENDPOINT, config.SEARCH_INDEX_NAME, credential)


def _build_filter(filters: dict) -> str | None:
    clauses = []
    for field in _ALLOWED_FILTERS:
        value = (filters or {}).get(field)
        if value:
            clauses.append(f"{field} eq '{_escape(value)}'")
    return " and ".join(clauses) if clauses else None


@lru_cache(maxsize=1)
def facet_values() -> dict:
    """Distinct values for each filterable field (for LLM grounding/validation)."""
    results = _client().search(
        search_text="*",
        facets=[f"{f},count:100" for f in _ALLOWED_FILTERS],
        top=0,
    )
    out = {f: [] for f in _ALLOWED_FILTERS}
    for name, values in (results.get_facets() or {}).items():
        out[name] = [v["value"] for v in values if v.get("value")]
    return out


def search(query: str, filters: dict, top: int = 10, skip: int = 0) -> dict:
    query = (query or "").strip()
    client = _client()

    vector_queries = None
    if query:
        vector_queries = [
            VectorizableTextQuery(text=query, k_nearest_neighbors=50, fields=config.VECTOR_FIELD)
        ]

    results = client.search(
        search_text=query or "*",
        vector_queries=vector_queries,
        query_type="semantic",
        semantic_configuration_name=config.SEMANTIC_CONFIG,
        query_caption="extractive",
        query_answer="extractive",
        filter=_build_filter(filters),
        select=_SELECT,
        facets=[f"{f},count:20" for f in _ALLOWED_FILTERS],
        top=top,
        skip=skip,
    )

    answers = [
        {"text": a.text, "score": a.score}
        for a in (results.get_answers() or [])
        if a.text
    ]

    facets = {}
    for name, values in (results.get_facets() or {}).items():
        facets[name] = [{"value": v["value"], "count": v["count"]} for v in values]

    # Collapse chunks to one card per source page, keeping the best-reranked chunk.
    best: dict = {}
    order: list = []
    for r in results:
        captions = r.get("@search.captions") or []
        caption = captions[0].text if captions else None  # .text is plain (no HTML) -> XSS-safe
        source_url = unquote(r.get("sourceUrl") or "")
        doc = {
            "parentId": r.get("parent_id"),
            "title": unquote(r.get("title") or "") or "(untitled)",
            "sourceUrl": source_url,
            "language": r.get("language"),
            "section": r.get("section"),
            "kind": r.get("kind"),
            "crawledAt": r.get("crawledAt"),
            "score": r.get("@search.score"),
            "reranker": r.get("@search.reranker_score"),
            "caption": caption,
            "snippet": (r.get("chunk") or "")[:400],
        }
        key = doc["parentId"] or source_url or len(order)
        if key not in best:
            best[key] = doc
            order.append(key)
        elif (doc["reranker"] or 0) > (best[key]["reranker"] or 0):
            best[key] = doc

    return {"answers": answers, "facets": facets, "results": [best[k] for k in order]}


_RAG_SELECT = ["id", "parent_id", "title", "sourceUrl", "language", "section", "kind", "chunk"]


def retrieve(query: str, top: int = 8, filters: dict | None = None) -> list[dict]:
    """Return full chunks for RAG grounding (hybrid + semantic + vector)."""
    query = (query or "").strip()
    if not query:
        return []
    results = _client().search(
        search_text=query,
        vector_queries=[VectorizableTextQuery(text=query, k_nearest_neighbors=top * 4, fields=config.VECTOR_FIELD)],
        query_type="semantic",
        semantic_configuration_name=config.SEMANTIC_CONFIG,
        filter=_build_filter(filters),
        select=_RAG_SELECT,
        top=top,
    )
    return [
        {
            "id": r.get("id"),
            "parentId": r.get("parent_id"),
            "title": unquote(r.get("title") or "") or "(untitled)",
            "sourceUrl": unquote(r.get("sourceUrl") or ""),
            "language": r.get("language"),
            "kind": r.get("kind"),
            "chunk": r.get("chunk") or "",
            "reranker": r.get("@search.reranker_score"),
        }
        for r in results
    ]
