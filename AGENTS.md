# LiteLLM 管理規範

本文件適用於此目錄及其所有子目錄。目標是安全、可重現地管理 LiteLLM Proxy 與 PostgreSQL，並避免洩漏憑證或破壞持久化資料。

* * *

## 架構與來源

- `compose.yaml`：服務拓樸 (LiteLLM Proxy, PostgreSQL, Redis)、容器映像、連接埠、掛載與健康檢查的唯一來源。
- `config.yaml`：LiteLLM 模型、路由與一般設定 (快取與 Redis 設定) 的唯一來源。
- `.env`：伺服器端密鑰、資料庫連線與映像設定；不得提交、列印或貼入日誌。
- `.client.env`：測試用虛擬金鑰；不得提交、列印或貼入日誌。
- `postgres-data/`：PostgreSQL 的持久化資料；禁止直接編輯、搬移或遞迴刪除。
- `backups/`：由 `make db-backup` 產生的資料庫備份；視同敏感資料。

* * *

## 標準操作介面

**所有例行管理操作應優先使用 `Makefile`。** 不要把臨時拼湊的 Docker 指令當成正式操作流程。先執行 `make help` 查看可用目標。

常用流程：

1. 修改前執行 `make doctor` 與 `make status`。
2. 修改 `compose.yaml` 或 `config.yaml` 後執行 `make validate`。
3. 使用 `make up` 套用變更；只需重新建立 Proxy 時使用 `make restart`。
4. 執行 `make health`，並在必要時使用 `make logs` 檢查錯誤。
5. 涉及映像版本、資料庫結構或大量設定變動前，先執行 `make db-backup`。

* * *

## 安全限制

- **不得洩漏憑證，也不得直接刪除 PostgreSQL 持久化資料。**
- 禁止將 `.env`、`.client.env`、API 金鑰、主金鑰、salt key、資料庫密碼或完整 `DATABASE_URL` 寫入程式碼、提交訊息、終端輸出或問題追蹤系統。
- 禁止使用 `set -x` 執行會載入密鑰的命令。
- 禁止使用 `docker compose down -v` 或直接刪除 `postgres-data/`。`make down` 只移除容器與網路，不會移除資料庫目錄。
- 資料庫還原會覆寫現有資料，只能使用 `make db-restore BACKUP=<檔案> CONFIRM=restore`，並須先確認備份檔來源與時間。
- LiteLLM 對外連接埠必須維持綁定 `127.0.0.1`；若要公開服務，必須另行加入具 TLS、存取控制與速率限制的反向代理。
- 不得在未備份與未閱讀版本變更說明的情況下更新 LiteLLM 或 PostgreSQL 的主要版本。
- `latest` 標籤不可重現。正式環境應將 `LITELLM_IMAGE` 固定為已驗證的版本或映像 digest。

* * *

## 設定變更原則

- 在 `config.yaml` 以 `os.environ/<NAME>` 參照密鑰，不得填入密鑰值。
- 新增模型時，名稱應穩定且能辨識供應商或用途；修改既有 `model_name` 前，先確認所有呼叫端。
- 修改環境變數名稱時，同步更新 `compose.yaml`、相關環境檔範例與操作說明。
- 不得任意移除健康檢查、資料庫健康相依條件、唯讀設定掛載或本機連接埠限制。
- 不確定 LiteLLM 參數或 API 是否仍受目前版本支援時，先查閱對應版本的官方文件，不得猜測。

* * *

## 驗證與故障排除

- **只有 `make validate` 與 `make health` 均成功，才可宣告服務可用。** 容器處於 `running` 不等於 LiteLLM 已可接受請求。
- 模型清單可使用 `make models` 驗證；此命令只讀取 `.client.env`，不得輸出其中的金鑰。
- 先以 `make status` 判斷服務狀態，再用 `make logs-proxy` 或 `make logs-db` 縮小問題範圍。
- DNS 解析異常時，可優先在 macOS 執行：

  ```sh
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder
  ```

- 若無可靠證據，不得把問題歸因於網路、供應商或 LiteLLM；保留可重現步驟、時間戳記與已遮蔽敏感資訊的錯誤內容。

* * *

## 提交要求

- 只提交與本次工作相關的檔案，不得覆寫其他人的未提交變更。
- 提交訊息遵循 Conventional Commits 1.0.0，例如 `chore(proxy): add routine management targets`。
- 提交前至少執行 `make validate`；若服務可啟動，再執行 `make up`、`make health` 與相關功能驗證。
- 提交訊息必須先寫入 `mktemp` 產生的 UTF-8 暫存檔，再以 `git commit -F "$commit_msg_file"` 提交；不得使用 `git commit -m`。
