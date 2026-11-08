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
`adapters/deepinfra-rerank/adapter.py` — **đã gỡ 08/11/2026**, nay dùng LiteLLM `/v1/rerank` (stdlib only, mounted into
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

With a decision model configured **for recall**, recall ranks candidates with Jev
and never calls a reranker — so enabling both would have left the requested
Qwen3-Reranker unused. `HINDSIGHT_API_RECALL_DECISION_MODEL_PROVIDER=none`
keeps the cross-encoder on the recall path (verified: `rerank | cohere |
Qwen/Qwen3-Reranker-0.6B | success`) while Jev still drives consolidation
triage and knowledge-page impact (`consolidation | typesafe |
typesafe/jev-1.14 | success`). Flip that variable to `typesafe` to rank recall
with Jev instead.

This split is the shipped default: `DECISION_MODEL_PROVIDER=typesafe` — Jev on
for every job only it can do — together with
`RECALL_DECISION_MODEL_PROVIDER=none`, so the reranker keeps the one job both
do. Section 13 has the measurements and the reasoning.

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

## 12. Findings from the three-way audit (applied, and deliberately not)

Three read-only audits ran in parallel against the live stack: compose
correctness + resource caps, fresh-machine portability, and Hindsight config /
adapter / security. Everything below was measured, not guessed.

### Applied

| Finding | Fix |
|---|---|
| **No resource caps at all** — one consolidation run could take the Docker VM, Postgres included, down (idle floor was 863 MB) | per-service `mem_limit` + `memswap_limit` + `cpus`, summing to ~2.9 GB (api 1 GB, worker/db 768 MB, cp 192 MB, adapter 96 MB, sink 64 MB). `memswap_limit == mem_limit` so a container fails alone instead of swapping the box. Caps are overridable in `.env` |
| DB pool 40 + 40 against Postgres `max_connections=100` | pools 12 (api) / 8 (worker), `max_connections=60`, plus `shared_buffers=256MB`, `work_mem=8MB`, `jit=off`, `effective_cache_size=1GB`, `max_parallel_workers_per_gather=1`, `shm_size: 256m` |
| DB healthcheck `start_period: 10s` could abort a slow first `up` | `start_period: 60s`, `retries: 30`; `stop_grace_period: 30s` so a checkpoint is not SIGKILLed |
| Ports published on `0.0.0.0` | `127.0.0.1` by default (`BIND_ADDR` to opt out). The API has no TLS of its own |
| Worker printed the Postgres password in cleartext (upstream `print()` of `DATABASE_URL`) | `scripts/worker-entrypoint.py` as PID 1: masks credentials on stdout/stderr **and** forwards SIGTERM so the 75 s graceful hand-back still works. A `| sed` pipeline would have broken shutdown |
| Webhook allowlist was `webhook-sink,172.16.0.0/12` | hostname only. The guard validates **tenant-supplied** URLs, so the CIDR let any key reach the compose network and read the reply from the delivery history |
| Reranker client timeout (60 s) outlived its purpose inside a 10 s retry budget | client 40 s, adapter 25 s, so the adapter fails first |
| Adapter had no bounds | body cap (413), 16-slot semaphore, rejects >512 documents instead of silently truncating (Hindsight pre-fills missing scores with 0.0), model-id regex against path traversal, drains unread bodies, 400 on bad JSON, one retry on 429/5xx. Runs non-root, read-only rootfs, `no-new-privileges` |
| `retain.completed` was not subscribed; `memory_defense.triggered` can never fire (policy disabled by default) | `retain.completed,consolidation.completed` |
| `mint-keys.ps1` used `RandomNumberGenerator::Fill`, absent on Windows PowerShell 5.1 — emitted zero keys | `Create()` + `GetBytes()`; works on 5.1 and 7 |
| `smoke-test.sh` could not pass on a healthy stack (POSTed to a route 1.1.0 does not expose, shelled out to a `curl` the image lacks, expected 200 from a 307) | rewritten; both scripts now read `POSTGRES_USER/POSTGRES_DB` from `.env`, refuse template placeholders, follow the CP redirect, skip docker-only checks with a clear message |
| `scripts/*.sh` were mode 100644 | executable in the git index |
| `POSTGRES_USER/POSTGRES_DB` were undocumented while every command hardcoded `hindsight` | documented, and every command now uses them |
| Control-plane tag was a literal | `HINDSIGHT_CP_IMAGE` |
| Fixed project name made two checkouts share one database | `COMPOSE_PROJECT_NAME` |
| No proxy support | `HTTP(S)_PROXY`/`NO_PROXY` passthrough with the compose service names exempt |
| Worker re-ran the whole migration chain | `RUN_MIGRATIONS_ON_STARTUP=false` on the worker |
| Trace storage: 50 000 chars x 14 days | 8 000 chars x 7 days (still the largest table on a busy bank) |
| Log rotation implicit | `x-logging` anchor (`local`, 20 MB x 3) per service |
| Docs drift: `bge-m3` URL in `.env.example`, "OpenRouter reranker", duplicated paragraphs, `curl` worker health | README and `.env.example` rewritten; root `LICENSE` added |

### Deliberately not done

- **Pinning every image by digest.** `HINDSIGHT_IMAGE`/`HINDSIGHT_CP_IMAGE` are
  already version-pinned and overridable; the remaining tags (`pgvector:pg18`,
  `python:3.12-slim`, `http-https-echo:35`) keep readable tags so a patch
  upgrade is one pull. A digest lock file is a reasonable next step, not a fix.
- **Mounting `pgdata` at the parent directory to avoid one 0-byte anonymous
  volume.** Moving it now would relocate live PGDATA; the orphan volume is inert
  and `docker volume prune` cannot touch the named one.
- **Dropping `webhook-sink`.** It is how webhook delivery is verified; it is now
  loopback-only, capped, rotated, and health-checked.
- **A reranker failover chain** (`HINDSIGHT_API_RERANKER_1_*`). Recall already
  degrades to RRF order deterministically; adding a second paid provider for the
  rare failure was not worth the config surface. Revisit if rerank 5xx shows up.
- **Knowledge-page BM25 language.** `simple` reaches `memory_units` only;
  knowledge pages are indexed with the english config in upstream migrations and
  SQL. Not fixable from env — documented as an upstream gap; the vector arm
  covers pages.
- **Lowering trace retention further.** 7 days is the compromise between
  debugging and "prompts stored twice".

### Worth measuring later

All six observed rerank calls returned `top=0.9974…1.0000` — Qwen3-Reranker's
yes-probability saturates on short facts. That is fine for ordering, but do not
set `min_scores.rerank` thresholds from these numbers without measuring on a
larger candidate set.

## 13. Jev vs the reranker: the overlap goes to the reranker, the rest stays on Jev

The question was whether recall should rank with the decision model (Jev, asked
"would showing this memory help rather than distract?") or with the cross-encoder
(Qwen3-Reranker). Both were measured on the same inputs, not argued about.

### Synthetic pool, 30 candidates, query "làm sao để backup database hindsight?"

| candidate | Qwen3 rank | Jev rank |
|---|---|---|
| "pg_dump -Fc để sao lưu…" | 1 | 1 |
| "backup nên kiểm tra bằng restore thử" | 6 | **2** |
| "pg_dump nén -Fc" | 4 | 4 |
| **"KHÔNG cần backup vì dữ liệu tái tạo được"** | **2** (0.9823) | **15** (0.21) |
| "mỗi user có schema riêng" (topical noise) | 10 | **3** |
| "user thích trả lời ngắn gọn" (junk) | **21** | 10 |

Qwen3 separates junk more sharply (0.9997 down to 7e-06) but scores a negated,
superseded fact at 0.98. Jev drops the negation to rank 15 and lifts the
"verify your backups" fact to rank 2, at the cost of letting topical noise into
the top 10 — the pool-relative calibration the upstream comments warn about.

Cost and latency, 30 candidates: Qwen3 1 195 ms / \$0.0000278 per recall, Jev
763 ms / \$0.0000767 (~2.8x). At 300 candidates Jev is ~\$0.0008 per recall.
Also: Jev returns **rank positions**, so `min_scores.reranker` is rejected (400)
for that provider; Qwen3 returns calibrated scores where a floor is possible.

### Real bank, same recall before/after the switch

Seeded six items into a scratch bank, including a superseded decision ("không cần
backup database vì dữ liệu có thể tái tạo từ log"), then recalled "có cần backup
database không?" with each ranker:

| rank | Qwen3-Reranker | Jev |
|---|---|---|
| 1 | superseded "không cần backup" fact | **the rule: back up daily with pg_dump** |
| 2 | the "was rejected" observation | the same rule (chunk) |
| 3 | the rule: back up daily with pg_dump | the "was rejected" observation |
| 4 | the rule (chunk) | restore procedure |
| 8 | restore procedure | superseded "không cần backup" fact |

On that axis Jev wins: in a memory bank the reader needs the current rule first,
and the superseded decision is context, not the answer. Jev put the answer at #1
and the stale decision at #8; Qwen3 did the opposite. Latency on the real recall
was 1 119 ms (Jev) against 1 100 ms (Qwen3). The reranker nevertheless keeps the
job, for the reasons below.

### Outcome: the overlap goes to the reranker

Ranking a recall pool is the one job both can do, and on balance the reranker
wins it: Qwen3 separates junk far more sharply, returns calibrated scores (so a
`min_scores.reranker` floor is possible; Jev returns rank positions and the
floor is rejected with 400), costs ~2.8x less per recall, and keeps recall
independent of OpenRouter:

| | reranker on recall | Jev on recall |
|---|---|---|
| providers recall depends on | DeepInfra (already mandatory for embeddings) | DeepInfra **and** OpenRouter |
| OpenRouter outage | recall unaffected; reflect and page refreshes degrade gracefully | **recall fails** |
| DeepInfra outage | recall fails either way (embeddings) | recall fails either way |
| cost per recall (30 candidates) | \$0.0000278 | \$0.0000767 |

Jev's edge on recall (demoting a superseded decision) is recovered more cheaply by
`HINDSIGHT_API_RECALL_PREFER_OBSERVATIONS=true`: when an
observation is returned, the raw facts it was consolidated from are dropped, so
the stale decision appears once, as its observation, and that observation says it
was rejected. Measured on the same bank and query:

| rank | Qwen3, prefer_observations off | Qwen3, prefer_observations on | Jev |
|---|---|---|---|
| 1 | stale "không cần backup" fact | "quyết định cũ ... **đã bị bác bỏ**" (observation) | the current rule |
| 2 | "was rejected" observation | the current rule | the current rule (chunk) |
| 3 | the current rule | restore procedure | "was rejected" observation |
| 8 | restore procedure | — | stale "không cần backup" fact |

With `prefer_observations` on, the rejected decision is either second and
labelled or first and labelled — never an unqualified stale claim. The cost is
detail: preferring observations trades granular fact text for the consolidated
summary (per-request `prefer_observations` still overrides the default).

So recall ranking stays on Qwen3:
`HINDSIGHT_API_RECALL_DECISION_MODEL_PROVIDER=none`.

### What that does *not* say: Jev stays on for the jobs only it can do

The reranker wins the overlap and nothing else. It scores (query, document)
relevance; it cannot answer a typed question about a memory, and those questions
have no other implementation:

| Jev-only job | What it decides | Enable flag (default in **bold**) |
|---|---|---|
| Consolidation triage | restatement, extension, contradiction or chatter between a new fact and an existing observation, settled before the consolidation LLM is called | `HINDSIGHT_API_CONSOLIDATION_USE_DECISION_MODEL` = **true** |
| Knowledge-page impact | which new memories could change an existing page (delta refresh), instead of running a full reflect | `HINDSIGHT_API_MENTAL_MODEL_DELTA_USE_DECISION_MODEL` = **true** |
| Knowledge-page refresh | whether a page rebuild has enough evidence | `HINDSIGHT_API_MENTAL_MODEL_REFRESH_USE_DECISION_MODEL` = **true** |
| Reflect | which evidence to prune, and when there is enough to answer | `HINDSIGHT_API_REFLECT_USE_DECISION_MODEL` = **true** |

All four default to true upstream; this compose file states them explicitly.
Turning Jev off does not move any of it to the reranker — each switch silently
falls back to a plain LLM path, so the capability is absent with no error and no
reminder. That is why the default here is
`HINDSIGHT_API_DECISION_MODEL_PROVIDER=typesafe` with `OPENROUTER_API_KEY`
required, not `none`.

One coupling is unavoidable: `recall_decision_model_prune` and
`recall_decision_model_dedup` (drop pool members Jev judges unhelpful, merge
near-duplicates) are Jev-only too, but 1.1.0 wires them to Jev *as the recall
ranker* — `engine/search/reranking.py` replaces the cross-encoder with the
decision reranker, it does not run one after the other. They therefore cannot be
layered on top of Qwen3; enabling them means handing recall's ranking to Jev, i.e.
reversing the section above. Left off, and recorded so the omission is a decision.

Two traps for whoever turns them on: `PATCH /v1/default/banks/{bank}/config`
**rejects** both names as unknown fields in 1.1.0 — they are served from
`HINDSIGHT_API_RECALL_DECISION_MODEL_PRUNE/_DEDUP`, or per request as
`{"prune": true, "dedup": true}` — and they cost real time, because every pool
member gets a decision question. Measured on the same four-candidate bank:
reranker 1 108 ms, Jev 1 707 ms, Jev + prune/dedup 4 072 ms, and the prune did not
drop anything (Jev judged the junk candidate helpful). Ranking with Jev also put
that junk at #2, where the reranker keeps it last.

### The price: triage overhead at small batch sizes, accepted

Same bank content, same two retains, consolidated once with Jev on and once off:

| | Jev ON | Jev OFF |
|---|---|---|
| `consolidation`, provider `typesafe` (the triage calls) | 5 calls, 5 170 tokens, 913 ms avg | — |
| `consolidation` (LLM) | 2 calls, 9 485 tokens | 2 calls, 9 716 tokens |
| total model calls | 7 | **2** |
| consolidation wall time | ~4.5 s of triage on top | 2.4 s |

At two new facts per consolidation Jev adds five triage calls and saves no LLM
call: upstream's "~40 % fewer LLM calls at the same pass rate" is measured on sets
with far larger consolidation batches, where triage settles most facts without an
LLM call. The cost is kept anyway, deliberately:

- It is the only path to the four capabilities above. Off means all four vanish
  into a fallback nobody will notice is being taken, and no one will remember to
  flip a flag later.
- The overhead scales with facts per consolidation — and so does the saving, so the
  balance inverts if this deployment ever ingests documents rather than chat turns.
- The blast radius is contained: recall never calls Jev. An OpenRouter outage
  degrades consolidation triage, reflect and page refreshes — reflect handles it
  (`decision_model_failed`) — but memory reads are untouched, because recall
  ranks with the reranker. Conversely, recall fails if DeepInfra does
  (embeddings), whichever ranker is configured — DeepInfra is not optional either
  way.

To reverse it anyway: `DECISION_MODEL_PROVIDER=none`, and relax the required-key
guard in `docker-compose.yml` too (`${OPENROUTER_API_KEY:?...}` →
`${OPENROUTER_API_KEY:-}`). The second edit is not optional: compose
interpolates the whole file at parse time, so an empty key aborts `up` even when
no operation would use it. Nothing else changes — the Qwen3-Reranker already owns
recall.

### If the reranker were dropped entirely (measured)

The counterfactual — Jev as the only ranker, `RECALL_DECISION_MODEL_PROVIDER=typesafe`
— was measured on this same stack, with one bank, one query, four candidates. The
bank held a superseded decision, the rule that replaced it, a restore-test fact,
and two irrelevant candidates (one topical, one pure noise).

| | Qwen3 reranker | Jev only | Jev + prune/dedup |
|---|---|---|---|
| recall wall clock (warm) | **1 108 ms** | 1 707 ms | 4 072 ms |
| ranker tokens per recall | — | 815–1 630 | 2 445 |
| rank of the pure-noise candidate | **4th (last)** | 2nd | 2nd (prune did not drop it) |
| rank of the restore-test rule | 2nd | 3rd | 3rd |
| `min_scores.reranker` floor | works (calibrated scores) | rejected, 400 | rejected, 400 |
| read-path providers | DeepInfra (already required for embeddings) | + OpenRouter | + OpenRouter |
| `rerank-adapter` container | needed (96 MB) | removable | removable |

Jev-only buys exactly two things: `prune`/`dedup` become reachable, and one
container plus one proxy route disappear. On this workload it costs 1.5x the
latency, a token bill on every read, the score floor, and — the part that matters —
junk separation: the noise candidate moves from last to second, which is the same
failure the 30-candidate pool showed earlier (Qwen3 rank 21 against Jev rank 10).
Prune did not compensate here: Jev judged the noise candidate *helpful*, so nothing
was dropped and only the bill grew.

Verdict: the reranker keeps the read path. Jev-only is worth revisiting only if
prune/dedup ever matter more than junk separation and read-path independence —
and then it is one env var, plus deleting the adapter service and its
`HINDSIGHT_API_RERANKER_*` block so nothing sits unused.
