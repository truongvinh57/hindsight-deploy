# Local GPU BGE-M3 (optional — NOT used by the default stack)

> The deployment embeds with **Qwen3-Embedding-0.6B on DeepInfra**; nothing here
> runs by default. This recipe is kept as the offline fallback and as the record
> of how the model was served. Switching to it (or away from it) requires
> re-ingesting every memory: BGE-M3 and Qwen3 are different vector spaces at the
> same 1024 width, so Hindsight will not detect the change.

Adapted from [`truongvinh57/bge-m3-deploy`](https://github.com/truongvinh57/bge-m3-deploy),
reduced from "2 vLLM instances + HAProxy, one GPU each" to **one vLLM instance per
model on a single GPU**, and changed so the embedding endpoint is the
**OpenAI-compatible `/v1/embeddings`** route Hindsight speaks.

## What changed vs upstream

| Upstream | Here | Why |
|---|---|---|
| 2× `vllm serve` (one per GPU) + HAProxy LB | 1 instance per model, no LB | this machine has one GPU (RTX 5070 Ti, 16 GB) |
| `--io-processor-plugin bge_m3_sparse_plugin` (custom `/pooling` task, `/v1/embeddings` = 501) | plugin removed → plain pooling model exposing `/v1/embeddings` | Hindsight's embeddings provider is OpenAI-compatible; it cannot call `/pooling` |
| `--gpu-memory-utilization 0.20` (sharing the card with MinerU) | 0.30 each, tuned for a card with no other tenant | no MinerU here |
| ports bound to 127.0.0.1 | bound to the compose network only | Hindsight reaches it by service name |

## Services

### `bge-m3` — embeddings (profile `local-embed`)

```yaml
image: vllm/vllm-openai:v0.31.0   # pinned like upstream
command: >
  vllm serve BAAI/bge-m3
  --runner pooling
  --served-model-name bge-m3
  --dtype bfloat16
  --max-model-len 8192
  --gpu-memory-utilization 0.30
  --max-num-seqs 32
```

Hindsight then talks to `http://bge-m3:8000/v1/embeddings` with
`HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai`, model `bge-m3`, 1024 dimensions —
the same weights DeepInfra serves, so the vector space (and therefore existing
memories) is unchanged when you switch backends.

### Reranker: not served by this stack (finding)

vLLM 0.31 will load Qwen3-Reranker — `--runner pooling --convert classify`
(plain `--runner pooling` fails to initialise, and `--task score` is rejected
outright) — but the server it exposes has **no Cohere-compatible rerank route**:

```
GET /openapi.json -> /classify, /pooling, /v1/models, /health, ...   (no /v1/rerank)
POST /v1/rerank   -> 404
POST /rerank      -> 404
POST /v1/score    -> 404
```

Hindsight's reranker providers speak either the Cohere `/rerank` wire format or
TEI's, so a Qwen3-Reranker behind this vLLM build cannot be wired without a
translation adapter. The default deployment therefore uses the **OpenRouter
reranker** (`cohere/rerank-v3.5`, verified 200 with `results[].relevance_score`).

If you want the reranker on-premises anyway, the supported route is TEI:

```bash
docker run --gpus all -p 8080:80 -v $PWD/data:/data --pull always \
  ghcr.io/huggingface/text-embeddings-inference:1.8 \
  --model-id BAAI/bge-reranker-v2-m3
```

then `HINDSIGHT_API_RERANKER_PROVIDER=tei` and
`HINDSIGHT_API_RERANKER_TEI_URL=http://your-host:8080`.

Note that with the decision model enabled, recall ranks candidates with **Jev**,
not with a cross-encoder at all — so the reranker only matters for operations
that do not use a decision model.

## GPU / driver notes

- The card is Blackwell (sm_120): it needs a vLLM/PyTorch build compiled for
  CUDA 12.8+. The pinned `vllm/vllm-openai:v0.31.0` is new enough; older pins
  fail with "no kernel image is available for execution on the device".
- `docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi`
  must print the card before anything else is worth trying.
- Weights are cached in the `hf-cache` volume (~2.3 GB for BGE-M3, ~1.5 GB for
  the reranker), so restarts do not re-download them.

## Disk / bandwidth

The vLLM image is ~10 GB. Neither profile is part of the default stack: the
default stack uses DeepInfra for embeddings and OpenRouter for reranking, and is
fully functional without a GPU.
