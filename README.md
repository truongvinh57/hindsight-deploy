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
- Embeddings: **BAAI/bge-m3** (1024-dim) — DeepInfra by default, local vLLM on
  the GPU when the `local-embed` profile is on. Same weights either way, so
  switching backends does not require re-indexing.
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

> **On a machine that uses the local embedder** (this one does — `.env` has
> `EMBEDDINGS_BASE_URL=http://bge-m3:8000/v1`), always bring the stack up with
> the profile, or the API starts without an embedding backend:
>
> ```bash
> docker compose --profile local-embed up -d
> ```
>
> Machines without a GPU leave those two lines out of `.env` and use
> `docker compose up -d`.

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
| Embeddings | `HINDSIGHT_API_EMBEDDINGS_OPENAI_*` | `BAAI/bge-m3`, 1024 dims |
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
| Model calls | `llm_requests`: `embedding_* | openai | BAAI/bge-m3`, `retain_extract_facts | deepseek | deepseek-flash`, `decision_recall_rerank | typesafe | typesafe/jev-1.14`, `decision_consolidation_triage | typesafe | typesafe/jev-1.14` - all `success` |
| Consolidation | worker log: `[CONSOLIDATION] bank=smoke ... tenant: user_hermes_agent` |
| Audit log | 9 rows: `retain`, `recall`, `consolidation`, `webhook_delivery` |
| Webhooks | sink received signed `POST /hindsight` with `x-hindsight-signature` + `consolidation.completed` body, 200 OK |
| Smoke test | `scripts/smoke-test.ps1` -> all checks passed |
| Local embeddings | `bge-m3` profile: vLLM returned `dim = 1024`, `model = bge-m3`; vLLM saw 4 `POST /v1/embeddings` per retain+recall |
| Failover model | DeepInfra `deepseek-ai/DeepSeek-V4.1-Flash-1017` answered `pong` over `/v1/openai/chat/completions` |
| Reranker | recall trace: `rerank | cohere | Qwen/Qwen3-Reranker-0.6B | success`; adapter log `docs=2 top=0.9997 took_ms=1045 cost=$0.0000024` |

---

## 8. Local GPU backends (optional)

```bash
# local BGE-M3 embeddings (vLLM, OpenAI-compatible /v1/embeddings)
docker compose --profile local-embed up -d bge-m3
# then in .env:
#   EMBEDDINGS_BASE_URL=http://bge-m3:8000/v1
#   EMBEDDINGS_API_KEY=local
docker compose up -d api worker

# switch embeddings back to the cloud backend:
#   comment out EMBEDDINGS_BASE_URL / EMBEDDINGS_API_KEY in .env
docker compose up -d api worker
```

The `bge-m3` service is defined in `docker-compose.yml` under the `local-embed`
profile, so it is inert until you ask for it. It is **verified working** on this
machine (RTX 5070 Ti): vLLM 0.31 serves `BAAI/bge-m3` through
`/v1/embeddings` at 1024 dims, and Hindsight's traces show every embedding
call hitting it.

**Reranker is not hosted here at all** — it is DeepInfra's Qwen3-Reranker-0.6B,
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

Adapters live in `bge-m3/` (vendored from
`truongvinh57/bge-m3-deploy`, adapted from 2×GPU to 1×GPU and to expose the
OpenAI-compatible embedding route). See `bge-m3/README.md`.

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

---

## 10. Repo layout

```
hindsight-deploy/
├── docker-compose.yml        # the stack, all non-secret config
├── .env                      # secrets (gitignored)
├── .env.example              # template
├── extensions/               # vendored static-keys tenant extension (MIT)
├── adapters/deepinfra-rerank/ # Cohere /rerank -> DeepInfra translation (stdlib)
├── bge-m3/                   # local vLLM BGE-M3 embedding stack (optional)
├── scripts/                  # smoke tests, key minting
└── docs/decisions.md         # why each choice was made, with evidence
```
