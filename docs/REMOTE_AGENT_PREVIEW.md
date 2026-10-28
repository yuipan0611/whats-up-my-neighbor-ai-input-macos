# 遠端分身第一階段

本分支基於 `3101f03`；所有新增程式在獨立 `Sources/NeighborAgentCore` 和 `Previews/RemoteAgent`。正式 App 的來源、資源、身分與建置入口保持原樣。

## 實作與影響範圍

1. 任務核心：獨立型別、狀態機、固定示範事件及離線測試。
2. 原生面板：獨立 App 身分、自己的設定目錄，明確標示示範與待遠端驗證。
3. SSH 層：使用系統 SSH、參數陣列和既有使用者設定；以假的程序驗證生命週期，沒有 VPS 資料時不連線。

風險：任務與 SSH 是新增的生命週期邊界；用 generation、task ID、事件序號阻擋取消後與舊任務的回呼。正式語音、貼上、手機協定與黑貓模組不引用此核心；現有使用者沒有新的執行路徑。

既有基線：語音協調器與手機協定離線測試。各階段新增測試通過後各自提交；最後執行完整離線測試與正式 App 建置，不安裝、不推送、不發布。

## 目前驗證界線

示範不呼叫模型、不查網站、不操作主桌面、不寫備忘錄。三家 provider 是未驗證的選擇標籤，不能視為已登入或接通。真實 Linux 桌面、帳號登入及遠端任務必須取得 VPS 資料後另行驗證。

## 面板預覽

建置及操作方式見 [預覽說明](../Previews/RemoteAgent/README.md)。預覽身分為 `tw.panh.NeighborRemoteAgentPreview`，只保存 provider 選擇；任務內容不寫入磁碟。正式 App 不載入這些來源。

任務核心已通過 16 個情境；面板模型通過輸入、生命週期、provider 與獨立設定測試。六種畫面包含待命、執行中、取消、失敗、完成及窄版深色。實際原生視窗已驗證範例輸入、provider 選擇、執行中禁用按鈕、取消與完成結果。VoiceOver 語音朗讀本身尚未人工驗證。

獨立畫面複查已關閉淺色文字對比問題，最終 disposition 為 `ship`，沒有未解決的畫面項目；此判斷僅適用本機預覽。

## SSH 連線層

`SSHTunnelConfiguration(hostAlias:localPort:remotePort:)` 只接受既有 SSH 別名及 1024–65535 的連接埠；預設將 Mac `127.0.0.1:18421` 轉送到遠端 `127.0.0.1:8421`。日後必須由明確的連線操作呼叫 `SSHTunnelController.start(configuration:)`；建構控制器或啟動面板不連線。

使用 `/usr/bin/ssh` 與獨立參數陣列，不經 shell、不儲存密碼、不接受互動提示、不略過主機驗證、不轉送 ssh-agent 或 X11、不執行遠端命令。禁止背景化與控制 socket 重用，以保留對本次 SSH 程序的生命週期管理。只終止自己建立的程序，不殺其他 SSH 工作階段。使用者既有 SSH 設定（包括 ProxyJump／ProxyCommand）是使用者信任的本機設定，不複製到產品或遠端。

`processRunning` **僅表示本機 SSH 程序啟動**，不能證明認證、forward、遠端 API、AI 訂閱或任務成功。程序異常結束、狀態 255 或意外正常結束都會標示失敗，不自動重連或重播。新的通道不接受舊程序回呼。

11 個 SSH 情境已涵蓋注入／參數拒絕、重複啟動、啟動失敗、斷線、取消後回呼、舊程序回呼及釋放停止。另外使用真實系統 SSH 的 `-G -F /dev/null` 檢查參數解析與 exit callback；這只讀取空設定，不建立連線、不讀使用者 SSH 設定。沒有任何 VPS 或三家登入的端到端驗證。

## 接手控制（2026-10-20 新增）

側欄新增「接手控制」：用 macOS 內建「螢幕共享」開啟遠端桌面，讓人親自處理分身做不到的步驟。

- **Linux VPS**：使用既有的 `SSHTunnelController`，另開一條 `127.0.0.1:15901 → 遠端 127.0.0.1:5901`。
- **本機第二使用者**：直接連 `127.0.0.1:5901`，不經過 SSH。

開啟檢視器前，會先確認該埠回傳 12 bytes 的 RFB 開頭訊息，所以 SSH 程序在跑不等於可以接手。主機別名只存在記憶體，偏好檔仍然只保存 provider。

需求與驗收見 [remote-desktop/PRD.md](remote-desktop/PRD.md)，分工與進度見 [remote-desktop/HANDOFF.md](remote-desktop/HANDOFF.md)，遠端伺服器設定見 `remote-desktop/SETUP.md`（由 Antigravity 撰寫，經審閱後收錄）。

**已驗證**
- `scripts/test-remote-desktop.sh` 22 個情境通過，包含：
  - 狀態機與 generation 擋舊回呼。
  - 探測逾時、SSH 中斷、檢視器失敗。
  - 4 種真實 loopback 探測。
  - 面板 model。
- 用真實探測器加真實時鐘，對沒有伺服器的 5901 實測：9.9 秒後顯示第二使用者的錯誤文案，檢視器啟動 0 次。
- 8 張預覽圖：新增「接手中」與「窄版深色失敗」兩張。
- 依獨立審閱修正（由 Gemini 實作）：
  - 15901 被佔用時直接失敗。
  - 每次探測不超過 10 秒期限。
  - 開啟中停用「結束接手」。
  - 測試增為 32 情境，三組 mutation 測試都被抓到。
- `scripts/check-screen-sharing-loopback.sh` 實測：真實的螢幕共享會連進 127.0.0.1:5901，使用 RFB 3.3，並走到密碼對話框。完整紀錄見 [reports/REMOTE_DESKTOP_HANDOFF_2026-10-20.md](../reports/REMOTE_DESKTOP_HANDOFF_2026-10-20.md)。
- 預覽 App 的 UI 點擊已實際操作（使用者授權）：按鈕、狀態文字、「結束接手」都符合 PRD。
- `scripts/check-vps-path-loopback.sh`：用本機 sshd 模擬 VPS，SSH 轉送這條路端到端通過。這次執行也抓到並修好了 TIME_WAIT 誤報「15901 被佔用」的 bug。

- **真實 VPS 端到端（2026-10-21）**：Hostinger Ubuntu 26.04＋TigerVNC。
  - `scripts/check-real-vps.sh` 結束碼 0：使用者在螢幕共享輸入 VNC 密碼，看到 XFCE 桌面，滑鼠與鍵盤可用；stop 後 15901 已釋放。
  - 預覽 App 選「Linux VPS」並輸入 `neighbor-vps` 之後：按接手控制，顯示「已開啟螢幕共享」；按結束接手，顯示「SSH 通道已關閉」，15901 也已釋放。
  - 紀錄見 [reports/REMOTE_DESKTOP_VPS_2026-10-21.md](../reports/REMOTE_DESKTOP_VPS_2026-10-21.md)。

**尚未驗證**
- 真正的 Vine Server：Homebrew cask 已停用，待使用者決定（見 PRD 第 10 節）。
