SHELL := /bin/sh
.DEFAULT_GOAL := help

PROJECT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
COMPOSE_FILE ?= $(PROJECT_DIR)/compose.yaml
ENV_FILE ?= $(PROJECT_DIR)/.env
CLIENT_ENV_FILE ?= $(PROJECT_DIR)/.client.env
CONFIG_FILE ?= $(PROJECT_DIR)/config.yaml
BACKUP_DIR ?= $(PROJECT_DIR)/backups
SCRIPTS_DIR ?= $(PROJECT_DIR)/scripts
SCRIPT_TEST_KEYS ?= $(SCRIPTS_DIR)/test-litellm-keys.sh
VIRTUAL_KEYS_FILE ?= $(PROJECT_DIR)/virtual-keys.txt
TAIL ?= 200
WAIT_RETRIES ?= 30
WAIT_INTERVAL ?= 2

COMPOSE ?= docker compose
DC = $(COMPOSE) --project-directory "$(PROJECT_DIR)" --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)"

.PHONY: help require-env doctor validate pull up down stop restart status images logs \
	logs-proxy logs-db health wait models proxy-shell db-shell db-backup db-restore test-keys

help: ## 顯示可用的管理目標
	@awk 'BEGIN {FS = ":.*## "; printf "LiteLLM 管理指令\n\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

require-env:
	@test -f "$(ENV_FILE)" || { echo "缺少 $(ENV_FILE)" >&2; exit 1; }
	@test -f "$(CONFIG_FILE)" || { echo "缺少 $(CONFIG_FILE)" >&2; exit 1; }

doctor: require-env ## 檢查本機工具、Docker daemon 與設定檔
	@command -v docker >/dev/null 2>&1 || { echo "找不到 docker" >&2; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Docker daemon 無法使用" >&2; exit 1; }
	@$(COMPOSE) version
	@$(MAKE) --no-print-directory validate

validate: require-env ## 驗證 Compose 與 LiteLLM YAML 語法
	@$(DC) config --quiet
	@if python3 -c 'import yaml' >/dev/null 2>&1; then \
		python3 -c 'import pathlib, yaml; data = yaml.safe_load(pathlib.Path("$(CONFIG_FILE)").read_text(encoding="utf-8")); assert isinstance(data, dict), "config.yaml 的頂層必須是 mapping"'; \
	else \
		$(DC) run --rm --no-deps --entrypoint python3 litellm -c 'import pathlib, yaml; data = yaml.safe_load(pathlib.Path("/app/config.yaml").read_text(encoding="utf-8")); assert isinstance(data, dict), "config.yaml 的頂層必須是 mapping"'; \
	fi
	@echo "設定驗證通過"

pull: require-env ## 拉取 compose.yaml 指定的容器映像
	@$(DC) pull

up: validate ## 建立或更新服務，並等待 LiteLLM 通過健康檢查
	@$(DC) up -d --remove-orphans
	@$(MAKE) --no-print-directory wait

down: require-env ## 移除容器與網路，但保留 PostgreSQL 資料
	@$(DC) down --remove-orphans

stop: require-env ## 停止服務但保留容器
	@$(DC) stop

restart: validate ## 重新建立 LiteLLM Proxy 並套用設定
	@$(DC) up -d --no-deps --force-recreate litellm
	@$(MAKE) --no-print-directory wait

status: require-env ## 顯示服務狀態
	@$(DC) ps

images: require-env ## 顯示服務使用的容器映像
	@$(DC) images

logs: require-env ## 顯示所有服務最近的日誌；可用 TAIL=n 調整行數
	@$(DC) logs --tail "$(TAIL)" -f

logs-proxy: require-env ## 顯示 LiteLLM Proxy 最近的日誌
	@$(DC) logs --tail "$(TAIL)" -f litellm

logs-db: require-env ## 顯示 PostgreSQL 最近的日誌
	@$(DC) logs --tail "$(TAIL)" -f db

health: require-env ## 呼叫 LiteLLM 容器內的存活檢查端點
	@$(DC) exec -T litellm python3 -c 'import sys, urllib.request; body = urllib.request.urlopen("http://localhost:4000/health/liveliness", timeout=10).read().decode(); sys.stdout.write(body + "\n")'

wait: require-env ## 等待 LiteLLM 存活檢查成功
	@attempt=0; \
	until $(DC) exec -T litellm python3 -c 'import urllib.request; urllib.request.urlopen("http://localhost:4000/health/liveliness", timeout=5)' >/dev/null 2>&1; do \
		attempt=$$((attempt + 1)); \
		if [ "$$attempt" -ge "$(WAIT_RETRIES)" ]; then \
			echo "LiteLLM 未在等待期限內通過健康檢查" >&2; \
			$(DC) ps; \
			exit 1; \
		fi; \
		sleep "$(WAIT_INTERVAL)"; \
	done
	@echo "LiteLLM 健康檢查通過"

models: require-env ## 使用 .client.env 的虛擬金鑰列出可用模型
	@test -f "$(CLIENT_ENV_FILE)" || { echo "缺少 $(CLIENT_ENV_FILE)" >&2; exit 1; }
	@set -a; . "$(CLIENT_ENV_FILE)"; set +a; \
		test -n "$$LITELLM_VIRTUAL_KEY" || { echo "LITELLM_VIRTUAL_KEY 未設定" >&2; exit 1; }; \
		endpoint="http://$$($(DC) port litellm 4000)/v1/models"; \
		curl --fail --silent --show-error -H "Authorization: Bearer $$LITELLM_VIRTUAL_KEY" "$$endpoint" | python3 -m json.tool

test-keys: ## 使用 scripts/test-litellm-keys.sh 批次測試 virtual keys
	@test -x "$(SCRIPT_TEST_KEYS)" || { echo "找不到可執行腳本：$(SCRIPT_TEST_KEYS)" >&2; exit 1; }
	@test -f "$(VIRTUAL_KEYS_FILE)" || { echo "找不到虛擬金鑰檔：$(VIRTUAL_KEYS_FILE)" >&2; exit 1; }
	@$(SCRIPT_TEST_KEYS) "$(VIRTUAL_KEYS_FILE)"

proxy-shell: require-env ## 開啟 LiteLLM Proxy 容器 shell
	@$(DC) exec litellm sh

db-shell: require-env ## 開啟 PostgreSQL psql
	@$(DC) exec db sh -c 'exec psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

db-backup: require-env ## 將 PostgreSQL 備份至 backups/；可用 BACKUP_DIR 覆寫路徑
	@umask 077; \
		mkdir -p "$(BACKUP_DIR)"; \
		backup="$(BACKUP_DIR)/litellm-$$(date +%Y%m%d-%H%M%S).dump"; \
		if $(DC) exec -T db sh -c 'exec pg_dump -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" --format=custom --no-owner --no-privileges' > "$$backup"; then \
			echo "備份完成：$$backup"; \
		else \
			rm -f "$$backup"; \
			echo "備份失敗" >&2; \
			exit 1; \
		fi

db-restore: require-env ## 覆寫還原資料庫；需 BACKUP=<檔案> CONFIRM=restore
	@test "$(CONFIRM)" = "restore" || { echo "拒絕還原：請加入 CONFIRM=restore" >&2; exit 1; }
	@test -n "$(BACKUP)" || { echo "缺少 BACKUP=<檔案>" >&2; exit 1; }
	@test -f "$(BACKUP)" || { echo "找不到備份檔：$(BACKUP)" >&2; exit 1; }
	@proxy_stopped=0; \
		cleanup() { if [ "$$proxy_stopped" -eq 1 ]; then $(DC) start litellm >/dev/null; fi; }; \
		trap cleanup EXIT HUP INT TERM; \
		$(DC) stop litellm; \
		proxy_stopped=1; \
		$(DC) exec -T db sh -c 'exec pg_restore -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" --clean --if-exists --exit-on-error --no-owner --no-privileges' < "$(BACKUP)"; \
		$(DC) start litellm >/dev/null; \
		proxy_stopped=0; \
		trap - EXIT HUP INT TERM
	@$(MAKE) --no-print-directory wait
	@echo "資料庫還原完成"
