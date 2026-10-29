# 貓咪辦公室第二版

2026-10-29 主線整合：先前已測試的 Office／瀏覽器／追蹤分支與三家工作台已一併納入本版來源，開關與舊功能保留。驗證與實際部署範圍見 [整合核驗](../reports/office-main-integration/VERIFICATION.md)；本人登入驗收延後。

三家遠端工作台：新增「三家協作 · NekoNode 官網」，由 Claude → Codex／Docker → Gemini 依序處理。VS Code 是查看與接手入口；安裝、限制、本人登入及回復方式見 [工作台文件](docs/WORKBENCH.md)，實際驗收狀態見 [驗收紀錄](../reports/workbench/VERIFICATION.md)。三家完整實機驗收必須另有本人登入成功證據，不能用模擬測試代替。

VPS 常駐的獨立原型：自然語言交辦、進度與成果保存、工作交接、生活原話紀錄。正式語音 App 未替換；Mac 可透過獨立的瀏覽器入口開啟。

**瀏覽器控管：** G0–G4 的實作與核驗已保留，G5 尚待完成；見 [貓咪的手 PRD](docs/agent-hands/PRD.md) 與 [交接文件](docs/agent-hands/CLAUDE-HANDOFF-2026-10-26.md)。來源完成與合併不代表新控管已在 VPS 啟用。

選配的 [VPS 持久 Chrome 實驗元件](docs/browser-workspace.md) 已另設生命週期／profile 邊界及測試，尚未接入辦公室執行者或正式 VPS；文件包含 Agent Zero 的工程評估、啟動方式與下一步觀看／接管驗收。

## 使用

1. 執行 `office/open-office.command`。它使用既有 `neighbor-vps` SSH 別名，確認 HTTP 服務後才在 Mac 瀏覽器顯示辦公室。
2. 在「工作與交接」輸入交辦。預設 Codex，可自行改選 Gemma。選取文字檔或生活紀錄，才會把那些原文附給這次工作。
3. 選一件任務，可補充交接與下一步、下載 Markdown；「接續這件工作」會附上該件工作的原文快照、保存內容與交接，建立新任務，不重跑或覆寫舊任務。
4. 「生活紀錄」保存原話，無需任何模型。只有明確選取，才會隨工作交給 Agent。日期由使用者選取，不自動推定事件發生時間。
5. 關掉面板，VPS 仍處理已保存的佇列。離線未送出的草稿只在面板記憶體中，關閉 App 前請交辦或另存。

手機聊天介面的 `+` 可選 TXT／MD、PNG／JPEG／WebP 與 PDF。文字檔維持 48KB 上限；圖片與 PDF 各 8MB，PDF 最多 8 頁。手機瀏覽器會把 PDF 每頁轉為圖片，與原始 PDF 一起上傳；Codex 讀取頁面圖片，並在本次交辦保留不可變的附件快照。圖片與 PDF 目前只能交給 Codex，Gemma 僅處理文字。附件選取後在送出時才上傳 VPS；送出給 Codex 後，明確選取的附件會隨交辦傳給 OpenAI。Luna／Sol／Astra、Claude、Gemini 只顯示規劃位置，標示尚未接通且不可選。

Mac 用 `office/open-office.command` 開啟瀏覽器，只需要一條 18421 通道；預覽退出時只停止自己建立的 SSH 程序。VPS 桌面上的「貓咪辦公室」捷徑從 0.4.0 起不能用，原因見下方「本機入口」。

## 執行者

- **Codex**：官方 CLI 0.163.0，VPS 本人 ChatGPT 登入，受帳號方案與額度限制。使用獨立 CODEX_HOME，不搬 Mac 憑證，不建立 API key。每件工作為 ephemeral 執行，由辦公室提供選定上下文並保存成果；登入狀態與「曾完成真任務」分開顯示。
- 目前外部能力為文字整理與公開網路研究。停用 shell、程序執行、電腦操作、外部 App／插件與子代理，read-only sandbox、15 分鐘上限、4MB 事件上限；不會寄信、修改外部系統或建立排程。取消時停止該次程序群組。
- **Gemma 3 4B**：選配，僅明確選用時啟動 Ollama；不隨開機預設啟動。適合約千字內短文，7,000 UTF-8 bytes 的總輸入上限、512 tokens 輸出上限。過長、被截斷或需上網時保留待補充／部分內容／待串接狀態。可在 VPS 停止 `neighbor-ollama` 釋放記憶體。

交辦、選定來源與明確選取的交接／生活紀錄會送到 OpenAI。未選取的生活紀錄不自動加入 prompt。記憶是辦公室自己的 SQLite＋Markdown，沒有使用 Hermes Agent 的記憶套件，也不把全份生活史灌入外部模型。

## 保存

元件替換的責任邊界與驗收條件見 [元件邊界](docs/component-boundaries.md)。
追蹤層使用專案自己的 `TracePort` 與中性事件；[獨立觀測實驗](lab/README.md)
會將同一套合成任務分別送到 Phoenix 與 Jaeger，從後端查回資料驗證替換。
正式任務、成果與事件仍由辦公室自己保存；觀測服務的資料庫不承擔任務狀態。

VPS `~/neighbor-office/data/`，目錄權限 700，服務檔案預設 600：

- `office.sqlite3`：交辦、執行者、來源與選定上下文快照、父任務、狀態、事件、交接原文與生活紀錄。SQLite 是資料來源。
- `inbox/`：UTF-8 .md/.txt（48KB 以內）與圖片／PDF（8MB 以內），同名不覆寫。PDF 另存逐頁圖片於 `<檔名>.pages/`。
- `tasks/<UUID>/source/`：本次明確選取的圖片或 PDF 與逐頁圖片快照，供 Codex 讀取，避免收件匣來源日後變動影響已交辦任務。
- `tasks/<UUID>/result.md`：成果；`partial.md` 為部分內容；`brief.md` 為待外部交接單。
- `tasks/<UUID>/handoff.md`：保存交接時的 Markdown 快照；下載端點另以最新狀態組成完整交接。
- `journal/YYYY-MM-DD.md`：當天原文匯出。畫面與總匯出顯示最近 200 筆，較早資料仍在 SQLite 與每日檔。

相同 UUID、相同內容重送保持同筆；內容改變卻沿用 UUID 會拒絕。成果落盤後才標記完成。暫停取消正在執行的工作並保留佇列；重啟將進行中標記中斷、保留等待工作與暫停旗標。接續建立子任務，最多附十筆生活紀錄，交接上下文總上限 80KB。

## 登入、部署與驗證

`install_codex.py` 安裝官方固定 CLI、code-mode host 與 bwrap 發行檔，逐一核對 SHA256。第一次在 VPS 的獨立 CODEX_HOME 執行 Codex 登入，由本人完成：可使用裝置碼，若帳號未啟用則改一般瀏覽器 OAuth＋SSH loopback callback。登入檔留 VPS，不放 Git、報告或匯出。

`deploy.sh` 僅供舊版 SSH 通道服務使用；偵測到手機公網版時會停止，避免覆蓋其服務設定。Gemma 的開機啟動保持停用。office 的 TCP 僅監聽 `127.0.0.1:8421`，只給 Caddy 對外提供 HTTPS／WSS（公網模式）；本機模式另走私有 socket（見下方）。Gemma 使用時僅監聽 `127.0.0.1:11434`。

離線測試：`python3 -I -m unittest discover -s office/tests -v`。
部署後檢查（從 Mac）：`python3 -I office/verify_public.py --expect-version <版本>`，共 27 項：公網、短暫測試裝置的配對與撤銷、本機 socket、Mac 通道。測試裝置會在結束前撤銷，輸出不含配對碼、cookie 或 token。
真實服務驗證：`python3 office/verify_v2.py --report reports/office-v2/codex-live.json`；Gemma 加 `--provider gemma`。會新增明確標示的合成紀錄，不能將其視為真實生活事件。詳細通過與未驗收項目見 `reports/office-v2/VERIFICATION.md`。

HTTP 維持 Host／Origin／頁面 token 檢查，以純文字顯示內容，不執行模型 HTML。資料庫遷移前的備份在 VPS `~/neighbor-office/backups/office-v2-20261021T124049Z/`，包含當時 SQLite、app 與兩份使用者服務設定。

## 本機入口（0.4.0 起）

本機模式（不用配對就能讀寫全部任務和生活紀錄）只開在私有 Unix socket：`~/neighbor-office/run/office.sock`。socket 權限 600、資料夾權限 700，只有服務使用者打得開。

- **Mac：** `open-office.command` 把 Mac 的 `127.0.0.1:18421` 用 SSH 轉送到這個 socket（SSH 以服務使用者身分登入）。
- **TCP `127.0.0.1:8421`：** 只認公網模式，必須帶配對 cookie。VPS 上任何程式送「本機 Host」過去都會拿到 421。原因是貓咪的手（另一個 Linux 使用者）也連得到 loopback，見 `docs/agent-hands/PRD.md` 5.8。
- **`--local-socket`：** 可以改 socket 路徑。路徑上限 100 bytes，資料夾必須只有自己能進入。
- **啟動規則：** 啟動時會換掉當機留下的舊 socket；如果 socket 還有服務在聽，就拒絕啟動。不是 socket 的檔案一律不刪。
- **`--dev-tcp-local`：** 只限單人使用的開發機。它讓 TCP 也提供本機模式，**不可在 VPS 使用**。
- **`--worker-socket`（0.5.0 起）：** 開啟「手」（`executor: hands`）專用的 worker 入口。權限 660，給 worker 的群組使用，預設不開。它只回答 hands 任務本身；契約見 `docs/agent-hands/PRD.md` 9.1。
- **收回開關：** `office.py hands-lock on|off|status`。
- **在 VPS 上直接呼叫本機 API：** `curl --unix-socket ~/neighbor-office/run/office.sock -H 'Host: 127.0.0.1:18421' http://127.0.0.1:18421/api/health`。`verify_live.py` 已改走這個 socket。

## 選配執行追蹤（第一個切片）

可用 OpenTelemetry／OpenInference 將實際執行記錄成「任務 → Codex → 網頁搜尋」的追蹤，供 Phoenix 等相容工具查看時間、狀態與關係。預設關閉，原本的標準庫執行方式不需安裝 SDK；SQLite 事件與 WebSocket 補回仍負責持久進度。

這個切片加入追蹤接線與測試，尚未代表已部署追蹤服務、接通多 Agent 或遷移資料庫。啟用所需的固定依賴、隔離測試、資料範圍、關閉方式與後續順序見 [執行追蹤開發文件](docs/observability.md)。

## 手機 Chrome 直連

`https://office.nekonode.cloud` 已部署，手機先用 VPS 產生的一次性碼配對，再透過 cookie 存取辦公室。配對碼可從 Mac 執行 `office/pair-iphone.command` 取得，只顯示在本機 Terminal，10 分鐘內有效。WebSocket 只傳即時進度，交辦仍走 HTTP；手機斷線後由 SQLite 的事件序號補回。辦公室的 TCP 維持只監聽 `127.0.0.1:8421`。

設計與 API 契約見 [手機 PRD](docs/mobile/PRD.md)，部署紀錄與驗收範圍見 [部署檢查單](docs/mobile/DEPLOY.md)。iPhone Chrome 已開啟配對頁、配對並交辦測試任務；使用者確認可直接看到繁體中文成果，鎖屏超過五分鐘後仍能查看完成成果與進度。手動斷網重送及撤銷這台 iPhone 尚未實測。
