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

output_dir="results/judging"
mkdir -p "$output_dir"

judge_model="ag/gemini-3-flash"
generation_prompt="Create a clean editorial poster, square composition: a small red robot watering one blue sunflower in a white ceramic pot, cream background, soft window light. Add exactly the text 'MEDIA LAB' at the top in bold black sans-serif. No other text."
edit_prompt="Edit the supplied poster only: change the blue sunflower to bright yellow. Preserve the red robot, white ceramic pot, cream background, square composition, and the exact text 'MEDIA LAB'. Add no other text."

generation_files=(
  "results/text-to-image/xai__grok-imagine-image.jpg"
  "results/text-to-image/ag__gemini-3.1-flash-image.jpg"
  "results/text-to-image/cx__gpt-5.5-image.png"
  "results/text-to-image/cx__gpt-5.4-image.png"
)

edit_files=(
  "results/image-edit/cx__gpt-5.5-image.png"
  "results/image-edit/cx__gpt-5.4-image.png"
)

mime_for_file() {
  file --brief --mime-type "$1"
}

judge_generation() {
  local image_file="$1"
  local slug payload image_b64 image_mime
  slug="$(basename "$image_file")"
  slug="${slug%.*}"
  payload="$output_dir/$slug.generation.request.json"
  image_b64="$output_dir/$slug.base64"
  image_mime="$(mime_for_file "$image_file")"

  base64 --wrap=0 "$image_file" > "$image_b64"
  jq -n \
    --arg model "$judge_model" \
    --arg expected "$generation_prompt" \
    --arg mime "$image_mime" \
    --rawfile image "$image_b64" \
    '{
      model: $model,
      temperature: 0,
      stream: false,
      messages: [{
        role: "user",
        content: [
          {
            type: "text",
            text: ("Act as a strict image benchmark judge. Compare the attached image with this expected prompt: " + $expected + " Return ONLY one compact JSON object with integer scores from 0 to 10 using keys: prompt_adherence, composition, text_accuracy, visual_quality, overall; plus boolean exact_media_lab, integer extra_text_count, and a short string notes. Do not use markdown.")
          },
          {
            type: "image_url",
            image_url: {url: ("data:" + $mime + ";base64," + $image), detail: "high"}
          }
        ]
      }]
    }' > "$payload"

  curl --silent --show-error --max-time 180 \
    --request POST \
    --header "Authorization: Bearer ${NINEROUTER_KEY}" \
    --header "Content-Type: application/json" \
    --data-binary "@$payload" \
    --output "$output_dir/$slug.generation.response.json" \
    "${NINEROUTER_URL%/}/v1/chat/completions"

  jq -r '.choices[0].message.content // .error.message // empty' \
    "$output_dir/$slug.generation.response.json" > "$output_dir/$slug.generation.judgment.json"
  printf '%s: ' "$slug"
  jq -c . "$output_dir/$slug.generation.judgment.json" 2>/dev/null || \
    tr '\n' ' ' < "$output_dir/$slug.generation.judgment.json"

  rm -f "$payload" "$image_b64"
}

judge_edit() {
  local edited_file="$1"
  local source_file="results/text-to-image/ag__gemini-3.1-flash-image.jpg"
  local slug payload source_b64 edited_b64 source_mime edited_mime
  slug="$(basename "$edited_file")"
  slug="${slug%.*}"
  payload="$output_dir/$slug.edit.request.json"
  source_b64="$output_dir/source.base64"
  edited_b64="$output_dir/$slug.base64"
  source_mime="$(mime_for_file "$source_file")"
  edited_mime="$(mime_for_file "$edited_file")"

  base64 --wrap=0 "$source_file" > "$source_b64"
  base64 --wrap=0 "$edited_file" > "$edited_b64"
  jq -n \
    --arg model "$judge_model" \
    --arg expected "$edit_prompt" \
    --arg source_mime "$source_mime" \
    --arg edited_mime "$edited_mime" \
    --rawfile source "$source_b64" \
    --rawfile edited "$edited_b64" \
    '{
      model: $model,
      temperature: 0,
      stream: false,
      messages: [{
        role: "user",
        content: [
          {
            type: "text",
            text: ("Act as a strict image-edit benchmark judge. Image 1 is SOURCE and image 2 is EDITED. Expected edit: " + $expected + " Return ONLY one compact JSON object with integer scores from 0 to 10 using keys: requested_change, preservation, text_accuracy, visual_quality, overall; plus booleans flower_is_yellow and exact_media_lab, and a short string notes. Do not use markdown.")
          },
          {type: "text", text: "IMAGE 1 - SOURCE"},
          {
            type: "image_url",
            image_url: {url: ("data:" + $source_mime + ";base64," + $source), detail: "high"}
          },
          {type: "text", text: "IMAGE 2 - EDITED"},
          {
            type: "image_url",
            image_url: {url: ("data:" + $edited_mime + ";base64," + $edited), detail: "high"}
          }
        ]
      }]
    }' > "$payload"

  curl --silent --show-error --max-time 180 \
    --request POST \
    --header "Authorization: Bearer ${NINEROUTER_KEY}" \
    --header "Content-Type: application/json" \
    --data-binary "@$payload" \
    --output "$output_dir/$slug.edit.response.json" \
    "${NINEROUTER_URL%/}/v1/chat/completions"

  jq -r '.choices[0].message.content // .error.message // empty' \
    "$output_dir/$slug.edit.response.json" > "$output_dir/$slug.edit.judgment.json"
  printf '%s: ' "$slug"
  jq -c . "$output_dir/$slug.edit.judgment.json" 2>/dev/null || \
    tr '\n' ' ' < "$output_dir/$slug.edit.judgment.json"

  rm -f "$payload" "$source_b64" "$edited_b64"
}

for image_file in "${generation_files[@]}"; do
  judge_generation "$image_file"
done

for edited_file in "${edit_files[@]}"; do
  judge_edit "$edited_file"
done
