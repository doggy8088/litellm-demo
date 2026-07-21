# LiteLLM Proxy 管理與團隊成本治理實戰範例

本專案為課程 **[AI 寫程式省錢術：從 Token 焦慮到團隊成本治理](https://learn.duotify.com/courses/ai-cost)** 的官方示範專案。

透過本專案，您將學會如何使用 Docker Compose 與 PostgreSQL、Redis 快速搭建具備生產級強健度的 LiteLLM Proxy，並建立嚴謹的權限隔離、額度限制（Budget Limits）、模型路由快取與團隊成本治理機制。

---

## 🎯 專案亮點與核心特色

- **統一 API 網關 (Unified API Gateway)**：整合 OpenAI、Anthropic、Ollama 等多種 LLM 供應商，提供標準 OpenAI 格式介面。
- **團隊成本與預算控制 (Budget & Cost Governance)**：支援針對 User / Team / Virtual Key 設定預算上限與重置週期（日/週/月），防止 API 額度超支。
- **快取優化與回應加速**：整合 Redis 快取機制，並支援 Anthropic prompt caching 自動注入點，降低重複 Prompt 的 Token 消耗。
- **高可用與持久化架構**：搭配 PostgreSQL 保存 Virtual Key、用戶權限與 Audit Log，支援資料庫備份與還原。
- **自動化管理介面 (Makefile Workflow)**：內建完整的 `Makefile` 管理指令，簡化檢查、啟動、重試、健康檢查與備份還原流程。

---

## 📁 專案架構說明

```
litellm-demo/
├── Makefile                # 自動化管理指令集 (核心操作介面)
├── AGENTS.md               # 專案規範與安全維護指引
├── compose.yaml            # Docker Compose 服務拓樸 (LiteLLM Proxy, PostgreSQL, Redis)
├── config.yaml             # LiteLLM 系統設定、快取與模型路由
├── .env.example            # 伺服器端環境變數範例
├── .client.env.example     # 用戶端測試金鑰設定範例
├── scripts/                # 自動化與批次測試腳本
│   ├── test-litellm-keys.sh
│   ├── import-ollama-keys-to-db.sh
│   └── update-ollama-model-costs.sh
└── README.md               # 本說明文件
```

---

## 🚀 快速上手 (Quick Start)

### 1. 環境準備與設定

複製環境變數範例檔並設定您的金鑰：

```bash
cp .env.example .env
cp .client.env.example .client.env
```

請編輯 `.env` 檔案，設定以下關鍵變數：
- `LITELLM_MASTER_KEY`: Proxy 管理者主金鑰 (例如 `sk-local-master-...`)
- `LITELLM_SALT_KEY`: 金鑰雜湊 Salt 值
- `POSTGRES_PASSWORD`: PostgreSQL 資料庫密碼
- `ANTHROPIC_API_KEY`: (可選) Anthropic API Key 或其他供應商金鑰

### 2. 環境與設定檔檢查

在啟動前執行 `make doctor` 驗證 Docker 環境與 YAML 設定檔語法：

```bash
make doctor
```

### 3. 啟動服務

啟動 LiteLLM Proxy、PostgreSQL 與 Redis 服務，並自動等待通過健康檢查：

```bash
make up
```

### 4. 驗證服務狀態與健康度

檢查容器運行狀態與健康檢查端點：

```bash
make status
make health
```

---

## 🛠️ Makefile 管理指令說明

本專案提供豐富的 `Makefile` 指令，建議所有例行維運皆透過 `make` 執行：

| 指令 | 說明 |
| :--- | :--- |
| `make help` | 顯示所有可用的 Makefile 指令與說明 |
| `make doctor` | 檢查 Docker 狀態與設定檔正確性 |
| `make validate` | 驗證 `compose.yaml` 與 `config.yaml` 語法 |
| `make up` | 啟動所有容器服務並等待健康檢查通過 |
| `make down` | 停止並移除容器與網路（**安全保留 PostgreSQL 資料庫**） |
| `make restart` | 重新建立 LiteLLM Proxy 容器並載入新設定 |
| `make status` | 顯示容器運行狀態與 Port 對應 |
| `make logs` | 追蹤檢視所有容器日誌 |
| `make logs-proxy` | 追蹤檢視 LiteLLM Proxy 日誌 |
| `make logs-db` | 追蹤檢視 PostgreSQL 日誌 |
| `make models` | 使用 `.client.env` 設定之測試金鑰查詢可用模型清單 |
| `make test-keys` | 批次測試 `virtual-keys.txt` 中的虛擬金鑰連線 |
| `make db-backup` | 將 PostgreSQL 資料庫備份至 `backups/` 目錄 |
| `make db-restore` | 安全覆寫還原資料庫 (`make db-restore BACKUP=<檔案> CONFIRM=restore`) |

---

## 🔐 安全規範與最佳實務

1. **嚴禁洩漏密鑰**：切勿將 `.env`、API Key 或 `DATABASE_URL` 提交至版本控制或印出於日誌中。
2. **本機連線限制**：LiteLLM Proxy 連接埠預設僅綁定 `127.0.0.1:4000`。若需對外公開，請務必外掛具備 TLS / 認證 / 限流功能的 Reverse Proxy (例如 Nginx, Traefik, Caddy)。
3. **資料持久化保護**：嚴禁執行 `docker compose down -v` 或刪除 `postgres-data/` 目錄。
4. **備份優先原則**：進行 Major 異動（如更新 LiteLLM 或 PostgreSQL 映像檔版本）前，務必執行 `make db-backup`。

---

## 📚 相關課程與資源

- 🎓 **主講課程**：[AI 寫程式省錢術：從 Token 焦慮到團隊成本治理](https://learn.duotify.com/courses/ai-cost)
- 📖 **官方規範**：請參閱 [AGENTS.md](file:///Users/will/projects/litellm-demo/AGENTS.md) 了解 AI Agent 與團隊維護本專案的作業規範。
