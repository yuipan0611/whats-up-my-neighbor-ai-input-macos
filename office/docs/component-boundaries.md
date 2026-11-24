# 元件邊界與替換驗收

## 架構決策

NekoNode 的任務、狀態與資料格式由專案自己定義。第三方 SDK、觀測服務、工作流引擎與資料庫透過明確邊界接入；替換時，要能指出需要修改的 adapter、設定與資料遷移步驟。

「可以替換」需要三種證據：核心程式不依賴特定實作、替代實作通過相同的行為測試、既有資料有可驗證的退出方式。自架能力與公開原始碼是選型條件；它們本身不能證明這三件事。

本文件定義本切片的邊界與驗收門檻。完成狀態以同一 commit 的測試和實測紀錄為準；下表不表示整個系統的所有元件已經完成替換驗證。

## 哪些東西由我們擁有

- 任務 UUID、接續任務關係、對使用者公開的狀態，以及成果保存的判定。
- HTTP／WebSocket 的請求、回應、事件序號與斷線補回契約。
- 原始文件、明確選取的來源快照、成果、來源版本與內容雜湊。
- 提供給 adapter 的中性資料結構及其版本。

供應商的 thread ID、workflow ID、trace ID、checkpoint 或文件 ID 可以保存為對照資料。它們不能取代本專案的任務 ID，也不能成為前端必須理解的內部物件。

DBOS decorators、框架 checkpoint 型別、模型 SDK 回應與 Phoenix client 應留在各自的整合層。API、UI 與核心任務規則使用本專案的資料契約。

## 本切片先固定追蹤邊界

追蹤契約放在標準庫可載入的 `tracing_contract.py`。它不需要 OpenTelemetry、OpenInference 或 Phoenix 套件。

| 邊界 | 責任 |
| --- | --- |
| `TracePort` | 依任務 ID、執行者與接續關係建立追蹤範圍，並提供關閉操作。 |
| `TaskReporter` | 接收本專案的任務結果狀態；核心不取得 SDK 的 span 物件。 |
| `AgentReporter` | 接收有版本的中性 `AgentEvent`；觀測後端不解析供應商的原始回應。 |
| Codex adapter | 將實際 CLI JSONL 事件轉成中性事件，保留類型、識別碼、狀態與合法 usage 等 metadata。 |
| OTel adapter | 將中性事件映射成 OpenTelemetry／OpenInference，使用官方 SDK 傳送 OTLP。 |
| Recording 實作 | 在沒有追蹤 SDK 的環境中記錄契約行為，供相同測試核對；不是新的正式任務資料庫。 |
| 停用模式 | 不建立 exporter，原有任務處理與持久進度仍可執行。 |

Codex 的 `item.started`、`item.completed` 等原始格式在 Codex adapter 內解讀。換其他執行器時，新 adapter 輸出相同的中性事件，觀測後端不必增加供應商分支。

中性事件只容納此追蹤用途需要的欄位，不攜帶完整 prompt、來源內容、reasoning、query 或 SDK 物件。版本及欄位必須經過執行時檢查；未支援版本不得改以原始 payload 匯出。`TypedDict` 和 `runtime_checkable Protocol` 只提供型別或結構提示，不能代替行為測試與輸入檢查。

## 追蹤替換的驗收門檻

### 1. 換追蹤實作

對相同的合成 CLI 情境，注入 Recording 與 OTel 實作，核對：

- 任務成果、完成／取消／失敗語意，以及持久事件保持一致。
- task、agent、tool 關係依實際動作形成；完成通知沒有開始事件時，不推測工具執行時間。
- 重複事件、未知事件、未完成工具與合法 usage 使用相同的處理規則。
- 追蹤故障不改變原任務結果，也不吞掉業務例外。
- 核心契約與 Recording 路徑能在沒有觀測 SDK 的環境執行。

另以第二種合成事件來源產生同樣的中性事件，確認觀測 adapter 不需要理解新的原始格式。這項測試驗證 adapter 邊界；它不代表第二家真實模型的能力、登入或計費已經接通。

### 2. 換觀測服務

使用相同的 OTel 接線與合成任務，將 OTLP endpoint 分別指向 Phoenix 和 Jaeger。除了 HTTP 接收成功，還要從各後端查回相同任務的 trace，確認識別碼、parent 關係、時間與結果狀態。

這項實測驗證標準追蹤的接收與查詢。不同產品的畫面、額外分析、認證方式及保留設定仍須個別配置；不能把接收成功推論成所有功能完全相同。

### 3. 保留退出方式

觀測服務只保存診斷資料。任務成功判定與網頁進度仍由本專案的持久事件負責。需要保留診斷歷史時，使用可查回的標準資料匯出，核對數量、識別碼及 parent 關係；單純擁有某產品的資料庫備份，尚不足以證明可匯入另一產品。

OTel exporter 為 best-effort，可能因抽樣、容量、故障或突然退出而遺失診斷資料。相關界限與開關見 [執行追蹤說明](observability.md)。

## 其餘元件的邊界與目前限制

| 元件 | 應由 adapter 或實作層負責 | 替換前必須驗證 | 本切片的範圍 |
| --- | --- | --- | --- |
| 追蹤 SDK | span、context、OpenInference 映射、批次匯出 | Recording／OTel 契約測試、無 SDK 執行 | 本次建立介面與替換驗證。 |
| 觀測後端 | 接收、查詢、UI、認證與保留 | Phoenix／Jaeger 實際接收及查回、歷史資料退出 | 本次的兩後端驗收對象；未通過實測前不列為已驗證。 |
| 模型／CLI | 認證、呼叫格式、原始事件、輸出轉換、能力宣告 | 相同結果契約、取消／timeout、文字／圖片／工具能力 | 本次隔開追蹤事件；原有 Codex／Gemma 執行分支仍需後續整理。 |
| 任務排程器 | claim、排隊、租約、重試、取消、恢復 | 重啟恢復、重複投遞、外部動作冪等、併發及事件順序 | 目前仍是既有 worker；DBOS 尚未成為可替換的已驗證實作。 |
| 工作流引擎 | steps、等待、framework checkpoint 與版本管理 | 升級相容、舊工作收尾、切換／回復流程 | 引擎內部歷史的跨產品搬移尚未驗證。 |
| 任務資料庫 | SQL、schema migration、交易、鎖與索引 | 取消和成果提交的原子語意、事件回放、匯出／還原 | SQLite 仍在使用；本次將成功時間的 SQL 收回 Store，但成果提交的 lock 耦合需另切片處理。 |
| 文件來源 | 本地／Google Drive 的讀取、版本、變更通知與權限對照 | 同一文件識別、重複同步、改名／刪除／離線、cursor 恢復 | 尚未完成可替換來源 adapter。 |
| 檔案儲存 | 內容讀寫、hash、權限與下載 URL | 原文及快照可匯出、檢查完整性、失效 URL 重建 | 現有本地檔案布局仍需獨立的遠端儲存驗證。 |
| 檢索／向量索引 | embedding 模型版本、維度、距離與查詢 | 原文可重建索引、檢索品質、版本切換 | 尚未接入；換模型或維度可能需要完整重建。 |
| 前端與通訊 | UI、HTTP／WS transport、重新連線 | API／事件契約、cursor、去重與補回 | 既有契約繼續使用；更換 transport 需自己的相容測試。 |

## 資料庫與工作流的退出限制

資料庫替換要同時處理資料與行為。SQLite 的鎖、交易與序號做法不能直接視為 PostgreSQL 的等價實作。遷移前要有 schema 版本、備份、資料核對、寫入切換及回復步驟，並重驗取消／成果提交與斷線回放。

若日後加入 DBOS，業務任務 UUID 與結果保持獨立，DBOS workflow ID 保存為對照。Decorator 與 checkpoint 留在工作流整合層。要退出該引擎，優先設計停止新工作、完成或明確中斷舊工作，再將新工作切換到另一實作的程序；不能假設執行中的引擎歷史可直接搬移。

外部動作的冪等鍵與核對資料應由本專案保存。工作流引擎恢復一次 step，不等於已證明任何外部動作都只發生一次。

## 新零件接入規則

先確認責任邊界、資料出口、授權條件及失敗語意，再接進業務流程。只有替換需求或多個實作確實存在時，才新增對應介面；不為每個函式建立抽象工廠。

優先使用成熟專案的 SDK、公開 API 與標準協定。自行撰寫的程式集中在薄的 adapter、任務規則及必要的資料轉換；queue、retry、序列化與 tracing transport 優先使用已驗證的現成元件。

每個聲稱「可替換」的零件，都應能指出替代實作、相同的契約測試、資料搬移方式及仍然不同的能力。新增元件不能讓供應商型別或框架內部狀態滲透前端和公開任務契約。

## 參考介面

- [OpenTelemetry 的 API／SDK 分離與 instrumentation 指引](https://opentelemetry.io/docs/concepts/instrumentation/libraries/)
- [OpenTelemetry Collector：接收、處理與匯出邊界](https://opentelemetry.io/docs/collector/)
- [OpenTelemetry 規格概觀](https://opentelemetry.io/docs/specs/otel/overview/)
