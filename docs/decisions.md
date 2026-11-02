# Decisions and evidence

Every choice below was verified against the running code or a live API call, not
copied from a blog post. Evidence is recorded so the next person does not
re-litigate it.

## 1. Multi-user: static-keys tenant extension (no Supabase)

Hindsight's auth is a `TenantExtension`. Three options exist upstream:

| Extension | Isolation | Verdict |
|---|---|---|
| `ApiKeyTenantExtension` (built-in) | one key, one schema — everyone shares data | rejected |
| `SupabaseTenantExtension` | Supabase JWT → schema per user | rejected: needs an external IdP |
| `StaticKeysTenantExtension` | env-declared keys → schema per user | **chosen** |

Evidence: `hindsight-api-slim/hindsight_api/extensions/tenant.py` defines
`authenticate()` → `TenantContext(schema_name=...)`; the extension's own
`extension.py` maps `user:key` pairs to `{prefix}_{user}`. There is no
"admin sees all schemas" path in the OSS server.

Consequence, verified in the code: the Control Plane holds a single
`HINDSIGHT_CP_DATAPLANE_API_KEY` (`src/lib/hindsight-client.ts`), so it sees
one schema. Multiple users therefore share one API, not one UI. Per-user UIs
would need one control-plane container per user.

## 2. No derived image

The upstream extension Dockerfile builds `FROM ghcr.io/vectorize-io/hindsight`
and copies the package into `/app/extensions`. The server loads extensions from
`PYTHONPATH`, so mounting the same directory read-only at the same path is
equivalent and keeps us on official images. `docker-compose.yml` therefore uses
`ghcr.io/vectorize-io/hindsight:1.1.0-slim` with
`PYTHONPATH=/app/extensions`.

`-slim` (not the 9 GB full image) because embeddings and reranking are remote:
the slim image has no bundled PyTorch/ML models, so ~500 MB instead of ~9 GB and
far less RAM.

## 3. LLM: DeepSeek primary, DeepInfra failover

`GET https://api.deepseek.com/models` returns `deepseek-flash` with
`input_modalities: ["text","image"]` — i.e. the same model is usable for the
VLM slot, which is why `HINDSIGHT_API_VLM_*` points at it rather than at a
separate vision model.

Failover uses Hindsight's documented multi-LLM strategy:
`HINDSIGHT_API_LLM_STRATEGY={"mode": "failover"}` plus an indexed member
`HINDSIGHT_API_LLM_1_*` — `provider=openai` with DeepInfra's
OpenAI-compatible base URL (`https://api.deepinfra.com/v1/openai`) and model
`deepseek-ai/DeepSeek-V4.1-Flash-1017`, which `GET /v1/models` confirms exists.

## 4. Embeddings, first pass: BAAI/bge-m3 (1024-dim) — superseded by section 11

*Kept as history: this is why the schema was moved off the 384-dim default.
Section 11 replaced BGE-M3 with Qwen3-Embedding-0.6B and removed the local
service entirely.*

Hindsight's default local embedder is `bge-small-en-v1.5` (384 dims) which is
English-centric — wrong tool for Vietnamese memory content. BGE-M3 is
multilingual and long-context (8192 tokens).

Two facts mattered:

1. The baseline schema hardcodes `vector(384)` in the initial migration, but
   the app **resizes** the column to the provider's dimension at startup
   (`hindsight_api/migrations.py: ensure_embedding_dimension`) — if the table is
   empty it `ALTER TABLE ... TYPE vector(N)`; if it has data at a different
   dimension it refuses to start. On a fresh database 1024 is therefore fine;
   switching later is a re-index, not a config flip.
2. DeepInfra serves `BAAI/bge-m3` over the OpenAI-compatible
   `/v1/openai/embeddings` route; a live call returned `dim=1024`. So the
   default backend is `HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai` with DeepInfra's
   base URL.

Because the local vLLM server runs the **same weights**, moving between DeepInfra
and local does not change the embedding space — no re-embedding required.

## 5. Reranker: Cohere rerank-v3.5 on OpenRouter (DeepInfra has no rerank API)

DeepInfra **does** host `Qwen/Qwen3-Reranker-0.6B`, but not behind a
Cohere/TEI-compatible rerank route: `POST /v1/rerank` is 404, and the model lives
on the generic inference API instead. The exact contract (confirmed with live
calls) is:

```
POST https://api.deepinfra.com/v1/inference/Qwen/Qwen3-Reranker-0.6B
Authorization: Bearer <deepinfra key>
Content-Type: application/json
{"queries": ["xin chao"], "documents": ["hello world", "goodbye", "xin chao ban"]}

<- {"scores": [0.0017, 0.0714, 0.9974], "inference_status": {...}}
```

Note it must be a JSON body with real arrays: the same fields sent as
multipart form data are parsed as single strings and yield one meaningless score.

Hindsight's `cohere` provider speaks `{"model","query","documents"}` ->
`{"results":[{"index","relevance_score"}]}`, so the two are bridged by
`adapters/deepinfra-rerank/adapter.py` (stdlib only, mounted into
`python:3.12-slim`, nothing built). Verified end to end:
`rerank | cohere | Qwen/Qwen3-Reranker-0.6B | success` in `llm_requests`, and
the adapter logged `docs=2 top=0.9997 took_ms=1045 cost=$0.0000024`.

The earlier OpenRouter `cohere/rerank-v3.5` route also works (HTTP 200,
`results[].relevance_score`) and remains the fallback if the adapter is dropped.

A local reranker was evaluated and dropped: vLLM 0.31 exposes `/classify` for
Qwen3-Reranker, not a Cohere/TEI `/rerank`, so Hindsight has nothing to call
(section 9). Nothing is hosted locally today.

## 6. Decision model: Jev 1.14 through OpenRouter's System One API

Hindsight's decision-model providers (`hindsight_api/config.py`) are
`hindsight`, `typesafe`, `cloudflare`, `openai`. The `typesafe` provider posts
System One bodies to `<base_url>/v1/systemone`.

OpenRouter publishes a System One API for Jev: the TypeSafe SDK base URL is
`https://openrouter.ai/api` (the SDK appends `/v1/systemone`), model id
`typesafe/jev-1.14`. A live call to
`https://openrouter.ai/api/v1/systemone` with
`{"model":"typesafe/jev-1.14","state":...,"questions":{...}}` returned
`{"answers":{"greeting":{"type":"noul","noul":0.99}}}` — the shape
`DecisionResponse` parses.

So: `HINDSIGHT_API_DECISION_MODEL_PROVIDER=typesafe`,
`..._BASE_URL=https://openrouter.ai/api`,
`..._MODEL=typesafe/jev-1.14`. The OpenRouter API key authenticates it; no
TypeSafe account, no proxy, no fork.

## 7. BM25: native backend with the `simple` dictionary

The native backend's default dictionary is `english`, which applies English
stemming/stopwords to Vietnamese text. `simple` tokenises without stemming —
the honest option until a multilingual backend (pgroonga/vchord) is added, at
the cost of replacing the Postgres image.

## 8. Webhooks: a local sink, with the SSRF guard opened deliberately

Webhook URLs are SSRF-guarded: private/loopback destinations are refused unless
listed in `HINDSIGHT_API_WEBHOOK_ALLOWED_HOSTS`. The sink is on the compose
network, so that variable lists `webhook-sink` and the compose CIDR
(`172.16.0.0/12`). Deliveries are signed with `WEBHOOK_SECRET` (HMAC) and can be
inspected at http://localhost:8087. Replace the sink with a real receiver by
changing `HINDSIGHT_API_WEBHOOK_URL` and narrowing the allowlist.

## 9. Local embeddings verified; reranker stays remote (DeepInfra)

`bge-m3` (since removed from the compose file) was brought up on the RTX 5070 Ti:

- Blackwell works with the pinned image: `vllm/vllm-openai:v0.31.0` loads
  BGE-M3 with FlashAttention 2 on sm_120.
- `POST /v1/embeddings` returns `{\"model\":\"bge-m3\", dim = 1024}`.
- One trap cost a startup: vLLM validates the `model` field against
  `--served-model-name`. Serving it as `bge-m3` while Hindsight asked for
  `BAAI/bge-m3` produced
  `openai.NotFoundError: 404 The model 'BAAI/bge-m3' does not exist` and the API
  refused to start. `--served-model-name BAAI/bge-m3` (the id DeepInfra also
  uses) fixes it and keeps one config for both backends.

Reranker, tested and rejected for the local stack:

- `--runner pooling` alone: engine core fails to initialise (generative
  architecture, no pooler).
- `--task score`: rejected — `vllm: error: unrecognized arguments: --task score`;
  the CLI hint says to use `--runner pooling --convert classify|reward`.
- `--runner pooling --convert classify`: loads, but the HTTP surface is
  `/classify` + `/pooling` only — `/v1/rerank`, `/rerank` and `/v1/score`
  all return 404, so Hindsight has nothing to call.
- Conclusion: do not host the reranker. Serve it from DeepInfra through the
  adapter above, or use TEI (`BAAI/bge-reranker-v2-m3`) if it must run on the
  GPU. The vLLM reranker service was removed from the compose file rather than
  shipped broken.

## 10. Recall ranks with Qwen3, Jev keeps the rest

With a decision model configured, recall ranks candidates with Jev and never
calls a reranker — so enabling both would have left the requested
Qwen3-Reranker unused. `HINDSIGHT_API_RECALL_DECISION_MODEL_PROVIDER=none`
keeps the cross-encoder on the recall path (verified: `rerank | cohere |
Qwen/Qwen3-Reranker-0.6B | success`) while Jev still drives consolidation
triage and knowledge-page impact (`decision_consolidation_triage | typesafe |
typesafe/jev-1.14 | success`). Flip that variable to `typesafe` to rank recall
with Jev instead.

## 11. Embeddings moved off the GPU: Qwen3-Embedding-0.6B on DeepInfra

The local vLLM BGE-M3 service was verified working (see section 9) and then
**removed from the running deployment**, because it cost more than it bought:

| | local BGE-M3 (vLLM) | Qwen3-Embedding-0.6B (DeepInfra) |
|---|---|---|
| disk | 32.3 GB image + 3.5 GB weights | 0 |
| VRAM | 4.4 GB | 0 |
| API cold start | 60-135 s (engine + model load) | ~10 s |
| ops surface | +1 container, GPU driver dependency | +0 |
| vectors | 1024 dims | 1024 dims (schema unchanged) |

Measured on the same Vietnamese pair (one relevant, one unrelated passage):
BGE-M3 scored 0.7527 / 0.2461 (gap 0.507), Qwen3-0.6B scored 0.6984 / 0.0961
(gap 0.602). One pair proves nothing statistically, but it does show the cloud
model is not a downgrade on this content.

**The privacy argument is weak here**, which is what tipped it: retain already
sends the raw content to DeepSeek for fact extraction and recall already sends
candidates to DeepInfra for reranking. Keeping embeddings local protected
nothing that was not already leaving the machine — it only saved latency and
quota.

What the switch required (and what any future embedding change requires):

1. **Re-ingest everything.** Both models are 1024-wide, so Hindsight's
   `ensure_embedding_dimension` sees no mismatch and silently accepts the old
   vectors into the new space. The two tenant schemas were dropped and rebuilt
   by the migration on the next startup (`vector(1024)` confirmed per schema).
   The data at that point was test data: 5 documents / 7 memory units.
2. **Query instruction.** Qwen3-Embedding is trained with
   `Instruct: ...\nQuery: ` on the query side only; it is set literally in
   `docker-compose.yml` (`HINDSIGHT_API_EMBEDDINGS_QUERY_PREFIX`, a newline in
   the value, which is why it is not interpolated from `.env`). Passage prefix
   stays empty. Changing it later also invalidates vectors.
3. **Stay at 0.6B.** 1024 dims fits pgvector's HNSW limit (2000). Qwen3-Embedding-4B
   is 2560-wide and would require halfvec / pgvectorscale / vchord, i.e. a
   different Postgres image — not a config change.

Remaining trade-off, stated plainly: Hindsight's embedding provider has **no
failover chain** (LLM and reranker do). DeepInfra being unreachable stops
retain/recall. If that ever matters more than the 32 GB, the local recipe is in
`truongvinh57/bge-m3-deploy` and in this repo's history — but re-enabling it is a
re-ingest, not a config toggle, so it was removed from the compose file rather
than left as a trap.
