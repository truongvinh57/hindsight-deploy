# hindsight-deploy

Self-hosted **Hindsight** (agent memory) on Docker: full feature set, several
isolated users, every model remote. Clone it on any machine with Docker, fill in
`.env`, run one smoke test.

- Hindsight **1.2.0**, upstream images, **nothing is built here**
- Users: **hermes-agent** (primary, and the control-plane's data-plane key) and
  **cherry-studio** (MCP), one bearer key and one PostgreSQL schema each
  (`user_hermes_agent`, `user_cherry_studio`)
- LLM: DeepInfra `deepseek-ai/DeepSeek-V4.1-Flash-1017`, also the vision slot
  (DeepSeek's own API was dropped after repeated 500/503 and SSL hangs)
- Embeddings: `Qwen/Qwen3-Embedding-0.6B` on DeepInfra (1024-dim)
- Reranker: `Qwen/Qwen3-Reranker-0.6B` on DeepInfra, through `rerank-adapter`
- Decision model (Jev 1.14, via OpenRouter): **on by default** — it does the jobs
  only a decision model can; ranking stays on the reranker (§5)
- **No GPU, no local model, no build step.**

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
            │ webhook (signed)
     ┌──────▼────────┐
     │ webhook-sink  │  JSON echo, inspect at :8087
     └───────────────┘
```

External calls: DeepSeek (LLM + vision), DeepInfra (LLM failover, embeddings,
reranker via `rerank-adapter`), OpenRouter (Jev, the decision model).

**Why nothing is built:** the multi-user tenant extension is not published to
PyPI, but the server imports extensions from `PYTHONPATH`. The package is
vendored under `extensions/` and mounted at `/app/extensions` — same effect as
upstream's derived Dockerfile, without maintaining a derived image. The reranker
adapter is a stdlib script mounted into a stock `python:3.12-slim`.

---

## 2. Prerequisites and sizing

| | |
|---|---|
| Docker Engine / Desktop + Compose v2 | tested on Docker 29.9 / Compose 5.6 |
| **Recommended host** | 4 vCPU, **8 GB RAM**, 10 GB disk |
| **Minimum** | 2 vCPU, **4 GB RAM** with the "tiny" overrides in `.env.example`, single user, light traffic |
| Disk | 3.4 GB images + ~0.1 GB database at rest; traces/audit grow with use |
| GPU | **not used** |

Every container is capped, so the stack cannot eat the host:

| service | memory cap | cpus |
|---|---|---|
| api | 1 GB | 1.5 |
| worker | 768 MB | 1.0 |
| db | 768 MB | 1.0 |
| control-plane | 192 MB | 0.5 |
| rerank-adapter | 96 MB | 0.25 |
| webhook-sink | 64 MB | 0.1 |
| **total** | **~2.9 GB** | **4.35** |

Idle usage is far lower (~0.9 GB total measured). Raise the caps per machine in
`.env` (`API_MEM_LIMIT`, `WORKER_MEM_LIMIT`, …).

> **Windows/Docker Desktop:** the VM gets roughly half of host RAM by default, so
> an 8 GB host gives the containers ~4 GB. Set `memory=4GB` (or more) in
> `%UserProfile%\.wslconfig` and restart Docker before going below an 8 GB host.

---

## 3. Quickstart

```bash
git clone https://github.com/truongvinh57/hindsight-deploy.git && cd hindsight-deploy
cp .env.example .env          # then fill in the required secrets
docker compose up -d
./scripts/smoke-test.sh       # Windows: .\scripts\smoke-test.ps1
```

If a required variable is missing, compose names it in the error. If it is still
a template placeholder, the smoke test refuses to run rather than certify a
stack that will 401 on its first model call.

| Endpoint | URL |
|---|---|
| API | http://localhost:8888 |
| API docs | http://localhost:8888/docs |
| Control Plane (admin UI) | http://localhost:9999 |
| Webhook sink (JSON echo) | http://localhost:8087 |
| MCP | http://localhost:8888/mcp/{bank_id}/ |

All three published ports bind **127.0.0.1** by default: the API speaks plain
HTTP with bearer keys, so exposing it is a deliberate decision. For agents on
other hosts put TLS in front, or set `BIND_ADDR=0.0.0.0` in `.env`.

Health:

```bash
curl -fsS http://localhost:8888/health
# the runtime image has no curl; probe the worker over its own python:
docker compose exec worker /app/api/.venv/bin/python -c \
  "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8889/health', timeout=8).status==200 else 1)"
```

---

## 4. Users, keys and isolation

Each request carries one user's bearer key; the tenant extension resolves it to
a PostgreSQL schema:

| User | Schema | Key variable |
|---|---|---|
| `hermes-agent` | `user_hermes_agent` | `HERMES_API_KEY` |
| `cherry-studio` | `user_cherry_studio` | `CHERRY_STUDIO_API_KEY` |

```bash
curl -H "Authorization: Bearer $HERMES_API_KEY" http://localhost:8888/v1/default/banks
curl -H "Authorization: Bearer $CHERRY_STUDIO_API_KEY" http://localhost:8888/v1/default/banks
```

Unknown or missing keys return `401`. A user never sees another user's schema —
graphs, documents, mental models and audit rows are all per schema.

**Add a user:** append `name:key` to `HINDSIGHT_API_TENANT_USERS` in
`docker-compose.yml`, then bring the **api up first** (it migrates tenant
schemas at boot) and only then the worker:

```bash
docker compose up -d api
docker compose run --rm api hindsight-admin run-db-migration   # optional: pre-provision
docker compose up -d worker
```

Restarting only the worker would leave it polling a schema that does not exist yet
(it swallows that error and looks idle). Keys are read at process start, so both
services must restart after a key change.

User ids are case-insensitive (dashes become underscores); keys must be ASCII and
must not contain commas.

**Admin UI** is bound to the `hermes-agent` key, so it shows that schema only. The
Control Plane has one data-plane identity by design; per-user UIs would mean one
CP container per user.

---

## 5. Configuration

Non-secret configuration lives in `docker-compose.yml` (the `x-hindsight-env`
anchor is shared by api and worker); secrets and per-machine overrides live in
`.env`.

### Models

| Purpose | Config | Value |
|---|---|---|
| LLM primary | `HINDSIGHT_API_LLM_PROVIDER/_MODEL` | `deepseek` / `deepseek-flash` |
| LLM failover | `HINDSIGHT_API_LLM_1_*` + `LLM_STRATEGY` | `openai` provider at DeepInfra, `{"mode":"failover"}` |
| Vision | `HINDSIGHT_API_VLM_*` | `deepseek` / `deepseek-flash` (text+image) |
| Embeddings | `HINDSIGHT_API_EMBEDDINGS_OPENAI_*` | `Qwen/Qwen3-Embedding-0.6B`, 1024 dims, query instruction |
| Reranker | `HINDSIGHT_API_RERANKER_COHERE_*` -> adapter | `Qwen/Qwen3-Reranker-0.6B` |
| Decision model (Jev) | `HINDSIGHT_API_DECISION_MODEL_*` | `typesafe`, base `https://openrouter.ai/api`, model `typesafe/jev-1.14`; key = `OPENROUTER_API_KEY` (required) |

Jev is not a chat model: Hindsight's `typesafe` provider posts System One bodies
to `<base>/v1/systemone`, and OpenRouter serves exactly that at
`https://openrouter.ai/api/v1/systemone`, so the base URL is
`https://openrouter.ai/api`. No adapter is involved.

**The split is by capability, not by preference.**

- *A reranker and Jev can both do it* — scoring how well a candidate answers the
  query, i.e. ranking a recall pool — the **reranker** does it.
- *Only a decision model can* — consolidation triage (does this new fact
  restate, extend, contradict or merely chatter about an observation),
  knowledge-page impact and delta gating, reflect's evidence-sufficiency check —
  **Jev is on by default**. Those switches fall back to a plain LLM path when no
  decision model exists, so leaving Jev off silently loses capability that
  nobody would remember to re-enable.

On recall the two are mutually exclusive: a recall decision model *replaces* the
cross-encoder (`engine/search/reranking.py`), it does not run after it. So
`HINDSIGHT_API_RECALL_DECISION_MODEL_PROVIDER: none` is what "prefer the
reranker on the overlap" means concretely. One consequence worth knowing: the
two Jev-only recall extras, `recall_decision_model_prune` and `_dedup`, ship
coupled to Jev-as-the-ranker in 1.1.0, so they cannot be layered on top of
Qwen3 — they are off along with recall's decision model.

**What it costs:** OpenRouter joins the consolidation, reflect and knowledge-page
paths — never recall — and a two-fact consolidation spends ~5 triage calls
(~5 170 tokens, ~4.5 s). That is the price of holding the
triage and page-gating capability on, and it is paid deliberately — the
measurements, the alternative and the one-line flip are in
`docs/decisions.md` §13.

**Recall is ranked by the Qwen3-Reranker**, with
`HINDSIGHT_API_RECALL_PREFER_OBSERVATIONS=true`: a raw fact collapses into the
observation that superseded it, so a stale decision shows once, labelled as
rejected. Ranking recall with Jev instead measures slightly better on superseded
decisions (it puts the current rule at #1 and demotes the rejected one to #8)
but worse on junk separation, costs ~2.8x per recall, and makes OpenRouter a hard
dependency of reads.

### Features enabled

Observations + auto-consolidation, decision model (Jev) for consolidation triage,
knowledge-page impact and reflect evidence sufficiency, mental models / knowledge
pages, MCP server, audit log (90 days), LLM request tracing (7 days, 8 000 chars
per side), native file storage, native BM25 with the `simple` dictionary (no
English stemming on Vietnamese memory text), signed webhooks for
`retain.completed` and `consolidation.completed`, metrics backlog.

Off on purpose: batch retain (needs a batch-capable provider), memory defense
(per-bank opt-in), OTEL export (no collector), Oracle backend, local models.

### Webhooks and the SSRF guard

The global webhook points at `webhook-sink`. Tenant-supplied webhook URLs are
validated against `HINDSIGHT_API_WEBHOOK_ALLOWED_HOSTS`, which lists **only** the
sink hostname. Do not widen it to a CIDR: that would let any tenant key reach the
whole compose network (API, admin UI, database) and read the response back through
the delivery history.

---

## 6. Operations

```bash
docker compose ps
docker compose logs -f api worker
docker compose restart api worker control-plane
```

### Backup / restore

```bash
# ${POSTGRES_USER}/${POSTGRES_DB} come from .env; adjust if you changed them.
docker compose exec -T db pg_dump -U "${POSTGRES_USER:-hindsight}" -d "${POSTGRES_DB:-hindsight}" -Fc > backup-$(date +%F).dump

docker compose down -v
docker compose up -d db
docker compose exec -T db pg_restore -U "${POSTGRES_USER:-hindsight}" -d "${POSTGRES_DB:-hindsight}" --clean --if-exists < backup-2026-11-02.dump
docker compose up -d
```

### Upgrade

1. Change `HINDSIGHT_IMAGE` / `HINDSIGHT_CP_IMAGE` in `.env`.
2. `docker compose pull`
3. `docker compose up -d` — migrations run automatically on API start.
4. Re-sync `extensions/` from the same upstream release tag (the extension is
   vendored, not fetched): the server loads it by path.
5. `./scripts/smoke-test.sh`

Pin tags; `:latest` is used nowhere.

### Rotate a user key

Change the key in `.env`, then restart **api, worker and control-plane** — the CP
sends `HERMES_API_KEY` as its data-plane token and reads it at process start.

### Inspect a tenant's schema

```bash
docker compose exec db psql -U "${POSTGRES_USER:-hindsight}" -d "${POSTGRES_DB:-hindsight}" -c '\dn'
docker compose exec db psql -U "${POSTGRES_USER:-hindsight}" -d "${POSTGRES_DB:-hindsight}" \
  -c 'set search_path=user_hermes_agent; select bank_id, count(*) from documents group by 1;'
```

---

## 7. Verification

```bash
./scripts/smoke-test.sh        # Linux / macOS / WSL / Git Bash
.\scripts\smoke-test.ps1       # Windows PowerShell 5.1+
```

Checks: API health, 401 on a bad key, per-user isolation (retain as hermes-agent,
recall as cherry-studio → nothing), the tenant schemas in Postgres, worker
health, that the **decision model (Jev) is configured** for the write path while
**recall still ranks with the reranker**, control-plane reachability (follows its
307 to `/login`), webhook sink. The bash script skips the database/worker/model
checks with a clear message when the docker CLI is not usable in that shell (e.g.
a WSL distro without Docker Desktop integration).

### Verified on the first deployment

Windows 11 + Docker Desktop, Docker 29.9 / Compose 5.6.

| Check | Evidence |
|---|---|
| Isolation | retain as hermes-agent is invisible to cherry-studio (404 on the other tenant's bank); `\dn` lists both schemas |
| Model calls | `llm_requests`: `retain | openai | deepseek-ai/DeepSeek-V4.1-Flash-1017`, `retain | openai | Qwen/Qwen3-Embedding-0.6B`, `consolidation | typesafe | typesafe/jev-1.14` (Jev triage), `consolidation | openai | deepseek-ai/DeepSeek-V4.1-Flash-1017`, `recall | cohere | Qwen/Qwen3-Reranker-0.6B` — all `success` |
| Embedding width | `vector_dims(embedding)` -> `1024` in both tenant schemas |
| Consolidation | worker log: `[CONSOLIDATION] bank=smoke ... tenant: user_hermes_agent` |
| Webhooks | sink received signed `retain.completed` and `consolidation.completed` POSTs (HMAC verified), HTTP 200 |
| Credential masking | worker logs `Database connected: postgresql://***:***@db:5432/hindsight` |
| Resource caps | `docker inspect`: api 1 GB / 1.5 cpu, worker+db 768 MB, cp 192 MB, adapter 96 MB, sink 64 MB |
| Adapter hardening | 200 on a valid rerank; 413 for >512 docs; 400 for a path-traversal model id; 400 for invalid JSON; 404 drained |
| Smoke tests | PowerShell and bash both green |

---

## 8. Security notes

- **Secrets**: only in `.env` (gitignored, `.env*` covered). Nothing is committed.
- **Ports**: loopback by default. `BIND_ADDR=0.0.0.0` is an explicit opt-in;
  the API/CP have no TLS of their own.
- **Control Plane access key is a tenant credential** — it authenticates to the
  API as `hermes-agent`.
- **Webhook allowlist** is hostname-only by design (see §5).
- **Logs**: the worker's startup line carries the database URL upstream; the
  `worker-entrypoint` wrapper masks credentials before they reach the log driver,
  and forwards SIGTERM so tasks are still handed back on shutdown.
- **Stored content**: LLM tracing keeps prompts/responses (8 000 chars, 7 days)
  and the audit log keeps 90 days of mutating calls. Both are per-tenant schema.
- **Caps**: see §2 — a runaway container fails alone instead of taking the VM.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `required variable X is missing a value` | no `.env` — `cp .env.example .env`, fill it |
| Smoke test says "template placeholders" | `.env` still has `change-me`/`sk-your-…` values |
| `api` unhealthy after 3 min | check `docker compose logs api`; first start runs migrations for every tenant |
| `db` marked unhealthy on first boot | raise `start_period` on the db healthcheck (initdb on a slow disk); the 60s default covers most |
| `FATAL: sorry, too many clients already` | lower `DB_POOL_MAX_SIZE`/`WORKER_DB_POOL_MAX_SIZE` (api+worker pools must stay under the db's `max_connections=60`) |
| `401` with a correct-looking key | key contains a comma or non-ASCII, or `api`/`worker` were not both restarted |
| Recall returns nothing for a user | that user's schema has no data yet; recall is per schema, per bank |
| Recall quality suddenly bad after a model change | vectors from two embedding models are mixed in one index; Hindsight does not warn when the width matches. Wipe the tenant schemas and re-ingest. |
| Webhook deliveries missing | the sink is private: keep `HINDSIGHT_API_WEBHOOK_ALLOWED_HOSTS` covering it, and check `HINDSIGHT_API_WEBHOOK_EVENT_TYPES` |
| Model calls time out on a proxied network | set `HTTP_PROXY`/`HTTPS_PROXY` in `.env`; `NO_PROXY` already keeps compose service names direct. Image pulls need the Docker daemon's own proxy config. |
| Reranker 5xx | `docker compose logs rerank-adapter` reproduces the DeepInfra error body; 401/402 there means the key or balance |
| SELinux host: API cannot import the extension | add `:z` to the `./extensions:/app/extensions:ro` mount (Fedora/RHEL) |

---

## 10. Repo layout

```
hindsight-deploy/
├── docker-compose.yml          # the stack: all non-secret config, caps, tuning
├── .env.example                # every variable, with a "tiny host" override set
├── extensions/                 # vendored static-keys tenant extension (MIT)
├── adapters/deepinfra-rerank/  # Cohere /rerank -> DeepInfra translation (stdlib)
├── scripts/
│   ├── smoke-test.sh|ps1       # verification, both platforms
│   ├── mint-keys.sh|ps1        # generate the bearer keys/secrets
│   └── worker-entrypoint.py    # PID 1 for the worker: masking + signal forwarding
├── docs/decisions.md           # why each choice was made, with evidence
└── LICENSE                     # MIT
```
