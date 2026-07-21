#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_ROOT}/compose.yaml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-litellm-demo}"
ENDPOINT="${LITELLM_ENDPOINT:-http://127.0.0.1:4000}"
MODEL="${LITELLM_CACHE_TEST_MODEL:-deepseek-v4-flash}"
COMPOSE_CMD="docker compose --env-file ${ENV_FILE} -p ${COMPOSE_PROJECT} -f ${COMPOSE_FILE}"
MASTER_KEY="${LITELLM_MASTER_KEY:-}"

if [ ! -f "${ENV_FILE}" ]; then
  echo "缺少環境設定檔：${ENV_FILE}" >&2
  exit 1
fi
source "${ENV_FILE}"

if [ -z "${MASTER_KEY}" ]; then
  echo "缺少 LITELLM_MASTER_KEY" >&2
  exit 1
fi

echo "===== LiteLLM Cache Test Report ====="
echo "endpoint=${ENDPOINT}"
echo "model=${MODEL}"
echo "compose=${COMPOSE_FILE}"
echo

redis_hits() {
  ${COMPOSE_CMD} exec -T redis redis-cli INFO stats | awk -F: '/^keyspace_hits:/{gsub(/\r/, "", $2); print $2; exit}'
}

redis_misses() {
  ${COMPOSE_CMD} exec -T redis redis-cli INFO stats | awk -F: '/^keyspace_misses:/{gsub(/\r/, "", $2); print $2; exit}'
}

cache_ping() {
  local headers body status
  headers="$(mktemp)"
  body="$(mktemp)"
  status="$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    "${ENDPOINT}/cache/ping")"
  local payload
  payload="$(cat "$body")"
  echo "cache_ping_status=${status}"
  echo "cache_ping_body=${payload}"
  rm -f "$headers" "$body"
}

send_once() {
  local label="$1"
  local prompt="$2"
  local headers body status cache_key duration
  headers="$(mktemp)"
  body="$(mktemp)"
  local payload
  payload="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"temperature\":0}"

  status="$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -X POST "${ENDPOINT}/v1/chat/completions" \
    -d "$payload")"

  cache_key="$(awk 'BEGIN{IGNORECASE=1} /^x-litellm-cache-key:/{sub(/^x-litellm-cache-key: /, \"\"); gsub(/\\r/, \"\"); print; exit}' "$headers")"
  duration="$(awk 'BEGIN{IGNORECASE=1} /^x-litellm-response-duration-ms:/{sub(/^x-litellm-response-duration-ms: /, \"\"); gsub(/\\r/, \"\"); print; exit}' "$headers")"
  echo "${label},status=${status},cache_key=${cache_key:-<MISS>},duration_ms=${duration}"
  rm -f "$headers" "$body"
}

echo "cache_stats_before: $(redis_hits) hits, $(redis_misses) misses"
cache_ping
echo

send_once "run_1" "cache test ping"
send_once "run_2" "cache test ping"
send_once "run_3" "cache test ping variation"
echo
echo "cache_stats_after: $(redis_hits) hits, $(redis_misses) misses"
