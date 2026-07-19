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

output_dir="${1:-results/text-to-image}"
mkdir -p "$output_dir"
overall_exit=0

prompt="Create a clean editorial poster, square composition: a small red robot watering one blue sunflower in a white ceramic pot, cream background, soft window light. Add exactly the text 'MEDIA LAB' at the top in bold black sans-serif. No other text."

models=(
  "xai/grok-2-image-1212"
  "ag/gemini-3.1-flash-image"
  "cx/gpt-5.5-image"
  "cx/gpt-5.4-image"
  "cx/gpt-5.3-image"
  "cx/gpt-image-2"
)

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

  printf 'Testing %s...\n' "$model"

  curl_exit=0
  curl_metrics_json="$(curl --silent --show-error --max-time 600 \
    --request POST \
    --header "Authorization: Bearer ${NINEROUTER_KEY}" \
    --header "Content-Type: application/json" \
    --data "$(jq -nc --arg model "$model" --arg prompt "$prompt" \
      '{model:$model,prompt:$prompt,n:1,size:"1024x1024"}')" \
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

  if jq empty "$curl_metrics" >/dev/null 2>&1; then
    jq \
      --arg model "$model" \
      --arg prompt "$prompt" \
      --arg artifact "$artifact" \
      --arg detected_mime "$mime_type" \
      --argjson curl_exit "$curl_exit" \
      '{
        model: $model,
        prompt: $prompt,
        curl_exit: $curl_exit,
        http_code,
        content_type,
        detected_mime: $detected_mime,
        time_total,
        size_download,
        artifact: $artifact
      }' "$curl_metrics" > "$summary"
  else
    jq -n \
      --arg model "$model" \
      --arg prompt "$prompt" \
      --arg artifact "$artifact" \
      --arg detected_mime "$mime_type" \
      --argjson curl_exit "$curl_exit" \
      '{
        model: $model,
        prompt: $prompt,
        curl_exit: $curl_exit,
        detected_mime: $detected_mime,
        artifact: $artifact
      }' > "$summary"
  fi

  jq '{model,curl_exit,http_code,detected_mime,time_total,size_download,artifact}' "$summary"

  http_code="$(jq -r '.http_code // 0' "$summary")"
  if [[ "$curl_exit" -ne 0 || "$http_code" -lt 200 || "$http_code" -ge 300 || "$mime_type" != image/* ]]; then
    overall_exit=1
  fi
done

exit "$overall_exit"
