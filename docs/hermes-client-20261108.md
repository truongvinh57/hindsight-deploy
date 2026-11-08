# Hermes client — thông số hiện hành (08/11/2026)

Hermes (agent) là client chính của bank `hermes`. Cấu hình nằm ở **phía Hermes**,
không nằm trong repo này:

`C:\Users\vinh.truong\AppData\Local\hermes\hindsight\config.json`

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `mode` | `local_external` | gọi API `http://127.0.0.1:8888` |
| `bank_id` | `hermes` | bank dùng chung cho agent |
| `recall_budget` | **`low`** | độ sâu truy hồi mỗi lượt (low/mid/high) |
| `recall_max_tokens` | **`2048`** | trần token bơm vào context mỗi lượt |
| `recall_sync` | `false` | recall chạy nền, không chặn câu trả lời |
| `retain_every_n_turns` | **`3`** | cứ 3 lượt đóng gói ký ức một lần |

## Vì sao 3 lượt, không phải 1

- `retain_every_n_turns = 1` từng gây **bản ghi gần trùng**: một sự kiện được lưu
  thành 5 bản, recall trả cả 5, làm loãng ngân sách token.
- Cơ chế hiện tại là **append** (chỉ gửi phần chênh lệch) và chạy nền
  (`retain_async = true`), nên 3 lượt không làm mất dữ liệu: khi phiên kết thúc,
  phần còn đệm được xả nốt (flush-on-shutdown).
- Lượt bị ngắt giữa chừng và lượt do cron sinh ra **không** được lưu (chủ ý).

## Đổi thông số

Sửa `config.json` ở phía Hermes rồi **mở phiên mới** — provider chỉ đọc cấu hình
lúc khởi tạo. Không cần restart stack Hindsight.

## Kiểm chứng

```bash
curl -s http://127.0.0.1:8888/health
# trong Hermes: hỏi một câu cần ngữ cảnh cũ, kiểm tra khối memory context được chèn
```
