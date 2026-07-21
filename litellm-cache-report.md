# LiteLLM Redis Cache 測試報告
本報告整理本次對 `/cache/ping`、重複 `chat/completions` 請求與 Redis 指標的實際驗證結果，並將可重複腳本 `scripts/test-litellm-cache.sh` 併入附錄。
## 測試環境
服務皆維持在 `/Users/will/projects/litellm-demo`，包含 `litellm-proxy`、`db`、`litellm-redis`。
## 測試目標
1. 驗證 Redis 快取初始化是否可用。  
2. 驗證相同請求的快取命中行為是否成立。  
3. 提供可重複執行的自動化腳本。
## 執行指令
`make status`  
`make health`  
`set -a; . ./.env; set +a; curl -sS -i "http://127.0.0.1:4000/cache/ping" -H "Authorization: Bearer $LITELLM_MASTER_KEY" | sed -n '1,30p'`
## 觀測結果
**快取服務已啟用。**
`/cache/ping` 回傳 `200 OK`，`cache_type` 為 `redis`，`ping_response` 與 `set_cache_response` 為可用狀態。
## 快取命中驗證
模型 `deepseek-v4-flash` 以相同 payload 重複呼叫兩次，再呼叫一筆不同訊息作對照：
- 第一次請求：`x-litellm-response-duration-ms` 約 `24465.015`，未同時出現 `x-litellm-cache-key`。
- 第二次請求（同樣訊息）：`x-litellm-response-duration-ms` 約 `0.445`，出現 `x-litellm-cache-key`，明顯縮短為毫秒等級。
- 第三次請求（變更訊息）：`x-litellm-response-duration-ms` 約 `9712.64`，屬不同內容的重新計算。
**結論：同一 payload 第二次明顯命中快取。**
## Redis 指標
`INFO stats` 對比如下：  
`keyspace_hits: 183 -> 191 -> 195`  
`keyspace_misses: 603 -> 616 -> 622`
## 分析結論
- 目前環境中，Redis 連線與快取初始化無異常。
- 透過回應時間差異與 `x-litellm-cache-key` 已確認命中行為存在。
- 不能直接查到快取明文內容，必須以「命中標頭 + 時間 + 指標」做間接驗證。
- 上次曾出現過快取不可用情境，重建容器後狀態已回復。  
## 建議
1. 在每次調整快取設定後，固定執行 `scripts/test-litellm-cache.sh` 做回歸。  
2. 若要更準確量測，使用更長內容（增加回應時間）可放大命中前後差異。  
3. 將 `MASTER_KEY` 的讀取行為改為只在受信任執行環境使用，避免在日誌輸出中誤植敏感值。  
## 測試腳本：scripts/test-litellm-cache.sh
