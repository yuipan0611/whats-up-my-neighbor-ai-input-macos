# 貓咪辦公室第二版

VPS 常駐的獨立原型：自然語言交辦、進度與成果保存、工作交接、生活原話紀錄。正式語音 App 未替換；Mac 入口是獨立「貓咪辦公室預覽」。

## 使用

1. 執行 `Previews/RemoteAgent/build-office-preview.sh` 建置，開啟 `build/office-preview/貓咪辦公室預覽.app`，按「連線／重連」。使用既有 `neighbor-vps` SSH 別名，確認 HTTP 服務後才顯示辦公室。
2. 在「工作與交接」輸入交辦。預設 Codex，可自行改選 Gemma。選取文字檔或生活紀錄，才會把那些原文附給這次工作。
3. 選一件任務，可補充交接與下一步、下載 Markdown；「接續這件工作」會附上該件工作的原文快照、保存內容與交接，建立新任務，不重跑或覆寫舊任務。
4. 「生活紀錄」保存原話，無需任何模型。只有明確選取，才會隨工作交給 Agent。日期由使用者選取，不自動推定事件發生時間。
5. 關掉面板，VPS 仍處理已保存的佇列。離線未送出的草稿只在面板記憶體中，關閉 App 前請交辦或另存。

也可使用 `office/open-office.command` 開啟 Mac 瀏覽器，或 VPS 桌面的「貓咪辦公室」。只有一條 18421 通道即可；預覽退出僅停止自己建立的 SSH 程序。

## 執行者

- **Codex**：官方 CLI 0.163.0，VPS 本人 ChatGPT 登入，受帳號方案與額度限制。使用獨立 CODEX_HOME，不搬 Mac 憑證，不建立 API key。每件工作為 ephemeral 執行，由辦公室提供選定上下文並保存成果；登入狀態與「曾完成真任務」分開顯示。
- 目前外部能力為文字整理與公開網路研究。停用 shell、程序執行、電腦操作、外部 App／插件與子代理，read-only sandbox、15 分鐘上限、4MB 事件上限；不會寄信、修改外部系統或建立排程。取消時停止該次程序群組。
- **Gemma 3 4B**：選配，僅明確選用時啟動 Ollama；不隨開機預設啟動。適合約千字內短文，7,000 UTF-8 bytes 的總輸入上限、512 tokens 輸出上限。過長、被截斷或需上網時保留待補充／部分內容／待串接狀態。可在 VPS 停止 `neighbor-ollama` 釋放記憶體。

交辦、選定來源與明確選取的交接／生活紀錄會送到 OpenAI。未選取的生活紀錄不自動加入 prompt。記憶是辦公室自己的 SQLite＋Markdown，沒有使用 Hermes Agent 的記憶套件，也不把全份生活史灌入外部模型。

## 保存

VPS `~/neighbor-office/data/`，目錄權限 700，服務檔案預設 600：

- `office.sqlite3`：交辦、執行者、來源與選定上下文快照、父任務、狀態、事件、交接原文與生活紀錄。SQLite 是資料來源。
- `inbox/`：UTF-8 .md/.txt，48KB 以內，同名不覆寫。
- `tasks/<UUID>/result.md`：成果；`partial.md` 為部分內容；`brief.md` 為待外部交接單。
- `tasks/<UUID>/handoff.md`：保存交接時的 Markdown 快照；下載端點另以最新狀態組成完整交接。
- `journal/YYYY-MM-DD.md`：當天原文匯出。畫面與總匯出顯示最近 200 筆，較早資料仍在 SQLite 與每日檔。

相同 UUID、相同內容重送保持同筆；內容改變卻沿用 UUID 會拒絕。成果落盤後才標記完成。暫停取消正在執行的工作並保留佇列；重啟將進行中標記中斷、保留等待工作與暫停旗標。接續建立子任務，最多附十筆生活紀錄，交接上下文總上限 80KB。

## 登入、部署與驗證

`install_codex.py` 安裝官方固定 CLI、code-mode host 與 bwrap 發行檔，逐一核對 SHA256。第一次在 VPS 的獨立 CODEX_HOME 執行 Codex 登入，由本人完成：可使用裝置碼，若帳號未啟用則改一般瀏覽器 OAuth＋SSH loopback callback。登入檔留 VPS，不放 Git、報告或匯出。

`deploy.sh` 上傳 source/static/tests，跑離線測試並重啟使用者 office 服務；Gemma 的開機啟動保持停用。不開新公網埠；office 僅 127.0.0.1:8421，Gemma 使用時僅 127.0.0.1:11434。

離線測試：`python3 -I -m unittest discover -s office/tests -v`。
真實服務驗證：`python3 office/verify_v2.py --report reports/office-v2/codex-live.json`；Gemma 加 `--provider gemma`。會新增明確標示的合成紀錄，不能將其視為真實生活事件。詳細通過與未驗收項目見 `reports/office-v2/VERIFICATION.md`。

HTTP 維持 Host／Origin／頁面 token 檢查，以純文字顯示內容，不執行模型 HTML。資料庫遷移前的備份在 VPS `~/neighbor-office/backups/office-v2-20261021T124049Z/`，包含當時 SQLite、app 與兩份使用者服務設定。
