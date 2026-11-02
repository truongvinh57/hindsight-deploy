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

## 4. Embeddings: BAAI/bge-m3 (1024-dim), not the default 384-dim model

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

`GET https://api.deepinfra.com/v1/models` lists `BAAI/bge-m3`,
`Qwen/Qwen3-Embedding-*`, but **no reranker**: `POST /v1/rerank` answers 404 and
the generic `/v1/inference/Qwen/Qwen3-Reranker-0.6B` rejects the request
("input is not json"). There is no DeepInfra rerank route Hindsight could speak.

OpenRouter does serve rerank models. `POST https://openrouter.ai/api/v1/rerank`
with `cohere/rerank-v3.5` returned HTTP 200 with
`results[].relevance_score` — the Cohere wire format Hindsight's `openrouter`
reranker provider expects (its default base URL and default model are exactly
those values).

A local Qwen3-Reranker remains available as a profile (`local-rerank`), served
by vLLM and wired through Hindsight's Cohere-compatible provider; see
`bge-m3/README.md`.

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

## 9. Local embeddings verified; local reranker rejected on evidence

`bge-m3` (profile `local-embed`) was brought up on the RTX 5070 Ti:

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
- Conclusion: keep OpenRouter `cohere/rerank-v3.5` (verified 200) or add a TEI
  container with a native `/rerank`. The vLLM reranker service was removed from
  the compose file rather than shipped broken.
