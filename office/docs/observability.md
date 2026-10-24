# 辦公室執行追蹤：第一個切片

此切片把既有的任務執行與 Codex CLI 事件接到 OpenTelemetry，使用 OpenInference 的 AI 追蹤欄位。SDK 負責批次傳輸與 OTLP 格式；辦公室只轉換實際觀察到的事件，讓 Phoenix 等相容工具能顯示執行關係。

預設關閉。SQLite 仍保存任務、成果與進度，原有 HTTP／WebSocket 與斷線補回契約維持不變。本切片不安裝 Phoenix、不導入 DBOS、不遷移 PostgreSQL，也不執行 VPS 部署。

## 能看到什麼

| 追蹤名稱 | OpenInference 類型 | 觀察範圍 |
| --- | --- | --- |
| `office.task` | `CHAIN` | 一次實際執行任務的時間、執行者與結果狀態。Codex、Gemma 都有此層。 |
| `codex.run` | `AGENT` | 一次 Codex CLI 執行，包含收到的事件類型與 CLI 回報的合法 token 計數。 |
| `codex.web_search` | `TOOL` | 同一 item ID 的搜尋開始／完成事件；其 parent 為該次 `codex.run`。 |

正常 Codex 路徑會形成 task → agent → tool 的關係。工具時間是辦公室收到 CLI 開始與完成事件的觀察區間。只有完成事件時，會保留時間戳事件，不推測開始時間；結束時仍未收到完成的工具會標記 `unfinished`，取消或錯誤則標記相應結果。

這一版只對已接通的 `web_search` 建立工具 span。Gemma 只有任務層追蹤；不會推測 CLI 內部模型呼叫，也不會顯示尚未接通的子 Agent。CLI token 計數是診斷資料，不是帳單保證。

每個任務與 Codex span 帶有 `nekonode.task.id`，可用辦公室既有的任務 UUID 在觀測工具中查找。`parent_id` 現在代表使用者按「接續工作」所建立的新任務，只記成 `nekonode.task.previous_id`；它不會被當作正在執行的 child-agent span。

## 資料與可靠性範圍

追蹤使用白名單 metadata：任務 ID、執行者、事件／工具類型、受限制的 item ID、時間、狀態、合法 token 數及例外類別。此接線不匯出交辦原文、生活紀錄、來源內容、附件路徑、reasoning 文字、搜尋 query、模型輸出、例外訊息或 stack trace。

第三方 SDK 的網路錯誤日誌仍可能包含 collector 位址。因此 endpoint 不接受 userinfo、query 或 fragment；認證請透過 `OTEL_EXPORTER_OTLP_TRACES_HEADERS` 設定。自行設定的 OTel resource attributes 與 collector 權限仍由部署者管理。

**追蹤是可丟失的診斷管線。** SDK queue 滿載、抽樣、collector 故障或程序突然終止時，部分 span 可能沒有送達。它不參與任務成功判定，也不替代 SQLite 的持久事件紀錄。網頁即時進度繼續使用原有事件與 WebSocket。

目前界限如下：

| 項目 | 設定 |
| --- | --- |
| SDK 等待匯出的 queue | 最多 512 個 span |
| 每批匯出 | 最多 64 個 span，排程間隔 1 秒 |
| OTLP HTTP exporter timeout | 2 秒；不是整個關機過程的時間保證 |
| 關機等待追蹤的時間 | 最多 2 秒，逾時允許放棄尚未送出的追蹤 |
| 一次 Codex 執行的工具 span | 最多 64 個；同一 item ID 不重複建立 |
| 一次 Codex 執行的事件 | 最多保留 128 個，另記丟棄計數 |

## 安裝與離線驗證

以下指令從程式庫根目錄執行。先驗證不安裝 SDK 的原有模式：

```sh
python3 -I -m unittest discover -s office/tests -v
```

沒有選配依賴時，SDK 整合測試會跳過，其他測試繼續執行。再建立獨立環境並安裝包含版本與 SHA256 的完整依賴清單：

```sh
python3 -m venv office/.venv-observability
office/.venv-observability/bin/python -m pip install --require-hashes -r office/requirements-observability.txt
office/.venv-observability/bin/python -I -m unittest discover -s office/tests -v
```

`requirements-observability.in` 表示直接依賴範圍；`requirements-observability.txt` 是實際安裝使用的固定清單。更新套件時，應重新產生 lock 並通過同一組測試，避免直接在正式環境浮動升級。

追蹤測試使用合成的 Codex CLI subprocess、記憶體 exporter 與本機 OTLP HTTP 接收端。它們不呼叫真實模型、不使用模型額度，也不讀取正式辦公室資料。HTTP／WebSocket 測試需要允許綁定 `127.0.0.1` 的暫時埠。

## 在獨立測試環境啟用

先準備自己管理的相容 OTLP HTTP collector，例如 Phoenix。Phoenix 的常見本機 traces URL 是 `http://127.0.0.1:6006/v1/traces`；請依實際部署填寫完整 URL，程式不會自動補上路徑。

以下範例使用獨立資料目錄與埠。collector 必須另外啟動；這條命令只啟動辦公室：

```sh
NEKO_TRACE_ENABLED=1 \
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:6006/v1/traces \
OTEL_TRACES_SAMPLER=always_on \
OTEL_RESOURCE_ATTRIBUTES=openinference.project.name=nekonode-test \
office/.venv-observability/bin/python -I office/office.py \
  --data /tmp/nekonode-tracing-lab/data \
  --port 18422
```

驗證期間明確指定 `always_on`，避免環境中已有的抽樣設定讓測試任務看似沒有追蹤。其他 OTel SDK 設定仍可能影響實際紀錄；例如 `OTEL_SDK_DISABLED`。查 `/api/health` 時，`tracing_enabled` 只表示辦公室已建立追蹤接線，不能證明 collector 可連線或 span 已送達。

驗收應同時核對辦公室的成果與事件、collector 收到的 span，以及 task／agent／tool 的 parent 關係。先使用合成測試資料；真實 Codex 任務仍需另行準備原有的登入與執行環境。

## 正式服務啟用與關閉

現有 systemd 服務使用 `/usr/bin/python3 -I`。把 SDK 裝進 venv 不會讓該服務自動取得套件；啟用時必須讓 `ExecStart` 指向安裝過依賴的 venv Python，並保留原本全部參數，包含手機公網版的 `--public-origin`。仍應保留 `-I`；程式會從自身相鄰路徑載入 `telemetry.py`。

部署需一併提供 `office.py`、`telemetry.py` 與固定依賴清單。`deploy.sh` 是舊版通道服務腳本，沒有替正式服務建立 venv，也不會自動啟用 tracing；手機公網版已有的阻擋檢查仍有效。不要用舊服務檔覆蓋目前的公網設定。

關閉時移除 `NEKO_TRACE_ENABLED` 或設為 `0`，再依既有程序重新啟動服務即可。關閉後不載入 SDK、不建立 exporter，也不需要資料庫回復或遷移。已在 collector 保存的診斷資料依 collector 自身的保留設定管理。

## 後續每次只驗證一層

1. **本切片：**完成選配追蹤接線，驗證舊流程、事件關係、取消與故障隔離。
2. **Phoenix 測試環境：**確認接收格式、查詢與顯示，量測追蹤帶來的記憶體與延遲。
3. **DBOS 耐久執行試驗：**用獨立任務驗證重啟恢復、事件回放、重複投遞與外部動作冪等，再決定如何接入排程。
4. **PostgreSQL 評估：**以實際事件量做負載與保留策略測試，確認備份與遷移／回復方案後再遷移。

後三項是後續驗證順序；這份文件不表示它們已完成或已部署。

## 上游介面

- [OpenTelemetry Python instrumentation](https://opentelemetry.io/docs/languages/python/instrumentation/)：span、context 與 SDK 接線。
- [OpenInference semantic conventions](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)：`CHAIN`、`AGENT`、`TOOL` 與 AI 追蹤欄位。
- [Phoenix self-hosting architecture](https://arize.com/docs/phoenix/self-hosting/architecture)：可自行部署的接收與查詢服務。
