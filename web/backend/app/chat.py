"""Conversational RAG: a small planner model decomposes the question into search
queries, hybrid+semantic retrieval grounds the answer, and the chat model streams a
cited response. All Azure OpenAI calls use Managed Identity.
"""
import json
import re
from functools import lru_cache

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AsyncAzureOpenAI

from . import config
from . import search as search_svc

_SCOPE = "https://cognitiveservices.azure.com/.default"


@lru_cache(maxsize=1)
def _client() -> AsyncAzureOpenAI:
    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(managed_identity_client_id=config.AZURE_CLIENT_ID), _SCOPE
    )
    return AsyncAzureOpenAI(
        azure_endpoint=config.FOUNDRY_ENDPOINT,
        azure_ad_token_provider=token_provider,
        api_version=config.OPENAI_API_VERSION,
    )


def _lang(text: str) -> str:
    return "ar" if re.search(r"[\u0600-\u06FF]", text or "") else "en"


async def plan_queries(messages: list[dict]) -> list[str]:
    """Agentic planning: turn the conversation into 1-3 focused search queries."""
    user_turns = [m for m in messages if m.get("role") == "user"]
    latest = user_turns[-1]["content"] if user_turns else ""
    if not latest.strip():
        return []
    history = "\n".join(f"{m['role']}: {m['content']}" for m in messages[-6:])
    prompt = (
        "Turn the user's latest question (with chat history) into 1-3 focused search "
        "queries for a retrieval system; decompose multi-part questions. Keep the "
        'user\'s language. Return JSON: {"queries": ["..."]}.\n\n'
        f"History:\n{history}\n\nLatest question: {latest}"
    )
    try:
        resp = await _client().chat.completions.create(
            model=config.PLANNER_DEPLOYMENT,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
        )
        data = json.loads(resp.choices[0].message.content or "{}")
        queries = [q for q in (data.get("queries") or []) if isinstance(q, str) and q.strip()]
        return queries[:3] or [latest]
    except Exception:
        return [latest]


def _dedupe(hits: list[dict], cap: int) -> list[dict]:
    best: dict = {}
    for h in hits:
        key = h.get("parentId") or h.get("id")
        if key not in best or (h.get("reranker") or 0) > (best[key].get("reranker") or 0):
            best[key] = h
    ranked = sorted(best.values(), key=lambda h: (h.get("reranker") or 0), reverse=True)
    return ranked[:cap]


def retrieve(queries: list[str], per_query: int = 6, cap: int = 8) -> list[dict]:
    """Run each planned query and merge to a deduped, ranked source set (blocking)."""
    hits: list[dict] = []
    for q in queries:
        hits.extend(search_svc.retrieve(q, top=per_query))
    return _dedupe(hits, cap)


def _system_prompt(lang: str) -> str:
    return (
        "You are a helpful assistant answering questions about a website's content. "
        "Answer ONLY from the numbered SOURCES provided. Cite sources inline as [n] "
        "using their numbers. If the answer is not in the sources, say you don't have "
        "that information and suggest rephrasing. Be concise and accurate. "
        f"Reply in {'Arabic' if lang == 'ar' else 'English'}, matching the user's language."
    )


def _context(sources: list[dict]) -> str:
    return "\n\n".join(
        f"[{i}] {s['title']} ({s['sourceUrl']})\n{s['chunk']}"
        for i, s in enumerate(sources, 1)
    )


async def stream_answer(messages: list[dict], sources: list[dict]):
    last = messages[-1]["content"] if messages else ""
    convo = [{"role": "system", "content": _system_prompt(_lang(last))}]
    for m in messages[:-1][-6:]:  # prior turns for conversational memory
        if m.get("role") in ("user", "assistant") and m.get("content"):
            convo.append({"role": m["role"], "content": m["content"][:4000]})
    convo.append({"role": "user", "content": f"SOURCES:\n{_context(sources)}\n\nQuestion: {last}"})

    stream = await _client().chat.completions.create(
        model=config.CHAT_DEPLOYMENT, messages=convo, stream=True
    )
    async for chunk in stream:
        if chunk.choices and chunk.choices[0].delta and chunk.choices[0].delta.content:
            yield chunk.choices[0].delta.content


async def suggest_followups(messages: list[dict], answer: str) -> list[str]:
    last = messages[-1]["content"] if messages else ""
    prompt = (
        "Given the question and answer, propose 3 short follow-up questions the user "
        'might ask next. Return JSON: {"followups": ["..."]}. Write them in '
        f"{'Arabic' if _lang(last) == 'ar' else 'English'}.\n\n"
        f"Question: {last}\nAnswer: {answer[:1500]}"
    )
    try:
        resp = await _client().chat.completions.create(
            model=config.PLANNER_DEPLOYMENT,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
        )
        data = json.loads(resp.choices[0].message.content or "{}")
        return [q for q in (data.get("followups") or []) if isinstance(q, str) and q.strip()][:3]
    except Exception:
        return []


async def extract_query(text: str, facets: dict) -> dict:
    """Parse a natural-language query into keyword text + validated facet filters."""
    text = (text or "").strip()
    empty = {"keywords": text, "filters": {}, "notes": ""}
    if not text:
        return empty
    # "unknown" etc. are index sentinels, not user-selectable filter values.
    sentinels = {"unknown", "none", "n/a", "null", ""}
    allowed = {
        f: [v for v in ((facets or {}).get(f) or []) if v.lower() not in sentinels]
        for f in ("language", "kind", "section")
    }
    prompt = (
        "You convert a user's search request into a keyword query plus optional filters "
        "for a website search index. Return JSON: "
        '{"keywords": "...", "filters": {"language": "", "kind": "", "section": ""}, "notes": "..."}.\n'
        "Rules: keywords = the core topic words only, with any filter words removed; keep "
        "the user's language. Only set a filter when the request clearly implies it, "
        "otherwise leave it as an empty string (never guess, never use 'unknown'). "
        "Only use a value from the allowed lists below. "
        "Map words like pdf/document->doc, picture/photo->image, screenshot->snapshot, "
        "webpage->page, arabic->ar, english->en. notes = one short sentence describing "
        "how you interpreted the request, in the user's language.\n"
        f"allowed.language = {allowed['language']}\n"
        f"allowed.kind = {allowed['kind']}\n"
        f"allowed.section = {allowed['section']}\n\n"
        f"Request: {text}"
    )
    try:
        resp = await _client().chat.completions.create(
            model=config.PLANNER_DEPLOYMENT,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
        )
        data = json.loads(resp.choices[0].message.content or "{}")
    except Exception:
        return empty

    raw = data.get("filters") if isinstance(data.get("filters"), dict) else {}
    filters: dict = {}
    for field in ("language", "kind", "section"):
        value = raw.get(field)
        if not isinstance(value, str) or value.strip().lower() in sentinels:
            continue
        match = next((v for v in allowed[field] if v.lower() == value.strip().lower()), None)
        if match:
            filters[field] = match
    keywords = data.get("keywords")
    keywords = keywords.strip() if isinstance(keywords, str) and keywords.strip() else text
    notes = data.get("notes") if isinstance(data.get("notes"), str) else ""
    return {"keywords": keywords, "filters": filters, "notes": notes.strip()}
