#!/usr/bin/env bash

set -u

if [[ -z "${NINEROUTER_URL:-}" ]]; then
  printf 'NINEROUTER_URL is required\n' >&2
  exit 1
fi

if [[ -z "${NINEROUTER_KEY:-}" ]]; then
  printf 'NINEROUTER_KEY is required\n' >&2
  exit 1
fi

source_image="${1:-results/text-to-image/ag__gemini-3.1-flash-image.jpg}"
output_dir="${2:-results/image-edit}"

if [[ ! -f "$source_image" ]]; then
  printf 'Source image not found: %s\n' "$source_image" >&2
  exit 1
fi

mkdir -p "$output_dir"
overall_exit=0

prompt="Edit the supplied poster only: change the blue sunflower to bright yellow. Preserve the red robot, white ceramic pot, cream background, square composition, and the exact text 'MEDIA LAB'. Add no other text."
models=(
  "cx/gpt-5.5-image"
  "cx/gpt-5.4-image"
  "cx/gpt-5.3-image"
  "cx/gpt-image-2"
)

source_mime="$(file --brief --mime-type "$source_image")"
if [[ "$source_mime" != image/* ]]; then
  printf 'Unsupported source image MIME type: %s\n' "$source_mime" >&2
  exit 1
fi

base64_file="$output_dir/source.base64"
payload="$output_dir/request.json"
base64 --wrap=0 "$source_image" > "$base64_file"
printf '%s\n' "$prompt" > "$output_dir/prompt.txt"

for model in "${models[@]}"; do
  slug="${model//\//__}"
  response="$output_dir/$slug.response"
  headers="$output_dir/$slug.headers"
  curl_metrics="$output_dir/$slug.curl.json"
  summary="$output_dir/$slug.json"

  rm -f \
    "$output_dir/$slug.bin" \
    "$output_dir/$slug.png" \
    "$output_dir/$slug.jpg" \
    "$output_dir/$slug.webp" \
    "$output_dir/$slug.error.json" \
    "$output_dir/$slug.error.txt" \
    "$response" "$headers" "$curl_metrics" "$summary"

  jq -n \
    --arg model "$model" \
    --arg prompt "$prompt" \
    --arg source_mime "$source_mime" \
    --rawfile source "$base64_file" \
    '{
      model: $model,
      prompt: $prompt,
      image: ("data:" + $source_mime + ";base64," + $source),
      image_detail: "high",
      output_format: "png"
    }' > "$payload"

  printf 'Testing edit with %s...\n' "$model"

  curl_exit=0
  curl_metrics_json="$(curl --silent --show-error --max-time 600 \
    --request POST \
    --header "Authorization: Bearer ${NINEROUTER_KEY}" \
    --header "Content-Type: application/json" \
    --data-binary "@$payload" \
    --dump-header "$headers" \
    --output "$response" \
    --write-out '%{json}' \
    "${NINEROUTER_URL%/}/v1/images/generations?response_format=binary")" || curl_exit=$?
  jq '{http_code,content_type,time_total,size_download}' <<< "$curl_metrics_json" > "$curl_metrics"

  mime_type="$(file --brief --mime-type "$response" 2>/dev/null || true)"
  extension="bin"
  case "$mime_type" in
    image/png) extension="png" ;;
    image/jpeg) extension="jpg" ;;
    image/webp) extension="webp" ;;
    application/json) extension="error.json" ;;
    text/*) extension="error.txt" ;;
  esac
  artifact="$output_dir/$slug.$extension"
  mv "$response" "$artifact"

  jq \
    --arg model "$model" \
    --arg prompt "$prompt" \
    --arg source_image "$source_image" \
    --arg artifact "$artifact" \
    --arg detected_mime "$mime_type" \
    --argjson curl_exit "$curl_exit" \
    '{
      model: $model,
      prompt: $prompt,
      source_image: $source_image,
      curl_exit: $curl_exit,
      http_code,
      content_type,
      detected_mime: $detected_mime,
      time_total,
      size_download,
      artifact: $artifact
    }' "$curl_metrics" > "$summary"

  jq '{model,curl_exit,http_code,detected_mime,time_total,size_download,artifact}' "$summary"

  http_code="$(jq -r '.http_code // 0' "$summary")"
  if [[ "$curl_exit" -ne 0 || "$http_code" -lt 200 || "$http_code" -ge 300 || "$mime_type" != image/* ]]; then
    overall_exit=1
  fi
done

rm -f "$base64_file" "$payload"
exit "$overall_exit"
