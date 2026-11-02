# hindsight-deploy

Self-hosted **Hindsight** (agent memory) on Docker: full feature set, multiple
isolated users, cloud + local model backends. One `docker compose up -d` per
machine, configuration in git, secrets in a gitignored `.env`.

- Hindsight version: **1.1.0** (upstream images, nothing is built here)
- Users: **hermes-agent** (primary) and **deepseek-harness**, each with its own
  bearer key and its own PostgreSQL schema (`user_hermes_agent`,
  `user_deepseek_harness`) — memory isolation at the database level.
- LLM: **DeepSeek `deepseek-flash`** primary, **DeepInfra
  `deepseek-ai/DeepSeek-V4.1-Flash-1017`** automatic failover.
- Embeddings: **`Qwen/Qwen3-Embedding-0.6B`** on DeepInfra (1024-dim, query-side
  instruction). No GPU is involved in the memory path.
- Reranker: **`Qwen/Qwen3-Reranker-0.6B`** on DeepInfra, through a small
  stdlib `rerank-adapter` that translates Cohere `/rerank` to DeepInfra's
  inference API (no model hosted, no image built).
- Decision model: **Jev 1.14** (`typesafe/jev-1.14`) through OpenRouter's
  System One API.

---

## 1. Architecture

```
        agents / apps                         browser
   (Bearer key per user)                        │
            │                                   ▼
            │                        ┌────────────────────┐
            │                        │ control-plane :9999│  admin UI
            │                        │ access key + 1 key │  (hermes-agent)
            │                        └─────────┬──────────┘
            ▼                                  │
     ┌─────────────┐   enqueue tasks   ┌───────▼────────┐
     │  api :8888  │◀─────────────────▶│  PostgreSQL 18 │
     │  FastAPI    │                   │  + pgvector    │
     └──────┬──────┘                   │  public schema │
            │                          │  user_* schemas│
            │ claim tasks              └───────┬────────┘
     ┌──────▼──────┐                           │
     │ worker      │───────────────────────────┘
     │ consolidation, mental models
     └──────┬──────┘
            │ webhook
     ┌──────▼────────┐
     │ webhook-sink  │  JSON echo, inspect deliveries at :8087
     └───────────────┘
```

External calls: DeepSeek (LLM + vision), DeepInfra (LLM failover + embeddings),
DeepInfra (reranker via `rerank-adapter`), OpenRouter (Jev decision model).

**Why nothing is built locally:** the multi-user tenant extension
(`hindsight-extensions/static-keys-tenant`) is not published to PyPI, but the
server imports extensions from `PYTHONPATH`. We vendor the package under
`extensions/` and mount it at `/app/extensions` — same effect as the upstream
Dockerfile, without maintaining a derived image.

---

## 2. Prerequisites

- Docker Engine / Docker Desktop with Compose v2 (tested: Docker 29.9, Compose 5.6)
- ~2 GB RAM for the stack (slim image, external model providers)
- Optional: NVIDIA GPU + Container Toolkit for the local backends
  (tested: RTX 5070 Ti 16 GB, driver 616.92)

---

## 3. Quickstart

```bash
cp .env.example .env      # then fill in keys
docker compose up -d db
docker compose up -d api  # first start runs migrations, then waits for /health
docker compose up -d worker control-plane webhook-sink
```

Or simply:

```bash
docker compose up -d
docker compose ps
```

> No GPU and no local model is required: embeddings come from DeepInfra. The
> whole stack starts with a plain `docker compose up -d` on any machine.

| Endpoint | URL |
|---|---|
| API | http://localhost:8888 |
| API docs | http://localhost:8888/docs |
| Control Plane (admin UI) | http://localhost:9999 |
| Webhook sink (JSON echo) | http://localhost:8087 |
| MCP | http://localhost:8888/mcp/{bank_id}/ |

Health:

```bash
curl -fsS http://localhost:8888/health
docker compose exec worker curl -fsS http://localhost:8889/health
```

---

## 4. Users, keys and isolation

Every request carries a user's bearer key. The tenant extension resolves it to a
Postgres schema:

| User | Schema | Key variable |
|---|---|---|
| `hermes-agent` | `user_hermes_agent` | `HERMES_API_KEY` |
| `deepseek-harness` | `user_deepseek_harness` | `DEEPSEEK_HARNESS_API_KEY` |

```bash
# hermes-agent
curl -H "Authorization: Bearer $HERMES_API_KEY" http://localhost:8888/v1/default/banks

# deepseek-harness
curl -H "Authorization: Bearer $DEEPSEEK_HARNESS_API_KEY" http://localhost:8888/v1/default/banks
```

Unknown or missing keys return `401`. A user never sees another user's schema:
graphs, documents, mental models and audit rows are all per-schema.

**Add a user:** append `name:key` to `HINDSIGHT_API_TENANT_USERS` in
`docker-compose.yml`, then `docker compose up -d api worker` (both must be
restarted — the worker enumerates tenants to consolidate). Optionally
pre-provision the schema:

```bash
docker compose run --rm api hindsight-admin run-db-migration
```

Rules for user ids and keys: ids are case-insensitive, dashes become
underscores; keys must be ASCII and must not contain commas.

**Admin UI** is bound to the `hermes-agent` key (`HINDSIGHT_CP_DATAPLANE_API_KEY`),
so it shows that user's schema only. The Control Plane has one data-plane
identity by design; per-user UIs would mean one CP container per user.

---

## 5. Configuration

Everything non-secret is in `docker-compose.yml` under the `x-hindsight-env`
anchor (shared by API and worker). Secrets and per-machine overrides are in
`.env`.

### Models

| Purpose | Config | Value |
|---|---|---|
| LLM primary | `HINDSIGHT_API_LLM_PROVIDER/_MODEL` | `deepseek` / `deepseek-flash` |
| LLM failover | `HINDSIGHT_API_LLM_1_*` + `LLM_STRATEGY` | `openai` provider pointed at DeepInfra, `{"mode":"failover"}` |
| Vision | `HINDSIGHT_API_VLM_*` | `deepseek` / `deepseek-flash` (text+image) |
| Embeddings | `HINDSIGHT_API_EMBEDDINGS_OPENAI_*` | `Qwen/Qwen3-Embedding-0.6B`, 1024 dims, query instruction |
| Reranker | `HINDSIGHT_API_RERANKER_COHERE_*` -> `rerank-adapter` | `Qwen/Qwen3-Reranker-0.6B` (DeepInfra) |
| Decision model | `HINDSIGHT_API_DECISION_MODEL_*` | `typesafe` provider, base `https://openrouter.ai/api`, model `typesafe/jev-1.14` |

The decision model is the subtle one: Jev is not a chat model. Hindsight's
`typesafe` provider posts System One bodies to `<base>/v1/systemone`, and
OpenRouter serves exactly that at `https://openrouter.ai/api/v1/systemone` —
so the base URL is `https://openrouter.ai/api` and the model id is
`typesafe/jev-1.14`. No adapter is involved.

### Features enabled

Observations + auto-consolidation, mental models / knowledge pages, MCP server,
audit log (90 days), LLM request tracing (14 days), native file storage,
native BM25 with the `simple` dictionary (no English stemming — correct for
Vietnamese), webhooks (signed, delivered to `webhook-sink`), metrics backlog.

Disabled on purpose: batch retain (needs a batch-capable provider), memory
defense (opt-in per bank, configure when needed), OTEL export (no collector
here), Oracle backend.

---

## 6. Operations

```bash
docker compose ps
docker compose logs -f api worker
docker compose restart api worker
```

### Backup / restore

```bash
# backup (all schemas incl. every tenant)
docker compose exec -T db pg_dump -U hindsight -d hindsight -Fc > backup-$(date +%F).dump

# restore into a fresh stack
docker compose down -v
docker compose up -d db
docker compose exec -T db pg_restore -U hindsight -d hindsight --clean --if-exists < backup-2026-11-02.dump
docker compose up -d
```

### Upgrade

1. Change `HINDSIGHT_IMAGE` / the control-plane tag in `docker-compose.yml`.
2. `docker compose pull`
3. `docker compose up -d` — migrations run automatically on API start.

Pin tags; `:latest` is not used anywhere.

### Rotate a user key

Change the key in `.env`, restart `api` and `worker`. Old key stops working
immediately; data stays in the same schema.

### Inspect a tenant's schema

```bash
docker compose exec db psql -U hindsight -d hindsight -c '\dn'
docker compose exec db psql -U hindsight -d hindsight -c 'set search_path=user_hermes_agent; select bank_id, count(*) from documents group by 1;'
```

---

## 7. Verification

```bash
./scripts/smoke-test.sh        # or scripts/smoke-test.ps1 on Windows
```

It checks: API health, 401 on a bad key, per-user schema isolation (retain as
hermes-agent, recall as deepseek-harness → nothing), tenant schemas exist in
Postgres, worker health, control-plane reachable, webhook sink reachable.

### Verified on the first deployment (2026-11-02)

Windows 11 + Docker Desktop, RTX 5070 Ti 16 GB, Docker 29.9 / Compose 5.6.

| Check | Evidence |
|---|---|
| Stack healthy | `db`, `api`, `worker`, `control-plane`, `webhook-sink` all `Up (healthy)` |
| Schema isolation | `\dn` lists `user_hermes_agent` + `user_deepseek_harness`; retain as one user is invisible to the other (404 on the other tenant's bank) |
| Embeddings 1024-dim | `select vector_dims(embedding) ...` -> `1024` |
| Model calls | `llm_requests`: `embedding_* | openai | Qwen/Qwen3-Embedding-0.6B`, `retain_extract_facts | deepseek | deepseek-flash`, `rerank | cohere | Qwen/Qwen3-Reranker-0.6B`, `decision_consolidation_triage | typesafe | typesafe/jev-1.14` - all `success` |
| Consolidation | worker log: `[CONSOLIDATION] bank=smoke ... tenant: user_hermes_agent` |
| Audit log | 9 rows: `retain`, `recall`, `consolidation`, `webhook_delivery` |
| Webhooks | sink received signed `POST /hindsight` with `x-hindsight-signature` + `consolidation.completed` body, 200 OK |
| Smoke test | `scripts/smoke-test.ps1` -> all checks passed |
| Embedding swap | wiped both tenant schemas (old bge-m3 vectors), started from DeepInfra Qwen3: `vector(1024)` recreated, smoke test green, API healthy in ~10s |
| Footprint after the swap | images 35.7 GB -> **3.39 GB**, volumes 3.6 GB -> **73 MB**, VRAM freed |
| Failover model | DeepInfra `deepseek-ai/DeepSeek-V4.1-Flash-1017` answered `pong` over `/v1/openai/chat/completions` |
| Reranker | recall trace: `rerank | cohere | Qwen/Qwen3-Reranker-0.6B | success`; adapter log `docs=2 top=0.9997 took_ms=1045 cost=$0.0000024` |

---

## 8. No local models in this repo

Embeddings and reranking are both remote, so the stack runs on any machine with
Docker and **no GPU**:

| Stage | Where it runs |
|---|---|
| Embeddings | `Qwen/Qwen3-Embedding-0.6B` on DeepInfra |
| Reranking | `Qwen/Qwen3-Reranker-0.6B` on DeepInfra, via `rerank-adapter` |
| LLM | `deepseek-flash` on DeepSeek, failover to DeepInfra |

Hosting BGE-M3 locally was tried and removed on purpose: it cost a 32 GB image,
a 3.5 GB weight volume, 4.4 GB VRAM and a 60-135 s cold start, and it protected
nothing that was not already leaving the machine (retain sends content to
DeepSeek, recall sends candidates to DeepInfra). The recipe still lives in
`truongvinh57/bge-m3-deploy` and in this repo's git history if you ever want it
back — but note it is **not** a drop-in swap: BGE-M3 and Qwen3-Embedding are
different vector spaces at the same 1024 width, so Hindsight would not notice
and every memory would need re-ingesting.

**Reranker is remote too** — DeepInfra's Qwen3-Reranker-0.6B, reached through
`rerank-adapter`: — it is DeepInfra's Qwen3-Reranker-0.6B,
reached through `rerank-adapter`:

```
Hindsight --(Cohere /rerank)--> rerank-adapter --(DeepInfra inference API)--> Qwen3-Reranker-0.6B
```

DeepInfra's contract is `POST /v1/inference/<model>` with
`{"queries": [...], "documents": [...]}` and a flat `{"scores": [...]}` reply —
not the Cohere shape Hindsight sends. The adapter is ~150 lines of Python
standard library, mounted into a stock `python:3.12-slim` container: nothing to
build, no model weights, stateless. Health at `GET /health`, one log line per
rerank with document count, top score, latency and DeepInfra cost.

To move reranking back to OpenRouter, set
`HINDSIGHT_API_RERANKER_PROVIDER=openrouter` plus the
`HINDSIGHT_API_RERANKER_OPENROUTER_*` variables instead; to do it on a local GPU,
use TEI with `BAAI/bge-reranker-v2-m3` (native `/rerank`) and
`HINDSIGHT_API_RERANKER_PROVIDER=tei`.

The adapter lives in `adapters/deepinfra-rerank/`.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `api` restarts every ~5 min | `/health` failing before models/migrations finish — raise `start_period`, check `docker compose logs api` |
| `401` with a correct-looking key | key contains a comma or non-ASCII, or `api`/`worker` were not both restarted |
| Everything 500 on first request | schema migration for that tenant still running (first request per user pays it) — retry after a few seconds, or pre-provision |
| Recall returns nothing for a user | that user's schema has no data yet; recall is per schema, per bank |
| Webhook deliveries missing | the sink is private: keep `HINDSIGHT_API_WEBHOOK_ALLOWED_HOSTS` covering it, and check `HINDSIGHT_API_WEBHOOK_EVENT_TYPES` |
| Reranker 5xx | check `docker compose logs rerank-adapter`: it reproduces the DeepInfra error body, and 402/401 there means the DeepInfra key or balance |
| Recall quality suddenly bad after a model change | vectors from two embedding models are mixed in one index; Hindsight does not warn when the width matches. Wipe the tenant schemas and re-ingest. |

---

## 10. Repo layout

```
hindsight-deploy/
├── docker-compose.yml        # the stack, all non-secret config
├── .env                      # secrets (gitignored)
├── .env.example              # template
├── extensions/               # vendored static-keys tenant extension (MIT)
├── adapters/deepinfra-rerank/ # Cohere /rerank -> DeepInfra translation (stdlib)
├── scripts/                  # smoke tests, key minting
└── docs/decisions.md         # why each choice was made, with evidence
```
