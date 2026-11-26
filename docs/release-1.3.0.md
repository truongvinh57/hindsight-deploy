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

## 2. Quyết định: knowledge banks tắt có chủ đích

`HINDSIGHT_API_ENABLE_KB: "false"` trong `docker-compose.yml`.

Lý do:

1. Đây là kho **bộ nhớ**, không phải kho tài liệu. Tài liệu RAG của công ty nằm ở Open WebUI; bật thêm một kho tài liệu thứ hai là nhân đôi chỗ lưu và chỗ cấu hình.
2. Image `slim` không kèm embedder cục bộ (không `torch`, không `sentence-transformers`), trong khi embedder mặc định của knowledge bank là `google/embeddinggemma-2` chạy local (~1,5 GB). Bật cờ mà không đổi embedder thì mọi lần tải tệp lên sẽ **lỗi**, không phải suy giảm.
3. Bật mặc định sẽ đổi bề mặt dịch vụ (endpoint mới, worker ingest mới, tab mới trên control-plane) mà không ai yêu cầu. Tắt và ghi lại ở đây minh bạch hơn là để mặc định tự đổi.

Muốn bật: đặt `true` và trỏ knowledge bank sang embedder từ xa
(`HINDSIGHT_API_KB_EMBEDDINGS_PROVIDER=openai` + `_BASE_URL`/`_MODEL`/`_API_KEY`).

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
- [ ] Nếu muốn dùng knowledge banks: chọn embedder từ xa trước khi bật cờ.
