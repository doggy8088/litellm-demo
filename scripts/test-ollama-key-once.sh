#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${LITELLM_ENDPOINT:-http://127.0.0.1:4000}"
KEY="${1:?請提供 Virtual Key，執行方式：$0 <api_key> [model] [endpoint]}"
MODEL_HINT="${2:-}"
ENDPOINT="${3:-$ENDPOINT}"
TIMEOUT="${LITELLM_TIMEOUT:-12}"

if [ -z "$KEY" ]; then
  echo "缺少 API Key" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "缺少 python3，請先安裝 python3 後再執行" >&2
  exit 1
fi

MASKED_KEY="${KEY:0:6}...${KEY: -6}"
echo "開始測試：$MASKED_KEY"
echo "Endpoint：$ENDPOINT"

curl_call() {
  local method="$1"
  local path="$2"
  local payload="$3"
  RESPONSE_STATUS=""
  RESPONSE_BODY=""
  
  local raw status body
  local code
  if [ -n "$payload" ]; then
    set +e
    raw="$(curl -sS -m "$TIMEOUT" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -X "$method" -d "$payload" "$ENDPOINT$path" -w '\n__HTTP_STATUS__:%{http_code}')"
    code=$?
    set -e
  else
    set +e
    raw="$(curl -sS -m "$TIMEOUT" -H "Authorization: Bearer $KEY" -X "$method" "$ENDPOINT$path" -w '\n__HTTP_STATUS__:%{http_code}')"
    code=$?
    set -e
  fi

  if [ "$code" -ne 0 ]; then
    RESPONSE_STATUS="000"
    RESPONSE_BODY="$raw"
  else
    RESPONSE_STATUS="$(printf '%s' "$raw" | tail -n 1 | sed 's/^__HTTP_STATUS__://')"
    RESPONSE_BODY="$(printf '%s' "$raw" | sed '$d')"
  fi
}

echo "1/3  測試 /v1/models"
curl_call GET "/v1/models" ""
if [ "$RESPONSE_STATUS" != "200" ]; then
  echo "/v1/models 失敗（HTTP $RESPONSE_STATUS）"
  echo "$RESPONSE_BODY"
  exit 1
fi

if [ -n "$MODEL_HINT" ]; then
  MODEL="$MODEL_HINT"
else
  MODEL="$(printf '%s' "$RESPONSE_BODY" | python3 - <<'PY'
import json
import sys

data = json.loads(sys.stdin.read() or "{}")
models = data.get("data", [])
if not models:
    raise SystemExit("No models found")
print(models[0].get("id") or models[0].get("model") or "")
PY
  )"
fi

if [ -z "$MODEL" ]; then
  echo "/v1/models 回傳空模型名稱"
  exit 1
fi

echo "2/3  使用模型：$MODEL"
PAYLOAD=$(cat <<JSON
{
  "model": "$MODEL",
  "messages": [
    {"role": "user", "content": "請只回覆 ok"}
  ],
  "max_tokens": 8
}
JSON
)

echo "3/3  測試 /v1/chat/completions"
curl_call POST "/v1/chat/completions" "$PAYLOAD"
if [ "$RESPONSE_STATUS" != "200" ]; then
  echo "/v1/chat/completions 失敗（HTTP $RESPONSE_STATUS）"
  echo "$RESPONSE_BODY"
  exit 1
fi

CHAT_MESSAGE="$(printf '%s' "$RESPONSE_BODY" | python3 - <<'PY'
import json
import sys

data = json.loads(sys.stdin.read() or "{}")
choices = data.get("choices", [])
if not choices:
    raise SystemExit("No choices in response")

message = choices[0].get("message", {}).get("content", "")
print((message or "").strip())
PY
)"

if [ -z "$CHAT_MESSAGE" ]; then
  echo "/v1/chat/completions 只回應成功但訊息空白"
  exit 1
fi

echo "PASS：模型可用"
echo "回應：$CHAT_MESSAGE"
echo "總結：PASS"
