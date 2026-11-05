# Rà soát Hindsight trước khi tích hợp vào Hermes — 05/11/2026

> **Cập nhật cuối ngày 05/11 (đã thực hiện):**
> - Nâng Hindsight **1.1.0 → 1.2.0** (api/worker `1.2.0-slim`, CP `1.2.0`); migration chạy
>   thành công, dữ liệu cũ còn nguyên (hermes bank 1, cherry doc 1). Dump rollback một lần:
>   `~/NTC-Backups/hindsight/20261105/pre-1.2.0-full.dump`.
> - Bỏ tenant `deepseek-harness` (backup + restore thử trước khi drop), CP thấy bank `hermes`.
> - Xóa repo `hermes-deploy` (local và GitHub) — patch `dashboard-select-none` không còn;
>   nó vốn không áp trên v0.22.7 và không cần cho Hindsight.
> - Gỡ plugin OpenViking khỏi Hermes: `memory.openviking` đã unset, 4 biến `OPENVIKING_*`
>   của plugin đã xóa (giữ `OPENVIKING_ADMIN_KEY`), plugin dir đã remove.
> - Cài plugin **hindsight 1.2.3**, `memory.provider=hindsight`, bank `hermes`, cấu hình theo
>   mục 8.1. Đã nghiệm thu end-to-end bằng một lượt CLI: 2 document → 3 memory unit
>   (2 world + 1 observation), metadata `source=hermes`, `observation_scopes=shared`;
>   sau đó xóa 2 document test, bank về 0.
> - **Không triển khai backup/monitoring** theo yêu cầu (chạy local trên máy này); chỉ giữ
>   dump một lần trước nâng cấp.
> - Cherry Studio MCP **không chỉnh**; lưu ý API restart làm session MCP cũ mất hiệu lực —
>   mở lại Cherry Studio khi cần.
> - Lưu ý môi trường: `hermes plugins install` sync dependency vào PM env mới
>   (`afec28…`), nhưng gateway đang chạy dùng env cũ (`7258…`). Đã cài
>   `hindsight-client`/`hindsight-embed` 0.10.3 vào cả hai PM env và venv 3.11 để mọi
>   đường chạy đều có module. Nếu phiên desktop vẫn báo thiếu module, khởi động lại Hermes
>   một lần.

Phạm vi: stack `~/hindsight-deploy` (Hindsight 1.1.0 lúc rà soát, nay 1.2.0), tenant
`hermes-agent` và `cherry-studio`, MCP của Cherry Studio, và tình trạng patch của
`~/hermes-deploy` (nay đã xóa).

## 1. Kết luận nhanh

- **Stack đang khỏe**: 6/6 container `healthy`, API trả `/health` 200, DB 18 MB, không có
  lỗi mới trong 48 giờ; retain/consolidation/recall đều có bản ghi `success`.
- **Đã bỏ tenant `deepseek-harness`**: xóa khỏi compose + `.env`, drop schema sau khi
  `pg_dump` và **đã phục hồi thử thành công** (347 memory unit, 142 observation, 2 bank).
- **Control Plane giờ thấy `hermes`**: CP dùng đúng `HERMES_API_KEY`; đã tạo bank `hermes`
  nên `/api/banks` trả về bank này (trước đó tenant hermes rỗng nên UI hiện "No banks").
- **Cherry Studio MCP chạy đúng ở phía server**: đã thử `initialize → tools/list →
  sync_retain → recall` trên một bank tạm, trả về đúng fact vừa ghi (reranker 0.9997).
  Bank `cherry-studio` thật hiện có 1 tài liệu nhưng **0 memory unit** — MCP mới được
  kiểm chứng kỹ thuật, chưa có dữ liệu thực tế.
- **Patch Hermes hiện KHÔNG áp**: source `v0.22.7` đang ở code gốc (3/3 hunk chưa áp).
  `apply.py --check` cũ báo sai "ĐÃ ÁP"; đã sửa để báo `CẦN ÁP` và exit 1. Patch **không
  cần cho Hindsight** — chỉ cần nếu còn dùng OpenViking và bấm Save trong Dashboard.
- **Rủi ro lớn nhất không phải cấu hình mà là vận hành**: **không có backup** cho
  `pgdata`, **không có giám sát**, Control Plane bị throttle 47% và chạm trần RAM
  (192 MiB), webhook sink chỉ là echo tạm (không phải audit trail).

## 2. Hiện trạng đã kiểm

| Hạng mục | Kết quả | Bằng chứng |
|---|---|---|
| Container | 6/6 healthy, restart=unless-stopped | `docker compose ps` |
| Phiên bản | Hindsight `1.2.0-slim`; CP `1.2.0`; Postgres `pgvector:pg18`, extension `vector 0.8.7` | `docker ps`, `pg_extension` |
| Tenant | `hermes-agent`, `cherry-studio` | `HINDSIGHT_API_TENANT_USERS` trong container |
| Schema | `user_hermes_agent`, `user_cherry_studio` | `\dn` |
| Dữ liệu | DB 18 MB; hermes 0 bank → nay có bank `hermes` 0 fact; cherry 1 doc / 1 chunk / 0 fact | `pg_database_size`, API banks |
| LLM | DeepInfra `deepseek-ai/DeepSeek-V4.1-Flash-1017`; 425 consolidation + 110 retain, **tất cả success** trong 7 ngày | `llm_requests` |
| Độ trễ | retain trung bình 7,5 s, p95 25,4 s, max 39,6 s; consolidation p95 15,0 s | `llm_requests` |
| Rerank | `cohere | Qwen/Qwen3-Reranker-0.6B | success`; adapter khỏe | `llm_requests`, health |
| Tài nguyên | API 347 MB/1 GB, worker 292/768 MB, DB 101/768 MB | `docker stats` |
| CP | 130 MB/192 MB, **memory.peak = 192 MiB (chạm trần)**, **17.152/36.211 kỳ bị throttle (47%)** | cgroup `memory.peak`, `cpu.stat` |
| Webhook sink | **72.025/93.817 kỳ bị throttle (77%)**, 48/64 MB | cgroup `cpu.stat` |
| Bảo mật cổng | 8888/9999/8087 chỉ bind `127.0.0.1` | `docker ps` |
| Quyền file `.env` | SYSTEM + Administrators + `vinh.truong`; không có `Users` | `Get-Acl` |
| Backup | **Không có** repo restic nào cho Hindsight; `sources.json` chỉ có omniroute/openwebui/openviking/monitoring | `~/NTC-Backups/restic`, `~/backup-deploy/sources.json` |
| Giám sát | **Không có** mục Hindsight trong `monitoring-deploy` | grep |
| Phiên bản upstream | `v1.1.0` là tag mới nhất; nhánh `main` local đi trước **157 commit** (chưa release) | `git tag`, `git rev-list` |

## 3. Thay đổi đã thực hiện trong lượt này

1. **Bỏ tenant `deepseek-harness`**
   - `docker-compose.yml`: `HINDSIGHT_API_TENANT_USERS` còn `hermes-agent` + `cherry-studio`.
   - `.env`: xóa `DEEPSEEK_HARNESS_API_KEY`; `.env.example`, README, `mint-keys.*`,
     `smoke-test.*` cập nhật theo (smoke test dùng cherry làm tenant đối chứng).
   - Backup trước khi xóa: `~/NTC-Backups/hindsight/20261105/user_deepseek_harness.dump`
     (2,8 MB, 25 bảng). **Đã restore thử** vào DB tạm: 347 memory unit, 142 observation,
     2 bank — khớp dữ liệu gốc. Lưu ý khi restore schema lẻ: phải `CREATE EXTENSION vector`
     trước, vì dump `-n` không kèm extension.
   - Sau đó `DROP SCHEMA user_deepseek_harness CASCADE`; DB còn 18 MB.
2. **Tạo bank `hermes`** (tenant `hermes-agent`) với mission tiếng Việt mô tả bộ nhớ dài hạn
   của trợ lý. CP `/api/banks` trả về bank này → mở UI control plane sẽ thấy `hermes`.
3. **Sửa `apply.py --check`** của `hermes-deploy`: trước đây khi thấy anchor gốc (code chưa vá)
   nó vẫn in "ĐÃ ÁP" dù `--check` không ghi → che mất việc patch bị mất sau nâng cấp. Nay in
   `CẦN ÁP (chưa ghi)` và exit 1; `--selftest` vẫn PASS. Cập nhật README/patches README theo
   trạng thái thật (v0.22.7, chưa áp, không cần cho Hindsight).
4. **Khôi phục Docker Desktop UI**: engine và container vẫn chạy; đã restart tiến trình UI,
   các container trở lại healthy. Cửa sổ UI vẫn không có `MainWindowHandle` — app đang chạy
   nền/tray, không phải lỗi engine. Mở lại từ biểu tượng Docker ở khay hệ thống.
5. **Nâng tài nguyên Control Plane / webhook sink** (đo trước khi đổi): `CP_CPUS=1.0`,
   `CP_MEM_LIMIT=320m`, `SINK_CPUS=0.25` trong `.env`; đã recreate, cả 6 container healthy.
   Kiểm lại `docker inspect`: CP `nano_cpus=1e9`, mem 320 MiB; sink 0.25 CPU.

## 4. Rủi ro "tự nerf sức mạnh"

### 4.1 Phía server (đang bật đúng, không bị nerf)

| Thiết lập | Trạng thái | Ghi chú |
|---|---|---|
| Observations + auto consolidation | `true` | Đã sinh 142 observation từ 347 fact trong dữ liệu cũ |
| Graph + temporal + reranking | đều `true` trong bank config | Đủ 3 nhánh truy hồi |
| Decision model Jev | `true` cho consolidation/reflect/mental model | Recall vẫn dùng reranker (đúng thiết kế) |
| `recall_prefer_observations` | `true` | Giảm trùng lặp fact thô khi trả observation |
| `retain_extraction_mode` | `concise` (mặc định upstream) | Đây là **điểm có thể đổi**: `verbose` trích chi tiết hơn, tốn token hơn |
| BM25 tiếng Việt | `simple` (không stemming) | Đúng cho tiếng Việt; knowledge page vẫn dùng `english` (gap upstream) |

### 4.2 Phía plugin Hermes — **đây là nơi dễ tự nerf nhất**

Các mặc định dưới đây lấy từ `hindsight-integrations/hermes` 1.2.3 (catalog pin
`d952b6e6`), không phải từ tài liệu marketing:

| Thiết lập | Mặc định | Tác động thực tế | Đề xuất |
|---|---|---|---|
| `recall_types` | `observation` | **Bỏ toàn bộ fact thô**. Trong dữ liệu thật của bank cũ, chỉ 142/347 = **41%** là observation; 59% là `world`/`experience` → mặc định này bỏ 59% dữ liệu, và **bank mới chưa có observation thì recall rỗng** | `observation,world,experience` |
| `recall_sync` | `false` | Recall chạy nền cho **lượt sau**, không khớp câu hỏi hiện tại → độ liên quan thấp hơn | `true` nếu chấp nhận thêm độ trễ; `false` nếu ưu tiên tốc độ |
| `recall_budget` | `mid` (300 candidate) | Đủ cho bank nhỏ; bank lớn có thể bỏ sót | `mid` trước, đo rồi lên `high` (1000) |
| `recall_max_tokens` | `4096` | Ổn; bank config mặc định 2048 nhưng plugin gửi 4096 mỗi request | giữ 4096 |
| `recall_min_scores` | không đặt | Câu hỏi lạc đề vẫn nhận tối đa 4096 token "ít liên quan nhất" | `{"reranker": 0.25}` sau khi đo |
| `memory_mode` | `hybrid` | Đúng: vừa inject vừa có tool | giữ |
| `auto_recall` / `auto_retain` | `true` / `true` | Đúng cho trợ lý cá nhân | giữ |
| `observation_scopes` | `shared` | Gộp observation toàn bank, tốt cho hồi tưởng xuyên phiên | giữ |
| `bank_id` | `hermes` | Khớp bank vừa tạo | giữ; chỉ dùng `bank_id_template` nếu muốn tách theo dự án |
| `retain_cron` | `false` | Kết quả cron không vào bộ nhớ | cân nhắc `true` nếu muốn nhớ việc chạy nền |

**Kết luận 4.2:** nếu cài plugin rồi để nguyên mặc định, ta sẽ có một bộ nhớ "trông có vẻ
chạy" nhưng chỉ đọc observation, recall lệch một lượt và không lọc nhiễu — đúng kiểu
"tự nerf" đáng lo. Cần đặt `recall_types` rộng ngay từ ngày đầu.

### 4.3 Điểm mạnh nên giữ

- Reranker Qwen3 + `prefer_observations` cho recall sạch, rẻ; không kéo OpenRouter vào read path.
- Jev chỉ dùng cho việc chỉ nó làm được (triage, reflect, knowledge page) — không bật cho recall.
- Embedding Qwen3-0.6B 1024 chiều, HNSW theo từng bank/fact type — phù hợp dữ liệu tiếng Việt.
- Static-key tenant: mỗi user một schema, không có đường "admin thấy tất cả" — cách ly thật.

## 5. Rủi ro vận hành dài hạn

| Rủi ro | Mức | Bằng chứng | Xử lý đề xuất |
|---|---|---|---|
| **Không backup `pgdata`** | Cao | Không có repo restic Hindsight; DB là nguồn sự thật duy nhất | `pg_dump -Fc` toàn DB hằng ngày (18 MB) + giữ 14–30 ngày; restore thử quý/lần. Có thể dùng Task Scheduler như các job restic hiện có |
| **Không giám sát** | Cao | `monitoring-deploy` không có Hindsight | 2 HTTP check Uptime Kuma: `http://127.0.0.1:8888/health`, `http://127.0.0.1:9999/api/health`; cảnh báo khi container restart |
| **CP bị throttle 47%, RAM chạm trần 192 MiB** | Trung bình | cgroup `cpu.stat`, `memory.peak` | **Đã áp 05/11:** `CP_CPUS=1.0`, `CP_MEM_LIMIT=320m`; recreate, CP healthy |
| **Webhook sink throttle 77%** | Thấp | cgroup `cpu.stat` | **Đã áp 05/11:** `SINK_CPUS=0.25`; hoặc bỏ sink nếu không dùng |
| **Webhook không phải audit trail** | Trung bình | `mendhak/http-https-echo` chỉ echo request, không lưu lịch sử | Nếu cần sự kiện, thay bằng receiver thật (n8n/DB) hoặc đọc `async_operations`/`audit_log` |
| **MCP session chết sau mỗi lần restart API** | Trung bình | Log Cherry: `Session not found`, `retryStopped: true` | Sau restart Hindsight, mở lại Cherry Studio hoặc toggle MCP server; ghi vào runbook |
| **MCP expose tool phá hủy** | Trung bình | `tools/list` có `delete_bank`, `clear_memories`, `delete_document`… | Đặt `mcp_enabled_tools` cho bank `cherry-studio` (allowlist retain/recall/reflect/get/list), loại delete/clear |
| **Không có quy trình nâng cấp** | Trung bình | Image pin 1.1.0; migrations chạy tự động khi `up` | Trước khi đổi tag: dump DB, đọc release notes, thử trên stack tạm; rollback = image cũ + restore dump |
| **Khóa tĩnh, xoay khóa cần restart** | Thấp | `HINDSIGHT_API_TENANT_USERS` trong env | Ghi runbook: đổi key → restart api/worker/CP → cập nhật Cherry/Hermes |
| **Không TLS** | Thấp (hiện tại) | Chỉ bind loopback | Giữ loopback; nếu đưa ra LAN, thêm nginx/Caddy TLS + firewall |
| **Docker Desktop UI không mở** | Thấp | Engine 29.9.2 chạy; UI không có cửa sổ | Mở từ tray; nếu cần, `docker desktop restart` (container tự về) |

## 6. Hermes patch: có đang áp? có cần?

- Source live: `C:\Users\vinh.truong\AppData\Local\hermes\hermes-agent`, tag **v0.22.7**
  (`b200f5bc60e3`), `git status` **sạch** — không có file nào bị vá.
- 3 hunk của `dashboard-select-none` **không có** trong source; code gốc (bug) vẫn còn.
  Patch bị mất khi nâng cấp từ v0.21.7.
- `apply.py --check` cũ báo sai "ĐÃ ÁP": khi thấy anchor gốc nó tính phần thay thế rồi gắn
  nhãn "applied" dù `write=False`. **Đã sửa**: nay báo `CẦN ÁP (chưa ghi)` và exit 1;
  `--selftest` PASS.
- **Có cần cho Hindsight?** Không. Schema cấu hình Hindsight không có select `default=None`
  (`mode` mặc định `cloud`, `recall_budget` mặc định `mid`) nên lỗi `Invalid value` không
  xảy ra. Patch chỉ cần nếu còn dùng **OpenViking** và bấm Save trong Dashboard.
- **Đề xuất:** không áp bây giờ; giữ script như "regression check" đến khi ngừng OpenViking,
  sau đó xóa patch khỏi `hermes-deploy` để repo phản ánh đúng thực tế.

## 7. Cherry Studio MCP

- Cấu hình client: `http://localhost:8888/mcp/cherry-studio/`, kiểu `streamableHttp`,
  bearer key `CHERRY_STUDIO_API_KEY`.
- Phía server đã kiểm chứng end-to-end trên bank tạm `mcp-selftest`:
  `initialize` → session id → `tools/list` (33 tool) → `sync_retain` →
  `recall` trả đúng fact, `scores.reranker=0.9997`, `semantic=0.766`.
- Bank `cherry-studio` thật: 1 tài liệu 74 ký tự, 1 chunk, **0 memory unit** — retain đã
  chạy nhưng không trích được fact nào từ câu test ngắn. Không phải lỗi MCP; chỉ là chưa
  có dữ liệu thực.
- Sự cố đã thấy trong log (03/11): sau khi API restart, Cherry giữ session cũ →
  `Session not found` → `retryStopped: true`; kết nối không tự phục hồi. Cần mở lại app
  hoặc toggle server sau mỗi lần restart Hindsight.
- Khuyến nghị bảo vệ: đặt `mcp_enabled_tools` cho bank cherry (ví dụ
  `retain,sync_retain,recall,reflect,get_bank,get_memory,list_memories,list_documents,get_document,get_operation,list_operations,list_tags`)
  để LLM không gọi được `delete_bank`/`clear_memories`.

## 8. Kế hoạch tích hợp Hindsight vào Hermes

### 8.1 Cấu hình đề xuất

`~/.hermes/hindsight/config.json` (hoặc `$HERMES_HOME/hindsight/config.json`):

```json
{
  "mode": "local_external",
  "api_url": "http://127.0.0.1:8888",
  "api_key": "<HERMES_API_KEY>",
  "bank_id": "hermes",
  "recall_budget": "mid",
  "recall_types": "observation,world,experience",
  "recall_max_tokens": 4096,
  "recall_sync": true,
  "recall_min_scores": { "reranker": 0.25 },
  "memory_mode": "hybrid",
  "observation_scopes": "shared",
  "retain_source": "hermes",
  "timeout": 120
}
```

- Dùng `127.0.0.1`, không dùng `localhost`: API chỉ bind IPv4; `[::1]:8888` fail
  (đã kiểm: IPv4 200, IPv6 000) — tránh phụ thuộc thứ tự phân giải tên trên Windows.
- `recall_min_scores` chỉ đặt **sau khi** đo vài truy vấn thật; 0.25 là ngưỡng khởi đầu
  hợp lý theo số liệu reranker hiện tại (relevant 0.7–1.0, lạc đề 0.0–0.1).

### 8.2 Các bước

1. `hermes plugins install hindsight` (catalog 1.2.3 @ `d952b6e6`; deps resolve được trên
   Python 3.14.9 — đã thử `uv pip compile --python-version 3.14`).
2. Ghi `config.json` như trên; đặt `HINDSIGHT_API_KEY` trong `$HERMES_HOME/.env` nếu không
   muốn để key trong JSON.
3. `hermes memory setup hindsight` (hoặc `hermes config set memory.provider hindsight`).
4. Khởi động lại Hermes (gateway/dashboard) để provider được nạp.
5. Giữ OpenViking ở trạng thái cài nhưng **không active** để rollback.

### 8.3 Rollback

- `hermes config set memory.provider openviking` + khởi động lại → quay lại nguyên trạng.
- Dữ liệu Hindsight nằm ở bank `hermes`, không ảnh hưởng OpenViking; có thể xóa bank nếu muốn.

### 8.4 Nghiệm thu sau tích hợp

- [ ] `hermes memory status` báo provider `hindsight`, bank `hermes`.
- [ ] 3–5 lượt chat thật → `llm_requests` có `retain` mới; `memory_units` tăng.
- [ ] Sau consolidation, `fact_type=observation` xuất hiện; recall trả cả observation + fact thô.
- [ ] Truy vấn lạc đề với `recall_min_scores` → không inject gì (hoặc rất ít).
- [ ] CP `/api/banks` thấy `hermes`, `fact_count` tăng; UI mở được.
- [ ] Không có 401/timeout trong log Hermes; độ trễ recall chấp nhận được.
- [ ] Cherry Studio vẫn recall được bank riêng; sau restart Hindsight phải reconnect MCP.

## 9. Việc nên làm tiếp

**Đã xong trong lượt này:** nâng Hindsight 1.2.0; bỏ tenant deepseek; tạo bank `hermes`;
nâng tài nguyên CP/sink; cài plugin Hindsight 1.2.3 + cấu hình; gỡ OpenViking khỏi Hermes;
xóa repo `hermes-deploy` (local + GitHub).

**Còn lại:**

1. **Xác nhận trên desktop:** mở một chat mới, hỏi lại “mã kiểm thử Hindsight” sau khi ghi
   một fact mới; kiểm `fact_count` của bank `hermes` tăng. Nếu log vẫn báo thiếu
   `hindsight_client`, khởi động lại Hermes một lần (gateway đang giữ PM env cũ).
2. **Theo dõi 1 tuần** rồi chỉnh `recall_budget` (mid → high nếu bank lớn) và
   `recall_min_scores` theo số đo thật.
3. **Tùy chọn:** đặt `mcp_enabled_tools` cho bank `cherry-studio` nếu muốn chặn
   `delete_bank`/`clear_memories`; theo yêu cầu hiện tại không chỉnh MCP Cherry.

**Không triển khai (theo yêu cầu):** backup định kỳ và giám sát — stack chạy local trên máy
này. Chỉ giữ một dump rollback trước nâng cấp:
`~/NTC-Backups/hindsight/20261105/pre-1.2.0-full.dump`.
