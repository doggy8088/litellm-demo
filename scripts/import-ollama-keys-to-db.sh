#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${LITELLM_ENDPOINT:-http://127.0.0.1:4000}"
MASTER_KEY="${LITELLM_MASTER_KEY:?請先在環境設定 LITELLM_MASTER_KEY}"
CONFIG_FILE="${1:-config.yaml}"
KEY_FILE="${2:-oc-keys.txt}"
API_BASE="${API_BASE:-https://ollama.com}"
PREFIX="${CRED_PREFIX:-ollama-key}"
TIMEOUT="${LITELLM_TIMEOUT:-12}"
DRY_RUN="${DRY_RUN:-0}"

if [ ! -f "$KEY_FILE" ]; then
  echo "找不到金鑰檔：$KEY_FILE" >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "找不到設定檔：$CONFIG_FILE" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "缺少 curl" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "缺少 python3" >&2
  exit 1
fi

tmp_models="$(mktemp)"
trap 'rm -f "$tmp_models"' EXIT

python3 - "$CONFIG_FILE" <<'PY' > "$tmp_models"
import json
import sys
import yaml

path = sys.argv[1]
cfg = yaml.safe_load(open(path))
model_list = cfg.get("model_list", [])

seen = set()
for item in model_list:
    name = item.get("model_name")
    if not name:
        continue
    litellm_model = item.get("litellm_params", {}).get("model", "")
    if not litellm_model:
        litellm_model = f"ollama_chat/{name}"
    if name not in seen:
        seen.add(name)
        print(json.dumps({"name": name, "litellm_model": litellm_model}))
PY

if [ ! -s "$tmp_models" ]; then
  echo "config.yaml 中沒取到 model_list，請先確認資料正確" >&2
  exit 1
fi

model_count="$(wc -l < "$tmp_models")"
key_count="$(grep -cve '^[[:space:]]*$' "$KEY_FILE")"
mapfile -t model_lines < "$tmp_models"

existing_credentials="$(curl -sS -H "x-litellm-api-key: $MASTER_KEY" "$ENDPOINT/credentials" | jq -r '.credentials[].credential_name' | sort -u)"

log_file="scripts/import-ollama-keys-to-db.log"
: > "$log_file"

created_creds=0
skipped_creds=0
created_models=0
failed_models=0
failed_lines=()
idx=0

while IFS= read -r api_key; do
  if [ -z "${api_key// }" ]; then
    continue
  fi
  idx=$((idx + 1))
  cred_name="${PREFIX}-$(printf '%03d' "$idx")"

  if echo "$existing_credentials" | grep -Fxq "$cred_name"; then
    skipped_creds=$((skipped_creds + 1))
  else
    if [ "$DRY_RUN" = "1" ]; then
      echo "DRY-RUN 跳過建立憑證：$cred_name"
    else
      payload="$(jq -n --arg credential_name "$cred_name" --arg api_key "$api_key" --arg api_base "$API_BASE" '{credential_name:$credential_name,credential_info:{provider:"ollama"},credential_values:{api_key:$api_key,api_base:$api_base}}')"
      response_file="$(mktemp)"
      status="$(curl -sS -o "$response_file" -w '%{http_code}' --max-time "$TIMEOUT" -H "x-litellm-api-key: $MASTER_KEY" -H 'Content-Type: application/json' -X POST "$ENDPOINT/credentials" -d "$payload")"
      if [ "$status" != "200" ]; then
        fail_msg="$(cat "$response_file" 2>/dev/null || true)"
        echo "建立憑證失敗 [$cred_name] HTTP $status" | tee -a "$log_file" >/dev/null
        echo "$fail_msg" >> "$log_file"
        rm -f "$response_file"
        continue
      fi
      rm -f "$response_file"
      created_creds=$((created_creds + 1))
    fi
  fi

  for entry in "${model_lines[@]}"; do
    model_name="$(printf '%s' "$entry" | jq -r '.name')"
    model_path="$(printf '%s' "$entry" | jq -r '.litellm_model')"
    if [ -z "$model_name" ]; then
      continue
    fi
    model_id="${model_name}-${cred_name}"

    model_payload="$(jq -n --arg model_name "$model_name" --arg model_path "$model_path" --arg cred "$cred_name" --arg model_id "$model_id" '{model_name:$model_name,litellm_params:{model:$model_path,litellm_credential_name:$cred},model_info:{id:$model_id}}')"
    if [ "$DRY_RUN" = "1" ]; then
      echo "DRY-RUN 建立 model: $model_name with $cred_name"
      continue
    fi

    model_response="$(mktemp)"
    model_status="$(curl -sS -o "$model_response" -w '%{http_code}' --max-time "$TIMEOUT" -H "x-litellm-api-key: $MASTER_KEY" -H 'Content-Type: application/json' -X POST "$ENDPOINT/model/new" -d "$model_payload")"
    if [ "$model_status" != "200" ]; then
      failed_models=$((failed_models + 1))
      echo "建立 model 失敗 [${model_name}] [${cred_name}] HTTP ${model_status}" | tee -a "$log_file" >/dev/null
      failed_lines+=("[$model_name][$cred_name] $model_status")
      cat "$model_response" >> "$log_file"
      echo "---" >> "$log_file"
    else
      created_models=$((created_models + 1))
    fi
    rm -f "$model_response"
  done
done < "$KEY_FILE"

echo "憑證：建立 $created_creds 把，跳過 $skipped_creds 把"
echo "模型：建立 $created_models 筆"
echo "失敗模型：$failed_models 筆"
echo "日誌：$log_file"
