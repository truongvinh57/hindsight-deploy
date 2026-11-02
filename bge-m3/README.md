# Local GPU backends (optional)

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
| ports bound to 127.0.0.1 | bound to the compose network only | Hindsight reaches them by service name |

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

### `reranker` — Qwen3-Reranker-0.6B (profile `local-rerank`)

```yaml
command: >
  vllm serve Qwen/Qwen3-Reranker-0.6B
  --runner pooling
  --served-model-name qwen3-reranker
  --dtype bfloat16
  --gpu-memory-utilization 0.10
  --max-model-len 8192
```

Hindsight reaches it with `HINDSIGHT_API_RERANKER_PROVIDER=cohere` and
`HINDSIGHT_API_RERANKER_COHERE_BASE_URL=http://reranker:8000/v1/rerank`, which
speaks the Cohere wire format.

> **Verify before relying on it.** Whether a given vLLM build serves
> Qwen3-Reranker through `/v1/rerank` depends on its pooling/score support. The
> check is one command:
> `curl -s -X POST http://localhost:8201/v1/rerank -H 'Content-Type: application/json'
>  -d '{"model":"qwen3-reranker","query":"xin chào","documents":["hello","goodbye"]}'`
> A 200 with `results[].relevance_score` means it works. If it does not, keep the
> OpenRouter reranker (default) or switch to TEI with
> `BAAI/bge-reranker-v2-m3`.

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
