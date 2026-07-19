# 9Router: Image-to-Video, Reference-to-Video và Video Extension

Ngày phân tích: **2026-07-18**  
Mục tiêu: tạo video dài từ ảnh có sẵn, giữ chủ thể/phong cách ổn định và nối dài video bằng `POST /v1/videos/extensions`.

Nguồn chính:

- 9Router video skill: <https://github.com/decolua/9router/blob/master/skills/9router-video/SKILL.md>
- xAI video API: <https://docs.x.ai/developers/rest-api-reference/inference/videos>
- xAI I2V: <https://docs.x.ai/developers/model-capabilities/video/image-to-video>
- xAI R2V: <https://docs.x.ai/developers/model-capabilities/video/reference-to-video>
- xAI extension: <https://docs.x.ai/developers/model-capabilities/video/extension>
- xAI Files inputs: <https://docs.x.ai/developers/model-capabilities/imagine/files/inputs>
- xAI persisted outputs: <https://docs.x.ai/developers/model-capabilities/imagine/files/outputs>

## Kết luận kiến trúc

Không có một mode duy nhất vừa khóa chính xác frame mở đầu, vừa nhận nhiều ảnh reference, vừa giữ reference trực tiếp qua mọi lần extend.

| Nhu cầu chính | Mode nên dùng | Payload chính | Đặc điểm |
|---|---|---|---|
| Muốn video bắt đầu đúng từ một ảnh đã thiết kế hoàn chỉnh | Image-to-video, I2V | `image` | Ảnh trở thành frame mở đầu; phù hợp nhất khi bố cục ban đầu phải chính xác |
| Muốn giữ người, sản phẩm, quần áo hoặc phong cách từ nhiều ảnh | Reference-to-video, R2V | `reference_images[]` | Reference hướng dẫn nội dung nhưng không khóa frame đầu |
| Muốn nối dài một shot đang có | Video extension | `video` + `duration` | Tiếp tục từ frame cuối; output chứa cả video cũ và đoạn mới |
| Muốn sửa nội dung nhưng không tăng độ dài | Video edit | `video` | Không phải cơ chế nối dài; duration giữ theo input và có giới hạn riêng |

Quy tắc API quan trọng:

- `image` và `reference_images` **loại trừ lẫn nhau**. Gửi cả hai sẽ nhận `400`.
- Extension chỉ nhận `video`; không nhận lại `image` hoặc `reference_images`.
- Vì reference không được đưa lại ở các bước extension, độ giống chủ thể/phong cách có thể drift dần.
- Không có giới hạn chính thức về số lần extension hoặc tổng duration tích lũy.
- Do đó, không nên thiết kế hệ thống dựa trên giả định “extend vô hạn vẫn giữ nguyên nhân vật”.

## Khuyến nghị cho nhu cầu chính

### Trường hợp một ảnh đã đúng hoàn toàn

Nếu bạn đã có một ảnh thể hiện đúng nhân vật, trang phục, sản phẩm, nền, màu và bố cục, hãy dùng **I2V**.

Đây là lựa chọn mạnh nhất để đảm bảo video mở đầu đúng với ý muốn:

1. Chuẩn bị ảnh canonical ở đúng tỷ lệ đầu ra, ví dụ `16:9` hoặc `9:16`.
2. Dùng ảnh đó trong field `image`.
3. Prompt chỉ mô tả chuyển động, camera và các invariant phải giữ.
4. Không ép `aspect_ratio` khác tỷ lệ ảnh, vì xAI cho biết override có thể kéo giãn ảnh.
5. Tạo seed 8-15 giây, QA, rồi mới extend.

Nếu các yêu cầu đang nằm ở nhiều ảnh khác nhau, cách kiểm soát cao là dựng trước một ảnh canonical bằng image editor/model ảnh, rồi dùng ảnh hoàn chỉnh đó làm I2V input.

### Trường hợp nhiều ảnh reference

Nếu cần một ảnh cho khuôn mặt, một ảnh cho trang phục, một ảnh cho sản phẩm hoặc style, hãy dùng **R2V**.

Mỗi ảnh nên có một vai trò ổn định:

| Reference | Vai trò gợi ý |
|---|---|
| `<IMAGE_1>` | Nhân vật, khuôn mặt, tóc, tỷ lệ cơ thể |
| `<IMAGE_2>` | Trang phục hoặc sản phẩm |
| `<IMAGE_3>` | Bối cảnh, ánh sáng, palette hoặc style |

Prompt nên gọi marker `<IMAGE_1>`, `<IMAGE_2>`, ... theo thứ tự của `reference_images[]`, giống convention trong ví dụ chính thức của xAI. REST schema chưa định nghĩa marker này thành một guarantee máy-đọc được. Không dùng các ảnh mâu thuẫn nhau về khuôn mặt, tuổi, trang phục hoặc ánh sáng.

R2V giữ reference như một hướng dẫn, không đảm bảo frame đầu trùng với bất kỳ reference nào.

### Video dài cần độ nhất quán cao

Khuyến nghị production mang tính model-dependent là workflow lai; benchmark hiện tại chưa đo định lượng mức giảm drift của phương pháp này:

1. Chia nội dung dài thành các shot ngắn.
2. Mỗi shot mới được khởi tạo lại bằng I2V hoặc R2V từ reference canonical.
3. Chỉ extend trong phạm vi một shot cần chuyển động liên tục.
4. Ghép các shot bằng editor hoặc `ffmpeg`.

Lý do:

- I2V/R2V tái áp reference trực tiếp ở đầu mỗi shot.
- Extension ưu tiên temporal continuity nhưng không nhận lại reference.
- Drift trong một extension bị chấp nhận sẽ trở thành input cho mọi extension sau.
- Với video 30-60 giây trở lên, nhiều shot được re-anchor thường đáng tin cậy hơn một chuỗi extension dài duy nhất.

Một policy khởi đầu hợp lý để đo chất lượng, không phải giới hạn xAI:

| Thành phần | Giá trị khởi đầu |
|---|---|
| Seed I2V/R2V | 8-15 giây |
| Mỗi extension | 4-6 giây |
| Số extension trước khi re-anchor | 1-3 |
| Resolution | `720p` |
| QA | Bắt buộc sau từng job |

Sau khi có dữ liệu riêng, có thể tăng segment lên tối đa 10 giây hoặc kéo dài chuỗi nếu drift vẫn nằm trong ngưỡng.

## Contract của endpoint

### `POST /v1/videos/generations`

Endpoint này tự chọn mode dựa trên field:

| Mode | Fields |
|---|---|
| Text-to-video | `prompt` |
| Image-to-video | `image`, tùy chọn `prompt` |
| Reference-to-video | `reference_images`, bắt buộc `prompt` |

Giới hạn chính thức:

| Field | Contract |
|---|---|
| `duration` | 1-15 giây; mặc định 8 |
| `aspect_ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3` |
| `resolution` | `480p`, `720p`, `1080p` theo schema |
| I2V ratio | Mặc định theo ảnh; override có thể stretch ảnh |
| I2V image types | JPEG, PNG, WebP |
| Image form | Public URL, data URI hoặc `file_id` |
| Reference count | Docs nói “one or more”; không công bố maximum chính thức |

`1080p` hiện chỉ được xAI ghi là hỗ trợ bởi `grok-imagine-video-1.5` cho I2V. 9Router instance đã phân tích chỉ đăng ký `grok-imagine-video`, do đó `720p` là lựa chọn an toàn hơn.

### `POST /v1/videos/extensions`

Request:

| Field | Required | Ý nghĩa |
|---|---:|---|
| `model` | Không | Dùng `xai/grok-imagine-video`; 9Router bỏ prefix trước khi forward |
| `prompt` | Có | Mô tả điều xảy ra tiếp theo |
| `duration` | Không | Độ dài **đoạn mới**, 2-10 giây; mặc định 6 |
| `video` | Có | `{ "url": "...mp4" }` hoặc `{ "file_id": "file_..." }` |
| `storage_options` | Không | Lưu output vào xAI Files để dùng cho bước sau |

Ví dụ theo contract một lần extension: input 10 giây, `duration: 5` trả output tích lũy 15 giây. Không cần tự nối clip 10 giây và 5 giây.

Không gửi các field sau trên extension:

- `aspect_ratio`
- `resolution`
- `image`
- `reference_images`

Aspect ratio và resolution được kỳ vọng kế thừa từ input, nhưng xAI không mô tả một contract riêng cho việc transform hai field này trong extension.

### `GET /v1/videos/{request_id}`

Status chính thức:

| Status | Xử lý |
|---|---|
| `pending` | Tiếp tục poll |
| `done` | Kiểm tra output, moderation, duration, storage và usage |
| `failed` | Dừng; đọc `error.code` và `error.message` |
| `expired` | Dừng; không tự submit lại |

Poll mỗi khoảng 5 giây là hợp lý. GET có thể retry với backoff; POST billable không nên tự retry khi kết quả submit không rõ.

## 9Router thực sự làm gì

Phân tích source 9Router commit `bc252ea`:

| Hành vi | Kết luận |
|---|---|
| Video upstream | `https://api.x.ai/v1/videos` |
| Actions | `generations`, `edits`, `extensions` |
| JSON body | Forward nguyên nội dung, trừ việc bỏ prefix `xai/` khỏi model |
| Field mới | `reference_images`, `storage_options`, `output`, `user` được forward dù skill chưa mô tả đầy đủ |
| Validation | 9Router không validate schema video; lỗi field đến từ xAI |
| Response success | Upstream JSON được pass-through |
| Timeout | 120 giây cho từng HTTP round trip, không phải deadline render job |
| Input data URI | Body được buffer trong RAM; không tối ưu cho video base64 lớn |
| Files API | Không có proxy `/v1/files` trong version đã phân tích |

Source liên quan:

- `open-sse/providers/registry/xai.js:35-41`
- `open-sse/handlers/videoCore.js:6-18`
- `open-sse/handlers/videoCore.js:33-43`
- `open-sse/handlers/videoCore.js:97-117`
- `open-sse/handlers/videoCore.js:148-165`
- `src/sse/handlers/videoGeneration.js:45-60`
- `src/sse/handlers/videoGeneration.js:92-114`
- `src/app/api/v1/videos/extensions/route.js:13-15`

Probe không tạo job trên instance ngày 2026-07-18:

```text
POST /v1/videos/extensions với body {}
-> HTTP 422 từ xAI: missing field `prompt`
```

Probe này xác nhận route extension tồn tại và body đi tới xAI. Nó không xác nhận một extension live đã render thành công. Response không có `request_id`, nên không có bằng chứng job async đã được accept; việc không phát sinh billing là suy luận từ synchronous validation, chưa được đối chiếu billing console.

## Chọn dạng input media

| Dạng | Ưu điểm | Nhược điểm | Khuyến nghị |
|---|---|---|---|
| Public HTTPS URL | Payload nhỏ, đơn giản | URL phải còn hiệu lực và xAI truy cập được | Tốt khi có object storage/CDN |
| Data URI | Không cần public asset | Request lớn, 9Router buffer toàn bộ body | Chỉ dùng cho ảnh nhỏ; tránh cho cumulative MP4 |
| `file_id` | Private, ổn định, không upload lại | Cùng xAI team; 9Router không proxy Files upload/cleanup | Tốt nhất cho chain production có direct xAI API key |

Đường dẫn local không phải REST input hợp lệ. CLI `9router xai video --image` có thể tự chuyển local image thành data URI, nhưng CLI hiện chỉ hỗ trợ generation/I2V, không hỗ trợ R2V, extension, `file_id` hoặc `storage_options`.

Với workflow dài, không truyền cumulative MP4 dưới dạng base64. Dùng `file_id` hoặc URL.

Preflight video input cho edit/extension:

- `url` phải public hoặc là data URI; URL phải có path/filename `.mp4`.
- MP4 phải dùng codec được xAI hỗ trợ, ví dụ H.264, H.265 hoặc AV1.
- `file_id` phải trỏ tới video đã upload hoàn tất và đúng MIME/type.
- Trong cùng một object `video`, chỉ dùng một trong `url` hoặc `file_id`.
- Với URL do bạn quản lý, kiểm tra xAI truy cập được mà không cần cookie/header riêng.

## Lưu output để extend an toàn

`video.url` mặc định là URL tạm thời và xAI không công bố TTL chính xác. Không chỉ lưu URL này rồi chờ nhiều giờ trước khi extend.

Nếu đã xác minh quyền quản lý xAI Files, nên thêm vào generation/extension và đặt TTL rõ ràng:

```json
"storage_options": {
  "filename": "project-step-0001.mp4",
  "expires_after": 604800
}
```

Khi job `done`, poll response có thể chứa:

```json
{
  "video": {
    "url": "https://vidgen.x.ai/...mp4",
    "file_output": {
      "file_id": "file_...",
      "filename": "project-step-0001.mp4"
    }
  }
}
```

Dùng `file_output.file_id` làm input cho extension kế tiếp:

```json
"video": { "file_id": "file_..." }
```

Ví dụ trên tự xóa file sau 7 ngày. Omit `expires_after` sẽ tạo file tồn tại cho tới khi bị xóa thủ công và tiếp tục phát sinh storage cost.

Nếu cần public URL tạm thời:

```json
"storage_options": {
  "filename": "project-step-0001.mp4",
  "expires_after": 604800,
  "public_url": { "expires_after": 86400 }
}
```

Cảnh báo:

- Public URL cho phép bất kỳ ai có link truy cập video.
- xAI giới hạn 1.000 active public URLs mỗi team.
- Storage hiện được công bố ở mức `0,025 USD/GiB/ngày`; download `0,20 USD/GiB`.
- Extension trả cumulative video, nên giữ mọi step vĩnh viễn sẽ làm storage tăng nhanh.
- Nên giữ parent đã được duyệt để rollback, xóa các branch bị reject theo retention policy.
- `storage_options` được 9Router forward theo source nhưng chưa được live-test trong benchmark hiện tại.
- TTL hợp lệ là 3.600-2.592.000 giây; public URL không thể sống lâu hơn stored file.

Nếu chỉ có Grok OAuth mà không có direct xAI API key, việc quản lý Files trực tiếp chưa được xác nhận. Không bật permanent `storage_options` cho tới khi đã xác minh cleanup. Khi đó, tải ngay ephemeral output về object storage của bạn, dùng một public/signed URL còn hiệu lực làm input bước kế tiếp và đặt retention ở storage của bạn.

## Connection affinity

Mỗi POST thành công trả header:

```http
x-9router-connection-id: <connection-id>
```

Mọi poll và extension sau đó nên gửi:

```http
x-connection-id: <connection-id>
```

Điểm quan trọng: pinning hiện là **soft preference**. Nếu connection bị lock hoặc unavailable, 9Router có thể chọn account khác.

Source:

- Nhận preferred connection: `src/sse/handlers/videoGeneration.js:112-120`
- Trả connection ID: `src/sse/handlers/videoGeneration.js:82-88`
- Chọn preferred nếu available: `src/sse/services/auth.js:107-164`

Khuyến nghị production:

1. Chỉ cấu hình một xAI connection cho worker tạo chuỗi video, hoặc dùng một 9Router instance chuyên dụng.
2. Lưu chain connection ID ngay sau seed POST.
3. Gửi ID đó trên mọi extension POST và poll GET.
4. Đọc `x-9router-connection-id` của mọi response thành công.
5. Nếu ID thay đổi, dừng chain với trạng thái `AFFINITY_LOST`.
6. Đặc biệt thận trọng khi dùng private `file_id`. xAI Files là team-scoped; hai connection cùng team có thể vẫn truy cập được, nhưng 9Router không chứng minh được team equivalence nên policy an toàn là fail closed khi connection đổi.

Kiểm tra response header chỉ phát hiện affinity change **sau khi POST có thể đã được accept và billed**. Biện pháp phòng ngừa duy nhất với implementation hiện tại là một dedicated 9Router instance/worker chỉ có đúng một xAI connection, hoặc gọi xAI trực tiếp với một API key cố định.

## Payload I2V khuyến nghị

Ảnh nên được crop sẵn đúng tỷ lệ. Prompt luôn được gửi dù I2V cho phép bỏ prompt.

```json
{
  "model": "xai/grok-imagine-video",
  "prompt": "Continue naturally from this exact image. Preserve the same person, face, age, hair, skin tone, clothing, body proportions, product details, background, lighting, color grade, and camera height. The subject slowly turns toward the window while the camera makes a very subtle push-in. No cut, morph, transformation, new object, wardrobe change, text, or logo change. End on a stable pose suitable for continuation.",
  "image": {
    "url": "https://assets.example.com/canonical-start-frame.jpg"
  },
  "duration": 12,
  "resolution": "720p",
  "storage_options": {
    "filename": "project-seed-0000.mp4",
    "expires_after": 604800
  }
}
```

Nếu ảnh đã là `16:9`, có thể thêm `"aspect_ratio":"16:9"`; nếu không chắc, omit để tránh stretch.

## Payload R2V khuyến nghị

```json
{
  "model": "xai/grok-imagine-video",
  "prompt": "The person from <IMAGE_1> keeps exactly the same face, age, hair, skin tone, and body proportions. They wear exactly the clothing from <IMAGE_2>. Preserve the product shape, colors, materials, markings, and proportions from <IMAGE_3>. Medium shot in a clean studio, soft side light, 35mm lens, slow controlled camera push-in. The subject gently lifts the product and looks at it. No cut, morph, identity change, wardrobe change, product redesign, extra text, or extra person. End on a stable pose suitable for continuation.",
  "reference_images": [
    { "url": "https://assets.example.com/person.jpg" },
    { "url": "https://assets.example.com/clothing.jpg" },
    { "url": "https://assets.example.com/product.jpg" }
  ],
  "duration": 12,
  "aspect_ratio": "16:9",
  "resolution": "720p",
  "storage_options": {
    "filename": "project-seed-0000.mp4",
    "expires_after": 604800
  }
}
```

Không thêm field `image` vào request R2V này.

## Payload extension khuyến nghị

```json
{
  "model": "xai/grok-imagine-video",
  "prompt": "Continue uninterrupted from the exact final frame. CONTINUITY LOCK: same person, face, age, hair, skin tone, body proportions, clothing, product geometry, location, 35mm lens, camera height, soft side light, color grade, and motion speed. No cut, reset, morph, identity change, wardrobe change, product redesign, new object, extra person, text, or logo change. NEXT ACTION ONLY: the subject slowly places the product on the table and rests both hands beside it; the camera remains steady. End in a stable held pose suitable for the next continuation.",
  "duration": 6,
  "video": {
    "file_id": "file_LAST_ACCEPTED_CHECKPOINT"
  },
  "storage_options": {
    "filename": "project-extension-0001.mp4",
    "expires_after": 604800
  }
}
```

Giữ nguyên block `CONTINUITY LOCK` qua mọi extension. Chỉ thay phần `NEXT ACTION ONLY`.

## Cách gọi qua 9Router

### Submit seed I2V/R2V

Lưu payload ở `seed.request.json`, sau đó:

```bash
curl_exit=0
curl --silent --show-error --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/videos/generations" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  -D seed.headers \
  --data-binary @seed.request.json \
  --output seed.create.json || curl_exit=$?

if [[ "$curl_exit" -ne 0 ]]; then
  printf 'SUBMIT_FAILED_OR_UNKNOWN: do not retry automatically\n' >&2
  exit 1
fi

REQUEST_ID="$(jq -r '.request_id // empty' seed.create.json)"
CHAIN_CONNECTION_ID="$(tr -d '\r' < seed.headers | awk -F ': ' \
  'tolower($1) == "x-9router-connection-id" { print $2 }' | tail -n 1)"

if [[ -z "$REQUEST_ID" || -z "$CHAIN_CONNECTION_ID" ]]; then
  printf 'SUBMIT_UNKNOWN: missing request or connection ID; do not retry automatically\n' >&2
  exit 1
fi
```

Nếu POST timeout, connection reset, client interruption, response bị truncate hoặc trả `5xx` mà không có `request_id`, không tự submit lại. Job có thể đã được tạo upstream. Synchronous `400/401/403/422/429` cho biết request bị từ chối, nhưng caller vẫn không nên retry mù; sửa nguyên nhân và tạo một operation mới có kiểm soát.

### Poll

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "x-connection-id: $CHAIN_CONNECTION_ID" \
  -D poll.headers \
  "$NINEROUTER_URL/v1/videos/$REQUEST_ID" \
  --output poll.json

jq '{status,progress,error,video,usage}' poll.json

POLL_CONNECTION_ID="$(tr -d '\r' < poll.headers | awk -F ': ' \
  'tolower($1) == "x-9router-connection-id" { print $2 }' | tail -n 1)"

if [[ -z "$POLL_CONNECTION_ID" || "$POLL_CONNECTION_ID" != "$CHAIN_CONNECTION_ID" ]]; then
  printf 'AFFINITY_LOST: stop the chain\n' >&2
  exit 1
fi
```

Lặp mỗi 5 giây đến `done`, `failed` hoặc `expired`. Đặt deadline tổng khoảng 10-15 phút tùy duration/resolution.

### Submit extension

Lưu payload ở `extend-0001.request.json`, sau đó:

```bash
curl_exit=0
curl --silent --show-error --fail-with-body \
  -X POST "$NINEROUTER_URL/v1/videos/extensions" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "x-connection-id: $CHAIN_CONNECTION_ID" \
  -H "Content-Type: application/json" \
  -D extend-0001.headers \
  --data-binary @extend-0001.request.json \
  --output extend-0001.create.json || curl_exit=$?

if [[ "$curl_exit" -ne 0 ]]; then
  printf 'SUBMIT_FAILED_OR_UNKNOWN: do not retry automatically\n' >&2
  exit 1
fi

EXTEND_REQUEST_ID="$(jq -r '.request_id // empty' extend-0001.create.json)"
EXTEND_CONNECTION_ID="$(tr -d '\r' < extend-0001.headers | awk -F ': ' \
  'tolower($1) == "x-9router-connection-id" { print $2 }' | tail -n 1)"

if [[ -z "$EXTEND_REQUEST_ID" || -z "$EXTEND_CONNECTION_ID" ]]; then
  printf 'SUBMIT_UNKNOWN: missing request or connection ID; do not retry automatically\n' >&2
  exit 1
fi

if [[ "$EXTEND_CONNECTION_ID" != "$CHAIN_CONNECTION_ID" ]]; then
  printf 'AFFINITY_LOST: stop the chain\n' >&2
  exit 1
fi
```

Poll `EXTEND_REQUEST_ID`, kiểm tra poll response connection, QA output, rồi dùng chính output đã được duyệt làm `video` của extension tiếp theo. Mismatch sau extension POST là phát hiện hậu kiểm; job có thể đã được accept trước khi mismatch được thấy.

## Công thức duration

Vì output extension là cumulative:

```text
total_duration = seed_duration + sum(extension_duration_i)
```

Ví dụ **giả định, chưa live-test end-to-end** cho target 60 giây; arithmetic chỉ đúng nếu xAI chấp nhận đủ tám extension và chưa chạm một giới hạn cumulative không được công bố:

| Bước | Duration mới | Output kỳ vọng |
|---:|---:|---:|
| Seed | 12 giây | 12 giây |
| Extend 1 | +6 | 18 giây |
| Extend 2 | +6 | 24 giây |
| Extend 3 | +6 | 30 giây |
| Extend 4 | +6 | 36 giây |
| Extend 5 | +6 | 42 giây |
| Extend 6 | +6 | 48 giây |
| Extend 7 | +6 | 54 giây |
| Extend 8 | +6 | 60 giây |

Sau mỗi step, xác nhận `.video.duration` gần bằng duration kỳ vọng trước khi tiếp tục.

## Prompt strategy chống drift

Mỗi prompt extension nên có bốn phần cố định:

```text
CONTINUE:
Continue uninterrupted from the exact final frame.

CONTINUITY LOCK:
[Nhân vật, khuôn mặt, tuổi, tóc, da, tỷ lệ cơ thể, trang phục,
sản phẩm, môi trường, lens, camera, ánh sáng, palette, tốc độ chuyển động.]

NEXT ACTION ONLY:
[Một hành động vật lý ngắn và tối đa một chuyển động camera.]

END FRAME:
End in a stable held pose suitable for the next continuation.
```

Thực hành nên áp dụng:

- Lặp nguyên văn `CONTINUITY LOCK` ở mọi bước.
- Không thêm adjective style mới giữa chuỗi.
- Mỗi segment chỉ có một hành động chính.
- Tránh cut, teleport, morph, thay đồ, chuyển bối cảnh hoặc nhiều người mới.
- Kết thúc ở frame rõ mặt/chủ thể, ít motion blur và không bị occlusion.
- Nếu output drift, reject và branch lại từ parent tốt gần nhất; không extend output đã drift.
- Không dùng seed prompt như một kịch bản dài nhiều hành động. Chia hành động theo segment.

Prompt giúp giảm drift nhưng không tạo guarantee về identity.

## QA gate sau mỗi job

Chỉ đánh dấu checkpoint `ACCEPTED` khi đạt tất cả điều kiện:

| Kiểm tra | Điều kiện |
|---|---|
| Job | `status == "done"` |
| Moderation | `video.respect_moderation == true` |
| Asset | Có `file_output.file_id`, caller-owned URL hoặc đã download thành công |
| Duration | Gần `parent_duration + requested_extension_duration` |
| Connection | Không thay đổi chain connection |
| Identity | Khuôn mặt/chủ thể không drift quá threshold |
| Product/wardrobe | Hình dáng, màu, logo, chi tiết chính giữ nguyên |
| Continuity | Không jump cut, reset pose, duplicate subject hoặc camera discontinuity |
| Prompt | Hành động mới xảy ra đúng và không thêm hành động ngoài yêu cầu |
| Cost | `usage.cost_in_usd_ticks` nằm trong budget còn lại |

Có thể tự động hóa QA bằng vision/video model, nhưng vẫn nên review thủ công ở các mốc quan trọng.

## State machine production

| State | Hành động |
|---|---|
| `DRAFT` | Lưu reference canonical, continuity bible, shot plan, target duration và budget |
| `PREFLIGHT` | Validate URL/file, MIME, ratio, mode I2V/R2V và dedicated connection |
| `READY_TO_SUBMIT` | Ghi operation ID, payload hash, parent ID và expected connection vào DB |
| `SUBMITTING` | Chỉ một worker được POST operation đó |
| `SUBMIT_UNKNOWN` | POST timeout/mất kết nối mà không có request ID; không auto-retry |
| `ACCEPTED` | Lưu `request_id`, connection ID, payload hash và parent |
| `POLLING` | GET mỗi khoảng 5 giây với connection đã lưu |
| `DONE_UNPERSISTED` | Job done nhưng chưa xác nhận asset bền vững |
| `QA_PENDING` | Chấm identity, continuity, duration, moderation và cost |
| `REJECTED` | Quay lại parent tốt gần nhất; retry là operation billable mới |
| `ACCEPTED_CHECKPOINT` | Khóa checkpoint làm parent duy nhất của bước sau |
| `EXTEND_READY` | Tạo payload extension từ checkpoint đã duyệt |
| `AFFINITY_LOST` | Connection đổi; dừng để tránh mất access/file hoặc split billing |
| `BUDGET_STOP` | Không submit nếu worst-case cost vượt budget |
| `FINAL` | Download master, hash, verify duration và dọn branch bị reject |

Dùng uniqueness constraint hoặc lease để hai worker không cùng extend một chain head.

## Billing và capacity planning

Giá xAI công bố tại ngày phân tích:

| Model | Giá |
|---|---:|
| `grok-imagine-video` | `0,050 USD/giây` |
| `grok-imagine-video-1.5` | `0,080 USD/giây` |

Điểm chưa rõ: docs không nói extension tính phí chỉ theo số giây mới hay theo toàn bộ cumulative output được render/trả về.

Ví dụ 60 giây với seed 12 giây và 8 extension x 6 giây:

| Cách tính giả định | Rendered/billed seconds | Cost ở `0,05 USD/s` |
|---|---:|---:|
| Chỉ tính giây mới | 60 | 3,00 USD |
| Mỗi output cumulative đều bị tính toàn bộ | 12+18+24+30+36+42+48+54+60 = 324 | 16,20 USD |

Đây là hai biên để lập budget, không phải kết luận billing của xAI. Hãy chạy một extension ngắn, lưu `usage.cost_in_usd_ticks`, rồi xác định cách tính thực tế trước khi scale.

Trong benchmark trước đó, generation 2 giây trả `1.000.000.000` ticks, tương ứng `0,10 USD`, khớp `0,05 USD/s`. Chưa có live extension cost để xác nhận công thức extension.

Các rủi ro billing khác:

- 9Router có thể rotate account sau synchronous `401`, `403` hoặc `429`.
- Core có thể refresh OAuth và resend một lần sau `401/403`.
- `Idempotency-Key` được forward nhưng xAI docs không cam kết deduplication video.
- POST timeout không chứng minh job chưa được tạo.
- Retry một extension bị reject tạo job và cost mới.
- Giữ mọi cumulative output làm tăng storage theo chuỗi.

## Những gì đã xác nhận và chưa xác nhận

| Finding | Mức xác nhận |
|---|---|
| 9Router route `/v1/videos/extensions` tồn tại | Source + live validation probe |
| Body extension được forward tới xAI | Source + live `422 missing prompt` probe |
| `reference_images` và `storage_options` được forward | Source-backed; chưa live-test |
| I2V dùng ảnh làm frame mở đầu | Official xAI contract |
| R2V dùng một hoặc nhiều reference mà không khóa frame đầu | Official xAI contract |
| `image` và `reference_images` không dùng cùng request | Official xAI contract |
| Extension trả input + đoạn mới | Official xAI contract |
| Segment extension dài 2-10 giây | Official xAI contract |
| Repeat extension tạo video dài tùy ý | Không được guarantee |
| Maximum cumulative duration | Không được công bố |
| Maximum số lần extension | Không được công bố |
| Reference fidelity qua nhiều extension | Model-dependent, không định lượng |
| Maximum số reference images | Không được công bố |
| Exact ephemeral URL TTL | Không được công bố |
| Extension billing chỉ tính giây mới | Không được công bố |
| Live I2V qua instance hiện tại | Chưa test billable |
| Live R2V qua instance hiện tại | Chưa test billable |
| Live extension render qua instance hiện tại | Chưa test billable |
| `storage_options` qua Grok OAuth | Chưa test |

## Đề xuất cập nhật `9router-video` skill

Skill hiện tại nên bổ sung:

1. Phân biệt rõ I2V `image` và R2V `reference_images`.
2. Ghi `image` và `reference_images` loại trừ lẫn nhau.
3. Mô tả extension duration là phần mới và output là cumulative.
4. Bổ sung `storage_options`, `file_output.file_id` và URL lifetime.
5. Ghi status `expired` là terminal.
6. Cảnh báo extension không nhận lại reference, nên có drift.
7. Ghi giới hạn generation 1-15 giây và extension 2-10 giây.
8. Cảnh báo không có maximum cumulative duration được công bố.
9. Ghi connection pinning là soft preference trong implementation hiện tại.
10. Sửa mô tả retry: handler cấp app có thể rotate account trên `401/403/429`.
11. Nêu CLI chỉ hỗ trợ generation/I2V, không hỗ trợ R2V hoặc extension.
12. Nêu `Idempotency-Key` không phải guarantee chống duplicate billing.

## Quyết định nên dùng

Cho nhu cầu “video phải đúng hình ảnh reference”:

- Dùng **I2V từ một ảnh canonical hoàn chỉnh** nếu bố cục/frame đầu và chi tiết phải chính xác nhất.
- Dùng **R2V** nếu cần kết hợp nhiều ảnh cho identity, outfit, product hoặc style.
- Dùng **extension cho continuity trong cùng shot**, không coi nó là công cụ duy trì reference vô hạn.
- Với video dài, re-anchor bằng I2V/R2V ở đầu mỗi shot và ghép hậu kỳ là phương án ít drift hơn.
- Trước khi scale, live-test một I2V/R2V seed và một extension 4-6 giây có `storage_options`, rồi đọc cost thực tế từ `usage.cost_in_usd_ticks`.
