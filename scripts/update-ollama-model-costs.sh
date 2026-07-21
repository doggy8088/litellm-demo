#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${LITELLM_ENDPOINT:-http://127.0.0.1:4000}"
MASTER_KEY="${LITELLM_MASTER_KEY:?請先在環境設定 LITELLM_MASTER_KEY}"
TIMEOUT="${LITELLM_TIMEOUT:-12}"
PRICE_MAP_FILE="${PRICE_MAP_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ollama-official-prices.json}"
LOG_FILE="${LOG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update-ollama-model-costs.log}"
ONLY_MISSING="${ONLY_MISSING:-1}"
DRY_RUN="${DRY_RUN:-0}"

if [ ! -f "$PRICE_MAP_FILE" ]; then
  echo "找不到價格檔：$PRICE_MAP_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq，請先安裝後再執行" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "缺少 curl，請先安裝後再執行" >&2
  exit 1
fi

: > "$LOG_FILE"

tmp_models="$(mktemp)"
trap 'rm -f "$tmp_models"' EXIT

raw="$(curl -sS -H "x-litellm-api-key: $MASTER_KEY" "$ENDPOINT/model/info")"
if [ -z "$raw" ]; then
  echo "無法取得 model 資料" >&2
  exit 1
fi

echo "$raw" | jq -c '.data[]' > "$tmp_models"

updated=0
skipped=0
missing=0
unchanged=0
failed=0

while IFS= read -r row; do
  model_name="$(echo "$row" | jq -r '.model_name // empty')"
  model_id="$(echo "$row" | jq -r '.model_info.id // empty')"
  current_is_zero="$(echo "$row" | jq -r '((.litellm_params.input_cost_per_token // 0) == 0 and (.litellm_params.output_cost_per_token // 0) == 0)')"

  if [ -z "$model_name" ] || [ -z "$model_id" ]; then
    continue
  fi

  price="$(jq -r --arg n "$model_name" '.[$n] // empty' "$PRICE_MAP_FILE")"
  if [ -z "$price" ] || [ "$price" = "null" ]; then
    price="$(python3 - "$model_name" "$PRICE_MAP_FILE" <<'PY'
import json
import re
import sys

name = sys.argv[1].lower()
path = sys.argv[2]
normalized = re.sub(r"[^a-z0-9]", "", name)

with open(path, "r", encoding="utf-8") as fp:
    data = json.load(fp)

for key, val in data.items():
    if re.sub(r"[^a-z0-9]", "", key.lower()) == normalized and isinstance(val, dict):
        print(json.dumps(val))
        raise SystemExit

print("", end="")
PY
)"
  fi

  if [ -z "$price" ]; then
    skipped=$((skipped + 1))
    echo "[$model_id] $model_name 未找到對應價格" >> "$LOG_FILE"
    continue
  fi

  target_in="$(echo "$price" | jq -r '.input_cost_per_token')"
  target_out="$(echo "$price" | jq -r '.output_cost_per_token')"
  target_is_zero="$(jq -n --argjson in "$target_in" --argjson out "$target_out" '$in == 0 and $out == 0')"
  source="$(echo "$price" | jq -r '.source // ""')"

  if [ "$target_is_zero" = "true" ]; then
    missing=$((missing + 1))
    echo "[$model_id] $model_name 價格來源為 0，已列為待補 (${source})" >> "$LOG_FILE"
    continue
  fi

  if [ "$ONLY_MISSING" = "1" ]; then
    if [ "$current_is_zero" != "true" ]; then
      unchanged=$((unchanged + 1))
      continue
    fi
  fi

  update_payload="$(jq -n \
    --arg name "$model_name" \
    --arg id "$model_id" \
    --argjson input "$target_in" \
    --argjson output "$target_out" \
    '{model_name:$name, model_info:{id:$id}, litellm_params:{input_cost_per_token:$input,output_cost_per_token:$output}}')"

  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY-RUN: update [$model_id][$model_name] input=$target_in output=$target_out source=$source"
    updated=$((updated + 1))
    continue
  fi

  response_file="$(mktemp)"
  status="$(curl -sS -o "$response_file" -w '%{http_code}' --max-time "$TIMEOUT" -H "x-litellm-api-key: $MASTER_KEY" -H 'Content-Type: application/json' -X POST "$ENDPOINT/model/update" -d "$update_payload")"
  if [ "$status" != "200" ]; then
    failed=$((failed + 1))
    echo "[$model_id] $model_name 更新失敗 HTTP $status" >> "$LOG_FILE"
    cat "$response_file" >> "$LOG_FILE"
    echo >> "$LOG_FILE"
  else
    updated=$((updated + 1))
    echo "[$model_id] $model_name 已更新 input=$target_in output=$target_out source=$source"
  fi
  rm -f "$response_file"
done < "$tmp_models"

echo "更新完成"
echo "已更新: $updated"
echo "已略過(無價格映射): $skipped"
echo "已標示為待補(0 價格): $missing"
echo "已略過(原本有值): $unchanged"
echo "更新失敗: $failed"
echo "日誌: $LOG_FILE"

if [ "$failed" -ne 0 ]; then
  echo "請查看日誌：$LOG_FILE"
  exit 1
fi
