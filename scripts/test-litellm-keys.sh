#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${LITELLM_ENDPOINT:-http://127.0.0.1:4000}"
KEY_FILE="${1:-virtual-keys.txt}"
MODEL_HINT="${MODEL_HINT:-}"
LOG_FILE="${2:-scripts/test-litellm-keys.log}"
TIMEOUT="${LITELLM_TIMEOUT:-12}"

if [ ! -f "$KEY_FILE" ]; then
  echo "找不到金鑰檔：$KEY_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq，請先安裝 jq 後再執行" >&2
  exit 1
fi

: > "$LOG_FILE"

total=0
ok=0
fail=0

mask_key() {
  local k="$1"
  local len="${#k}"
  if [ "$len" -lt 12 ]; then
    echo "******"
  else
    echo "${k:0:6}...${k: -6}"
  fi
}

call_api() {
  local method="$1"
  local url="$2"
  local key="$3"
  local data="${4:-}"
  local out_file="$5"

  if [ -n "$data" ]; then
    curl -sS -o "$out_file" -w "%{http_code}" \
      --max-time "$TIMEOUT" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      -X "$method" \
      -d "$data" \
      "$url"
  else
    curl -sS -o "$out_file" -w "%{http_code}" \
      --max-time "$TIMEOUT" \
      -H "Authorization: Bearer $key" \
      -X "$method" \
      "$url"
  fi
}

echo "開始測試"
echo "Endpoint: $ENDPOINT"
echo "金鑰檔: $KEY_FILE"
echo "測試結果日誌: $LOG_FILE"

while IFS= read -r key; do
  [ -z "${key// }" ] && continue
  [ "${key:0:1}" = "#" ] && continue
  total=$((total + 1))

  masked="$(mask_key "$key")"
  echo "[$total] $masked"

  model_body="$(mktemp)"
  model_status="$(call_api GET "$ENDPOINT/v1/models" "$key" "" "$model_body")"

  if [ "$model_status" != "200" ]; then
    echo "  - /v1/models: 失敗 (HTTP $model_status)"
    cat "$model_body" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
    rm -f "$model_body"
    fail=$((fail + 1))
    continue
  fi

  model_count="$(jq -r '.data | length' "$model_body" 2>/dev/null || echo 0)"
  if [ "$model_count" -eq 0 ] || [ "$model_count" = "null" ]; then
    echo "  - /v1/models: 無可用模型"
    rm -f "$model_body"
    fail=$((fail + 1))
    continue
  fi

  target_model="${MODEL_HINT}"
  if [ -z "$target_model" ]; then
    target_model="$(jq -r '.data[0].id' "$model_body")"
  fi
  rm -f "$model_body"

  payload="$(cat <<JSON
{
  "model": "$target_model",
  "messages": [
    {"role": "user", "content": "請回覆「ok」"}
  ],
  "max_tokens": 8
}
JSON
)"

  chat_body="$(mktemp)"
  chat_status="$(call_api POST "$ENDPOINT/v1/chat/completions" "$key" "$payload" "$chat_body")"
  if [ "$chat_status" != "200" ]; then
    echo "  - /v1/models: ok ($model_count 個)"
    echo "  - /v1/chat/completions: 失敗 (HTTP $chat_status)"
    cat "$chat_body" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
    rm -f "$chat_body"
    fail=$((fail + 1))
    continue
  fi

  rm -f "$chat_body"
  echo "  - /v1/models: ok ($model_count 個)"
  echo "  - /v1/chat/completions: ok (model=$target_model)"
  ok=$((ok + 1))
done < "$KEY_FILE"

echo "測試完成：總共 $total 把，成功 $ok 把，失敗 $fail 把"
if [ "$fail" -ne 0 ]; then
  echo "請查看日誌：$LOG_FILE"
fi
