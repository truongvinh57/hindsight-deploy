#!/usr/bin/env python3
"""Cohere-compatible /rerank  ->  DeepInfra inference API adapter.

Hindsight's 'cohere' reranker provider speaks the Cohere wire format:

    POST <base_url>            {"model": "...", "query": "...", "documents": [...]}
    <- {"results": [{"index": 0, "relevance_score": 0.97}, ...]}

DeepInfra serves Qwen3-Reranker at a different contract:

    POST https://api.deepinfra.com/v1/inference/<model>
         Authorization: Bearer <key>, application/json
         {"queries": ["<query>"], "documents": ["d1", "d2", ...]}
    <- {"scores": [0.97, 0.12, ...], "request_id": ..., "inference_status": {...}}

This process is that translation and nothing else: standard library only, no
model, no state. It is mounted into a stock python:3.12-slim container, so
there is no image to build either.

Env:
  DEEPINFRA_API_KEY   required
  DEEPINFRA_MODEL     default Qwen/Qwen3-Reranker-0.6B
  DEEPINFRA_BASE      default https://api.deepinfra.com
  PORT                default 8080
  TIMEOUT             upstream timeout seconds, default 25 (must stay below
                      Hindsight's HINDSIGHT_API_RERANKER_COHERE_TIMEOUT)
  MAX_CONCURRENCY     in-flight upstream calls, default 16
  MAX_BODY_BYTES      request body cap, default 8 MiB
  MAX_DOCUMENTS       hard cap on documents per request, default 512
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEEPINFRA_BASE = os.environ.get("DEEPINFRA_BASE", "https://api.deepinfra.com").rstrip("/")
DEEPINFRA_MODEL = os.environ.get("DEEPINFRA_MODEL", "Qwen/Qwen3-Reranker-0.6B")
API_KEY = os.environ.get("DEEPINFRA_API_KEY", "")
PORT = int(os.environ.get("PORT", "8080"))
TIMEOUT = float(os.environ.get("TIMEOUT", "25"))
MAX_CONCURRENCY = int(os.environ.get("MAX_CONCURRENCY", "16"))
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(8 * 1024 * 1024)))
MAX_DOCUMENTS = int(os.environ.get("MAX_DOCUMENTS", "512"))

# Only ever a "provider/model" slug, never a path: this value is interpolated
# into the upstream URL and the adapter holds the bearer token.
MODEL_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
SLOTS = threading.BoundedSemaphore(MAX_CONCURRENCY)

logging.basicConfig(level=logging.INFO, format='{"severity":"%(levelname)s","message":"%(message)s"}')
log = logging.getLogger("rerank-adapter")


def _upstream(model: str, body: bytes) -> dict:
    req = urllib.request.Request(
        f"{DEEPINFRA_BASE}/v1/inference/{model}",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def rerank(query: str, documents: list, model: str):
    """Call DeepInfra and return (one relevance score per document, raw payload)."""
    body = json.dumps({"queries": [query], "documents": documents}).encode("utf-8")
    try:
        payload = _upstream(model, body)
    except urllib.error.HTTPError as exc:
        # One retry, and only for the transient classes. 4xx other than 429 are
        # real errors (bad model, quota) and are surfaced unchanged.
        if exc.code == 429 or exc.code >= 500:
            retry_after = exc.headers.get("Retry-After") if exc.headers else None
            try:
                delay = min(float(retry_after), 2.0) if retry_after else 0.5
            except (TypeError, ValueError):
                delay = 0.5
            log.warning("deepinfra %s, retrying in %.1fs", exc.code, delay)
            time.sleep(delay)
            payload = _upstream(model, body)
        else:
            raise

    scores = payload.get("scores") or []
    # One query: DeepInfra answers a flat list. Tolerate a per-query matrix too,
    # in case the endpoint starts returning [[...]] like its docs sketch.
    if scores and isinstance(scores[0], list):
        scores = scores[0]
    if len(scores) != len(documents):
        raise ValueError(f"DeepInfra returned {len(scores)} scores for {len(documents)} documents")
    return [float(s) for s in scores], payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        log.info("%s %s", self.address_string(), fmt % args)

    def _send(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _drain(self) -> None:
        """Consume an unread body so the keep-alive connection stays in sync."""
        length = int(self.headers.get("Content-Length") or 0)
        if 0 < length <= MAX_BODY_BYTES:
            self.rfile.read(length)

    def do_GET(self):
        if self.path in ("/health", "/health/live"):
            self._send(200, {"status": "ok", "model": DEEPINFRA_MODEL})
        else:
            self._drain()
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path not in ("/v1/rerank", "/rerank"):
            self._drain()
            self._send(404, {"error": f"unknown path {self.path}"})
            return

        started = time.time()
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            self._drain()
            self._send(413, {"error": f"body too large: {length} > {MAX_BODY_BYTES}"})
            return

        try:
            raw = self.rfile.read(length) if length else b"{}"
            request = json.loads(raw or b"{}")
        except json.JSONDecodeError as exc:
            self._send(400, {"error": f"invalid JSON: {exc}"})
            return

        try:
            query = request.get("query")
            documents = request.get("documents") or []
            if not isinstance(query, str) or not query.strip():
                self._send(400, {"error": "query is required"})
                return
            if not isinstance(documents, list):
                self._send(400, {"error": "documents must be a list"})
                return
            if not documents:
                self._send(200, {"results": []})
                return
            if len(documents) > MAX_DOCUMENTS:
                # Reject rather than truncate: Hindsight pre-fills missing scores
                # with 0.0, so a truncated list silently ranks the tail last.
                self._send(413, {"error": f"too many documents: {len(documents)} > {MAX_DOCUMENTS}"})
                return
            model = request.get("model") or DEEPINFRA_MODEL
            if not MODEL_RE.match(str(model)):
                self._send(400, {"error": f"invalid model id: {model!r}"})
                return

            with SLOTS:
                scores, payload = rerank(query, [str(d) for d in documents], model)

            results = sorted(
                ({"index": i, "relevance_score": round(s, 6)} for i, s in enumerate(scores)),
                key=lambda r: r["relevance_score"],
                reverse=True,
            )
            log.info(
                "rerank model=%s docs=%d top=%.4f took_ms=%d cost=%.8f",
                model,
                len(documents),
                results[0]["relevance_score"] if results else 0.0,
                int((time.time() - started) * 1000),
                float((payload.get("inference_status") or {}).get("cost") or 0.0),
            )
            self._send(200, {"results": results})
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:500]
            log.error("deepinfra HTTP %s: %s", exc.code, detail)
            self._send(502, {"error": f"deepinfra {exc.code}", "detail": detail})
        except Exception as exc:  # noqa: BLE001 - never kill the server for one request
            log.error("rerank failed: %s", exc)
            self._send(502, {"error": str(exc)[:300]})


def main() -> None:
    if not API_KEY:
        raise SystemExit("DEEPINFRA_API_KEY is required")
    log.info(
        "rerank adapter listening on :%d -> %s (%s), concurrency=%d timeout=%.0fs",
        PORT, DEEPINFRA_BASE, DEEPINFRA_MODEL, MAX_CONCURRENCY, TIMEOUT,
    )
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
