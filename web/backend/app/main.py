"""FastAPI app: search API + snapshot thumbnail proxy + static SPA."""
from pathlib import Path

from fastapi import FastAPI, Query, Response
from fastapi.staticfiles import StaticFiles

from . import blobs
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


# Serve the built SPA (present only in the container image, not during local API dev).
if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="spa")
