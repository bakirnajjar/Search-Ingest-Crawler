"""FastAPI app: search API + conversational RAG + snapshot thumbnail proxy + static SPA."""
import json
import re
from pathlib import Path

from fastapi import FastAPI, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import blobs
from . import chat as chat_svc
from . import search as search_svc

app = FastAPI(title="Search Ingest Web", docs_url="/api/docs", openapi_url="/api/openapi.json")

STATIC_DIR = Path(__file__).resolve().parent / "static"


@app.get("/api/health")
def health():
    return {"status": "ok"}


@app.get("/api/search")
def api_search(
    q: str = Query("", max_length=1000),
    language: str | None = Query(None, max_length=32),
    section: str | None = Query(None, max_length=128),
    kind: str | None = Query(None, max_length=32),
    top: int = Query(20, ge=1, le=50),
    skip: int = Query(0, ge=0, le=1000),
):
    filters = {"language": language, "section": section, "kind": kind}
    return search_svc.search(q, filters, top=top, skip=skip)


@app.get("/api/search/smart")
async def api_search_smart(
    q: str = Query("", max_length=1000),
    top: int = Query(20, ge=1, le=50),
    skip: int = Query(0, ge=0, le=1000),
):
    facets = await run_in_threadpool(search_svc.facet_values)
    interp = await chat_svc.extract_query(q, facets)
    results = await run_in_threadpool(
        search_svc.search, interp["keywords"], interp["filters"], top, skip
    )
    return {"interpreted": interp, **results}


@app.get("/api/thumbnail")
def api_thumbnail(url: str = Query(..., max_length=2000)):
    data = blobs.get_snapshot_png(url)
    if not data:
        return Response(status_code=404)
    return Response(
        content=data,
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=86400"},
    )


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage]


def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


@app.post("/api/chat")
async def api_chat(req: ChatRequest, request: Request):
    messages = [{"role": m.role, "content": m.content} for m in req.messages if m.content][-12:]

    async def gen():
        try:
            queries = await chat_svc.plan_queries(messages)
            sources = await run_in_threadpool(chat_svc.retrieve, queries)
            yield _sse("sources", {"sources": [
                {"n": i + 1, "title": s["title"], "sourceUrl": s["sourceUrl"],
                 "kind": s["kind"], "language": s["language"]}
                for i, s in enumerate(sources)
            ]})
            parts: list[str] = []
            async for token in chat_svc.stream_answer(messages, sources):
                if await request.is_disconnected():
                    break
                parts.append(token)
                yield _sse("token", {"t": token})
            answer = "".join(parts)
            # Citation post-validation: only [n] that map to a real source.
            cited = sorted({int(n) for n in re.findall(r"\[(\d+)\]", answer) if 0 < int(n) <= len(sources)})
            citations = [{"n": n, "title": sources[n - 1]["title"], "sourceUrl": sources[n - 1]["sourceUrl"]} for n in cited]
            followups = await chat_svc.suggest_followups(messages, answer) if answer else []
            yield _sse("done", {"citations": citations, "followups": followups})
        except Exception as exc:  # surface a clean error event to the client
            yield _sse("error", {"message": str(exc)})

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


# Serve the built SPA (present only in the container image, not during local API dev).
if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="spa")
