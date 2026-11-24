# 元件替換邊界：第 1b 階段

## 決定與範圍

NekoNode 的任務、事件與成果屬於產品本身，不以任何觀測平台或 Agent 框架的內部物件作為唯一資料來源。優先使用成熟套件和公開協定；替換邊界只包裝真正使用到的能力，不另外發明通用 Agent／工作流程框架。

**可替換不等於零成本。** 更換模型的能力差異、不同資料庫的交易與排序語意，以及工作流程引擎的執行中狀態，都需要實際遷移與驗收。本文件不宣稱所有元件已完成抽換。

## 本切片落實什麼

使用原本的 `Office(..., telemetry=...)` 與 `CodexAgent(..., telemetry=...)` 注入點，不改任務、資料庫、HTTP 或 WebSocket 的執行邏輯。

`observation_ports.py` 以 Python 標準庫 Protocol 明確記錄兩個分離契約：

- `TaskObserver`：任務的開始／結束、結果 metadata 與有界關閉。回傳的 handle 是實作自行管理的不透明值；核心只交還它，不存進資料庫、不傳給前端，也不呼叫 OTel span 方法。
- `CodexObserver`／`CodexEventReceiver`：現有 Codex CLI 的事件轉譯。這是 provider-specific adapter 邊界，**不是所有模型必須模仿的通用事件協定**。任務核心不需要這個擴充契約。

實作不必繼承 Protocol；現有 `OfficeTelemetry` 是透過結構符合契約。Protocol 的 runtime 檢查只確認成員存在，不保證型別、故障隔離或效能；行為由整合測試驗證。

新增測試分成兩層：

1. **不依賴 SDK 的實作替換。** 兩個獨立的標準庫 observer 分別使用普通 Python object 與 `None` 作為 handle。與關閉追蹤的情況比較，任務成果、持久事件順序、事件補讀游標必須相同；取消與例外仍正常傳遞。合成 CLI 也要能使用非 OTel observer。
2. **OTLP 接收端替換。** 使用真正的官方 exporter 和 protobuf／HTTP 傳輸。完成第一個接收端的測試並停止它後，只改 endpoint、重建接線，再對第二個獨立接收端執行相同的辦公室流程。核對 trace、任務 ID、結果與事件順序。

第二層使用測試接收端，不代表 Phoenix、Jaeger 或其他產品已經安裝驗收；也不驗證歷史資料會自動搬移。既有的追蹤整合測試仍負責父子 span、取消、敏感內容排除及 exporter 故障隔離。

## 所有主要元件的退出路徑

| 元件 | 產品與實作的邊界 | 替換時要處理什麼 | 本切片狀態 |
| --- | --- | --- | --- |
| 追蹤實作 | `TaskObserver`，不透明 handle 留在 adapter 內 | metadata、安全與故障隔離；替換實作通過相同契約測試 | 已加契約與替換測試 |
| 追蹤接收服務 | 標準 OTLP HTTP；endpoint／認證由部署設定提供 | 接收相容性、UI／查詢差異、資料保留與歷史匯出另驗證 | 已加雙接收端測試；尚未驗收實際產品 |
| 模型／執行者 | 供應商專用 adapter 轉成產品任務結果與事件 | 工具、串流、token 與取消語意的差異；不可假造缺少的能力 | 尚未抽離完成；目前任務與 UI 仍有 Codex／Gemma 分支 |
| 耐久工作流程引擎 | 產品任務 ID、步驟輸入與成果由我們定義；引擎 decorator／checkpoint 留在實作層 | 執行中工作先排空，或從明確完成的步驟邊界重建；外部動作需去重 | DBOS 尚未導入；先以獨立實驗驗收 |
| 任務／事件資料庫 | Store／repository 層及既有 HTTP／WebSocket 事件契約 | transaction、併發 claim、序號與提交順序、備份／回復／資料遷移 | 仍是 SQLite；現有 `store.connect()`／SQL 耦合尚待逐步拆除 |
| 文件與成果儲存 | 產品 document/artifact ID、內容 hash 與版本；儲存位置留在 adapter | 本機路徑與物件 key 映射、完整性與刪除語意 | 檔案仍在現有本機目錄，尚未抽離完整介面 |
| 向量檢索 | 保留原始文件／段落與 embedding 模型、版本、維度資訊 | 更換 embedding 可能要重建索引，不能假設不同向量可直接混用 | 後續設計與驗收項目 |
| Chrome 控制 | 單一控制器與產品定義的操作權／接管狀態 | 瀏覽器 session、工具結果、未確認外部動作、人工交接 | 後續獨立切片；本次未實作 |
| 本機／Drive 文件接入 | 來源 connector → 文件 ID、版本、內容與刪除事件 | Drive 游標、失去權限、離線與刪除的差異 | 後續獨立切片；本次未實作 |

不要求一次寫完所有介面；每接入一個元件，先落實它那一列的邊界與替換測試。把 SDK 包在一個檔案裡只是開始，**資料能否帶走、執行中任務怎麼退出**同樣必須寫清楚。

## 不綁定觀測平台的部署規則

任務程式不引入 Phoenix／Langfuse 客戶端，不依賴它們的資料表、平台 task ID 或 UI URL。觀測資料走已存在的標準 OTLP exporter。以新的環境設定啟動程序即可切換接收端，不在任務執行中熱換全域 tracer。

現有設定的角色：

- `NEKO_TRACE_ENABLED=0`：不載入選配 SDK；任務與持久事件仍可運作。
- `NEKO_TRACE_ENABLED=1`：啟用既有 OTel adapter。
- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`：完整 HTTP(S) traces endpoint。
- `OTEL_EXPORTER_OTLP_TRACES_HEADERS`：部署者提供接收端認證，不寫進 repository 或任務資料。

換 endpoint 只改未來追蹤的去向，不會搬移歷史 trace，不保證第三方平台有相同搜尋／展示功能。SDK queue 是 best-effort；SQLite 事件仍是目前的持久進度來源。

## 驗收指令

從 repository 根目錄執行：

```sh
python3 -I -m unittest discover -s office/tests -p 'test_observation_portability.py' -v
python3 -I -m unittest discover -s office/tests -v
```

選配環境使用第一階段的固定依賴：

```sh
python3 -m venv office/.venv-observability
office/.venv-observability/bin/python -m pip install --require-hashes -r office/requirements-observability.txt
office/.venv-observability/bin/python -I -m unittest discover -s office/tests -v
```

沒有 SDK 時，OTLP 替換測試應跳過，標準庫替換測試仍必須執行。測試只使用合成 CLI、FakeModel、暫存 SQLite 與 loopback 接收端，不讀正式資料、不呼叫真實模型、不部署 VPS。

## 接下來的驗證順序

先在獨立測試環境接上 Phoenix，透過同一個 OTLP 邊界驗收；不把 Phoenix 的內部資料模型帶回產品核心。再逐項拆除現有模型與 Store 的耦合，並驗證 DBOS 的工作退出／重建規則。保留每個切片獨立回退的能力，不同時遷移資料庫、替換執行引擎和改前端協定。

參考：[OTLP 官方規格](https://opentelemetry.io/docs/specs/otlp/)、[第一階段追蹤文件](observability.md)。
