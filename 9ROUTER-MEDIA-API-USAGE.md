---
name: 9router-media-api-usage
description: Hướng dẫn cho AI Agent sử dụng 9Router để tạo/sửa ảnh và tạo/sửa/nối dài video. Dùng khi cần gọi trực tiếp 9Router Media REST API an toàn.
compatibility: 9Router v0.5.35, commit bc252ea80298d4879dc6b3c69585af1610d2c76f
---

# 9Router Media API Usage

Tài liệu này là runbook dành cho AI Agent. Làm đúng contract, validation và quy tắc an toàn bên dưới. Không tự suy đoán model, không tự retry POST media có thể tính phí, và không tiếp tục chuỗi video nếu checkpoint chưa được kiểm tra.

Các shell block là ví dụ Bash. Khi chạy qua nhiều tool invocation/process, không dựa vào biến của block trước; phải đọc state từ file JSON như hướng dẫn ở phần video.

## 1. Biến môi trường

```bash
export NINEROUTER_URL="http://localhost:20128"
export NINEROUTER_KEY="sk-..."
```

Chuẩn hóa URL trước khi ghép path:

```bash
NINEROUTER_URL="${NINEROUTER_URL%/}"
```

Thiết lập shell an toàn nếu chạy dưới dạng script:

```bash
set -Eeuo pipefail
umask 077
: "${NINEROUTER_URL:?Missing NINEROUTER_URL}"
: "${NINEROUTER_KEY:?Missing NINEROUTER_KEY}"
NINEROUTER_URL="${NINEROUTER_URL%/}"
```

Health check, ghi qua temporary file để không đọc nhầm response cũ:

```bash
tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM

curl --silent --show-error --fail-with-body \
  --connect-timeout 10 --max-time 30 \
  "$NINEROUTER_URL/api/health" \
  --output "$tmp"

jq -e 'type == "object" and .ok == true' "$tmp" >/dev/null
mv -- "$tmp" health.json
trap - EXIT HUP INT TERM
```

Luôn gửi key khi gọi qua remote/tunnel/VPS. Middleware bắt buộc valid API key cho remote `/v1`, kể cả khi setting handler `requireApiKey` tắt. Loopback local có thể qua middleware không cần key, nhưng handler vẫn có thể yêu cầu key nếu setting bật.

```http
Authorization: Bearer $NINEROUTER_KEY
```

Dependencies cho các shell recipe:

```text
bash, curl, jq, file, base64, awk, mktemp, date, readlink, sync
```

Cho workflow video cần thêm `flock`, `sha256sum`, `ffprobe` và `ffmpeg`; `ffmpeg` được dùng để decode-test output, không chỉ ghép shot. Agent phải preflight dependency trước khi tạo job billable:

```bash
for cmd in curl jq file base64 awk mktemp date readlink sync; do
  command -v "$cmd" >/dev/null || { printf 'Missing command: %s\n' "$cmd" >&2; exit 1; }
done

for cmd in flock sha256sum ffprobe ffmpeg; do
  command -v "$cmd" >/dev/null || { printf 'Missing video command: %s\n' "$cmd" >&2; exit 1; }
done
```

## 2. Endpoint

| Capability | Endpoint |
|---|---|
| Discovery model ảnh | `GET /v1/models/image` |
| Metadata model | `GET /v1/models/info?id={model}` |
| Tạo ảnh | `POST /v1/images/generations` |
| Sửa ảnh Codex | `POST /v1/images/generations` với `image` hoặc `images[]` |
| Text-to-video | `POST /v1/videos/generations` |
| Image-to-video | `POST /v1/videos/generations` với `image` |
| Reference-to-video | `POST /v1/videos/generations` với `reference_images[]` |
| Sửa video | `POST /v1/videos/edits` |
| Nối dài video | `POST /v1/videos/extensions` |
| Poll video job | `GET /v1/videos/{request_id}` |

## 3. Model

### Ảnh

Luôn discovery trước khi chọn model. Endpoint này được dựng từ active connections, static registry, enabled models, custom models và model aliases; unknown model ID có thể được suy luận là image bằng tên:

```bash
tmp="$(mktemp)"
curl --silent --show-error --fail-with-body \
  --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  "$NINEROUTER_URL/v1/models/image" \
  --output "$tmp"

jq -e 'type == "object" and (.data | type == "array")' "$tmp" >/dev/null
mv -- "$tmp" image-models.json
jq -r '.data[].id' image-models.json
```

Xem metadata:

```bash
MODEL="cx/gpt-5.4-image"

tmp="$(mktemp)"
curl --silent --show-error --fail-with-body -G \
  --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  --data-urlencode "id=$MODEL" \
  "$NINEROUTER_URL/v1/models/info" \
  --output "$tmp"

jq -e 'type == "object"' "$tmp" >/dev/null
mv -- "$tmp" model-info.json
jq . model-info.json
```

`/v1/models/info` chỉ tra static registry. Nó có thể trả `404` cho enabled/custom/dynamic model đang có trong `/v1/models/image`; `404` ở info không tự động có nghĩa POST sẽ fail.

Model thường dùng:

| Model | Use case |
|---|---|
| `ag/gemini-3.1-flash-image` | Text-to-image đơn giản |
| `cx/gpt-5.4-image` | Tạo ảnh và sửa ảnh |
| `cx/gpt-5.5-image` | Tạo ảnh và sửa ảnh |
| `xai/grok-imagine-image` | Tạo ảnh xAI; có thể chưa xuất hiện trong catalog cũ |

Không dùng `xai/grok-2-image-1212`; model đã bị upstream thay thế bởi `grok-imagine-image`.

Catalog không đảm bảo account thực sự có quyền dùng model, và model được suy luận là ảnh chưa chắc provider có image adapter. Nếu upstream trả unsupported/model-not-found, đánh dấu model unavailable cho 9Router instance/request context hiện tại và yêu cầu operator kiểm tra connections. Image response không trả serving connection ID, nên agent không được quy lỗi cho một connection cụ thể trừ khi instance chỉ có một connection.

### Image provider/adapters

Chỉ các provider sau có adapter ở `/v1/images/generations`:

| Provider/alias | Adapter behavior |
|---|---|
| `openai`, `minimax`, `openrouter`, `recraft`, `vercel-ai-gateway`, `xai` | OpenAI-compatible JSON; provider config có thể whitelist fields |
| `gemini` | Chỉ prompt; trả `b64_json` |
| `ag`/`antigravity` | Executor riêng; chỉ dùng text-to-image |
| `cx`/`codex` | ChatGPT Codex SSE; text-to-image và edit |
| `hf`/`huggingface` | Prompt-only; upstream binary được normalize thành base64 |
| `nb`/`nanobanana` | Async nội bộ; text-to-image và image edit URL inputs |
| `fal`/`fal-ai` | Async nội bộ; `image` cho img2img |
| `stability`/`stability-ai` | `size` thành aspect ratio, `style`, `output_format` |
| `bfl`/`black-forest-labs` | Async nội bộ; exact width/height, optional `image` |
| `runway`/`runwayml` | Async image adapter; image/reference behavior phụ thuộc model |
| `cf`/`cloudflare-ai` | Text-to-image, img2img, mask/inpainting theo model |
| `sdwebui` | Local no-auth, txt2img |
| `comfyui` | Placeholder adapter; graph workflow đầy đủ chưa được implement |

Không gọi image generation chỉ vì provider registry có `serviceKinds:["image"]`. Ví dụ registry Venice có image models/config nhưng không có adapter trong version này, nên POST trả provider unsupported. OpenRouter có adapter/config nhưng registry `serviceKinds` hiện thiếu `image`, nên có thể không xuất hiện trong `/v1/models/image` dù explicit provider/model vẫn route được.

### Video

Model:

```text
xai/grok-imagine-video
```

Không phụ thuộc hoàn toàn vào `/v1/models/video`; một số 9Router version có route video nhưng chưa expose video discovery đúng.

Metadata probe:

```bash
curl --silent --show-error --fail-with-body -G \
  --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  --data-urlencode "id=xai/grok-imagine-video" \
  "$NINEROUTER_URL/v1/models/info" \
  --output video-model-info.json
```

## 4. Tạo ảnh

### Request fields

| Field | Required | Ghi chú |
|---|---:|---|
| `model` | Có | Model ID |
| `prompt` | Có | Prompt tạo ảnh |
| `n` | Không | Provider-dependent; Codex không dùng |
| `size` | Không | Provider-dependent |
| `quality` | Không | Provider-dependent |
| `background` | Không | Codex/provider-dependent |
| `output_format` | Không | Codex, ví dụ `png` |
| Body `response_format` | Không | Provider-dependent |
| Query `response_format=binary` | Không | 9Router trả raw bytes của ảnh đầu tiên |

Image POST có thể tạo ảnh/tốn quota. 9Router có thể refresh credential rồi resend trên `401/403`, và handler có thể fallback sang account khác trên bất kỳ error được classifier đánh dấu. Client không được tự retry network timeout/`5xx` một cách mù; request đầu có thể đã được upstream xử lý.

Helper binary dùng chung:

```bash
post_image_binary() {
  local request_file="$1"
  local output_base="$2"
  local tmp mime ext

  [[ -s "$request_file" ]] || { printf 'Missing request file: %s\n' "$request_file" >&2; return 1; }
  tmp="$(mktemp)" || return 1

  if ! curl --silent --show-error --fail-with-body \
    --connect-timeout 10 --max-time 600 \
    -X POST "$NINEROUTER_URL/v1/images/generations?response_format=binary" \
    -H "Authorization: Bearer $NINEROUTER_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "@$request_file" \
    --output "$tmp"; then
    rm -f -- "$tmp"
    printf 'IMAGE_SUBMIT_FAILED_OR_UNKNOWN: do not retry automatically\n' >&2
    return 1
  fi

  mime="$(file --brief --mime-type "$tmp")"
  case "$mime" in
    image/png) ext="png" ;;
    image/jpeg) ext="jpg" ;;
    image/webp) ext="webp" ;;
    *)
      printf 'Unexpected image MIME: %s\n' "$mime" >&2
      rm -f -- "$tmp"
      return 1
      ;;
  esac

  mv -- "$tmp" "$output_base.$ext"
  printf '%s\n' "$output_base.$ext"
}
```

### Tạo ảnh Antigravity

Dùng payload tối giản; không kỳ vọng `size`, `n` hoặc `quality` được áp dụng.

```bash
jq -n '{
  model: "ag/gemini-3.1-flash-image",
  prompt: "A cinematic product photo of a red robot on a cream background, soft window light"
}' > image-create.request.json

post_image_binary image-create.request.json image-create
```

### Tạo ảnh Codex

```bash
jq -n '{
  model: "cx/gpt-5.4-image",
  prompt: "A clean editorial poster of a red robot watering one blue sunflower, cream background. Add exactly the text MEDIA LAB at the top.",
  size: "1024x1024",
  quality: "high",
  background: "opaque",
  output_format: "png"
}' > image-create.request.json

post_image_binary image-create.request.json image-create
```

`size` là yêu cầu, không phải guarantee output dimension. Kiểm tra file thực tế.

### Tạo ảnh xAI

```bash
jq -n '{
  model: "xai/grok-imagine-image",
  prompt: "A cinematic product photo of a red robot on a cream background",
  n: 1
}' > image-create.request.json

post_image_binary image-create.request.json image-create
```

Một số catalog cũ chưa liệt kê `xai/grok-imagine-image`. Nếu router bắt đầu enforce catalog và trả lỗi, cập nhật registry/9Router thay vì quay lại model xAI cũ.

### Xác định MIME và extension

Không tin tuyệt đối vào HTTP `Content-Type`. Helper `post_image_binary` sniff magic bytes bằng `file` trước khi promote temporary output.

### JSON response

Bỏ query binary nếu cần JSON:

```bash
tmp="$(mktemp)"
if ! curl --silent --show-error --fail-with-body \
  --connect-timeout 10 --max-time 600 \
  -X POST "$NINEROUTER_URL/v1/images/generations" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @image-create.request.json \
  --output "$tmp"; then
  rm -f -- "$tmp"
  printf 'IMAGE_SUBMIT_FAILED_OR_UNKNOWN: do not retry automatically\n' >&2
  exit 1
fi

jq -e 'type == "object" and (.data | type == "array") and (.data | length > 0)' "$tmp" >/dev/null
mv -- "$tmp" image-create.response.json
```

Client phải xử lý cả:

```json
{"data":[{"url":"https://..."}]}
```

và:

```json
{"data":[{"b64_json":"..."}]}
```

## 5. Sửa ảnh

Sửa ảnh Codex dùng cùng endpoint:

```text
POST /v1/images/generations
```

### Một ảnh local

Ưu tiên data URI. Không giả định Codex image backend tải được remote image URL.

```bash
SOURCE_IMAGE="source.jpg"
SOURCE_MIME="$(file --brief --mime-type "$SOURCE_IMAGE")"

case "$SOURCE_MIME" in
  image/png|image/jpeg|image/webp) ;;
  *) printf 'Unsupported source MIME: %s\n' "$SOURCE_MIME" >&2; exit 1 ;;
esac

image_tmp="$(mktemp)"
request_tmp="$(mktemp)"
trap 'rm -f -- "$image_tmp" "$request_tmp"' EXIT HUP INT TERM

base64 --wrap=0 "$SOURCE_IMAGE" > "$image_tmp"

jq -n \
  --arg model "cx/gpt-5.4-image" \
  --arg prompt "Change only the blue flower to bright yellow. Preserve the robot, pot, background, composition, lighting, and all existing text. Add no new text." \
  --arg mime "$SOURCE_MIME" \
  --rawfile image "$image_tmp" \
  '{
    model: $model,
    prompt: $prompt,
    image: ("data:" + $mime + ";base64," + $image),
    image_detail: "high",
    output_format: "png"
  }' > "$request_tmp"

mv -- "$request_tmp" image-edit.request.json
rm -f -- "$image_tmp"
trap - EXIT HUP INT TERM

post_image_binary image-edit.request.json image-edit
```

Helper đã sniff MIME trước khi rename output.

### Nhiều ảnh reference

`images[]` là array string. Mỗi string là data URI, remote URL hoặc raw base64.

```json
{
  "model": "cx/gpt-5.4-image",
  "prompt": "Use image 1 as the main composition and image 2 as the product reference. Replace only the product; preserve the lighting, background, text, and camera.",
  "images": [
    "data:image/jpeg;base64,...",
    "data:image/png;base64,..."
  ],
  "image_detail": "high",
  "output_format": "png"
}
```

### Prompt edit

```text
CHANGE ONLY:
[Chi tiết phải thay đổi.]

PRESERVE EXACTLY:
[Identity, face, product geometry, wardrobe, background, composition,
lighting, color, camera, text/logo và tỷ lệ.]

DO NOT ADD:
[Text, object, person hoặc style mới.]
```

Không dùng `ag/gemini-3.1-flash-image` để edit nếu metadata chỉ có `textToImage`.

## 6. Codex image SSE

Muốn nhận progress/partial image:

```bash
curl --no-buffer --silent --show-error --fail-with-body \
  --connect-timeout 10 --max-time 600 \
  -X POST "$NINEROUTER_URL/v1/images/generations" \
  -H "Authorization: Bearer $NINEROUTER_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  --data-binary @image-create.request.json
```

Event:

- `progress`
- `partial_image`
- `done`
- `error`

Không kết hợp SSE với query `?response_format=binary`. HTTP `200` vẫn có thể chứa event `error`; SSE consumer chỉ được báo thành công sau event `done` và phải fail khi nhận `error`.

## 7. Video job contract

Ba video POST đều tạo operation async có thể tính phí:

```text
POST /v1/videos/{generations|edits|extensions}
-> JSON body có request_id
-> response header x-9router-connection-id

GET /v1/videos/{request_id}
-> trạng thái và output do xAI trả về
```

9Router không enforce enum status; nó pass-through JSON upstream. Xử lý chặt như sau:

| Status | Phân loại |
|---|---|
| `pending`, `processing` | Non-terminal; poll tiếp |
| `done`, `completed` | Terminal success; vẫn phải persist và QA |
| `failed`, `error`, `expired`, `cancelled` | Terminal failure; không resubmit tự động |
| Thiếu/khác các giá trị trên | Protocol error; dừng thay vì poll vô hạn |

`completed`, `error` và `cancelled` được CLI trong repo nhận biết để chịu được response variant; contract xAI thường dùng `pending`, `done`, `failed`, `expired`.

Mỗi operation phải có state JSON tồn tại trước khi gửi POST. Không dùng lại tên operation, không giữ `request_id` hoặc connection ID chỉ trong biến shell, và không overwrite evidence của lần submit trước.

## 8. Khởi tạo durable operation

### Biến bắt buộc

Mỗi operation có một directory riêng. State chịu được việc agent chạy block tiếp theo trong process mới:

```bash
export OPERATIONS_DIR="$PWD/.9router-video/my-project/operations"
mkdir --parents --mode=700 -- "$OPERATIONS_DIR"
export OP_DIR="$OPERATIONS_DIR/0000-seed"
export ACTION="generations"                  # generations | edits | extensions
export REQUEST_FILE="$PWD/video.request.json"
export EXPECTED_DURATION_SECONDS="8"
export BUDGET_LIMIT_TICKS="50000000000"
export MAX_OPERATION_TICKS="8000000000"
export POST_TERMINAL_RESERVATION_TICKS="1000000000"
export CHAIN_ACCOUNTED_TICKS="0"
export BUDGET_LEDGER_REF="billing-ledger://my-project/revision-1"
export BUDGET_RESERVATION_CONFIRMED="true"
export BUDGET_RESERVATION_EXPIRES_AT="$(( $(date +%s) + 1800 ))"
export DEDICATED_XAI_CONNECTION="true"
export PARENT_STATE=""                       # bắt buộc cho extensions
export MIN_PARENT_TTL_SECONDS="3600"
export EXTERNAL_FILE_CONNECTION_ID=""         # bắt buộc nếu request dùng file_id ngoài chain
export EXTERNAL_FILE_VALID_UNTIL=""           # Unix epoch vận hành, bắt buộc cùng external file_id
export EXTERNAL_VIDEO_DURATION_SECONDS=""      # bắt buộc cho edit video ngoài accepted parent
export EXTERNAL_VIDEO_METADATA_CONFIRMED="false" # bắt buộc cho external edit file_id
export EXTERNAL_URLS_IMMUTABLE_CONFIRMED="true" # object-version URL hoặc immutable content policy
export FILES_CLEANUP_CONFIRMED="true"          # bắt buộc nếu request có storage_options
export MIN_IDENTITY_SCORE="90"
export MIN_PRODUCT_SCORE="90"
export MIN_CONTINUITY_SCORE="90"
export MIN_ACTION_SCORE="85"
export QA_EXEMPTION_REASON=""                  # bắt buộc nếu threshold nào bằng 0
```

`MAX_OPERATION_TICKS` là reservation worst-case tổng của operation. `POST_TERMINAL_RESERVATION_TICKS` là phần vẫn phải giữ sau khi có request usage, dành cho storage retention/download/cleanup chưa phát sinh. `BUDGET_LIMIT_TICKS` là budget toàn chain. `CHAIN_ACCOUNTED_TICKS` phải được đọc từ billing transaction như số đã account trước reservation hiện tại; nó bao gồm actual cost của mọi branch đã chạy cộng reservation của mọi operation khác đang chạy hoặc mơ hồ, không chỉ cost của accepted parent. `BUDGET_LEDGER_REF` xác định transaction/revision đã atomically reserve operation hiện tại. Với extension, không giả định upstream chỉ tính phần mới; lấy giá hiện hành từ xAI thay vì hard-code giá trong agent.

Operation state không thay thế chain-wide billing ledger. Trước khi chạy init, orchestrator phải conditionally reserve `MAX_OPERATION_TICKS`, trả về reference và lease expiry, rồi set `BUDGET_RESERVATION_CONFIRMED=true`. Nếu init không publish được operation directory, orchestrator phải release reservation. Submit mơ hồ giữ nguyên toàn reservation. Sau terminal response, ledger thay compute reservation bằng actual ticks nếu có nhưng tiếp tục giữ `POST_TERMINAL_RESERVATION_TICKS` cho tới khi storage/download/cleanup được settle. Các shell block chỉ verify và ghi local accounting; chúng không update external ledger.

`DEDICATED_XAI_CONNECTION=true` là invariant vận hành của operator rằng 9Router instance/worker này chỉ có một xAI connection. Dashboard provider API có thể inspect connection hiện tại, nhưng không có public `/v1` endpoint hoặc atomic lease ngăn connection khác được thêm sau khi kiểm tra. Bắt buộc invariant đó cho extension production vì `x-connection-id` chỉ là soft preference.

### Tạo operation và write-ahead state

Block này canonicalize request, kiểm tra payload/parent, verify external budget reservation và atomically publish operation directory chứa `request.json`/`state.json`. Nó không gọi 9Router API và không tự update billing ledger:

```bash
set -Eeuo pipefail
umask 077

: "${OP_DIR:?Missing OP_DIR}"
: "${ACTION:?Missing ACTION}"
: "${REQUEST_FILE:?Missing REQUEST_FILE}"
: "${EXPECTED_DURATION_SECONDS:?Missing EXPECTED_DURATION_SECONDS}"
: "${BUDGET_LIMIT_TICKS:?Missing BUDGET_LIMIT_TICKS}"
: "${MAX_OPERATION_TICKS:?Missing MAX_OPERATION_TICKS}"
: "${POST_TERMINAL_RESERVATION_TICKS:?Missing POST_TERMINAL_RESERVATION_TICKS}"
: "${CHAIN_ACCOUNTED_TICKS:?Missing CHAIN_ACCOUNTED_TICKS}"
: "${BUDGET_LEDGER_REF:?Missing BUDGET_LEDGER_REF}"
: "${BUDGET_RESERVATION_CONFIRMED:?Missing BUDGET_RESERVATION_CONFIRMED}"
: "${BUDGET_RESERVATION_EXPIRES_AT:?Missing BUDGET_RESERVATION_EXPIRES_AT}"
: "${DEDICATED_XAI_CONNECTION:?Missing DEDICATED_XAI_CONNECTION}"
PARENT_STATE="${PARENT_STATE:-}"
MIN_PARENT_TTL_SECONDS="${MIN_PARENT_TTL_SECONDS:-3600}"
EXTERNAL_FILE_CONNECTION_ID="${EXTERNAL_FILE_CONNECTION_ID:-}"
EXTERNAL_FILE_VALID_UNTIL="${EXTERNAL_FILE_VALID_UNTIL:-}"
EXTERNAL_VIDEO_DURATION_SECONDS="${EXTERNAL_VIDEO_DURATION_SECONDS:-}"
EXTERNAL_VIDEO_METADATA_CONFIRMED="${EXTERNAL_VIDEO_METADATA_CONFIRMED:-false}"
EXTERNAL_URLS_IMMUTABLE_CONFIRMED="${EXTERNAL_URLS_IMMUTABLE_CONFIRMED:-false}"
FILES_CLEANUP_CONFIRMED="${FILES_CLEANUP_CONFIRMED:-false}"
MIN_IDENTITY_SCORE="${MIN_IDENTITY_SCORE:-90}"
MIN_PRODUCT_SCORE="${MIN_PRODUCT_SCORE:-90}"
MIN_CONTINUITY_SCORE="${MIN_CONTINUITY_SCORE:-90}"
MIN_ACTION_SCORE="${MIN_ACTION_SCORE:-85}"
QA_EXEMPTION_REASON="${QA_EXEMPTION_REASON:-}"

is_tick_value() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,14})$ ]] && (( 10#$1 <= 1000000000000000 ))
}

is_score() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$1 <= 100 ))
}

case "$ACTION" in
  generations|edits|extensions) ;;
  *) printf 'Invalid ACTION: %s\n' "$ACTION" >&2; exit 1 ;;
esac

is_tick_value "$BUDGET_LIMIT_TICKS" || { printf 'Invalid budget limit\n' >&2; exit 1; }
is_tick_value "$MAX_OPERATION_TICKS" || { printf 'Invalid operation reservation\n' >&2; exit 1; }
is_tick_value "$POST_TERMINAL_RESERVATION_TICKS" || { printf 'Invalid post-terminal reservation\n' >&2; exit 1; }
is_tick_value "$CHAIN_ACCOUNTED_TICKS" || { printf 'Invalid chain ledger amount\n' >&2; exit 1; }
(( 10#$POST_TERMINAL_RESERVATION_TICKS <= 10#$MAX_OPERATION_TICKS )) || {
  printf 'Post-terminal reservation exceeds total operation reservation\n' >&2
  exit 1
}
[[ "$MIN_PARENT_TTL_SECONDS" =~ ^(0|[1-9][0-9]{0,6})$ ]] || { printf 'Invalid parent TTL requirement\n' >&2; exit 1; }
[[ "$BUDGET_RESERVATION_EXPIRES_AT" =~ ^[1-9][0-9]{8,11}$ ]] || { printf 'Invalid budget lease expiry\n' >&2; exit 1; }
[[ "$BUDGET_RESERVATION_CONFIRMED" == "true" || "$BUDGET_RESERVATION_CONFIRMED" == "false" ]] || {
  printf 'BUDGET_RESERVATION_CONFIRMED must be true or false\n' >&2
  exit 1
}
[[ "$FILES_CLEANUP_CONFIRMED" == "true" || "$FILES_CLEANUP_CONFIRMED" == "false" ]] || {
  printf 'FILES_CLEANUP_CONFIRMED must be true or false\n' >&2
  exit 1
}
[[ "$EXTERNAL_URLS_IMMUTABLE_CONFIRMED" == "true" || "$EXTERNAL_URLS_IMMUTABLE_CONFIRMED" == "false" ]] || {
  printf 'EXTERNAL_URLS_IMMUTABLE_CONFIRMED must be true or false\n' >&2
  exit 1
}
[[ "$EXTERNAL_VIDEO_METADATA_CONFIRMED" == "true" || "$EXTERNAL_VIDEO_METADATA_CONFIRMED" == "false" ]] || {
  printf 'EXTERNAL_VIDEO_METADATA_CONFIRMED must be true or false\n' >&2
  exit 1
}
[[ "$DEDICATED_XAI_CONNECTION" == "true" || "$DEDICATED_XAI_CONNECTION" == "false" ]] || {
  printf 'DEDICATED_XAI_CONNECTION must be true or false\n' >&2
  exit 1
}
(( 10#$MAX_OPERATION_TICKS > 0 )) || { printf 'Reservation must be positive\n' >&2; exit 1; }
for score in "$MIN_IDENTITY_SCORE" "$MIN_PRODUCT_SCORE" "$MIN_CONTINUITY_SCORE" "$MIN_ACTION_SCORE"; do
  is_score "$score" || { printf 'QA thresholds must be integers from 0 to 100\n' >&2; exit 1; }
done
if [[ "$MIN_IDENTITY_SCORE" == "0" || "$MIN_PRODUCT_SCORE" == "0" ||
      "$MIN_CONTINUITY_SCORE" == "0" || "$MIN_ACTION_SCORE" == "0" ]]; then
  [[ -n "$QA_EXEMPTION_REASON" ]] || { printf 'Zero QA threshold requires QA_EXEMPTION_REASON\n' >&2; exit 1; }
fi
request_snapshot="$(mktemp)"
chmod 600 "$request_snapshot"
chmod 600 "$REQUEST_FILE"
trap 'rm -f -- "$request_snapshot"' EXIT HUP INT TERM
jq -S . "$REQUEST_FILE" > "$request_snapshot"
REQUEST_FILE="$request_snapshot"
jq -e 'type == "object"' "$REQUEST_FILE" >/dev/null

case "$ACTION" in
  generations)
    jq -e '
      def image_input:
        type == "object" and (has("url") != has("file_id")) and
        (if has("url") then
           ((.url | type) == "string" and
            (.url | test("^https://[^[:space:]]+$") or
                    test("^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$")))
         else
           ((.file_id | type) == "string" and (.file_id | test("^file_[A-Za-z0-9._~-]+$")))
         end);
      (.model == "xai/grok-imagine-video" or .model == "grok-imagine-video") and
      ((.prompt | type) == "string" and (.prompt | length) > 0) and
      ((.duration // 8) as $d |
        (($d | type) == "number" and ($d | floor) == $d and $d >= 1 and $d <= 15)) and
      ((has("aspect_ratio") | not) or
        (.aspect_ratio | IN("1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"))) and
      ((has("resolution") | not) or
        (.resolution | IN("480p", "720p"))) and
      ((has("image") and has("reference_images")) | not) and
      (has("video") | not) and
      ((has("image") | not) or (.image | image_input)) and
      ((has("reference_images") | not) or
        ((.reference_images | type) == "array" and
         (.reference_images | length) > 0 and
         all(.reference_images[]; image_input))) and
      ((keys - ["model","prompt","duration","aspect_ratio","resolution","image",
                "reference_images","storage_options","output","user"]) | length == 0)
    ' "$REQUEST_FILE" >/dev/null
    ;;
  edits)
    jq -e '
      def video_input:
        type == "object" and (has("url") != has("file_id")) and
         (if has("url") then
           ((.url | type) == "string" and
            (.url | test("^https://[^?#[:space:]]+\\.mp4([?#].*)?$")))
         else
           ((.file_id | type) == "string" and (.file_id | test("^file_[A-Za-z0-9._~-]+$")))
         end);
      (.model == "xai/grok-imagine-video" or .model == "grok-imagine-video") and
      ((.prompt | type) == "string" and (.prompt | length) > 0) and
      (.video | video_input) and
      ([has("duration"), has("aspect_ratio"), has("resolution"),
        has("image"), has("reference_images")] | any | not) and
      ((keys - ["model","prompt","video","storage_options","output","user"]) | length == 0)
    ' "$REQUEST_FILE" >/dev/null
    ;;
  extensions)
    [[ -n "$PARENT_STATE" ]] || { printf 'extensions requires PARENT_STATE\n' >&2; exit 1; }
    [[ "$DEDICATED_XAI_CONNECTION" == "true" ]] || {
      printf 'extensions requires a dedicated single-xAI-connection worker\n' >&2
      exit 1
    }
    jq -e '
      def video_input:
        type == "object" and (has("url") != has("file_id")) and
         (if has("url") then
           ((.url | type) == "string" and
            (.url | test("^https://[^?#[:space:]]+\\.mp4([?#].*)?$")))
         else
           ((.file_id | type) == "string" and (.file_id | test("^file_[A-Za-z0-9._~-]+$")))
         end);
      (.model == "xai/grok-imagine-video" or .model == "grok-imagine-video") and
      ((.prompt | type) == "string" and (.prompt | length) > 0) and
      (.video | video_input) and
      ((.duration // 6) as $d |
        (($d | type) == "number" and ($d | floor) == $d and $d >= 2 and $d <= 10)) and
      ([has("image"), has("reference_images"), has("aspect_ratio"),
        has("resolution")] | any | not) and
      ((keys - ["model","prompt","duration","video","storage_options","output","user"]) | length == 0)
    ' "$REQUEST_FILE" >/dev/null
    ;;
esac

jq -e '
  (has("storage_options") | not) or
  ((.storage_options | type) == "object" and
   (.storage_options.filename | type) == "string" and
   (.storage_options.filename | test("^[A-Za-z0-9._-]+\\.mp4$")) and
   (.storage_options.expires_after | type) == "number" and
   (.storage_options.expires_after | floor) == .storage_options.expires_after and
   .storage_options.expires_after >= 3600 and
   .storage_options.expires_after <= 2592000 and
   ((.storage_options | has("public_url") | not) or
    ((.storage_options.public_url | type) == "object" and
     (.storage_options.public_url.expires_after | type) == "number" and
     (.storage_options.public_url.expires_after | floor) == .storage_options.public_url.expires_after and
     .storage_options.public_url.expires_after >= 3600 and
     .storage_options.public_url.expires_after <= .storage_options.expires_after)))
' "$REQUEST_FILE" >/dev/null

if jq -e 'has("storage_options")' "$REQUEST_FILE" >/dev/null; then
  [[ "$FILES_CLEANUP_CONFIRMED" == "true" ]] || {
    printf 'storage_options requires confirmed Files cleanup before POST\n' >&2
    exit 1
  }
fi

request_uses_file_id="$(jq -r '
  ([.image?.file_id?, .reference_images[]?.file_id?, .video?.file_id?] |
   map(select(type == "string" and length > 0)) | length) > 0
' "$REQUEST_FILE")"
request_uses_https_url="$(jq -r '
  ([.image?.url?, .reference_images[]?.url?, .video?.url?] |
   map(select(type == "string" and startswith("https://"))) | length) > 0
' "$REQUEST_FILE")"

if [[ "$request_uses_https_url" == "true" && "$EXTERNAL_URLS_IMMUTABLE_CONFIRMED" != "true" ]]; then
  printf 'HTTPS media inputs require immutable/versioned content confirmation\n' >&2
  exit 1
fi

while IFS=$'\t' read -r declared_mime payload; do
  [[ -n "$declared_mime" ]] || continue
  decoded="$(mktemp)"
  trap 'rm -f -- "$request_snapshot" "$decoded"' EXIT HUP INT TERM
  printf '%s' "$payload" | base64 --decode > "$decoded"
  actual_mime="$(file --brief --mime-type "$decoded")"
  [[ "$actual_mime" == "$declared_mime" ]] || {
    printf 'Image data URI magic bytes do not match declared MIME\n' >&2
    exit 1
  }
  rm -f -- "$decoded"
  trap 'rm -f -- "$request_snapshot"' EXIT HUP INT TERM
done < <(jq -r '
  [.image?.url?, .reference_images[]?.url?][] | strings |
  select(startswith("data:image/")) |
  capture("^data:(?<mime>image/(?:png|jpeg|webp));base64,(?<payload>.*)$") |
  [.mime,.payload] | @tsv
' "$REQUEST_FILE")

jq -en --argjson expected "$EXPECTED_DURATION_SECONDS" '
  ($expected | type) == "number" and $expected > 0
' >/dev/null

if [[ "$ACTION" == "generations" ]]; then
  jq -en --argjson expected "$EXPECTED_DURATION_SECONDS" \
    --argjson requested "$(jq '.duration // 8' "$REQUEST_FILE")" \
    '$expected == $requested' >/dev/null || {
    printf 'EXPECTED_DURATION_SECONDS must equal generation duration\n' >&2
    exit 1
  }
fi

parent_operation=""
parent_connection=""
parent_spent="0"
parent_input='null'
parent_state_abs=""
input_valid_until=""
parent_state_hash=""
input_sha256=""

if [[ "$ACTION" == "generations" && -n "$PARENT_STATE" ]]; then
  printf 'generations must start a new shot and cannot use PARENT_STATE\n' >&2
  exit 1
fi

if [[ -n "$PARENT_STATE" ]]; then
  [[ "$DEDICATED_XAI_CONNECTION" == "true" ]] || {
    printf 'Any parent-linked operation requires a dedicated single-xAI-connection worker\n' >&2
    exit 1
  }
  parent_state_abs="$(readlink -f -- "$PARENT_STATE")"
  parent_state_hash="$(sha256sum "$parent_state_abs" | awk '{print $1}')"
  jq -e '.phase == "ACCEPTED_CHECKPOINT" and .chain_eligible == true' \
    "$parent_state_abs" >/dev/null
  parent_operation="$(jq -r '.operation_id' "$parent_state_abs")"
  parent_connection="$(jq -r '.connection.chain_id // empty' "$parent_state_abs")"
  parent_spent="$(jq -r '.budget.compute_accounted_after_ticks // .budget.accounted_after_ticks // empty' "$parent_state_abs")"
  parent_input="$(jq -c '.checkpoint.reusable_input // null' "$parent_state_abs")"
  parent_expires="$(jq -r '.checkpoint.reusable_expires_at // empty' "$parent_state_abs")"
  input_valid_until="$parent_expires"
  parent_local_rel="$(jq -r '.checkpoint.local_file // empty' "$parent_state_abs")"
  parent_hash="$(jq -r '.checkpoint.sha256 // empty' "$parent_state_abs")"
  if jq -e '.checkpoint.reusable_input.url | type == "string"' "$parent_state_abs" >/dev/null 2>&1; then
    input_sha256="$parent_hash"
  fi

  [[ -n "$parent_connection" && "$parent_spent" =~ ^[0-9]+$ ]] || {
    printf 'Parent checkpoint lacks durable connection/budget state\n' >&2
    exit 1
  }
  [[ "$parent_input" != "null" ]] || {
    printf 'Parent checkpoint has no reusable file_id or caller-owned URL\n' >&2
    exit 1
  }
  [[ -n "$parent_local_rel" && -n "$parent_hash" ]] || {
    printf 'Parent checkpoint lacks local rollback artifact metadata\n' >&2
    exit 1
  }
  parent_local="$(dirname -- "$parent_state_abs")/$parent_local_rel"
  [[ -s "$parent_local" ]] || { printf 'Parent local rollback artifact is missing\n' >&2; exit 1; }
  [[ "$(sha256sum "$parent_local" | awk '{print $1}')" == "$parent_hash" ]] || {
    printf 'Parent local rollback artifact hash changed\n' >&2
    exit 1
  }
  if [[ -n "$parent_expires" ]]; then
    [[ "$parent_expires" =~ ^[0-9]+$ ]] || { printf 'Parent reusable expiry is invalid\n' >&2; exit 1; }
    (( parent_expires - $(date +%s) >= MIN_PARENT_TTL_SECONDS )) || {
      printf 'Parent reusable input expires too soon\n' >&2
      exit 1
    }
  fi

  if [[ "$ACTION" == "edits" || "$ACTION" == "extensions" ]]; then
    jq -e --argjson input "$parent_input" '.video == $input' "$REQUEST_FILE" >/dev/null || {
      printf 'Request video is not the accepted parent reusable_input\n' >&2
      exit 1
    }
  fi
  if [[ "$ACTION" == "extensions" ]]; then
    jq -en \
      --argjson expected "$EXPECTED_DURATION_SECONDS" \
      --argjson parent "$(jq '.checkpoint.duration_seconds' "$parent_state_abs")" \
      --argjson extension "$(jq '.duration // 6' "$REQUEST_FILE")" \
      '(($expected - ($parent + $extension)) | if . < 0 then -. else . end) <= 0.001' >/dev/null || {
      printf 'EXPECTED_DURATION_SECONDS must equal parent duration plus extension duration\n' >&2
      exit 1
    }
  fi
  if [[ "$ACTION" == "edits" ]]; then
    jq -en \
      --argjson expected "$EXPECTED_DURATION_SECONDS" \
      --argjson parent "$(jq '.checkpoint.duration_seconds' "$parent_state_abs")" \
      '$expected == (if $parent > 8.7 then 8.7 else $parent end)' >/dev/null || {
      printf 'Edit expected duration must equal min(parent duration, 8.7)\n' >&2
      exit 1
    }
  fi
fi

if [[ "$ACTION" == "edits" && -z "$parent_state_abs" ]]; then
  jq -en --argjson source "$EXTERNAL_VIDEO_DURATION_SECONDS" '($source | type) == "number" and $source > 0' >/dev/null || {
    printf 'External edit requires numeric EXTERNAL_VIDEO_DURATION_SECONDS\n' >&2
    exit 1
  }
  jq -en --argjson source "$EXTERNAL_VIDEO_DURATION_SECONDS" \
    --argjson expected "$EXPECTED_DURATION_SECONDS" '
    ($source | type) == "number" and $source > 0 and
    $expected == (if $source > 8.7 then 8.7 else $source end)
  ' >/dev/null || {
    printf 'External edit requires source duration and expected min(source, 8.7)\n' >&2
    exit 1
  }
  if jq -e '.video.file_id | type == "string"' "$REQUEST_FILE" >/dev/null 2>&1; then
    [[ "$EXTERNAL_VIDEO_METADATA_CONFIRMED" == "true" ]] || {
      printf 'External edit file_id requires confirmed duration/codec/container metadata\n' >&2
      exit 1
    }
  fi
fi

expected_connection="$parent_connection"
if [[ "$request_uses_file_id" == "true" && -z "$parent_state_abs" ]]; then
  [[ -n "$EXTERNAL_FILE_CONNECTION_ID" ]] || {
    printf 'External private file_id requires EXTERNAL_FILE_CONNECTION_ID\n' >&2
    exit 1
  }
  [[ "$EXTERNAL_FILE_VALID_UNTIL" =~ ^[1-9][0-9]{8,11}$ ]] || {
    printf 'External private file_id requires EXTERNAL_FILE_VALID_UNTIL\n' >&2
    exit 1
  }
  [[ "$DEDICATED_XAI_CONNECTION" == "true" ]] || {
    printf 'Private file_id requires a dedicated single-xAI-connection worker\n' >&2
    exit 1
  }
  expected_connection="$EXTERNAL_FILE_CONNECTION_ID"
  input_valid_until="$EXTERNAL_FILE_VALID_UNTIL"
fi

if [[ "$request_uses_file_id" == "true" && "$DEDICATED_XAI_CONNECTION" != "true" ]]; then
  printf 'Private file_id requires a dedicated single-xAI-connection worker\n' >&2
  exit 1
fi

now_epoch="$(date +%s)"
[[ "$BUDGET_RESERVATION_CONFIRMED" == "true" ]] || { printf 'Budget reservation is not confirmed\n' >&2; exit 1; }
(( BUDGET_RESERVATION_EXPIRES_AT - now_epoch >= 300 )) || {
  printf 'Budget reservation lease expires too soon\n' >&2
  exit 1
}
if [[ -n "$input_valid_until" ]]; then
  (( input_valid_until - now_epoch >= MIN_PARENT_TTL_SECONDS )) || {
    printf 'Input validity window is too short\n' >&2
    exit 1
  }
fi

if (( 10#$CHAIN_ACCOUNTED_TICKS < 10#$parent_spent )); then
  printf 'Chain billing ledger is behind accepted parent cost\n' >&2
  exit 1
fi

if (( 10#$CHAIN_ACCOUNTED_TICKS > 10#$BUDGET_LIMIT_TICKS - 10#$MAX_OPERATION_TICKS )); then
  initial_phase="BUDGET_STOP"
else
  initial_phase="READY_TO_SUBMIT"
fi

op_parent="$(dirname -- "$OP_DIR")"
[[ -d "$op_parent" ]] || { printf 'Create and verify parent directory first: %s\n' "$op_parent" >&2; exit 1; }
[[ ! -e "$OP_DIR" ]] || {
  printf 'Operation directory already exists; never reuse it: %s\n' "$OP_DIR" >&2
  exit 1
}

stage_dir="$(mktemp -d "$op_parent/.operation.XXXXXX")"
chmod 700 "$stage_dir"
request_tmp="$stage_dir/request.json"
state_tmp="$stage_dir/state.json"
trap 'rm -f -- "$request_snapshot" "$request_tmp" "$state_tmp"; rmdir -- "$stage_dir" 2>/dev/null || true' EXIT HUP INT TERM

mv -- "$request_snapshot" "$request_tmp"
request_hash="$(sha256sum "$request_tmp" | awk '{print $1}')"

operation_id="$(basename -- "$OP_DIR")"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg operation_id "$operation_id" \
  --arg action "$ACTION" \
  --arg phase "$initial_phase" \
  --arg created_at "$created_at" \
  --arg request_hash "$request_hash" \
  --arg parent_state "$parent_state_abs" \
  --arg parent_state_hash "$parent_state_hash" \
  --arg parent_operation "$parent_operation" \
  --arg expected_connection "$expected_connection" \
  --arg budget_ledger_ref "$BUDGET_LEDGER_REF" \
  --argjson parent_input "$parent_input" \
  --argjson dedicated "$DEDICATED_XAI_CONNECTION" \
  --argjson expected_duration "$EXPECTED_DURATION_SECONDS" \
  --argjson external_video_duration "${EXTERNAL_VIDEO_DURATION_SECONDS:-null}" \
  --argjson input_valid_until "${input_valid_until:-null}" \
  --arg input_sha256 "$input_sha256" \
  --argjson reservation_expires "$BUDGET_RESERVATION_EXPIRES_AT" \
  --argjson reservation_confirmed "$BUDGET_RESERVATION_CONFIRMED" \
  --argjson uses_file_id "$request_uses_file_id" \
  --argjson storage_cleanup_confirmed "$FILES_CLEANUP_CONFIRMED" \
  --argjson external_video_metadata_confirmed "$EXTERNAL_VIDEO_METADATA_CONFIRMED" \
  --argjson min_identity "$MIN_IDENTITY_SCORE" \
  --argjson min_product "$MIN_PRODUCT_SCORE" \
  --argjson min_continuity "$MIN_CONTINUITY_SCORE" \
  --argjson min_action "$MIN_ACTION_SCORE" \
  --arg qa_exemption_reason "$QA_EXEMPTION_REASON" \
  --argjson limit_ticks "$BUDGET_LIMIT_TICKS" \
  --argjson spent_before "$CHAIN_ACCOUNTED_TICKS" \
  --argjson reserved_ticks "$MAX_OPERATION_TICKS" \
  --argjson post_terminal_reserved_ticks "$POST_TERMINAL_RESERVATION_TICKS" \
  '{
    schema_version: 1,
    operation_id: $operation_id,
    action: $action,
    phase: $phase,
    chain_eligible: ($phase != "BUDGET_STOP"),
    created_at: $created_at,
    dedicated_xai_connection: $dedicated,
    request: {
      file: "request.json",
      sha256: $request_hash,
      uses_file_id: $uses_file_id,
      storage_cleanup_confirmed: $storage_cleanup_confirmed,
      external_video_metadata_confirmed: $external_video_metadata_confirmed
    },
    parent: {
      state_file: (if ($parent_state | length) > 0 then $parent_state else null end),
      state_sha256: (if ($parent_state_hash | length) > 0 then $parent_state_hash else null end),
      operation_id: (if ($parent_operation | length) > 0 then $parent_operation else null end),
      reusable_input: $parent_input
    },
    connection: {
      expected_id: (if ($expected_connection | length) > 0 then $expected_connection else null end),
      serving_id: null,
      chain_id: (if ($expected_connection | length) > 0 then $expected_connection else null end)
    },
    input_valid_until: $input_valid_until,
    input_sha256: (if ($input_sha256 | length) > 0 then $input_sha256 else null end),
    external_video_duration_seconds: $external_video_duration,
    job: {request_id: null, status: null},
    expected: {
      duration_seconds: $expected_duration,
      duration_tolerance_seconds: 1.0,
      min_identity_score: $min_identity,
      min_product_score: $min_product,
      min_continuity_score: $min_continuity,
      min_action_score: $min_action,
      qa_exemption_reason: (if ($qa_exemption_reason | length) > 0 then $qa_exemption_reason else null end)
    },
    budget: {
      ledger_ref: $budget_ledger_ref,
      reservation_confirmed: $reservation_confirmed,
      reservation_expires_at: $reservation_expires,
      limit_ticks: $limit_ticks,
      accounted_before_ticks: $spent_before,
      reserved_ticks: $reserved_ticks,
      post_terminal_reserved_ticks: $post_terminal_reserved_ticks,
      actual_ticks: null,
      accounted_after_ticks: null,
      actual_is_estimate: null
    },
    submit: {started_at: null, finished_at: null, curl_exit: null, http_code: null},
    poll: {started_at: null, deadline_epoch: null, attempts: 0, retryable_failures: 0},
    output: null,
    checkpoint: null,
    stop_reason: (if $phase == "BUDGET_STOP" then "worst-case reservation exceeds budget" else null end)
  }' > "$state_tmp"

sync -f "$stage_dir"
mv -T -- "$stage_dir" "$OP_DIR"
sync -f "$op_parent"
trap - EXIT HUP INT TERM
jq '{
  operation_id,
  action,
  phase,
  budget: {
    ledger_ref: .budget.ledger_ref,
    limit_ticks: .budget.limit_ticks,
    accounted_before_ticks: .budget.accounted_before_ticks,
    reserved_ticks: .budget.reserved_ticks
  },
  connection: {
    expected_id: .connection.expected_id,
    chain_id: .connection.chain_id
  },
  parent_operation_id: .parent.operation_id
}' "$OP_DIR/state.json"
```

Nếu phase là `BUDGET_STOP`, không submit và release external reservation. `READY_TO_SUBMIT` chỉ hợp lệ khi orchestrator đã atomically ghi reservation của operation này vào ledger revision trong `budget.ledger_ref`. Init build cả request/state trong staging directory rồi rename directory; nếu init fail trước rename, release reservation qua `BUDGET_LEDGER_REF`. Shell recipe phù hợp cho chain tuần tự một worker; hệ thống nhiều worker phải dùng transaction/uniqueness constraint ngoài shell để chỉ cho phép một child active trên mỗi accepted parent và không vượt budget toàn chain.

## 9. Submit đúng một lần

Trước submit, external ledger phải renew reservation đủ lâu cho full-content preflight và POST. Ví dụ không có HTTPS media input:

```bash
export SUBMIT_BUDGET_RESERVATION_RENEWED_UNTIL="$(( $(date +%s) + 900 ))"
```

Block tự tính minimum từ số HTTPS input; mỗi full download reserve tối đa 1.800 giây, external edit URL cần thêm một duration probe, POST cần 150 giây và có safety margin. Block chỉ tạo POST từ state `READY_TO_SUBMIT`, giữ lock trong suốt POST và tạo directory evidence bằng `mkdir`. Nếu process chết ở `SUBMITTING`, lần chạy lại chỉ reduce response body/header đã được fsync; nếu evidence không hoàn chỉnh, nó dừng như outcome mơ hồ. Không được đổi phase về `READY_TO_SUBMIT` để gửi lại.

```bash
set -Eeuo pipefail
umask 077
: "${NINEROUTER_URL:?Missing NINEROUTER_URL}"
: "${NINEROUTER_KEY:?Missing NINEROUTER_KEY}"
: "${OP_DIR:?Missing OP_DIR}"
NINEROUTER_URL="${NINEROUTER_URL%/}"
SUBMIT_BUDGET_RESERVATION_RENEWED_UNTIL="${SUBMIT_BUDGET_RESERVATION_RENEWED_UNTIL:-}"
STATE_FILE="$OP_DIR/state.json"

state_update() {
  local filter="$1" tmp
  shift
  tmp="$(mktemp "$OP_DIR/.state.XXXXXX")"
  if ! jq "$@" "$filter" "$STATE_FILE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$STATE_FILE"
  sync -f "$OP_DIR"
}

header_value() {
  local name="$1" file="$2"
  awk -F ':' -v wanted="$name" '
    tolower($1) == tolower(wanted) {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/\r$/, "")
      value=$0
    }
    END { print value }
  ' "$file"
}

response_http_code() {
  awk '/^HTTP\// { code=$2 } END { print code }' "$1"
}

exec 9>"$OP_DIR/operation.lock"
flock -n 9 || { printf 'Operation is locked by another worker\n' >&2; exit 1; }

phase="$(jq -r '.phase' "$STATE_FILE")"
case "$phase" in
  READY_TO_SUBMIT) ;;
  SUBMITTING)
    if [[ -s "$OP_DIR/submit/body.json" && -s "$OP_DIR/submit/headers" ]]; then
      replay_only=true
    else
      printf 'SUBMIT_UNKNOWN: SUBMITTING has no complete durable response evidence\n' >&2
      exit 1
    fi
    ;;
  *)
  printf 'Refusing submit from phase %s\n' "$phase" >&2
  exit 1
    ;;
esac
replay_only="${replay_only:-false}"

request_file="$OP_DIR/$(jq -r '.request.file' "$STATE_FILE")"
action="$(jq -r '.action' "$STATE_FILE")"
expected_connection="$(jq -r '.connection.expected_id // empty' "$STATE_FILE")"
if [[ "$replay_only" == "false" ]]; then
  expected_hash="$(jq -r '.request.sha256' "$STATE_FILE")"
  actual_hash="$(sha256sum "$request_file" | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || { printf 'Request hash changed\n' >&2; exit 1; }

  now_epoch="$(date +%s)"
  [[ "$(jq -r '.budget.reservation_confirmed' "$STATE_FILE")" == "true" ]] || {
    printf 'Budget reservation is not confirmed\n' >&2
    exit 1
  }
  [[ "$SUBMIT_BUDGET_RESERVATION_RENEWED_UNTIL" =~ ^[1-9][0-9]{8,11}$ ]] || {
    printf 'Submit requires a renewed external budget lease\n' >&2
    exit 1
  }
  https_input_count="$(jq '[.video?.url?, .image?.url?, .reference_images[]?.url?] |
    map(select(type == "string" and startswith("https://"))) | length' "$request_file")"
  preflight_windows="$https_input_count"
  if [[ "$action" == "edits" ]] && jq -e '.video.url | type == "string"' "$request_file" >/dev/null 2>&1; then
    preflight_windows=$((preflight_windows + 1))
  fi
  required_submit_lease=$((preflight_windows * 1800 + 150 + 300))
  (( SUBMIT_BUDGET_RESERVATION_RENEWED_UNTIL - now_epoch >= required_submit_lease )) || {
    printf 'Budget lease does not cover submit preflight plus POST margin\n' >&2
    exit 1
  }
  state_update '.budget.reservation_expires_at = $until' \
    --argjson until "$SUBMIT_BUDGET_RESERVATION_RENEWED_UNTIL"

  input_valid_until="$(jq -r '.input_valid_until // empty' "$STATE_FILE")"
  if [[ -n "$input_valid_until" ]]; then
    (( input_valid_until - now_epoch >= required_submit_lease )) || {
      printf 'Media input validity window must cover submit preflight and POST\n' >&2
      exit 1
    }
  fi

  parent_state="$(jq -r '.parent.state_file // empty' "$STATE_FILE")"
  if [[ -n "$parent_state" ]]; then
    parent_state_hash="$(jq -r '.parent.state_sha256 // empty' "$STATE_FILE")"
    [[ -s "$parent_state" && "$(sha256sum "$parent_state" | awk '{print $1}')" == "$parent_state_hash" ]] || {
      printf 'Accepted parent state changed after child init\n' >&2
      exit 1
    }
    jq -e '.phase == "ACCEPTED_CHECKPOINT" and .chain_eligible == true' "$parent_state" >/dev/null
  fi

  input_index=0
  while IFS= read -r input_url; do
    [[ -n "$input_url" ]] || continue
    input_index=$((input_index + 1))
    input_part="$(mktemp "$OP_DIR/.input.XXXXXX.part")"
    trap 'rm -f -- "$input_part"' EXIT HUP INT TERM
    curl --silent --show-error --fail --location \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 1800 \
      --output "$input_part" "$input_url"
    [[ -s "$input_part" ]] || { printf 'HTTPS media input is empty\n' >&2; exit 1; }

    actual_mime="$(file --brief --mime-type "$input_part")"
    case "$actual_mime" in
      image/png|image/jpeg|image/webp) ;;
      video/mp4)
        ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height \
          -of json "$input_part" | jq -e '
            (.streams | length) >= 1 and
            all(.streams[]; (.codec_name | IN("h264","hevc","av1")) and .width > 0 and .height > 0)
          ' >/dev/null
        ;;
      *) printf 'Unexpected HTTPS media MIME: %s\n' "$actual_mime" >&2; exit 1 ;;
    esac

    if (( input_index == 1 )); then
      expected_input_hash="$(jq -r '.input_sha256 // empty' "$STATE_FILE")"
      if [[ -n "$expected_input_hash" ]]; then
        [[ "$(sha256sum "$input_part" | awk '{print $1}')" == "$expected_input_hash" ]] || {
          printf 'Parent URL bytes changed after QA\n' >&2
          exit 1
        }
      fi
    fi
    rm -f -- "$input_part"
    trap - EXIT HUP INT TERM
  done < <(jq -r '[.video?.url?, .image?.url?, .reference_images[]?.url?][] |
    strings | select(startswith("https://"))' "$request_file")

  if [[ "$action" == "edits" && -z "$parent_state" ]] && \
     jq -e '.video.url | type == "string"' "$request_file" >/dev/null 2>&1; then
    edit_url="$(jq -r '.video.url' "$request_file")"
    edit_probe="$(mktemp "$OP_DIR/.edit-input.XXXXXX.part")"
    trap 'rm -f -- "$edit_probe"' EXIT HUP INT TERM
    curl --silent --show-error --fail --location \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 1800 --output "$edit_probe" "$edit_url"
    probed_duration="$(ffprobe -v error -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 "$edit_probe")"
    jq -en --argjson probed "$probed_duration" \
      --argjson declared "$(jq '.external_video_duration_seconds' "$STATE_FILE")" '
      ((($probed - $declared) | if . < 0 then -. else . end) <= 0.1)
    ' >/dev/null || { printf 'External edit duration differs from preflight declaration\n' >&2; exit 1; }
    rm -f -- "$edit_probe"
    trap - EXIT HUP INT TERM
  fi

  now_epoch="$(date +%s)"
  reservation_expires="$(jq -r '.budget.reservation_expires_at' "$STATE_FILE")"
  (( reservation_expires - now_epoch >= 180 )) || {
    printf 'Budget lease expired during preflight; renew and rerun without submitting\n' >&2
    exit 1
  }

  mkdir --mode=700 -- "$OP_DIR/submit" || {
    printf 'Submit evidence already exists; refusing duplicate POST\n' >&2
    exit 1
  }

  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_update '.phase = "SUBMITTING" | .submit.started_at = $now' --arg now "$started_at"

  connection_args=()
  if [[ -n "$expected_connection" ]]; then
    connection_args=(-H "x-connection-id: $expected_connection")
  fi

  : > "$OP_DIR/submit/headers.part"
  : > "$OP_DIR/submit/body.part"
  curl_exit=0
  http_code="$(curl --silent --show-error \
    --connect-timeout 10 --max-time 150 \
    -X POST "$NINEROUTER_URL/v1/videos/$action" \
    -H "Authorization: Bearer $NINEROUTER_KEY" \
    "${connection_args[@]}" \
    -H "Content-Type: application/json" \
    --dump-header "$OP_DIR/submit/headers.part" \
    --data-binary "@$request_file" \
    --output "$OP_DIR/submit/body.part" \
    --write-out '%{http_code}')" || curl_exit=$?

  mv -- "$OP_DIR/submit/headers.part" "$OP_DIR/submit/headers"
  mv -- "$OP_DIR/submit/body.part" "$OP_DIR/submit/body.json"
  sync -f "$OP_DIR/submit"
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_update '
    .submit.finished_at = $now |
    .submit.curl_exit = $curl_exit |
    .submit.http_code = $http_code |
    .submit.headers_file = "submit/headers" |
    .submit.body_file = "submit/body.json"
  ' --arg now "$finished_at" --argjson curl_exit "$curl_exit" --arg http_code "$http_code"
else
  curl_exit="$(jq -r '.submit.curl_exit // 0' "$STATE_FILE")"
  http_code="$(jq -r '.submit.http_code // "000"' "$STATE_FILE")"
  [[ "$http_code" != "000" ]] || http_code="$(response_http_code "$OP_DIR/submit/headers")"
fi

if (( curl_exit != 0 )); then
  state_update '.phase = "SUBMIT_UNKNOWN" | .chain_eligible = false | .stop_reason = $reason' \
    --arg reason "curl exit $curl_exit; request may have reached upstream"
  printf 'SUBMIT_UNKNOWN: never auto-retry this operation\n' >&2
  exit 1
fi

request_id="$(jq -r 'if type == "object" and (.request_id | type) == "string" then .request_id else empty end' \
  "$OP_DIR/submit/body.json" 2>/dev/null || true)"
serving_connection="$(header_value x-9router-connection-id "$OP_DIR/submit/headers")"
[[ -z "$request_id" || "$request_id" =~ ^[A-Za-z0-9._~-]+$ ]] || request_id=""

if [[ "$http_code" =~ ^2[0-9][0-9]$ && -n "$request_id" && -n "$serving_connection" ]]; then
  chain_connection="$expected_connection"
  [[ -n "$chain_connection" ]] || chain_connection="$serving_connection"

  if [[ -n "$expected_connection" && "$serving_connection" != "$expected_connection" ]]; then
    state_update '
      .phase = "AFFINITY_LOST" |
      .chain_eligible = false |
      .job.request_id = $request_id |
      .connection.serving_id = $serving |
      .stop_reason = "POST accepted on a different connection; reconcile cost/output but do not continue chain"
    ' --arg request_id "$request_id" --arg serving "$serving_connection"
    printf 'AFFINITY_LOST: job may be billable; quarantine this operation\n' >&2
    exit 1
  fi

  state_update '
    .phase = "ACCEPTED" |
    .job.request_id = $request_id |
    .connection.serving_id = $serving |
    .connection.chain_id = $chain
  ' --arg request_id "$request_id" --arg serving "$serving_connection" --arg chain "$chain_connection"
  jq '{phase,job,connection}' "$STATE_FILE"
  exit 0
fi

if [[ "$http_code" =~ ^(400|401|402|403|404|405|406|410|413|415|422|429)$ ]]; then
  state_update '
    .phase = "SUBMIT_REJECTED" |
    .chain_eligible = false |
    .stop_reason = ("synchronous HTTP " + $http_code + "; inspect submit/body.json")
  ' --arg http_code "$http_code"
  printf 'SUBMIT_REJECTED: fix cause; any retry must be a new reviewed operation\n' >&2
else
  state_update '
    .phase = "SUBMIT_UNKNOWN" |
    .chain_eligible = false |
    .stop_reason = ("HTTP " + $http_code + " or malformed success; acceptance is unknown")
  ' --arg http_code "$http_code"
  printf 'SUBMIT_UNKNOWN: never auto-retry this operation\n' >&2
fi
exit 1
```

9Router có thể tự refresh credential rồi resend một lần sau `401/403`, sau đó rotate account và resend khi response cuối của account là `401/403/429`. Logic này dựa trên HTTP status, không phải local deduplication. Vì vậy “submit đúng một lần” ở đây chỉ nói về caller; không phải guarantee upstream nhận đúng một POST.

`Idempotency-Key` được 9Router forward nếu gửi, nhưng xAI video idempotency không được implementation bảo đảm. Không dùng header đó để tự động retry.

## 10. Poll có phân loại lỗi

Block này retry transport error, HTTP `408`, `429`, `5xx` và gateway `400` có message `No credentials for provider: xai` khi dedicated account đang cooldown. Permanent `4xx` khác chỉ được coi là final trên dedicated worker; ở multi-connection worker, error response không có serving header là affinity-unknown. Set `RECONCILE_AFFINITY_LOST=true` để poll một accepted mismatched job nhằm ghi cost/output, nhưng state vẫn bị quarantine và không bao giờ trở lại chain.

```bash
set -Eeuo pipefail
umask 077
: "${NINEROUTER_URL:?Missing NINEROUTER_URL}"
: "${NINEROUTER_KEY:?Missing NINEROUTER_KEY}"
: "${OP_DIR:?Missing OP_DIR}"
NINEROUTER_URL="${NINEROUTER_URL%/}"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-900}"
RESUME_AFTER_TIMEOUT="${RESUME_AFTER_TIMEOUT:-false}"
RECONCILE_AFFINITY_LOST="${RECONCILE_AFFINITY_LOST:-false}"
BUDGET_RESERVATION_RENEWED_UNTIL="${BUDGET_RESERVATION_RENEWED_UNTIL:-}"
STATE_FILE="$OP_DIR/state.json"

state_update() {
  local filter="$1" tmp
  shift
  tmp="$(mktemp "$OP_DIR/.state.XXXXXX")"
  if ! jq "$@" "$filter" "$STATE_FILE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$STATE_FILE"
  sync -f "$OP_DIR"
}

header_value() {
  local name="$1" file="$2"
  awk -F ':' -v wanted="$name" '
    tolower($1) == tolower(wanted) {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/\r$/, "")
      value=$0
    }
    END { print value }
  ' "$file"
}

exec 9>"$OP_DIR/operation.lock"
flock -n 9 || { printf 'Operation is locked by another worker\n' >&2; exit 1; }

phase="$(jq -r '.phase' "$STATE_FILE")"
quarantine=false
case "$phase" in
  ACCEPTED|POLLING) ;;
  POLL_TIMEOUT)
    [[ "$RESUME_AFTER_TIMEOUT" == "true" ]] || {
      printf 'Set RESUME_AFTER_TIMEOUT=true to resume the same request_id deliberately\n' >&2
      exit 1
    }
    ;;
  AFFINITY_LOST)
    [[ "$RECONCILE_AFFINITY_LOST" == "true" ]] || {
      printf 'Set RECONCILE_AFFINITY_LOST=true to reconcile this quarantined job\n' >&2
      exit 1
    }
    quarantine=true
    ;;
  RECONCILING|RECONCILE_TIMEOUT)
    [[ "$RECONCILE_AFFINITY_LOST" == "true" ]] || {
      printf 'Set RECONCILE_AFFINITY_LOST=true to resume quarantined reconciliation\n' >&2
      exit 1
    }
    quarantine=true
    ;;
  *) printf 'Refusing poll from phase %s\n' "$phase" >&2; exit 1 ;;
esac

request_id="$(jq -r '.job.request_id // empty' "$STATE_FILE")"
connection_id="$(jq -r '.connection.serving_id // empty' "$STATE_FILE")"
dedicated="$(jq -r '.dedicated_xai_connection' "$STATE_FILE")"
[[ -n "$request_id" && -n "$connection_id" ]] || { printf 'Missing durable job identity\n' >&2; exit 1; }
mkdir -p -- "$OP_DIR/poll"

now_epoch="$(date +%s)"
deadline="$(jq -r '.poll.deadline_epoch // empty' "$STATE_FILE")"
reset_deadline=false
if [[ -z "$deadline" || "$phase" == "POLL_TIMEOUT" || "$phase" == "AFFINITY_LOST" ||
      "$phase" == "RECONCILE_TIMEOUT" ]]; then
  deadline=$((now_epoch + POLL_TIMEOUT_SECONDS))
  reset_deadline=true
fi

account_terminal_cost() {
  local response_file="$1" usage_ticks estimated accounted_before accounted_after limit_ticks retained_ticks
  usage_ticks="$(jq -r '.usage.cost_in_usd_ticks // empty' "$response_file")"
  estimated=false
  if [[ ! "$usage_ticks" =~ ^(0|[1-9][0-9]{0,14})$ ]]; then
    usage_ticks="$(jq -r '.budget.reserved_ticks' "$STATE_FILE")"
    retained_ticks=0
    estimated=true
  else
    retained_ticks="$(jq -r '.budget.post_terminal_reserved_ticks' "$STATE_FILE")"
  fi
  accounted_before="$(jq -r '.budget.accounted_before_ticks' "$STATE_FILE")"
  limit_ticks="$(jq -r '.budget.limit_ticks' "$STATE_FILE")"
  accounted_after=$((10#$accounted_before + 10#$usage_ticks + 10#$retained_ticks))
  state_update '
    .budget.actual_ticks = $usage |
    .budget.post_terminal_reserved_ticks = $retained |
    .budget.compute_accounted_after_ticks = ($accounted_after - $retained) |
    .budget.accounted_after_ticks = $accounted_after |
    .budget.actual_is_estimate = $estimated |
    .budget.over_limit = ($accounted_after > $limit)
  ' --argjson usage "$usage_ticks" --argjson retained "$retained_ticks" \
    --argjson accounted_after "$accounted_after" \
    --argjson estimated "$estimated" --argjson limit "$limit_ticks"
}

process_success_response() {
  local response_rel="$1" response_file="$OP_DIR/$1" response_dir poll_connection status progress
  response_dir="$(dirname -- "$response_file")"
  poll_connection="$(header_value x-9router-connection-id "$response_dir/headers")"
  if [[ -z "$poll_connection" || "$poll_connection" != "$connection_id" ]]; then
    state_update '
      .phase = "AFFINITY_LOST" |
      .chain_eligible = false |
      .connection.serving_id = (if ($observed | length) > 0 then $observed else .connection.serving_id end) |
      .stop_reason = "poll response came from a missing or different connection"
    ' --arg observed "$poll_connection"
    printf 'AFFINITY_LOST: stop chain\n' >&2
    exit 1
  fi

  status="$(jq -r 'if type == "object" and (.status | type) == "string" then .status | ascii_downcase else "" end' \
    "$response_file" 2>/dev/null || true)"
  progress="$(jq -r '.progress // empty' "$response_file" 2>/dev/null || true)"
  printf 'status=%s progress=%s\n' "$status" "$progress"

  case "$status" in
    pending|processing)
      state_update '.job.status = $status' --arg status "$status"
      ;;
    done|completed)
      account_terminal_cost "$response_file"
      if ! jq -e '.video.respect_moderation == true' "$response_file" >/dev/null; then
        state_update '
          .phase = "REJECTED" |
          .chain_eligible = false |
          .job.status = $status |
          .poll.final_response_file = $response |
          .stop_reason = "terminal output did not pass upstream moderation"
        ' --arg status "$status" --arg response "$response_rel"
        printf 'REJECTED: terminal output did not pass upstream moderation\n' >&2
        exit 1
      fi
      state_update '
        .phase = (if $quarantine then "QUARANTINED_DONE" else "DONE_UNPERSISTED" end) |
        .chain_eligible = (if $quarantine then false else .chain_eligible end) |
        .job.status = $status |
        .poll.final_response_file = $response
      ' --arg status "$status" --arg response "$response_rel" --argjson quarantine "$quarantine"
      jq '{
        status,
        progress,
        usage,
        video: {
          duration: .video.duration,
          respect_moderation: .video.respect_moderation,
          has_download_url: (.video.url != null),
          has_file_output: (.video.file_output.file_id != null)
        }
      }' "$response_file"
      exit 0
      ;;
    failed|error|expired|cancelled)
      account_terminal_cost "$response_file"
      state_update '
        .phase = "FAILED_FINAL" |
        .chain_eligible = false |
        .job.status = $status |
        .poll.final_response_file = $response |
        .stop_reason = "terminal upstream job failure"
      ' --arg status "$status" --arg response "$response_rel"
      jq '{status,error,usage}' "$response_file" >&2
      exit 1
      ;;
    *)
      state_update '
        .phase = "PROTOCOL_ERROR" |
        .chain_eligible = false |
        .job.status = (if ($status | length) > 0 then $status else null end) |
        .stop_reason = "missing or unknown upstream status"
      ' --arg status "$status"
      printf 'Unknown poll status; stop\n' >&2
      exit 1
      ;;
  esac
}

last_response="$(jq -r '.poll.last_response_file // empty' "$STATE_FILE")"
last_http_code="$(jq -r '.poll.last_http_code // empty' "$STATE_FILE")"
shopt -s nullglob
attempt_dirs=("$OP_DIR"/poll/[0-9][0-9][0-9][0-9][0-9][0-9])
shopt -u nullglob
latest_attempt=""
for candidate in "${attempt_dirs[@]}"; do
  if [[ -s "$candidate/body.json" && -s "$candidate/headers" ]]; then
    latest_attempt="$candidate"
  fi
done
if [[ -n "$latest_attempt" ]]; then
  latest_code="$(awk '/^HTTP\// { code=$2 } END { print code }' "$latest_attempt/headers")"
  latest_rel="${latest_attempt#"$OP_DIR/"}/body.json"
  latest_number="$(basename -- "$latest_attempt")"
  if (( 10#$latest_number > $(jq -r '.poll.attempts' "$STATE_FILE") )); then
    state_update '
      .poll.attempts = $attempt |
      .poll.last_http_code = $http_code |
      .poll.last_curl_exit = 0 |
      .poll.last_response_file = $response
    ' --argjson attempt "$((10#$latest_number))" --arg http_code "$latest_code" --arg response "$latest_rel"
  fi
  last_response="$latest_rel"
  last_http_code="$latest_code"
fi
if [[ "$last_http_code" =~ ^2[0-9][0-9]$ && -n "$last_response" && -s "$OP_DIR/$last_response" ]]; then
  process_success_response "$last_response"
fi

now_epoch="$(date +%s)"
[[ "$BUDGET_RESERVATION_RENEWED_UNTIL" =~ ^[1-9][0-9]{8,11}$ ]] || {
  printf 'Network polling requires a renewed external budget lease\n' >&2
  exit 1
}
(( BUDGET_RESERVATION_RENEWED_UNTIL >= deadline + 300 )) || {
  printf 'Budget lease must extend past persisted poll deadline plus reconciliation margin\n' >&2
  exit 1
}
state_update '
  .phase = (if $quarantine then "RECONCILING" else "POLLING" end) |
  .chain_eligible = (if $quarantine then false else (if $reset then true else .chain_eligible end) end) |
  .stop_reason = (if $quarantine then .stop_reason else (if $reset then null else .stop_reason end) end) |
  .poll.started_at = (if $reset then $started else .poll.started_at end) |
  .poll.deadline_epoch = $deadline |
  .budget.reservation_expires_at = $until
' --argjson quarantine "$quarantine" --argjson reset "$reset_deadline" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson deadline "$deadline" \
  --argjson until "$BUDGET_RESERVATION_RENEWED_UNTIL"

while true; do
  now_epoch="$(date +%s)"
  if (( now_epoch >= deadline )); then
    state_update '
      .phase = (if $quarantine then "RECONCILE_TIMEOUT" else "POLL_TIMEOUT" end) |
      .chain_eligible = false |
      .stop_reason = "poll deadline reached; do not resubmit"
    ' --argjson quarantine "$quarantine"
    printf 'POLL_TIMEOUT: job identity remains in state.json; do not resubmit\n' >&2
    exit 1
  fi

  attempt=$(( $(jq -r '.poll.attempts' "$STATE_FILE") + 1 ))
  state_update '.poll.attempts = $attempt' --argjson attempt "$attempt"
  printf -v attempt_name '%06d' "$attempt"
  attempt_dir="$OP_DIR/poll/$attempt_name"
  mkdir --mode=700 -- "$attempt_dir"
  : > "$attempt_dir/headers.part"
  : > "$attempt_dir/body.part"

  remaining=$((deadline - now_epoch))
  max_time=150
  (( remaining < max_time )) && max_time="$remaining"

  curl_exit=0
  http_code="$(curl --silent --show-error \
    --connect-timeout 10 --max-time "$max_time" \
    -H "Authorization: Bearer $NINEROUTER_KEY" \
    -H "x-connection-id: $connection_id" \
    --dump-header "$attempt_dir/headers.part" \
    "$NINEROUTER_URL/v1/videos/$request_id" \
    --output "$attempt_dir/body.part" \
    --write-out '%{http_code}')" || curl_exit=$?

  mv -- "$attempt_dir/headers.part" "$attempt_dir/headers"
  mv -- "$attempt_dir/body.part" "$attempt_dir/body.json"
  sync -f "$attempt_dir"
  state_update '
    .poll.last_http_code = $http_code |
    .poll.last_curl_exit = $curl_exit |
    .poll.last_response_file = $response
  ' --arg http_code "$http_code" --argjson curl_exit "$curl_exit" \
    --arg response "poll/$attempt_name/body.json"

  retryable=false
  if (( curl_exit != 0 )); then
    retryable=true
  elif [[ "$http_code" == "408" || "$http_code" == "429" || "$http_code" =~ ^5[0-9][0-9]$ ]]; then
    retryable=true
  elif [[ "$http_code" == "400" ]] && jq -e '
    (.error.message // "") | test("No credentials for provider: xai|All accounts unavailable"; "i")
  ' "$attempt_dir/body.json" >/dev/null 2>&1; then
    retryable=true
  elif [[ "$http_code" =~ ^4[0-9][0-9]$ ]]; then
    if [[ "$dedicated" != "true" ]]; then
      state_update '
        .phase = "POLL_AFFINITY_UNKNOWN" |
        .chain_eligible = false |
        .stop_reason = ("headerless poll HTTP " + $http_code + " on a multi-connection worker")
      ' --arg http_code "$http_code"
      printf 'POLL_AFFINITY_UNKNOWN: cannot prove which account returned HTTP %s\n' "$http_code" >&2
      exit 1
    fi
    state_update '
      .phase = "POLL_FAILED_FINAL" |
      .chain_eligible = false |
      .stop_reason = ("permanent poll HTTP " + $http_code + "; inspect " + $response)
    ' --arg http_code "$http_code" --arg response "poll/$attempt_name/body.json"
    printf 'Permanent poll HTTP %s; stop\n' "$http_code" >&2
    exit 1
  elif [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    state_update '.phase = "PROTOCOL_ERROR" | .chain_eligible = false | .stop_reason = ("unexpected poll HTTP " + $http_code)' \
      --arg http_code "$http_code"
    exit 1
  fi

  if [[ "$retryable" == "true" ]]; then
    if [[ "$dedicated" != "true" ]]; then
      state_update '
        .phase = "POLL_RETRY_UNSAFE" |
        .chain_eligible = false |
        .stop_reason = "retryable poll failure on a soft-affinity multi-connection worker"
      '
      printf 'POLL_RETRY_UNSAFE: do not risk polling another account\n' >&2
      exit 1
    fi

    failures=$(( $(jq -r '.poll.retryable_failures' "$STATE_FILE") + 1 ))
    state_update '.poll.retryable_failures = $n' --argjson n "$failures"
    exponent="$failures"
    (( exponent > 4 )) && exponent=4
    delay=$((5 * (2 ** (exponent - 1)) + RANDOM % 4))
    if (( curl_exit == 0 && delay < 35 )); then
      delay=35
    fi
    (( delay > 60 )) && delay=60
    retry_after="$(header_value retry-after "$attempt_dir/headers")"
    if [[ "$retry_after" =~ ^[0-9]+$ ]] && (( retry_after > delay && retry_after <= 60 )); then
      delay="$retry_after"
    fi
    printf 'retryable poll failure: curl=%s HTTP=%s; retry in %ss\n' "$curl_exit" "$http_code" "$delay" >&2
    sleep "$delay"
    continue
  fi

  process_success_response "poll/$attempt_name/body.json"
  sleep 5
done
```

HTTP error response của 9Router thường không có `x-9router-connection-id`; không thể xác minh affinity từ lỗi đó. Dedicated worker là điều kiện để retry tự động an toàn, không phải response header.

## 11. Payload generation

9Router forward video JSON gần như nguyên vẹn và chỉ strip prefix `xai/` khỏi `model`. Validation field bên dưới là contract upstream xAI, không phải validation do 9Router thực hiện.

Generation fields thường dùng:

| Field | Contract upstream |
|---|---|
| `model` | `xai/grok-imagine-video` |
| `prompt` | Prompt rõ ràng; runbook luôn yêu cầu dù một số I2V flow có thể cho omit |
| `duration` | 1-15 giây; mặc định 8 |
| `aspect_ratio` | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3` |
| `resolution` | Upstream schema có thể có `1080p`, nhưng runbook preflight giới hạn model registered `grok-imagine-video` ở `480p`/`720p`; dùng `720p` |

### Text-to-video

```bash
jq -n '{
  model: "xai/grok-imagine-video",
  prompt: "A red toy robot slowly waters a yellow sunflower in a clean studio, locked camera, soft side light, no text",
  duration: 8,
  aspect_ratio: "16:9",
  resolution: "720p",
  storage_options: {
    filename: "project-seed-0000.mp4",
    expires_after: 604800
  }
}' > video.request.json
```

### Image-to-video

I2V dùng `image` làm frame bắt đầu. Omit `aspect_ratio` để dùng ratio của ảnh; override ratio khác có thể stretch ảnh.

```bash
jq -n '{
  model: "xai/grok-imagine-video",
  prompt: "Continue naturally from this exact image. Preserve the same person, face, hair, clothing, body proportions, product details, background, lighting, color grade, camera height, text, and logo. Add only subtle natural motion. No cut, morph, transformation, new object, or wardrobe change. End on a stable pose.",
  image: {url: "https://assets.example.com/canonical-frame.jpg"},
  duration: 12,
  resolution: "720p",
  storage_options: {
    filename: "project-seed-0000.mp4",
    expires_after: 604800
  }
}' > video.request.json
```

File local nhỏ có thể trở thành data URI mà không để lại base64 plaintext tạm:

```bash
set -Eeuo pipefail
umask 077
SOURCE_IMAGE="canonical-frame.jpg"
SOURCE_MIME="$(file --brief --mime-type "$SOURCE_IMAGE")"
case "$SOURCE_MIME" in
  image/png|image/jpeg|image/webp) ;;
  *) printf 'Unsupported image MIME: %s\n' "$SOURCE_MIME" >&2; exit 1 ;;
esac

image_tmp="$(mktemp)"
request_tmp="$(mktemp)"
trap 'rm -f -- "$image_tmp" "$request_tmp"' EXIT HUP INT TERM
base64 --wrap=0 "$SOURCE_IMAGE" > "$image_tmp"

jq -n --arg mime "$SOURCE_MIME" --rawfile image "$image_tmp" '{
  model: "xai/grok-imagine-video",
  prompt: "Continue naturally from this exact image. Preserve every visual detail. Add only subtle controlled motion. No cut or transformation.",
  image: {url: ("data:" + $mime + ";base64," + $image)},
  duration: 8,
  resolution: "720p",
  storage_options: {filename: "project-seed-0000.mp4", expires_after: 604800}
}' > "$request_tmp"

mv -- "$request_tmp" video.request.json
rm -f -- "$image_tmp"
trap - EXIT HUP INT TERM
```

9Router buffer toàn JSON body trong RAM. Chỉ dùng data URI cho ảnh nhỏ; video cumulative phải dùng `file_id` hoặc URL. `image` cũng có thể là `{"file_id":"file_..."}`, nhưng 9Router không proxy Files upload/list/delete.

### Reference-to-video

R2V dùng `reference_images[]` để hướng dẫn identity, outfit, product hoặc style; nó không khóa frame đầu. Không gửi `image` cùng `reference_images`.

```bash
jq -n '{
  model: "xai/grok-imagine-video",
  prompt: "The person from <IMAGE_1> keeps the same face, age, hair, skin tone, and body proportions. They wear exactly the clothing from <IMAGE_2>. Preserve the product geometry, colors, materials, markings, and proportions from <IMAGE_3>. Medium studio shot, soft side light, 35mm lens, slow camera push-in. The subject gently lifts the product and looks at it. No cut, morph, identity change, wardrobe change, product redesign, text, or extra person. End on a stable pose.",
  reference_images: [
    {url: "https://assets.example.com/person.jpg"},
    {url: "https://assets.example.com/clothing.jpg"},
    {url: "https://assets.example.com/product.jpg"}
  ],
  duration: 12,
  aspect_ratio: "16:9",
  resolution: "720p",
  storage_options: {filename: "project-seed-0000.mp4", expires_after: 604800}
}' > video.request.json
```

Mỗi reference item dùng đúng một `url` hoặc `file_id`. `<IMAGE_1>`, `<IMAGE_2>`, ... là convention theo thứ tự array trong ví dụ xAI, không phải schema guarantee. Không có maximum reference count được implementation 9Router enforce hoặc tài liệu upstream công bố; dùng ít ảnh, mỗi ảnh một vai trò và không mâu thuẫn.

## 12. Payload edit

```bash
jq -n '{
  model: "xai/grok-imagine-video",
  prompt: "Change only the flower petals from yellow to bright blue. Preserve the robot, pot, studio background, camera motion, timing, lighting, and all other details. Add no text.",
  video: {url: "https://assets.example.com/source.mp4"},
  storage_options: {filename: "project-edit-0001.mp4", expires_after: 604800}
}' > video.request.json
```

Không gửi custom `duration`, `aspect_ratio` hoặc `resolution` cho edit. Theo contract upstream, edit giữ duration input nhưng cap khoảng 8,7 giây, giữ aspect ratio và cap resolution ở 720p. Input `video` dùng đúng một trong:

```json
{"url":"https://assets.example.com/source.mp4"}
```

```json
{"url":"data:video/mp4;base64,..."}
```

```json
{"file_id":"file_..."}
```

Tránh data URI cho video. URL phải truy cập được không cần cookie/header riêng và trỏ tới MP4/codec được xAI hỗ trợ. Nếu edit một accepted checkpoint, set `PARENT_STATE` và dùng chính `.checkpoint.reusable_input` làm `.video`; nếu edit asset ngoài chain, `PARENT_STATE` có thể rỗng nhưng vẫn phải reserve budget và dùng operation state mới.

## 13. Payload extension

Extension request:

| Field | Required | Contract upstream |
|---|---:|---|
| `model` | Upstream không; runbook có | Gửi explicit `xai/grok-imagine-video` để preflight không suy đoán |
| `prompt` | Có | Hành động tiếp theo |
| `duration` | Không | Phần mới 2-10 giây; mặc định 6 |
| `video` | Có | URL hoặc `file_id` của accepted parent |
| `storage_options` | Có nếu dùng xAI Files | Tạo reusable output cho bước sau; nếu omit, upload output vào caller-owned storage |

Không gửi `image`, `reference_images`, `aspect_ratio` hoặc `resolution`. Extension output là cumulative; ví dụ input 10 giây cộng `duration:5` dự kiến trả output 15 giây.

Đọc reusable input từ parent state trong process hiện tại; không dựa vào biến shell còn sót từ process cũ:

```bash
set -Eeuo pipefail
umask 077
: "${PARENT_STATE:?Missing PARENT_STATE}"
jq -e '.phase == "ACCEPTED_CHECKPOINT" and .checkpoint.reusable_input != null' \
  "$PARENT_STATE" >/dev/null

request_tmp="$(mktemp)"
trap 'rm -f -- "$request_tmp"' EXIT HUP INT TERM
jq -n \
  --argjson video "$(jq -c '.checkpoint.reusable_input' "$PARENT_STATE")" \
  '{
    model: "xai/grok-imagine-video",
    prompt: "Continue uninterrupted from the exact final frame. CONTINUITY LOCK: same person, face, hair, clothing, body proportions, product geometry, location, lens, camera height, lighting, color grade, and motion speed. No cut, reset, morph, identity change, wardrobe change, product redesign, new object, extra person, text, or logo change. NEXT ACTION ONLY: the subject slowly places the product on the table and rests both hands beside it; the camera remains steady. End in a stable held pose.",
    duration: 6,
    video: $video,
    storage_options: {
      filename: "project-extension-0001.mp4",
      expires_after: 604800
    }
  }' > "$request_tmp"
chmod 600 "$request_tmp"
mv -- "$request_tmp" video.request.json
chmod 600 video.request.json
trap - EXIT HUP INT TERM
```

Sau đó khởi tạo operation mới với `ACTION=extensions`, `PARENT_STATE` trỏ tới parent và `EXPECTED_DURATION_SECONDS` bằng parent duration cộng phần mới. Init block tự lấy chain connection từ parent state và kiểm tra request `.video` khớp reusable input.

## 14. Persist output và QA checkpoint

`video.url` mặc định là URL tạm thời. Mỗi terminal success phải có hai asset trước khi trở thành parent:

- Bản local đã download, `ffprobe` được và hash SHA-256 để audit/rollback.
- Reusable input cho API kế tiếp: `file_output.file_id` còn hạn hoặc URL do caller quản lý còn hạn. Chỉ download local là chưa đủ cho extension.

### Download và kiểm tra media

```bash
set -Eeuo pipefail
umask 077
: "${OP_DIR:?Missing OP_DIR}"
BUDGET_RESERVATION_RENEWED_UNTIL="${BUDGET_RESERVATION_RENEWED_UNTIL:-}"
STATE_FILE="$OP_DIR/state.json"

state_update() {
  local filter="$1" tmp
  shift
  tmp="$(mktemp "$OP_DIR/.state.XXXXXX")"
  if ! jq "$@" "$filter" "$STATE_FILE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$STATE_FILE"
  sync -f "$OP_DIR"
}

exec 9>"$OP_DIR/operation.lock"
flock -n 9 || { printf 'Operation is locked by another worker\n' >&2; exit 1; }
now_epoch="$(date +%s)"
[[ "$BUDGET_RESERVATION_RENEWED_UNTIL" =~ ^[1-9][0-9]{8,11}$ ]] || {
  printf 'Persist requires a renewed external budget lease\n' >&2
  exit 1
}
(( BUDGET_RESERVATION_RENEWED_UNTIL - now_epoch >= 2100 )) || {
  printf 'Budget lease must cover download and QA margin\n' >&2
  exit 1
}
state_update '.budget.reservation_expires_at = $until' --argjson until "$BUDGET_RESERVATION_RENEWED_UNTIL"
phase="$(jq -r '.phase' "$STATE_FILE")"
case "$phase" in
  DONE_UNPERSISTED) quarantine=false ;;
  QUARANTINED_DONE) quarantine=true ;;
  *) printf 'Operation is not ready to persist\n' >&2; exit 1 ;;
esac

final_response="$OP_DIR/$(jq -r '.poll.final_response_file' "$STATE_FILE")"
video_url="$(jq -r '.video.url // .video.file_output.public_url // empty' "$final_response")"
[[ "$video_url" =~ ^https:// ]] || { printf 'Missing HTTPS video.url\n' >&2; exit 1; }

output="$OP_DIR/output.mp4"
if [[ -e "$output" ]]; then
  [[ -s "$output" ]] || { printf 'Existing output is empty\n' >&2; exit 1; }
  media_file="$output"
else
  part="$(mktemp "$OP_DIR/.output.XXXXXX.part")"
  trap 'rm -f -- "$part"' EXIT HUP INT TERM
  curl --silent --show-error --fail --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 1800 \
    --output "$part" "$video_url"
  [[ -s "$part" ]] || { printf 'Downloaded video is empty\n' >&2; exit 1; }
  media_file="$part"
fi

probe_file="$(mktemp "$OP_DIR/.probe.XXXXXX.json")"
trap 'rm -f -- "${part:-}" "$probe_file"' EXIT HUP INT TERM
ffprobe -v error -print_format json -show_format -show_streams "$media_file" > "$probe_file"
jq -e '
  (.format.format_name | type == "string" and test("(^|,)mov(,|$)|(^|,)mp4(,|$)")) and
  ([.streams[] | select(.codec_type == "video")] | length) >= 1 and
  all(.streams[] | select(.codec_type == "video");
    (.codec_name | IN("h264", "hevc", "av1")) and .width > 0 and .height > 0)
' "$probe_file" >/dev/null
ffmpeg -v error -xerror -i "$media_file" -map 0:v:0 -f null -
actual_duration="$(jq -r '.format.duration' "$probe_file")"
jq -en --argjson n "$actual_duration" '($n | type) == "number" and $n > 0' >/dev/null
sha256="$(sha256sum "$media_file" | awk '{print $1}')"
request_file="$OP_DIR/$(jq -r '.request.file' "$STATE_FILE")"
requested_resolution="$(jq -r '.resolution // empty' "$request_file")"
requested_ratio="$(jq -r '.aspect_ratio // empty' "$request_file")"
actual_width="$(jq -r '[.streams[] | select(.codec_type == "video")][0].width' "$probe_file")"
actual_height="$(jq -r '[.streams[] | select(.codec_type == "video")][0].height' "$probe_file")"
case "$requested_resolution" in
  480p) (( actual_height == 480 || actual_width == 480 )) || { printf 'Output does not match requested 480p\n' >&2; exit 1; } ;;
  720p) (( actual_height == 720 || actual_width == 720 )) || { printf 'Output does not match requested 720p\n' >&2; exit 1; } ;;
esac
if [[ -n "$requested_ratio" ]]; then
  ratio_ok="$(jq -n --arg ratio "$requested_ratio" --argjson w "$actual_width" --argjson h "$actual_height" '
    ($ratio | split(":") | map(tonumber)) as $r |
    (((($w / $h) - ($r[0] / $r[1])) | if . < 0 then -. else . end) <= 0.02)
  ')"
  [[ "$ratio_ok" == "true" ]] || { printf 'Output aspect ratio differs from request\n' >&2; exit 1; }
fi
if [[ "$media_file" != "$output" ]]; then
  mv -- "$media_file" "$output"
  trap - EXIT HUP INT TERM
fi
rm -f -- "$probe_file"
trap - EXIT HUP INT TERM

state_update '
  .phase = (if $quarantine then "QUARANTINED_PERSISTED" else "QA_PENDING" end) |
  .chain_eligible = (if $quarantine then false else .chain_eligible end) |
  .output = {
    local_file: "output.mp4",
    sha256: $sha256,
    duration_seconds: $duration,
    downloaded_at: $now,
    source_url_ephemeral: ($video[0].video.url != null)
  }
' --arg sha256 "$sha256" --argjson duration "$actual_duration" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson quarantine "$quarantine" \
  --slurpfile video "$final_response"

jq '{phase,output}' "$STATE_FILE"
```

### QA input

Vision/video reviewer phải tạo JSON có score 0-100 theo threshold trong state:

```json
{
  "reviewer": "agent-or-human-id",
  "moderation_passed": true,
  "identity_score": 94,
  "product_score": 93,
  "continuity_score": 92,
  "action_score": 95,
  "notes": "No visible identity or product drift. Requested action completed."
}
```

`moderation_passed` không thay thế upstream field `video.respect_moderation`; cả hai đều phải true. Nếu use case không có identity/product, set threshold tương ứng thành `0` và `QA_EXEMPTION_REASON` ngay từ init; không sửa state thủ công sau submit và không tự điền score giả.

### Chấp nhận checkpoint

Set URL do caller quản lý nếu không dùng xAI Files:

```bash
export QA_FILE="$PWD/qa.json"
export REUSABLE_URL=""                    # HTTPS URL do caller quản lý, không phải video.url tạm
export REUSABLE_URL_EXPIRES_AT=""         # Unix epoch vận hành; bắt buộc cho mọi REUSABLE_URL
export FILES_CLEANUP_CONFIRMED="true"     # Có quyền/policy xóa xAI Files
export MIN_REUSABLE_TTL_SECONDS="3600"
```

Acceptance block fail closed và persist cost. Nếu `usage.cost_in_usd_ticks` vắng, nó dùng reservation làm chi phí ước lượng bảo thủ:

```bash
set -Eeuo pipefail
umask 077
: "${OP_DIR:?Missing OP_DIR}"
: "${QA_FILE:?Missing QA_FILE}"
REUSABLE_URL="${REUSABLE_URL:-}"
REUSABLE_URL_EXPIRES_AT="${REUSABLE_URL_EXPIRES_AT:-}"
FILES_CLEANUP_CONFIRMED="${FILES_CLEANUP_CONFIRMED:-false}"
MIN_REUSABLE_TTL_SECONDS="${MIN_REUSABLE_TTL_SECONDS:-3600}"
BUDGET_RESERVATION_RENEWED_UNTIL="${BUDGET_RESERVATION_RENEWED_UNTIL:-}"
STATE_FILE="$OP_DIR/state.json"

state_update() {
  local filter="$1" tmp
  shift
  tmp="$(mktemp "$OP_DIR/.state.XXXXXX")"
  if ! jq "$@" "$filter" "$STATE_FILE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -- "$tmp" "$STATE_FILE"
  sync -f "$OP_DIR"
}

reject_checkpoint() {
  local reason="$1"
  local qa_json='null' qa_sha=''
  if [[ -n "${qa_evidence:-}" && -s "$qa_evidence" ]]; then
    qa_json="$(jq -c . "$qa_evidence")"
    qa_sha="$(sha256sum "$qa_evidence" | awk '{print $1}')"
  fi
  state_update '
    .phase = "REJECTED" |
    .chain_eligible = false |
    .stop_reason = $reason |
    .rejected_qa = (if $qa == null then null else {file:"qa.evidence.json", sha256:$sha, evidence:$qa} end)
  ' --arg reason "$reason" --argjson qa "$qa_json" --arg sha "$qa_sha"
  printf 'REJECTED: %s\n' "$reason" >&2
  exit 1
}

exec 9>"$OP_DIR/operation.lock"
flock -n 9 || { printf 'Operation is locked by another worker\n' >&2; exit 1; }
now_epoch="$(date +%s)"
[[ "$BUDGET_RESERVATION_RENEWED_UNTIL" =~ ^[1-9][0-9]{8,11}$ ]] || {
  printf 'QA acceptance requires a renewed external budget lease\n' >&2
  exit 1
}
(( BUDGET_RESERVATION_RENEWED_UNTIL - now_epoch >= MIN_REUSABLE_TTL_SECONDS )) || {
  printf 'Budget lease must cover the reusable-asset window\n' >&2
  exit 1
}
state_update '.budget.reservation_expires_at = $until' --argjson until "$BUDGET_RESERVATION_RENEWED_UNTIL"
[[ "$(jq -r '.phase' "$STATE_FILE")" == "QA_PENDING" ]] || {
  printf 'Operation is not QA_PENDING\n' >&2
  exit 1
}
jq -e 'type == "object"' "$QA_FILE" >/dev/null
qa_evidence="$OP_DIR/qa.evidence.json"
if [[ -e "$qa_evidence" ]]; then
  jq -e 'type == "object"' "$qa_evidence" >/dev/null
else
  qa_tmp="$(mktemp "$OP_DIR/.qa.XXXXXX")"
  trap 'rm -f -- "$qa_tmp"' EXIT HUP INT TERM
  jq -S . "$QA_FILE" > "$qa_tmp"
  mv -- "$qa_tmp" "$qa_evidence"
  sync -f "$OP_DIR"
  trap - EXIT HUP INT TERM
fi
qa_hash="$(sha256sum "$qa_evidence" | awk '{print $1}')"

final_response="$OP_DIR/$(jq -r '.poll.final_response_file' "$STATE_FILE")"
output="$OP_DIR/$(jq -r '.output.local_file' "$STATE_FILE")"
[[ -s "$output" ]] || reject_checkpoint 'missing local output'
expected_hash="$(jq -r '.output.sha256' "$STATE_FILE")"
[[ "$(sha256sum "$output" | awk '{print $1}')" == "$expected_hash" ]] || reject_checkpoint 'local output hash changed'

upstream_status="$(jq -r 'if (.status | type) == "string" then .status | ascii_downcase else "" end' "$final_response")"
case "$upstream_status" in done|completed) ;; *) reject_checkpoint 'job is not terminal success' ;; esac
jq -e '.video.respect_moderation == true' "$final_response" >/dev/null || reject_checkpoint 'upstream moderation did not pass'
jq -e '.moderation_passed == true' "$qa_evidence" >/dev/null || reject_checkpoint 'reviewer moderation did not pass'

storage_error="$(jq -c '.video.storage_error // .video.file_output.storage_error // empty' "$final_response")"
[[ -z "$storage_error" ]] || reject_checkpoint "storage error: $storage_error"

actual_duration="$(jq -r '.output.duration_seconds' "$STATE_FILE")"
duration_ok="$(jq -n \
  --argjson actual "$actual_duration" \
  --argjson expected "$(jq '.expected.duration_seconds' "$STATE_FILE")" \
  --argjson tolerance "$(jq '.expected.duration_tolerance_seconds' "$STATE_FILE")" \
  '($actual - $expected | if . < 0 then -. else . end) <= $tolerance')"
[[ "$duration_ok" == "true" ]] || reject_checkpoint 'duration outside configured tolerance'

jq -e \
  --argjson identity "$(jq '.expected.min_identity_score' "$STATE_FILE")" \
  --argjson product "$(jq '.expected.min_product_score' "$STATE_FILE")" \
  --argjson continuity "$(jq '.expected.min_continuity_score' "$STATE_FILE")" \
  --argjson action "$(jq '.expected.min_action_score' "$STATE_FILE")" '
    (.reviewer | type == "string" and length > 0) and
    ([.identity_score, .product_score, .continuity_score, .action_score] |
      all(.[]; (type == "number") and . >= 0 and . <= 100)) and
    (.identity_score >= $identity) and
    (.product_score >= $product) and
    (.continuity_score >= $continuity) and
    (.action_score >= $action)
  ' "$qa_evidence" >/dev/null || reject_checkpoint 'QA score invalid/below threshold or reviewer missing'

now_epoch="$(date +%s)"
file_id="$(jq -r '.video.file_output.file_id // empty' "$final_response")"
file_expires="$(jq -r '.video.file_output.expires_at // empty' "$final_response")"
reusable_input='null'
reusable_expires='null'

if [[ -n "$file_id" ]]; then
  [[ "$file_id" =~ ^file_[A-Za-z0-9._~-]+$ ]] || reject_checkpoint 'invalid xAI file_id'
  [[ "$FILES_CLEANUP_CONFIRMED" == "true" ]] || reject_checkpoint 'xAI file exists but cleanup is not confirmed'
  [[ "$file_expires" =~ ^[1-9][0-9]{8,11}$ ]] || reject_checkpoint 'xAI file expiry is required and invalid'
  (( file_expires - now_epoch >= MIN_REUSABLE_TTL_SECONDS )) || reject_checkpoint 'xAI file TTL is too short'
  reusable_expires="$file_expires"
  reusable_input="$(jq -n --arg file_id "$file_id" '{file_id:$file_id}')"
elif [[ -n "$REUSABLE_URL" ]]; then
  [[ "$REUSABLE_URL" =~ ^https://[^?#[:space:]]+\.mp4([?#].*)?$ ]] || reject_checkpoint 'reusable URL must be an HTTPS MP4 URL'
  ephemeral_url="$(jq -r '.video.url // empty' "$final_response")"
  [[ "$REUSABLE_URL" != "$ephemeral_url" ]] || reject_checkpoint 'default video.url is ephemeral, not caller-owned storage'
  [[ "$REUSABLE_URL_EXPIRES_AT" =~ ^[1-9][0-9]{8,11}$ ]] || reject_checkpoint 'reusable URL requires an explicit operational expiry'
  (( REUSABLE_URL_EXPIRES_AT - now_epoch >= MIN_REUSABLE_TTL_SECONDS )) || reject_checkpoint 'reusable URL TTL is too short'
  reusable_part="$(mktemp "$OP_DIR/.reusable.XXXXXX.part")"
  trap 'rm -f -- "$reusable_part"' EXIT HUP INT TERM
  curl --silent --show-error --fail --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 1800 \
    --output "$reusable_part" "$REUSABLE_URL" || reject_checkpoint 'reusable URL is not anonymously readable'
  [[ "$(sha256sum "$reusable_part" | awk '{print $1}')" == "$expected_hash" ]] || reject_checkpoint 'reusable URL bytes differ from QA-approved output'
  rm -f -- "$reusable_part"
  trap - EXIT HUP INT TERM
  reusable_expires="$REUSABLE_URL_EXPIRES_AT"
  reusable_input="$(jq -n --arg url "$REUSABLE_URL" '{url:$url}')"
else
  reject_checkpoint 'no reusable file_id or caller-owned URL'
fi

jq -e '
  (.budget.actual_ticks | type == "number") and
  (.budget.accounted_after_ticks | type == "number") and
  (.budget.over_limit != true)
' "$STATE_FILE" >/dev/null || reject_checkpoint 'terminal cost is missing or exceeds chain budget'

qa_compact="$(jq -c . "$qa_evidence")"
state_update '
  .phase = "ACCEPTED_CHECKPOINT" |
  .chain_eligible = true |
  .job.status = $status |
  .checkpoint = {
    accepted_at: $accepted_at,
    reusable_input: $reusable,
    reusable_expires_at: $expires,
    local_file: .output.local_file,
    sha256: .output.sha256,
    duration_seconds: $duration,
    qa: $qa,
    qa_file: "qa.evidence.json",
    qa_sha256: $qa_hash
  }
' --arg status "$upstream_status" --arg accepted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson reusable "$reusable_input" --argjson expires "$reusable_expires" \
  --argjson duration "$actual_duration" --argjson qa "$qa_compact" --arg qa_hash "$qa_hash"

jq '{
  phase,
  connection: {chain_id: .connection.chain_id},
  budget: {
    ledger_ref: .budget.ledger_ref,
    actual_ticks: .budget.actual_ticks,
    compute_accounted_after_ticks: .budget.compute_accounted_after_ticks,
    post_terminal_reserved_ticks: .budget.post_terminal_reserved_ticks,
    accounted_after_ticks: .budget.accounted_after_ticks,
    actual_is_estimate: .budget.actual_is_estimate,
    over_limit: .budget.over_limit
  },
  checkpoint: {
    accepted_at: .checkpoint.accepted_at,
    reusable_kind: (if .checkpoint.reusable_input.file_id then "file_id" else "url" end),
    reusable_expires_at: .checkpoint.reusable_expires_at,
    local_file: .checkpoint.local_file,
    sha256: .checkpoint.sha256,
    duration_seconds: .checkpoint.duration_seconds,
    qa_file: .checkpoint.qa_file,
    qa_sha256: .checkpoint.qa_sha256
  }
}' "$STATE_FILE"
```

Signed URL trong state có thể là credential; `umask 077` là bắt buộc và không được đưa operation directory vào public artifact/log. `file_id` upstream là team-scoped; mọi request dùng private `file_id`, kể cả generation/edit, phải pin cùng chain connection.

## 15. Storage lifecycle

Để xAI persist output, thêm:

```json
"storage_options": {
  "filename": "project-step-0001.mp4",
  "expires_after": 604800
}
```

Theo contract upstream, `expires_after` hợp lệ từ 3.600 đến 2.592.000 giây. Upstream có thể cho omit và giữ file đến khi xóa thủ công, nhưng runbook preflight bắt buộc TTL để tránh storage vô hạn. Chỉ dùng permanent file trong một policy riêng có cleanup automation và budget ledger phù hợp.

Public URL tạm do xAI Files tạo có thể được yêu cầu bằng:

```json
"storage_options": {
  "filename": "project-step-0001.mp4",
  "expires_after": 604800,
  "public_url": {"expires_after": 86400}
}
```

9Router v0.5.35 forward `storage_options` và response nhưng không proxy xAI Files upload/list/delete. Agent phải có direct xAI Files client hoặc caller-owned object storage để upload, renew URL và cleanup. Không chấp nhận checkpoint nếu `storage_error` có giá trị hoặc asset sẽ hết hạn trước QA/child submission/rollback window.

## 16. Video dài

Expected cumulative duration:

```text
expected_total = seed_duration + sum(extension_duration_i)
```

Không có maximum cumulative duration hoặc maximum extension count được 9Router enforce hay xAI công bố. Không hứa chain tùy ý sẽ thành công. State machine bắt buộc:

```text
DRAFT -> PREFLIGHT -> READY_TO_SUBMIT -> SUBMITTING -> ACCEPTED
-> POLLING -> DONE_UNPERSISTED -> QA_PENDING
-> ACCEPTED_CHECKPOINT hoặc REJECTED
-> operation con mới
```

Fail-closed states:

| State | Hành động |
|---|---|
| `BUDGET_STOP` | Không POST |
| `SUBMIT_REJECTED` | Sửa nguyên nhân; retry là operation mới có review/budget |
| `SUBMIT_UNKNOWN` | Không resubmit; reconcile request log/billing/operator |
| `POLL_RETRY_UNSAFE` | Dừng vì không có dedicated connection |
| `POLL_AFFINITY_UNKNOWN` | Headerless error trên multi-connection worker; không coi là terminal job result |
| `POLL_TIMEOUT` | Giữ request ID; resume/reconcile poll, không tạo job mới |
| `AFFINITY_LOST` | Quarantine job; ghi nhận cost/output nhưng không dùng trong chain |
| `RECONCILING`, `RECONCILE_TIMEOUT` | Chỉ poll/download job quarantine; không bật lại chain eligibility |
| `QUARANTINED_DONE`, `QUARANTINED_PERSISTED` | Output/cost đã thu thập cho audit/cleanup; không QA thành parent |
| `FAILED_FINAL`, `PROTOCOL_ERROR`, `REJECTED` | Không dùng output làm parent |

Prompt extension nên giữ block continuity bất biến và chỉ thay hành động mới:

```text
CONTINUE:
Continue uninterrupted from the exact final frame.

CONTINUITY LOCK:
[Same identity, face, age, hair, skin tone, body proportions, clothing,
product geometry, location, lens, camera height, lighting, color grade,
texture, motion speed và time of day.]

NEXT ACTION ONLY:
[Một hành động ngắn và tối đa một camera movement.]

DO NOT:
[No cut, reset, morph, new person, wardrobe change, product redesign,
new object, text, logo change, location change hoặc style change.]

END FRAME:
End in a stable held pose suitable for the next continuation.
```

Extension không nhận lại `image` hoặc `reference_images`, nên fidelity có thể drift. Với video dài:

1. Chia nội dung thành shot ngắn.
2. Re-anchor mỗi shot bằng I2V/R2V từ canonical reference.
3. Chỉ extend ngắn trong cùng shot.
4. QA từng output trước khi tạo child.
5. Ghép các shot sau khi normalize codec, resolution, frame rate và audio layout.

Không dùng một chuỗi extension vô hạn để thay thế re-anchor. Khi concat, tránh manifest tạo từ path không tin cậy; output phải ghi vào temporary file, `ffprobe`, hash rồi mới promote thành final master.

## 17. Connection affinity

POST/GET thành công trả:

```http
x-9router-connection-id: connection-id
```

Mọi poll và mọi video POST dùng private `file_id` hoặc chain parent phải gửi:

```http
x-connection-id: connection-id
```

Pinning là soft preference. Nếu preferred connection unavailable, 9Router có thể chọn account khác. Response header chỉ phát hiện đổi account sau khi POST có thể đã được accept và billed. Production chain phải:

- Dùng 9Router worker/instance chỉ có một xAI connection.
- Lưu chain ID trong parent `state.json`.
- Load ID từ state trong mỗi process; không dựa vào biến shell cũ.
- So sánh header trên mọi response thành công.
- Fail closed khi ID thiếu hoặc đổi.
- Không giả định hai connection thuộc cùng xAI team.

## 18. Retry và billing safety

Caller không tự retry video POST khi gặp timeout, reset, interruption, truncated response, `408`, `5xx`, malformed success hoặc thiếu `request_id`/connection header. Job có thể đã được tạo. `SUBMITTING` còn sót sau crash chỉ được reduce từ response evidence hoàn chỉnh đã fsync; nếu evidence thiếu/truncated thì coi như `SUBMIT_UNKNOWN` cho đến khi operator reconcile.

Các synchronous submit `4xx` được classifier liệt kê ghi `SUBMIT_REJECTED`; `408`, unclassified `4xx` và response mơ hồ vẫn là `SUBMIT_UNKNOWN`. Không retry ngay cùng operation. Sửa payload/auth/entitlement, reserve lại budget và tạo operation ID mới có chủ đích.

GET poll:

- Retry transport error, `408`, `429`, `5xx` và gateway `400 No credentials` do cooldown với backoff/jitter chỉ trên dedicated worker.
- Permanent `4xx` khác là final chỉ trên dedicated worker; multi-connection worker phải ghi `POLL_AFFINITY_UNKNOWN` vì error không có serving header.
- Không retry unknown status/protocol shape.
- Resume cùng `request_id`; không biến poll failure thành POST mới.

9Router có thể refresh/resend và rotate account nội bộ như mô tả ở phần submit. Vì không có local dedup store, chỉ một orchestrator được quyền tạo child trên một parent. Production DB nên có uniqueness constraint hoặc lease cho `(chain_id, parent_operation_id, active)`; `flock` trong recipe chỉ ngăn hai process thao tác cùng `OP_DIR`.

## 19. Cost và budget

Poll response có thể chứa:

```json
{"usage":{"cost_in_usd_ticks":1000000000}}
```

```text
1 USD = 10.000.000.000 ticks
```

Đổi sang USD để hiển thị:

```bash
jq '.usage.cost_in_usd_ticks / 10000000000' final-response.json
```

Budget policy:

- Trước POST, require `accounted_before_ticks + MAX_OPERATION_TICKS <= BUDGET_LIMIT_TICKS` trong cùng transaction reserve.
- `MAX_OPERATION_TICKS` phải bao gồm compute uncertainty; `POST_TERMINAL_RESERVATION_TICKS` giữ riêng phần storage retention/download/cleanup sau terminal response.
- Ambiguous/in-flight operation giữ nguyên reservation cho đến khi reconcile.
- Sau terminal response, account `usage.cost_in_usd_ticks + POST_TERMINAL_RESERVATION_TICKS`; nếu usage thiếu, giữ toàn `MAX_OPERATION_TICKS` như estimate bảo thủ.
- External ledger phải settle/release phần post-terminal reserve sau khi retention/download/cleanup thực sự hoàn tất; shell state không thay thế transaction này.
- Không lấy giá model từ registry 9Router; registry không phải billing source of truth.
- Dùng TTL và cleanup policy cho mọi cumulative output vì storage tăng theo từng step.

## 20. Error handling

| Error/status | Hành động |
|---|---|
| Gateway `401` | Kiểm tra `NINEROUTER_KEY`; không loop retry |
| Submit `No credentials for provider: xai` | Dừng; yêu cầu connect xAI account |
| Poll dedicated `400 No credentials` | Có thể là cooldown tạm của connection; backoff rồi poll cùng request ID |
| Upstream `403 permission_denied` | Dừng; kiểm tra entitlement/team/billing |
| `400 invalid model` | Sửa model ID; model video registered là `xai/grok-imagine-video` |
| `422 missing prompt` | Sửa payload và tạo operation mới |
| `invalid_argument` | Sửa MIME, URL, duration hoặc conflicting mode |
| `failed_precondition` | Đổi model/mode/resolution theo upstream contract |
| `pending`, `processing` | Poll tiếp |
| `done`, `completed` | Download, validate, QA, rồi mới accept |
| `failed`, `error`, `expired`, `cancelled` | Terminal; không auto-resubmit |
| Unknown/missing status | Protocol error; dừng |
| `service_unavailable` khi submit | Outcome có thể mơ hồ; không retry |

## 21. Agent checklist

### Ảnh

- Discovery model.
- Chọn model account hỗ trợ.
- Tạo payload theo provider.
- Với edit Codex, ưu tiên data URI.
- Không kết hợp SSE và binary query.
- Sniff output MIME.
- Validate output trước khi báo hoàn tất.

### Video

- Chọn đúng một generation mode: T2V, I2V hoặc R2V.
- Không gửi `image` cùng `reference_images`.
- Validate URL/MIME/file ID và upstream field constraints.
- Reserve worst-case budget trước POST.
- Tạo unique operation directory/state trước POST.
- Chỉ một worker submit; không reuse operation ID.
- Persist request hash, request ID, connection ID và mọi response evidence.
- Không retry submit outcome mơ hồ.
- Poll permanent/retryable error đúng phân loại.
- Download, `ffprobe` và hash output.
- Require upstream moderation, explicit QA scores và reusable asset.
- Chỉ `ACCEPTED_CHECKPOINT` được làm parent.
- Lưu actual cost hoặc conservative reservation.

### Video dài

- Dedicated single-xAI-connection worker.
- Load parent/connection/reusable input từ state file.
- Extension duration 2-10 giây.
- Verify cumulative duration trong tolerance đã cấu hình.
- Reject drift ngay; không extend output reject.
- Re-anchor bằng I2V/R2V khi cần.
- Dừng trước khi worst-case reservation vượt budget.
- TTL đủ dài và cleanup cho mọi persisted asset.
- Final master phải được validate và hash.

## 22. Capability boundaries

- 9Router v0.5.35 chỉ proxy video xAI ở ba action `generations`, `edits`, `extensions` và poll GET.
- Video body được forward gần như nguyên vẹn; 9Router không validate duration, reference, storage, moderation, codec, cost hoặc QA.
- I2V, R2V, edit, extension và `storage_options` phụ thuộc entitlement/account xAI và contract upstream có thể đổi.
- 9Router không proxy xAI Files lifecycle trong version này.
- Không có guarantee về maximum cumulative length, extension count, reference count hoặc long-chain identity fidelity.
- Không có guarantee `Idempotency-Key` chống job trùng.
- Không có guarantee model catalog đồng nghĩa model/account đang usable.
