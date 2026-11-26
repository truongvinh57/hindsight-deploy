# Nâng cấp Hindsight 1.2.0 → 1.3.0

**Ngày:** 26/11/2026 · **Môi trường:** `~/hindsight-deploy` (máy IT06, Docker Desktop)
**Nguồn rà soát:** tag `v1.3.0`, commit `a0ea5f9` (24/11/2026), clone `~/workspace/hindsight-1.3.0`
**Kết luận:** đã nâng cấp, chạy production, kiểm chứng đủ đường đọc – ghi – hợp nhất – webhook.

---

## 1. Đọc source: 1.3.0 khác 1.2.0 ở đâu

Đối chiếu bằng `git diff v1.2.0 v1.3.0` trên chính source, không dựa vào release notes.

| Hạng mục | 1.2.0 | 1.3.0 | Ảnh hưởng tới stack này |
|---|---|---|---|
| Biến môi trường API | 543 tên | 603 tên | **60 thêm, 0 bỏ** — không có biến nào bị đổi tên, cấu hình cũ giữ nguyên nghĩa |
| Knowledge banks | có cờ, mặc định tắt | **bật mặc định** (`DEFAULT_ENABLE_KB=True`) | phải quyết định: xem mục 2 |
| Extension đa người dùng | `extensions/tenant.py`, `base.py` | **giống hệt từng dòng** | `StaticKeysTenantExtension` đang mount chạy nguyên, không phải sửa |
| System One (Jev) | `<base_url>/v1/systemone` | không đổi | vẫn đi qua LiteLLM `aigateway.newtecons.vn` như cũ |
| Trọng số recency | hard-code `0.2` | biến `HINDSIGHT_API_RECENCY_ALPHA`, mặc định `0.2` | hành vi xếp hạng y nguyên |
| Trần ứng viên rerank theo ngân sách | `_LOW=0` → kế thừa 300 | như cũ | mức `100` đang đặt vẫn có hiệu lực |
| Migration Alembic | 116 revision | 122 revision (**6 mới**) | tự chạy khi API khởi động (`RUN_MIGRATIONS_ON_STARTUP=true`) |
| Control-plane | — | biến môi trường **không đổi** | chỉ thay tag image |
| Thời gian drain khi tắt worker | 30 s | 20 s (`HINDSIGHT_API_WORKER_SHUTDOWN_DRAIN_SECONDS`) | `stop_grace_period: 75s` vẫn dư |

Sửa lỗi đáng kể với đúng workload này (đọc từ changelog rồi đối chiếu code):

- `#6742` chia slot LLM công bằng giữa tenant, bank và tài liệu — có lợi khi một tenant chạy nhiều bank.
- `#6733` retain không giữ connection pool trong lúc chấm entity — bớt nghẽn pool khi retain nhiều.
- `#6810` thử lại probe embeddings OpenAI khi gặp 429 lúc khởi động — đúng đường DeepInfra đang dùng.
- `#6825` migration giữ `search_path` cho schema extension — liên quan trực tiếp các schema `user_*`.
- `#6812` mental model giữ structured output khi một lượt refresh lỗi.

## 2. Knowledge banks: bật, chỉ văn bản

Ban đầu đặt `HINDSIGHT_API_ENABLE_KB: "false"` (kho này là kho bộ nhớ). Sau đó bật theo yêu cầu, với
cấu hình tối thiểu chạy được trên image `slim`:

| Biến | Giá trị | Vì sao |
|---|---|---|
| `HINDSIGHT_API_ENABLE_KB` | `true` | mở endpoint `/v1/default/knowledge-banks` và tab trên control-plane |
| `HINDSIGHT_API_KB_EMBEDDINGS_PROVIDER` | `text` | dùng lại embedder của bộ nhớ (Qwen3-Embedding-0.6B trên DeepInfra, 1024 chiều). Mặc định upstream là `local` (EmbeddingGemma 2) cần `torch`, image `slim` không có |
| `HINDSIGHT_API_KB_DISABLED_MEDIA_TYPES` | `image,audio,video` | embedder chỉ nhận văn bản; ảnh/audio/video bị từ chối ngay (HTTP 415) thay vì lỗi giữa lúc ingest |
| `HINDSIGHT_API_KB_RERANKER_URL` / `_MODEL` / `_API_KEY` | LiteLLM `/v1/rerank`, Qwen3-Reranker | dùng chung reranker với recall; không đặt thì KB vẫn tìm được nhưng bỏ qua rerank |
| `HINDSIGHT_API_KB_RERANKER_IMAGES` | `false` | **bắt buộc**: PDF sinh thêm một ảnh mỗi trang, reranker gửi ảnh đó cho DeepInfra và bị 422 (`Input should be a valid string`), search trả 503. Tắt ảnh thì chỉ văn bản vào rerank |
| `HINDSIGHT_API_KB_MAX_FILE_MB` | `100` | hạ từ 500 để một tệp lớn không ăn hết 1 GB của api |

Định dạng đọc được: văn bản/markdown, PDF, Office (docx/pptx/xlsx/xls) — chuyển bằng `markitdown` có
sẵn trong image. Ảnh, audio, video: không.

## 3. Quy trình đã chạy

1. Dump toàn bộ DB trước khi đổi tag: `preimage/20261126-130711/hindsight-db-before-1.3.0.sql.gz` (355 MB, có `CREATE SCHEMA user_hermes_agent`, `user_cherry_studio`).
2. Clone source tag `v1.3.0` và fetch thêm `v1.2.0` để diff.
3. Sửa `docker-compose.yml`: image `1.3.0-slim` (api, worker), control-plane `1.3.0`, thêm khối knowledge banks tắt.
4. `docker compose config -q` → hợp lệ; `docker compose up -d`.
5. API chạy migration 6 revision rồi lên healthy; worker nhận 2 schema, `pending=0`.

## 4. Bằng chứng sau nâng cấp

| Hạng mục | Số đo | Cách đo |
|---|---|---|
| Phiên bản | api/worker `hindsight:1.3.0-slim`, CP `1.3.0` | `docker compose ps` |
| Migration | `kbtok1a2b3c4` (head của 1.3.0) | `select version_num from public.alembic_version` |
| Dữ liệu bộ nhớ | 62.343 memory_unit, **62.343 có vector** (không mất embedding) | `count(*), count(embedding)` |
| Chiều vector | 1024 ở cả ba schema | `pg_attribute.atttypmod` |
| Recall (5 truy vấn thật, budget low) | min 2,13 s · trung vị 3,48 s · max 4,00 s; 21–32 ký ức/lượt | client `hindsight_client.arecall` |
| Ghi (retain) | 6,8 s, `success=true` | client `aretain` vào bank `hermes` |
| Hợp nhất | `consolidation=completed`, 7 lượt gọi LLM thành công | `async_operations`, `llm_requests` |
| Webhook | 2 lượt `webhook_delivery=completed` | `async_operations` |
| Lỗi LLM sau nâng cấp | **0** (53 lỗi trong 24 h đều thuộc 25/11 07:29–09:44 UTC, trước khi nâng) | `llm_requests where status='error'` |
| Control-plane | `/` trả 307 → `/login` 200 | `curl` |

Kiểm chứng knowledge banks (bank thử `kb-kiem-thu`, đã xoá sau khi đo):

| Hạng mục | Số đo | Cách đo |
|---|---|---|
| Tạo bank | 0,17 s, HTTP 200 | `POST /v1/default/knowledge-banks` |
| Ingest văn bản | 0,86 s, 1 passage, `status=ready` | `POST /{bank}/ingest` |
| Ingest PDF (11 trang) | 202 → operation `knowledge_ingest` completed, `status=ready`, 5 passage | `POST /{bank}/files/ingest`, đọc `/{bank}/operations` |
| Search | 0,76–1,56 s, 3 hit; `rerank` 418–1 046 ms, `embed` 314–766 ms, `store.search` 5–6 ms | `POST /{bank}/search` với `trace: true` |
| Ảnh bị từ chối | HTTP 415 `"'x.png' is image, which this server does not ingest"` | `POST /{bank}/files/ingest` |
| Dọn dẹp | `DELETE /{bank}` → 200, danh sách bank rỗng | `GET /v1/default/knowledge-banks` |

## 5. Rollback

Ảnh `1.2.0-slim` và CP `1.2.0` vẫn còn trên máy, nhưng **chỉ đổi tag là không đủ**: schema đã ở revision `kbtok1a2b3c4`, bản 1.2.0 không có revision đó nên Alembic sẽ dừng ở bước đọc lịch sử.

```bash
# 1) trả image cũ
#    sửa docker-compose.yml: 1.3.0-slim -> 1.2.0-slim ; 1.3.0 -> 1.2.0
docker compose up -d

# 2) nếu API không lên được vì revision lạ: khôi phục dump
gunzip -c preimage/20261126-130711/hindsight-db-before-1.3.0.sql.gz |   docker exec -i hindsight-db-1 psql -U hindsight -d hindsight
```
Khôi phục dump sẽ **mất mọi ký ức ghi sau 13:07 ngày 26/11**.

## 6. Việc còn lại

- [ ] Đưa `preimage/` vào lịch backup (dump 355 MB đang chỉ nằm trên PC).
- [ ] Theo dõi 24 h: `async_operations` lỗi, độ trễ recall, RSS của api/worker.
- [ ] Knowledge banks mới chỉ nhận văn bản/tài liệu. Muốn ảnh, audio, video: dựng image có `local-ml`
      (torch + PyAV) hoặc trỏ `HINDSIGHT_API_KB_EMBEDDINGS_PROVIDER=openai` vào một embedder đa phương
      thức từ xa, rồi bỏ các mục tương ứng khỏi `HINDSIGHT_API_KB_DISABLED_MEDIA_TYPES`.
- [ ] Muốn `reflect` trích dẫn tài liệu: liên kết knowledge bank với bank bộ nhớ (linked knowledge
      banks) — chưa cấu hình, chưa kiểm chứng.
