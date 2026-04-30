"""
Clothing Image Search API
=========================
A FastAPI API that searches for clothing images by name and type,
downloads the best matching image, and streams it in the response.

Search order: Bing -> DuckDuckGo -> Google

Usage examples:
    GET /api/v1/clothing/image?name=nike+hoodie&type=hoodie
    GET /api/v1/clothing/image?name=adidas+running+shoes&type=shoes
    GET /api/v1/clothing/image?name=levis+501&type=jeans
"""

from __future__ import annotations

import html
import io
import logging
import re
import urllib.parse
from contextlib import asynccontextmanager
from typing import Optional

import httpx
from duckduckgo_search import DDGS
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("clothing-api")
logging.getLogger("primp.impersonate").setLevel(logging.ERROR)

# ---------------------------------------------------------------------------
# Shared HTTP client
# ---------------------------------------------------------------------------
HTTP_CLIENT: httpx.AsyncClient | None = None

DEFAULT_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
}


@asynccontextmanager
async def lifespan(app: FastAPI):
    global HTTP_CLIENT
    HTTP_CLIENT = httpx.AsyncClient(
        timeout=httpx.Timeout(30.0),
        follow_redirects=True,
        headers=DEFAULT_HEADERS,
    )
    logger.info("Clothing API started on http://127.0.0.1:8000")
    yield
    await HTTP_CLIENT.aclose()
    logger.info("Clothing API stopped")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Clothing Image Search API",
    description=(
        "Search any clothing item by name and type. "
        "Uses Bing -> DuckDuckGo -> Google fallback chain."
    ),
    version="2.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Image validation helpers
# ---------------------------------------------------------------------------
IMAGE_SIGNATURES = [
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"GIF87a", "image/gif"),
    (b"GIF89a", "image/gif"),
    (b"RIFF", "image/webp"),
    (b"BM", "image/bmp"),
]

SKIP_DOMAINS = {
    "gstatic.com",
    "google.com",
    "googleapis.com",
    "googleusercontent.com",
    "google-analytics.com",
    "schema.org",
    "w3.org",
    "duckduckgo.com",
    "bing.com",
}


def should_skip_url(url: str) -> bool:
    try:
        domain = urllib.parse.urlparse(url).hostname or ""
        return any(skip in domain for skip in SKIP_DOMAINS)
    except Exception:
        return True


def validate_image(image_bytes: bytes) -> tuple[bytes, str]:
    if len(image_bytes) < 8:
        raise ValueError("file too small to be a valid image")
    for sig, mime in IMAGE_SIGNATURES:
        if image_bytes[: len(sig)] == sig:
            return image_bytes, mime
    raise ValueError("unknown image signature")


def extract_image_urls_from_bing_page(page: str) -> list[str]:
    urls: list[str] = []
    for pattern in [
        r'"murl":"([^"]+)"',
        r'"imgurl":"([^"]+)"',
        r'"turl":"([^"]+)"',
        r"murl%3a(https?%3a%2f%2f[^&\"]+)",
    ]:
        found = re.findall(pattern, page, re.IGNORECASE)
        for value in found:
            value = urllib.parse.unquote(value).replace(r"\/", "/")
            if value and not should_skip_url(value):
                urls.append(value)
        if urls:
            break
    seen = set()
    unique = []
    for value in urls:
        if value not in seen:
            seen.add(value)
            unique.append(value)
    return unique


# ---------------------------------------------------------------------------
# Search engines
# ---------------------------------------------------------------------------
async def search_duckduckgo(query: str, max_results: int = 10) -> list[str]:
    try:
        import asyncio

        loop = asyncio.get_event_loop()

        def run_ddg() -> list[str]:
            found: list[str] = []
            with DDGS() as ddgs:
                for result in ddgs.images(query, max_results=max_results * 2):
                    image_url = result.get("image", "")
                    if image_url and not should_skip_url(image_url):
                        found.append(image_url)
                    if len(found) >= max_results:
                        break
            return found

        urls = await loop.run_in_executor(None, run_ddg)
        logger.info("DDG found %d image URLs for %s", len(urls), query)
        return urls
    except Exception as exc:
        logger.warning("DDG failed: %s", exc)
        return []


async def search_bing(query: str, max_results: int = 10) -> list[str]:
    try:
        assert HTTP_CLIENT is not None
        response = await HTTP_CLIENT.get(
            "https://www.bing.com/images/search",
            params={"q": query, "form": "HDRSC2", "first": "1"},
            headers={
                **DEFAULT_HEADERS,
                "Referer": "https://www.bing.com/",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            },
        )
        response.raise_for_status()
        urls = extract_image_urls_from_bing_page(html.unescape(response.text))
        logger.info("Bing found %d image URLs for %s", len(urls), query)
        return urls[:max_results]
    except Exception as exc:
        logger.warning("Bing failed: %s", exc)
        return []


async def search_google(query: str, max_results: int = 10) -> list[str]:
    patterns = [
        re.compile(
            r'\["(https?://[^"]+\.(?:jpg|jpeg|png|webp)(?:\?[^"]*)?)",[0-9]+,[0-9]+\]'
        ),
        re.compile(r'"(https?://[^"]+\.(?:jpg|jpeg|png|webp)(?:\?[^"]*)?)"'),
    ]
    try:
        assert HTTP_CLIENT is not None
        response = await HTTP_CLIENT.get(
            "https://www.google.com/search",
            params={"q": query, "tbm": "isch", "ijn": "0", "tbs": "isz:m"},
            headers={
                **DEFAULT_HEADERS,
                "Accept": (
                    "text/html,application/xhtml+xml,application/xml;"
                    "q=0.9,image/webp,*/*;q=0.8"
                ),
                "Referer": "https://www.google.com/",
            },
        )
        response.raise_for_status()
        text = response.text

        seen: set[str] = set()
        found: list[str] = []
        for pattern in patterns:
            for match in pattern.finditer(text):
                image_url = match.group(1)
                if image_url in seen or should_skip_url(image_url):
                    continue
                seen.add(image_url)
                found.append(image_url)
                if len(found) >= max_results:
                    break
            if len(found) >= max_results:
                break

        logger.info("Google found %d image URLs for %s", len(found), query)
        return found
    except Exception as exc:
        logger.warning("Google failed: %s", exc)
        return []


async def search_images(query: str, max_results: int = 10) -> tuple[list[str], str]:
    engines = [
        ("Bing", search_bing),
        ("DuckDuckGo", search_duckduckgo),
        ("Google", search_google),
    ]
    for engine_name, fn in engines:
        urls = await fn(query, max_results=max_results)
        if urls:
            logger.info("Using %s results for %s", engine_name, query)
            return urls, engine_name
    return [], "none"


# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------
async def download_image(url: str) -> tuple[bytes, str]:
    assert HTTP_CLIENT is not None
    try:
        response = await HTTP_CLIENT.get(
            url,
            headers={**DEFAULT_HEADERS, "Accept": "image/*,*/*;q=0.8"},
        )
        response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        raise ValueError(f"http {exc.response.status_code}") from exc
    except httpx.RequestError as exc:
        raise ValueError(f"request error: {exc}") from exc

    content_type = response.headers.get("content-type", "image/jpeg")
    if "image" not in content_type:
        content_type = "image/jpeg"
    return response.content, content_type


def build_query(name: str, clothing_type: Optional[str] = None) -> str:
    parts = [name.strip()]
    if clothing_type and clothing_type.strip():
        parts.append(clothing_type.strip())
    parts.append("clothing product photo with white background")
    return " ".join(parts)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/", tags=["health"])
async def root():
    return {
        "service": "Clothing Image Search API",
        "version": "2.1.0",
        "status": "running",
        "docs": "/docs",
        "search_engines": ["Bing", "DuckDuckGo", "Google"],
        "usage": "GET /api/v1/clothing/image?name=nike&type=hoodie",
    }


@app.get(
    "/api/v1/clothing/image",
    tags=["clothing"],
    summary="Get a clothing image",
    response_class=StreamingResponse,
)
async def get_clothing_image(
    name: str = Query(..., min_length=1, max_length=200),
    type: Optional[str] = Query(default=None, max_length=100),
    index: int = Query(default=0, ge=0, le=9),
):
    query = build_query(name, type)
    logger.info("Image request: query=%s index=%d", query, index)

    image_urls, search_engine = await search_images(query, max_results=10)
    if not image_urls:
        raise HTTPException(
            status_code=404,
            detail=f"No images found for '{query}'. Try another query.",
        )

    start = min(index, len(image_urls) - 1)
    for i in range(start, len(image_urls)):
        url = image_urls[i]
        logger.info("Trying image %d/%d: %s", i + 1, len(image_urls), url[:100])
        try:
            image_bytes, _ = await download_image(url)
            image_bytes, detected_mime = validate_image(image_bytes)
            logger.info(
                "Serving image index=%d mime=%s size=%d", i, detected_mime, len(image_bytes)
            )
            return StreamingResponse(
                io.BytesIO(image_bytes),
                media_type=detected_mime,
                headers={
                    "Content-Disposition": f'inline; filename="clothing_{name.replace(" ", "_")}.jpg"',
                    "Cache-Control": "public, max-age=3600",
                    "X-Image-Source": url,
                    "X-Search-Query": query,
                    "X-Result-Index": str(i),
                    "X-Search-Engine": search_engine,
                },
            )
        except Exception as exc:
            logger.warning("Image index=%d failed (%s), trying next", i, exc)
            continue

    raise HTTPException(
        status_code=502,
        detail="Found image URLs but failed to download a valid image.",
    )


@app.get(
    "/api/v1/clothing/search",
    tags=["clothing"],
    summary="Search clothing images metadata only",
    response_class=JSONResponse,
)
async def search_clothing_images(
    name: str = Query(..., min_length=1, max_length=200),
    type: Optional[str] = Query(default=None, max_length=100),
    max_results: int = Query(default=5, ge=1, le=10),
):
    query = build_query(name, type)
    image_urls, search_engine = await search_images(query, max_results=max_results)
    if not image_urls:
        raise HTTPException(status_code=404, detail=f"No images found for '{query}'.")

    type_param = f"&type={urllib.parse.quote(type)}" if type else ""
    name_param = urllib.parse.quote(name)

    return {
        "query": query,
        "search_engine": search_engine,
        "count": len(image_urls),
        "results": [
            {
                "index": i,
                "image_url": url,
                "api_url": f"/api/v1/clothing/image?name={name_param}{type_param}&index={i}",
            }
            for i, url in enumerate(image_urls)
        ],
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)
