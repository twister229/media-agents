# Báo cáo test 9Router Media Skills

Ngày test: **2026-07-18**  
Phạm vi: **tạo ảnh, sửa ảnh, tạo video, sửa video** qua instance được cấu hình bởi `NINEROUTER_URL`.  
Skill nguồn:

- Entry: <https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router/SKILL.md>
- Image: <https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-image/SKILL.md>
- Video: <https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-video/SKILL.md>

Phân tích chuyên sâu về I2V, R2V và video dài bằng extension: [`9ROUTER-LONG-VIDEO-GUIDE.md`](./9ROUTER-LONG-VIDEO-GUIDE.md).

## Kết luận nhanh

| Nhu cầu | Model nên dùng | Kết quả test | Lưu ý |
|---|---|---:|---|
| Tạo ảnh nhanh nhất trong lần test này | `xai/grok-imagine-image` | Pass, 7,08 giây, vision judge 7/10 | **Không xuất hiện trong catalog**; dùng như workaround cho ID xAI cũ đã deprecated |
| Tạo ảnh ổn định, model có trong catalog | `ag/gemini-3.1-flash-image` | Pass, 13,30 giây, vision judge 7/10 | Chỉ nên gửi `prompt`; `size`, `n`, `quality` không có tác dụng rõ ràng |
| Tạo và sửa ảnh, lựa chọn mặc định | `cx/gpt-5.4-image` | Pass; tạo 47,97 giây, sửa 64,55 giây | Bài sửa ảnh được judge 8/10, tốt nhất trong một mẫu test |
| Tạo và sửa ảnh bằng model mới hơn | `cx/gpt-5.5-image` | Pass; tạo 116,84 giây, sửa 92,33 giây | Chậm hơn `5.4` và không cho kết quả tốt hơn trong một mẫu test này |
| Tạo và sửa video | `xai/grok-imagine-video` | Pass cả generation và edit | API bất đồng bộ; bắt buộc poll bằng đúng connection đã tạo job |
| Không nên dùng | `xai/grok-2-image-1212` | Fail | xAI đã deprecated model ngày 2026-02-24 |
| Không nên dùng trên connection hiện tại | `cx/gpt-5.3-image` | Fail cả generation và edit | ChatGPT backend báo model không được hỗ trợ |
| Không nên dùng trên connection hiện tại | `cx/gpt-image-2` | Fail cả generation và edit | Có trong catalog động nhưng `/models/info` trả `404`; backend không hỗ trợ |

Khuyến nghị thực dụng:

1. Dùng `cx/gpt-5.4-image` làm mặc định khi cần cả tạo và sửa ảnh.
2. Dùng `ag/gemini-3.1-flash-image` khi chỉ cần text-to-image và muốn nhanh hơn Codex.
3. Dùng `xai/grok-imagine-image` nếu chấp nhận workaround ngoài catalog và cần tốc độ.
4. Dùng `xai/grok-imagine-video` cho video; luôn lưu `request_id` và header `x-9router-connection-id`.
5. Không dùng `grok-2-image-1212`, `gpt-5.3-image` hoặc `gpt-image-2` trên cấu hình account hiện tại.

Các xếp hạng trên chỉ là **quan sát từ một mẫu cho mỗi model**, không phải benchmark thống kê. Muốn kết luận chắc chắn về chất lượng hoặc tốc độ cần chạy lặp lại nhiều prompt và nhiều seed/lần sinh.

## Phạm vi và phương pháp

### Model được discovery công bố

`GET /v1/models/image` trả 6 model:

| STT | Model |
|---:|---|
| 1 | `xai/grok-2-image-1212` |
| 2 | `ag/gemini-3.1-flash-image` |
| 3 | `cx/gpt-5.5-image` |
| 4 | `cx/gpt-5.4-image` |
| 5 | `cx/gpt-5.3-image` |
| 6 | `cx/gpt-image-2` |

Video discovery không nhất quán:

| Probe | Kết quả |
|---|---|
| `GET /v1/models/video` | `404 Unknown model kind: video` |
| `GET /v1/models` và lọc `kind == "video"` | Không có model |
| `GET /v1/models/info?id=xai/grok-imagine-video` | `200`, nhận ra model và params nhưng trả `endpoint:null` |
| `POST /v1/videos/generations` | Route tồn tại và chạy thành công |

Do đó, với instance này không thể dùng discovery làm nguồn duy nhất cho video. Model video thực tế đã test là `xai/grok-imagine-video`.

### Prompt tạo ảnh chung

```text
Create a clean editorial poster, square composition: a small red robot
watering one blue sunflower in a white ceramic pot, cream background,
soft window light. Add exactly the text 'MEDIA LAB' at the top in bold
black sans-serif. No other text.
```

### Prompt sửa ảnh chung

Ảnh nguồn là output của `ag/gemini-3.1-flash-image`.

```text
Edit the supplied poster only: change the blue sunflower to bright yellow.
Preserve the red robot, white ceramic pot, cream background, square
composition, and the exact text 'MEDIA LAB'. Add no other text.
```

### Cách chấm

- Kiểm tra kỹ thuật: HTTP status, thời gian, số byte, MIME thực tế, kích thước và khả năng mở file.
- Kiểm tra nội dung ảnh: `ag/gemini-3-flash` đọc ảnh bằng vision với rubric cố định, `temperature: 0`.
- Kiểm tra nội dung video: cùng model Gemini đọc hai MP4, so sánh source và edited video với rubric cố định.
- Điểm judge chỉ là tín hiệu tham khảo. Một judge và một mẫu không đủ để xếp hạng tuyệt đối.
- Không có API key nào được ghi vào artefact hoặc báo cáo.

## Kết quả tạo ảnh

| Model được gọi | Catalog | HTTP | Thời gian | Output thực tế | Judge | Kết luận |
|---|---:|---:|---:|---|---:|---|
| `xai/grok-2-image-1212` | Có | 404 sau retry tối giản | 1,01 giây | JSON error | Không chấm | Fail: deprecated; upstream yêu cầu `grok-imagine-image` |
| `xai/grok-imagine-image` | **Không** | 200 | **7,08 giây** | JPEG, 1024x1024, 136.891 byte | 7/10 | Pass bằng workaround ngoài catalog |
| `ag/gemini-3.1-flash-image` | Có | 200 | 13,30 giây | JPEG, 1024x1024, 681.027 byte | 7/10 | Pass |
| `cx/gpt-5.5-image` | Có | 200 | 116,84 giây | PNG, 1254x1254, 1.780.696 byte | 7/10 | Pass nhưng chậm nhất trong các model thành công |
| `cx/gpt-5.4-image` | Có | 200 | 47,97 giây | PNG, 1254x1254, 1.687.417 byte | 7/10 | Pass; hợp lý hơn `5.5` trong lần test này |
| `cx/gpt-5.3-image` | Có | 400 | 6,43 giây | JSON error | Không chấm | Fail: model không được ChatGPT account hỗ trợ |
| `cx/gpt-image-2` | Có, dạng động | 400 | 2,85 giây | JSON error | Không chấm | Fail: model không được ChatGPT account hỗ trợ |

Nhận xét từ vision judge cho bốn ảnh thành công:

| Model | Bám prompt | Bố cục | Chữ | Chất lượng | `MEDIA LAB` chính xác | Chữ thừa |
|---|---:|---:|---:|---:|---:|---:|
| `xai/grok-imagine-image` | 7 | 7 | 7 | 7 | Có | 0 |
| `ag/gemini-3.1-flash-image` | 7 | 7 | 7 | 7 | Có | 0 |
| `cx/gpt-5.5-image` | 7 | 7 | 7 | 7 | Có | 0 |
| `cx/gpt-5.4-image` | 7 | 7 | 7 | 7 | Có | 0 |

Judge cho điểm phẳng 7/10 cho cả bốn ảnh, vì vậy không nên dùng điểm này để tuyên bố model nào tạo ảnh đẹp nhất. Khác biệt có ý nghĩa rõ nhất trong lần test là thời gian và khả năng hỗ trợ edit.

## Kết quả sửa ảnh

`/v1/models/info` công bố capability `edit` cho `cx/gpt-5.5-image`, `cx/gpt-5.4-image` và `cx/gpt-5.3-image`. `cx/gpt-image-2` được test thêm vì xuất hiện trong catalog động, dù metadata info bị thiếu.

| Model | Metadata edit | HTTP | Thời gian | Output | Judge | Kết luận |
|---|---:|---:|---:|---|---:|---|
| `cx/gpt-5.5-image` | Có | 200 | 92,33 giây | PNG, 1254x1254, 1.966.344 byte | 7/10 | Đổi đúng hoa sang vàng, giữ được text và phần chính |
| `cx/gpt-5.4-image` | Có | 200 | 64,55 giây | PNG, 1254x1254, 1.988.281 byte | **8/10** | Nhanh hơn và được judge chấm tốt hơn trong lần test |
| `cx/gpt-5.3-image` | Có | 400 | 10,39 giây | JSON error | Không chấm | Metadata nói hỗ trợ nhưng backend từ chối model |
| `cx/gpt-image-2` | Không xác định | 400 | 2,27 giây | JSON error | Không chấm | Model động không dùng được với ChatGPT account hiện tại |

Không test edit bằng `ag/gemini-3.1-flash-image` vì metadata chỉ công bố `textToImage`. Implementation hiện tại cũng loại bỏ image part trước khi gửi tới Antigravity, nên gọi edit có nguy cơ sinh ảnh mới từ prompt thay vì sửa ảnh nguồn.

## Kết quả video

Phần benchmark dưới đây chỉ bao phủ text-to-video và video edit. Contract, payload và kiến trúc đề xuất cho image-to-video, reference-to-video và chuỗi extension được trình bày trong [`9ROUTER-LONG-VIDEO-GUIDE.md`](./9ROUTER-LONG-VIDEO-GUIDE.md).

### Tạo video

| Thuộc tính | Kết quả |
|---|---|
| Model | `xai/grok-imagine-video` |
| Endpoint | `POST /v1/videos/generations` |
| Input | Text-to-video, 2 giây, `1:1`, `480p` |
| Create HTTP | 200 |
| Thời gian nhận `request_id` | 1,69 giây |
| Poll | Hoàn tất ở poll thứ 4, khoảng 15-17 giây sau submit |
| Output | MP4, 262.679 byte, duration upstream báo 2 giây |
| Upstream cost | 1.000.000.000 ticks = **0,10 USD** theo công thức xAI |
| Judge | Bám prompt 7/10, motion 6/10 |

### Sửa video

| Thuộc tính | Kết quả |
|---|---|
| Model | `xai/grok-imagine-video` |
| Endpoint | `POST /v1/videos/edits` |
| Input | URL của video vừa tạo; đổi cánh hoa vàng thành xanh, giữ phần còn lại |
| Create HTTP | 200 |
| Thời gian nhận `request_id` | 2,02 giây |
| Poll | Hoàn tất ở poll thứ 6, khoảng 25-27 giây sau submit |
| Output | MP4, 224.693 byte, duration upstream báo 2 giây |
| Upstream cost | 1.200.000.000 ticks = **0,12 USD** theo công thức xAI |
| Judge | Đổi đúng màu 7/10, preservation 7/10, visual quality 6/10 |

Tổng cost do upstream trả về cho hai job video test là **0,22 USD**. Đây là cost do response báo, không chứng minh số tiền thực tế được invoice hoặc job có được bao phủ bởi subscription OAuth hay không.

## Bảng tham số thực dụng

| Provider/model | Tạo ảnh | Sửa ảnh | Tham số nên dùng | Tham số không nên kỳ vọng |
|---|---:|---:|---|---|
| `xai/grok-imagine-image` | Có | Không qua adapter hiện tại | `prompt`, `n`, `response_format` | `size`, `quality`, `image`, `images[]` |
| `ag/gemini-3.1-flash-image` | Có | Không | `prompt` | `n`, `size`, `quality`, `response_format`; output hiện dùng 1:1 |
| `cx/gpt-5.5-image` | Có | Có | `prompt`, `image`, `images[]`, `image_detail`, `size`, `quality`, `background`, `output_format` | `n`; body `response_format` không quyết định binary mode |
| `cx/gpt-5.4-image` | Có | Có | Giống `cx/gpt-5.5-image` | Giống `cx/gpt-5.5-image` |
| `cx/gpt-5.3-image` | Backend từ chối | Backend từ chối | Không dùng trên connection hiện tại | Mọi tham số |
| `cx/gpt-image-2` | Backend từ chối | Backend từ chối | Không dùng trên connection hiện tại | Mọi tham số |

| Model video | Generation | Image-to-video | Edit | Extension | Tham số chính |
|---|---:|---:|---:|---:|---|
| `xai/grok-imagine-video` | Đã test, pass | Chưa test | Đã test, pass | Chưa test | `prompt`, `duration`, `aspect_ratio`, `resolution`, `image`, `reference_images`, `video`, `storage_options`, `output`, `user` |

Source xác nhận 9Router forward `reference_images`, `storage_options` và route extension. Probe body `{}` trên `/v1/videos/extensions` trả `422 missing field prompt` từ xAI và không trả `request_id`, xác nhận route hoạt động tới bước upstream validation. Không có bằng chứng job async đã được accept; việc không phát sinh billing là suy luận chưa đối chiếu billing console. I2V, R2V và extension render vẫn chưa được live-test vì mỗi POST hợp lệ có thể phát sinh cost.

Giới hạn xAI hiện hành theo API docs:

| Field | Giá trị |
|---|---|
| Generation `duration` | 1-15 giây, mặc định 8 |
| Generation `aspect_ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3` |
| Generation `resolution` | `480p`, `720p`, `1080p` |
| Image-to-video `image` | `{ "url": "https://..." }`, data URI hoặc `file_id` |
| Edit `video` | Public MP4 URL, data URI hoặc `file_id` |
| Extension `duration` | 2-10 giây, mặc định 6 |

## Cách gọi khuyến nghị

### Thiết lập

```bash
export NINEROUTER_URL="http://localhost:20128"
export NINEROUTER_KEY="sk-..."

curl --fail-with-body "$NINEROUTER_URL/api/health"
```

### Discovery ảnh

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  "$NINEROUTER_URL/v1/models/image" | jq '.data[].id'

curl --fail-with-body -G \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  --data-urlencode "id=cx/gpt-5.4-image" \
  "$NINEROUTER_URL/v1/models/info" | jq
```

### Tạo ảnh bằng model có trong catalog

```bash
curl --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/images/generations?response_format=binary" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ag/gemini-3.1-flash-image",
    "prompt": "A clean editorial poster of a red robot watering a flower"
  }' \
  --output out.bin

file out.bin
```

Dùng `out.bin` trước rồi kiểm tra magic bytes bằng `file`; đừng tin tuyệt đối vào `Content-Type` của binary response.

### Tạo ảnh bằng workaround xAI

```bash
curl --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/images/generations?response_format=binary" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "xai/grok-imagine-image",
    "prompt": "A clean editorial poster of a red robot watering a flower",
    "n": 1
  }' \
  --output out.bin
```

Model này chạy được trong test nhưng không có trong `/v1/models/image` và `/v1/models/info`, nên có thể ngừng hoạt động nếu router bắt đầu enforce catalog.

### Tạo ảnh bằng Codex

```bash
curl --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/images/generations?response_format=binary" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "cx/gpt-5.4-image",
    "prompt": "A clean editorial poster of a red robot watering a flower",
    "size": "1024x1024",
    "quality": "high",
    "output_format": "png"
  }' \
  --output out.png
```

Trong test, yêu cầu `1024x1024` cho Codex cho ra file `1254x1254`; cần kiểm tra kích thước output thay vì giả định tham số được tuân thủ chính xác.

### Sửa ảnh bằng Codex

```bash
SOURCE_MIME="$(file --brief --mime-type source.jpg)"
SOURCE_B64="$(base64 --wrap=0 source.jpg)"

jq -n \
  --arg model "cx/gpt-5.4-image" \
  --arg prompt "Change only the flower from blue to yellow" \
  --arg mime "$SOURCE_MIME" \
  --arg image "$SOURCE_B64" \
  '{
    model: $model,
    prompt: $prompt,
    image: ("data:" + $mime + ";base64," + $image),
    image_detail: "high",
    output_format: "png"
  }' |
curl --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/images/generations?response_format=binary" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  --output edited.png
```

Ưu tiên data URI. Codex image backend có thể không tự tải được URL ảnh từ xa trong luồng này.

### Tạo video

```bash
curl_exit=0
curl --silent --show-error --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/videos/generations" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  -D create.headers \
  -d '{
    "model": "xai/grok-imagine-video",
    "prompt": "A red robot watering a yellow sunflower, locked camera",
    "duration": 4,
    "aspect_ratio": "1:1",
    "resolution": "480p"
  }' \
  --output create.json || curl_exit=$?

if [[ "$curl_exit" -ne 0 ]]; then
  printf 'SUBMIT_FAILED_OR_UNKNOWN: do not retry automatically\n' >&2
  exit 1
fi

REQUEST_ID="$(jq -r '.request_id // empty' create.json)"
CONNECTION_ID="$(tr -d '\r' < create.headers | awk -F ': ' \
  'tolower($1) == "x-9router-connection-id" { print $2 }' | tail -n 1)"

if [[ -z "$REQUEST_ID" || -z "$CONNECTION_ID" ]]; then
  printf 'SUBMIT_UNKNOWN: missing request or connection ID; do not retry automatically\n' >&2
  exit 1
fi

curl --silent --show-error --fail-with-body \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "x-connection-id: $CONNECTION_ID" \
  -D poll.headers \
  "$NINEROUTER_URL/v1/videos/$REQUEST_ID" \
  --output poll.json

POLL_CONNECTION_ID="$(tr -d '\r' < poll.headers | awk -F ': ' \
  'tolower($1) == "x-9router-connection-id" { print $2 }' | tail -n 1)"

if [[ -z "$POLL_CONNECTION_ID" || "$POLL_CONNECTION_ID" != "$CONNECTION_ID" ]]; then
  printf 'AFFINITY_LOST: stop this workflow\n' >&2
  exit 1
fi

jq . poll.json
```

Lặp GET cho tới khi `status` là `done`, `failed` hoặc `expired`. Khi `done`, tải URL tại `.video.url`.

### Sửa video

```bash
curl_exit=0
curl --silent --show-error --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/videos/edits" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  -D edit.headers \
  -d '{
    "model": "xai/grok-imagine-video",
    "prompt": "Change only the flower petals from yellow to blue",
    "video": {
      "url": "https://example.com/source.mp4"
    }
  }' \
  --output edit.json || curl_exit=$?

if [[ "$curl_exit" -ne 0 ]]; then
  printf 'SUBMIT_FAILED_OR_UNKNOWN: do not retry automatically\n' >&2
  exit 1
fi

EDIT_REQUEST_ID="$(jq -r '.request_id // empty' edit.json)"
EDIT_CONNECTION_ID="$(tr -d '\r' < edit.headers | awk -F ': ' \
  'tolower($1) == "x-9router-connection-id" { print $2 }' | tail -n 1)"

if [[ -z "$EDIT_REQUEST_ID" || -z "$EDIT_CONNECTION_ID" ]]; then
  printf 'SUBMIT_UNKNOWN: missing request or connection ID; do not retry automatically\n' >&2
  exit 1
fi
```

Poll edit job giống generation job và dùng connection ID lấy từ chính response `edit.headers`.

## Cảnh báo vận hành và billing

1. Video creation là billable và bất đồng bộ. Nếu POST timeout, connection reset, client interruption, response bị truncate hoặc trả `5xx` mà không có `request_id`, không submit lại ngay; trước tiên kiểm tra log/dashboard hoặc request đã lưu.
2. Một lệnh client không đảm bảo chỉ có một upstream attempt. 9Router hiện có thể rotate account khi nhận `401`, `403` hoặc `429` trước khi trả response.
3. `Idempotency-Key` được 9Router forward nhưng xAI video docs hiện không cam kết deduplication cho header này. Không coi đây là bảo đảm chống billing trùng.
4. Image handler có account fallback rộng hơn video. Một request ảnh lỗi có thể được gửi sang account khác; cần cân nhắc khi benchmark nhiều account.
5. Poll video phải dùng `x-connection-id` bằng giá trị của header `x-9router-connection-id` khi tạo job. Video job bị ràng buộc với upstream account.
6. Không gửi đồng thời `Accept: text/event-stream` và `?response_format=binary` cho Codex image.
7. URL ảnh từ xa trong Codex edit có thể không được prefetch; dùng data URI để ổn định hơn.
8. Binary response của xAI và Antigravity được khai báo `image/png` trong test nhưng magic bytes là JPEG. Luôn sniff MIME trước khi đặt extension.

## Sai lệch giữa skill và runtime

| Vấn đề | Skill/tài liệu hiện tại | Runtime quan sát được | Đề xuất sửa skill |
|---|---|---|---|
| Entry skill thiếu video | Bảng capability trong `9router/SKILL.md` không có video | Repo có `9router-video`; route video hoạt động | Thêm URL `9router-video/SKILL.md` và discovery video |
| xAI image ID cũ | Catalog trả `grok-2-image-1212` | Upstream báo deprecated | Thay bằng `xai/grok-imagine-image` trong registry và skill |
| Discovery video | Kỳ vọng model video có `kind:"video"` | `/v1/models/video` trả 404; `/models/info` có model nhưng `endpoint:null` | Bổ sung mapping kind và endpoint `/v1/videos/generations` |
| Common image fields | Skill nói field chung hoạt động mọi nơi | Antigravity bỏ qua hầu hết field; Codex bỏ qua `n`; xAI không dùng `size` | Ghi bảng tham số theo provider/model |
| Response mặc định | Skill thiên về URL response | Antigravity và Codex thường trả base64/binary | Ghi rõ response theo provider |
| MIME binary | Skill ngụ ý đúng PNG/JPEG theo header | Header `image/png` nhưng bytes là JPEG ở xAI/Antigravity | Bảo toàn MIME upstream hoặc sniff bytes |
| `cx/gpt-image-2` | Xuất hiện trong catalog động | `/models/info` 404 và backend từ chối | Không expose nếu connection không thực sự hỗ trợ |
| `cx/gpt-5.3-image` | Metadata công bố text-to-image và edit | Backend từ chối cả hai | Health-check enabled model trước khi expose |
| Video retry | Skill nói creation không auto-retry, trừ refresh 401 | Source có thể rotate trên 401/403/429 | Mô tả đúng rotation và rủi ro billable |
| CLI key variable | Skill dùng `NINEROUTER_KEY` | Source CLI đọc `NINE_ROUTER_API_KEY` | Thống nhất một tên env hoặc hỗ trợ cả hai |

## Artefact và script

| Nội dung | Đường dẫn |
|---|---|
| Runner text-to-image | `scripts/benchmark-images.sh` |
| Runner image edit | `scripts/benchmark-edits.sh` |
| Runner video generation | `scripts/benchmark-video.sh` |
| Runner video edit | `scripts/benchmark-video-edit.sh` |
| Vision judge | `scripts/judge-images.sh` |
| Guide I2V, R2V và extension | `9ROUTER-LONG-VIDEO-GUIDE.md` |
| Ảnh tạo mới | `results/text-to-image/` |
| Ảnh đã sửa | `results/image-edit/` |
| Video tạo mới | `results/video/` |
| Video đã sửa | `results/video-edit/` |
| Kết quả chấm tự động | `results/judging/` |

Video runner từ chối chạy lại nếu output directory đã có `create.json`. Muốn chủ động tạo một job mới, phải truyền một thư mục output mới. Guard này giảm nguy cơ vô tình submit lại job billable nhưng không thể thay thế kiểm soát idempotency phía upstream.

## Phần chưa test

| Capability | Trạng thái | Lý do |
|---|---|---|
| Image-to-video bằng field `image` | Chưa test | Không cần thiết để xác nhận text-to-video và edit; sẽ phát sinh thêm cost |
| Reference-to-video bằng `reference_images` | Chưa test | Request hợp lệ sẽ phát sinh thêm cost |
| Video extension | Chưa test | Là một job billable riêng; user chưa yêu cầu kiểm tra extension cụ thể |
| `storage_options` qua Grok OAuth | Chưa test | Files lifecycle/cleanup qua OAuth chưa được xác nhận |
| Video CLI `9router xai video` | Chưa test | Phiên này test REST API được skill mô tả; không xác nhận CLI binary có được cài trên máy |
| Lặp nhiều lần mỗi model | Chưa test | Tránh tiêu tốn quota/cost; số liệu hiện tại là single-run |
| Các model không được instance expose | Chưa test | Ma trận lấy catalog của instance làm phạm vi |

## Verdict

Trên instance được test ngày 2026-07-18:

- `ag/gemini-3.1-flash-image`, `cx/gpt-5.4-image` và `cx/gpt-5.5-image` tạo ảnh thành công.
- `cx/gpt-5.4-image` và `cx/gpt-5.5-image` sửa ảnh thành công; `5.4` là lựa chọn mặc định hợp lý nhất trong lần test.
- `xai/grok-imagine-image` chạy thành công và nhanh nhất nhưng là workaround ngoài catalog.
- `xai/grok-imagine-video` tạo và sửa video thành công.
- Catalog hiện chứa ba image ID không dùng được trên cấu hình hiện tại và không discover được video model dù route video hoạt động.
- Skill cần được cập nhật theo provider thay vì mô tả các field ảnh là dùng chung cho mọi model.
