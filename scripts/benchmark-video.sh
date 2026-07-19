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

output_dir="${1:-results/video}"
mkdir -p "$output_dir"

if [[ -e "$output_dir/create.json" ]]; then
  printf 'Refusing to submit another potentially billable job in an existing result directory: %s\n' "$output_dir" >&2
  printf 'Pass a new output directory when you intentionally want a new run.\n' >&2
  exit 2
fi

prompt="A small red toy robot gently waters one yellow sunflower in a white ceramic pot, cream studio background, locked camera, soft window light. No text."
model="xai/grok-imagine-video"
idempotency_key="media-agents-benchmark-2026-07-18-v1"

printf '%s\n' "$prompt" > "$output_dir/prompt.txt"

# The client sends one creation request. 9Router may still rotate accounts on
# pre-job auth/quota errors. The forwarded idempotency key is not a documented
# xAI deduplication guarantee, so never repeat an ambiguous creation manually.
curl_exit=0
curl_metrics_json="$(curl --silent --show-error --max-time 120 \
  --request POST \
  --header "Authorization: Bearer ${NINEROUTER_KEY}" \
  --header "Content-Type: application/json" \
  --header "Idempotency-Key: $idempotency_key" \
  --data "$(jq -nc --arg model "$model" --arg prompt "$prompt" \
    '{model:$model,prompt:$prompt,duration:2,aspect_ratio:"1:1",resolution:"480p"}')" \
  --dump-header "$output_dir/create.headers" \
  --output "$output_dir/create.json" \
  --write-out '%{json}' \
  "${NINEROUTER_URL%/}/v1/videos/generations")" || curl_exit=$?
jq '{http_code,content_type,time_total,size_download}' <<< "$curl_metrics_json" > "$output_dir/create.curl.json"

http_code="$(jq -r '.http_code // 0' "$output_dir/create.curl.json" 2>/dev/null || printf '0')"
request_id="$(jq -r '.request_id // empty' "$output_dir/create.json" 2>/dev/null || true)"
connection_id="$(tr -d '\r' < "$output_dir/create.headers" | awk -F ': ' 'tolower($1) == "x-9router-connection-id" { print $2 }' | tail -n 1)"

jq -n \
  --arg model "$model" \
  --arg prompt "$prompt" \
  --arg request_id "$request_id" \
  --arg connection_id "$connection_id" \
  --argjson curl_exit "$curl_exit" \
  --argjson http_code "${http_code:-0}" \
  '{
    model: $model,
    prompt: $prompt,
    duration: 2,
    aspect_ratio: "1:1",
    resolution: "480p",
    curl_exit: $curl_exit,
    http_code: $http_code,
    request_id: $request_id,
    connection_id_present: ($connection_id != "")
  }' > "$output_dir/summary.json"

if [[ "$curl_exit" -ne 0 || -z "$request_id" ]]; then
  jq '{model,curl_exit,http_code,request_id,connection_id_present}' "$output_dir/summary.json"
  exit 1
fi

deadline=$((SECONDS + 600))
poll_count=0
status="pending"

while (( SECONDS < deadline )); do
  poll_count=$((poll_count + 1))
  curl --silent --show-error --max-time 30 \
    --header "Authorization: Bearer ${NINEROUTER_KEY}" \
    --header "x-connection-id: $connection_id" \
    --output "$output_dir/poll-latest.json" \
    "${NINEROUTER_URL%/}/v1/videos/$request_id" || true

  status="$(jq -r '.status // empty' "$output_dir/poll-latest.json" 2>/dev/null || true)"
  printf 'Poll %d: %s\n' "$poll_count" "${status:-unknown}"
  if [[ "$status" == "done" || "$status" == "failed" || "$status" == "expired" ]]; then
    break
  fi
  sleep 5
done

video_url="$(jq -r '.video.url // empty' "$output_dir/poll-latest.json" 2>/dev/null || true)"
if [[ "$status" == "done" && -n "$video_url" ]]; then
  if ! curl --silent --show-error --fail --max-time 300 \
    --output "$output_dir/xai__grok-imagine-video.mp4.part" \
    "$video_url"; then
    rm -f "$output_dir/xai__grok-imagine-video.mp4.part"
    printf 'Video download failed\n' >&2
    exit 1
  fi
  mv "$output_dir/xai__grok-imagine-video.mp4.part" "$output_dir/xai__grok-imagine-video.mp4"
fi

artifact=null
if [[ -f "$output_dir/xai__grok-imagine-video.mp4" ]]; then
  artifact="\"$output_dir/xai__grok-imagine-video.mp4\""
fi

jq \
  --arg status "${status:-unknown}" \
  --argjson poll_count "$poll_count" \
  --argjson artifact "$artifact" \
  '. + {
    status: $status,
    poll_count: $poll_count,
    artifact: $artifact
  }' "$output_dir/summary.json" > "$output_dir/summary.tmp.json"
mv "$output_dir/summary.tmp.json" "$output_dir/summary.json"

jq '{model,curl_exit,http_code,request_id,connection_id_present,status,poll_count,artifact}' "$output_dir/summary.json"

if [[ "$status" != "done" || ! -f "$output_dir/xai__grok-imagine-video.mp4" ]]; then
  exit 1
fi
