---
title: 貓咪的手：交接板
date: 2026-10-23
status: D1–D17 已拍板；H3 有第一件真任務證據、仍待完整驗收；G0 完成、G1／G2 本機模擬完成、G3、G4 Mac 本機真 Chrome＋模擬完成（皆未部署）；G5 未開始；P0 完成、P1 本機完成、P2 安裝腳本完成（未在 VPS 執行）、P4 本機完成但個人帳號路徑失效（待 YUI 決定）、P3、P5、P6 未開始（ADR-003）
---

# 交接板

**2026-10-26 最新施工入口：** [給 Claude 的交接](CLAUDE-HANDOFF-2026-10-26.md)；瀏覽器控管、操作紀錄與接手詳細契約見 [ADR-002](ADR-002-browser-actions-audit-handover.md)。G0–G3 的進度見下方「增補施工」表與進度紀錄；全部只在本機分支 commit，沒有 push、合併或部署。下表 H2／H3 摘要未重驗 VPS 現況。

需求、決策、權限與體驗規則以 [PRD.md](PRD.md) 為準。本檔只記錄分工與進度。nekonode-site 分支 `docs/vps-agent-mvp-20261023` 的那份 VPS-first PRD 只當需求參考，**不拿來派工**；它的 A01–A20 對到哪個 H 任務，見 [ADR-001](ADR-001-office-sqlite-vs-vps-mvp-prd.md)。各 H 任務開工前，先看 ADR-001 第 7 節有沒有新增給它的項目。

## 分工

| ID | 任務 | 負責 | 擁有的檔案／範圍 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| H0 | PRD 與交接板 | Claude | `office/docs/agent-hands/*` | — | 完成（D1–D11 已拍板） |
| H1 | VPS 基礎：swap、`neko-hands`、Chrome、VNC 改歸 neko-hands、`/srv/neko-handoff`；worker 群組與 worker socket 的資料夾（neighbor 與 neko-hands 同屬一個群組，資料夾 2750） | Claude（依 YUI 指示以 root 執行）；腳本 `office/hands/setup-h1.sh` | VPS 系統設定 | D1、D2、D8 | **完成**（2026-10-23，VPS 實機）。見 `reports/agent-hands/H1-VERIFICATION-2026-10-23.md` |
| H2 | 辦公室安全底座：loopback 修補、worker API、「手」執行者、先停一下與收回開關 | Claude | `office/office.py`、`office/tests/test_local_entry.py`、`office/tests/test_hands.py` | D1 | **完成（歷史證據）**。2026-10-23 已部署至 0.5.1；114 項測試與公網 27 項紀錄見下方。新 broker／audit 由 G1／G2 補，不視為已實作 |
| H3 | worker＋Codex 登入＋瀏覽器 MCP；合成任務 | Claude＋YUI（登入） | `office/hands/*`（新增） | H1、H2、D9、D13 | **進行中**：2026-10-24 登入與第一件真 Chrome 任務已完成；惡意內容、連續 100 件、磁碟上限、重啟等仍待驗。G0／G3 補能力盤點與受限 adapter |
| H4 | GitHub App（營運者建立）、辦公室代為 clone／push／開 Draft PR、鑰匙收回、越權測試 | Claude＋YUI | `office/github_app.py`（新增）、`office/tests/test_github_push.py`、驗證紀錄 `reports/agent-hands/` | H2、H3、D4 | 未開始 |
| H5 | 體驗層：自動轉交、三種卡片、鑰匙清單、文案清理、禁用詞掃描 | Claude | `office/static/*`（先在下方留言，與手機版協調）、`office/tests/test_copy.py` | H3、D10 | 未開始 |
| — | **v1a 完成點** | — | — | H1–H5 | — |
| H6 | 看看貓咪（noVNC＋WebSocket 轉接）、接手時自動停手。接手中斷線**維持暫停**，按「交還」才繼續；接手狀態存在辦公室；同時只有一台裝置接手；交還後先看再做；接手時間不算進 30 分鐘，斷線超過 2 分鐘算一件「等你」；接手中由 worker 暫停整組 agent 程序、停止截圖；heartbeat 多回 `hold`（PRD 第 6 節、D12） | Claude＋YUI | `office/static/viewer*`、`office.py` 的 viewer 端點與 `hands_heartbeat` 的 `hold`、`office/hands/*` 的暫停與恢復（H3 完成後接手）、`office/tests/test_viewer.py`（新增） | H3、H5、D6、D12 | 未開始 |
| H7 | 貓咪資料夾：Mac LaunchAgent＋rsync | Claude | `office/handoff-sync/*`（新增） | H1、D5 | 未開始 |
| H8 | 通知 | Claude＋YUI | `office/notify*`（新增） | H5、D11 | 未開始 |
| H9 | REVOKE.md、撤銷演練 | Claude＋YUI | `office/docs/agent-hands/REVOKE.md` | H4–H8 | 未開始 |

## 2026-10-26 增補施工：G0–G5

這是 H 任務的增補，不另建服務。G1／G2 接到 H2／H3／H4／H5，G4 接到 H6；v1a 原有能力與新增 broker 能力分開標示，不能以舊 H 完成推定 G 已完成。

| ID | 交付 | 接到 H | 狀態 |
|---|---|---|---|
| G0 | 能力路徑表、現況版本、同 UID／CDP／shell 旁路 | H3 | **完成**（2026-10-26，VPS 唯讀實測）：`reports/agent-hands/BROWSER-CAPABILITY-BASELINE.md`。沙箱內可直連 CDP、讀 profile 與 Codex 登入檔、連 X 桌面，broker 只能保證自己這條路 |
| G1 | 固定規則與 broker 核心、action_id／lease／epoch／目標版本 | H2／H3 | **完成（本機模擬）**：`office/browser_actions.py`；未接真 Chrome、未部署 |
| G2 | 決策／結果紀錄、遮蔽、owner 查詢與遷移 | H2／H4／H5 | **完成（本機模擬）**：`office/browser_audit.py`＋owner 分頁 API；22 項測試、14 組 mutation |
| G3 | 受限瀏覽器 adapter、needs_human 卡片、真 Chrome 驗證 | H3／H5 | **完成（Mac 本機真 Chrome＋模擬）**：`office/browser_cdp.py`、`office/hands/browser_adapter.py`、worker proxy、`--browser-cdp`；合成網站與暫存 profile。needs_human 只做到 agent 停止訊息＋紀錄，App／網頁卡片未做；真 Codex、VPS 未跑 |
| G4 | 接手停止確認、控制世代、斷線／重啟 hold、重新觀察與計時 | H6 | **完成（Mac 本機真 Chrome＋模擬）**：`office/browser_control.py`＋owner／worker 控制路由＋worker 多輪與停整個程序群組。viewer（noVNC、按鈕、人工輸入通道）、D11 通知、真 Codex、VPS 未做或未跑 |
| G5 | 撤銷、故障、回退與跨裝置驗收 | H9 | 未開始 |

施工順序、檔案分工及驗收見 [Claude 交接](CLAUDE-HANDOFF-2026-10-26.md)。目前文件由 Codex 整合；產品檔案仍交 Claude，開工先在此記接手。新增 ADR-002 未修改 D13／D14；強制隔離需要另案設計，不能用 broker 內測試冒充。

## 2026-10-28 增補施工：P0–P6（Claude 與 Gemini）

設計、帳號與風險見 [ADR-003](ADR-003-claude-gemini-executors.md)。D15–D17 已拍板，D9 由 D16 取代。

| ID | 交付 | 負責 | 擁有的檔案／範圍 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| P0 | ADR-003、PRD v0.5、本表 | Claude | `office/docs/agent-hands/*` | — | **完成**（只改文件） |
| P1 | Claude 腦：共用子程序執行器、`ClaudeAgent`、`claude` 執行者、網頁模型選單 | Claude | `office/office.py`、`office/static/*`、`office/tests/test_providers.py`（新增） | P0 | **完成（本機）**：188 項測試；真 Claude CLI 只驗了未登入的路徑；未部署 |
| P2 | Claude 腦上 VPS：釘版安裝、YUI 登入、部署、條款查證 | Claude＋YUI（登入、同意部署） | `office/install_agent_clis.py`（新增）、`reports/agent-hands/` | P1 | **準備完成**：釘版安裝腳本＋4 項測試；條款查證見 TERMS 報告的「Claude 覆核」。VPS 安裝、登入、部署都未做 |
| P3 | Claude 手：worker `agent` 欄位、Claude 指令、沙箱、受限 adapter；neko-hands 安裝與登入 | Claude＋YUI（登入） | `office/hands/worker.py`、`office/tests/test_hands_worker.py` | P2、G0–G4 部署 | 未開始 |
| P4 | Gemini 腦 | Claude＋YUI（登入） | 同 P1／P2 | P1 | **待 YUI 決定**：Gemini CLI 版本完成（22 項 provider 測試）。但 2026-06-18 起個人帳號改用 Antigravity CLI，見 ADR-003 第 4 節 |
| P5 | Gemini 手 | Claude＋YUI（登入） | 同 P3 | P3、P4 | 未開始 |
| P6 | Mac 原生 Preview 模型選單 | 與 `worktrees/native-vps-desktop-preview` 協調 | 那個 worktree | P2 | 未開始 |

## 規則

- **H2 的 loopback 修補完成並部署之前，不建立 neko-hands。**
- **GitHub App 私鑰只放 neighbor。** neko-hands 的環境裡不能出現任何 GitHub 鑰匙；push 一律經過 `/api/worker/push`，而且只推 `neko/*`。
- 在 `claude/agent-hands-prd` 分支上 commit。合併到 main、push、部署到 VPS，都要另外取得 YUI 同意。
- 一個檔案只有一個負責人。要改別人的檔案，先在下方留言。
- 新介面文案要通過 PRD 3.8 的禁用詞掃描。
- 不讀取、不輸入、不保存密碼、token、cookie、配對碼或私鑰，也不寫進報告或聊天。
- 這台 Mac 拿得到的操作由 Claude 自己執行並自己驗證，不要請 YUI 跑指令再回報：YUI 2026-10-23 指示「這種東西你應該自己操控電腦確認」。root 用 `ssh -i ~/.ssh/neighbor_vps_ed25519 -o IdentitiesOnly=yes root@31.97.108.187`。只有真的需要 YUI 本人的步驟（登入帳號、建立 GitHub App、在 hPanel 操作），才先用確認問題講清楚要輸入什麼、什麼時候輸入。
- 不要把 `.impeccable/`、`design/` 或 `worktrees/neighbor-remote-agent` 的實驗混進來。
- 驗收紀錄把自動測試、模擬、實機（VPS／Mac／iPhone 分開）和 `NOT RUN` 分開標示；Chromium 的結果不寫成 Chrome 的結果（ADR-001 第 8 節）。

## 進度紀錄

- 2026-10-28｜Claude｜P2 準備＋條款查證
  - **`office/install_agent_clis.py`：** 從 npm registry 下載 Claude Code `2.1.183`（linux-x64 原生執行檔）與 Gemini CLI `0.47.0`。先比對寫死的 SHA-512 才解開；拒絕不安全或不對的封包內容；整包換上，不碰登入資料夾；不用 sudo。
  - **自動測試：** 4 項。
  - **實際下載（Mac，暫存資料夾）：** 兩個套件的 SHA-512 都相符。Gemini 的啟動檔能執行並回報 0.47.0。Claude 的 Linux 執行檔沒有在 Mac 執行。暫存資料夾已刪除。
  - **條款：** Gemini（Antigravity CLI）先寫報告，Claude 覆核並更正（見 TERMS 報告最後一節）。
    - Claude 額度與 Mac 共用，官方確認。
    - 「無人值守」沒有找到明確官方說法。
    - Gemini CLI 個人帳號 2026-06-18 起改為 Antigravity CLI。
  - **Antigravity 實測（YUI 的登入，一句提示，空資料夾）：**
    - 串流事件有 `init`（含工具清單）、`step_update`、`result`（含 `structured_output`）。
    - 預設 60 個工具；`--mode plan` 在關掉 slash command 時沒有效果。
  - **NOT RUN：** VPS 安裝、YUI 登入、部署。
- 2026-10-28｜Claude｜P4｜本機程式完成（自動測試＋真 CLI 未登入路徑；沒有 VPS、已登入的 Gemini、網頁實測）
  - **`GeminiAgent`：**
    - 用 Gemini CLI 0.47.0 的 `-p '' -o stream-json --approval-mode plan`，prompt 從 stdin 送入。
    - `GEMINI_CLI_HOME` 隔離在 `runtime/gemini-home`；每次執行前改寫 settings（Google 登入、兩個工具、沒有 MCP、不送使用統計）。
    - 每個 `tool_use` 只要不是 `google_web_search`／`web_fetch` 就停掉。
    - 回覆是串流文字：接起來後當 JSON 解析，也接受 ```json 程式碼框或前面多一句話。
    - 代碼 41 轉成「需要登入」；`RESOURCE_EXHAUSTED`／quota／429 轉成「用量暫時用完」。
  - **接線：** `gemini` 執行者、`gemini_last_success`、`/api/health` 的 `providers.gemini`。網頁的 Gemini 選項依健康狀態開關，隱私提示寫 Google。
  - **自動測試：** 新增 8 項，provider 測試共 22 項。突變檢查 7 種都抓得到：工具檢查、代碼 41、quota 判斷、開場事件、改寫 settings、plan 模式、status 判斷。
  - **真 CLI（Mac，Gemini CLI 0.47.0）：**
    - 沒有登入檔時，健康檢查判定未登入。
    - 放一個無效的登入檔後執行，1.3 秒得到「Gemini 尚未登入」，工作資料夾維持空的。
    - 從套件原始碼確認串流事件：`init`、`message`（delta）、`tool_use`、`tool_result`、`error`、`result`。
  - **NOT RUN：**
    - 已登入的真 Gemini 任務：plan 模式下會不會正常回答、`web_fetch` 會不會被擋，都要等登入後驗證。
    - VPS、網頁實測、條款查證。
- 2026-10-28｜Claude｜P1｜完成（本機自動測試＋本機網頁；沒有 VPS、真的已登入 Claude、iPhone、Mac App）
  - **程式：**
    - Codex 腦的子程序執行（串流、心跳、卡住提示、15 分鐘、4 MB、取消、清理）抽成 `CliAgent`，`CodexAgent` 改用它，行為不變。唯一差異：stdout 上不是 JSON 物件的行一律略過，原本會變成一般失敗。
    - 新增 `ClaudeAgent`：
      - 工具只有 `WebSearch`、`WebFetch`，`--permission-mode dontAsk`，不載入 MCP、不讀設定、不留對話紀錄。
      - 設定在 `runtime/claude-home`，`--json-schema` 取得結構化成果。
      - 開場事件的工具清單只要超出 `WebSearch`、`WebFetch`、`StructuredOutput`，或帶了 MCP，就直接中止。
      - `authentication_failed` 轉成「需要登入」，`rate_limit`／`billing_error` 轉成「用量暫時用完」，都走 `needs_provider`。
    - `claude` 執行者：
      - `Store.submit` 接受；圖片與 PDF 仍只給 Codex。
      - 執行、保存與 `claude_last_success` 跟 Codex 同一條路。
      - `/api/health` 多 `providers`，`provider` 仍是 Codex，舊版 App 不受影響。
      - `main()` 會建 `ClaudeAgent`；VPS 還沒裝 Claude，所以顯示「尚未接通」。
    - 網頁：手機選單的 Claude 依健康狀態可選，桌面多 `Claude · Anthropic` 選項，隱私提示改說 Anthropic。顯示名稱、頭像、「正在整理內容」也跟著執行者換。
  - **自動測試：**
    - 新增 `test_providers.py` 14 項，用照劇本吐事件的假 Claude CLI。
    - 突變檢查：拿掉工具檢查、`is_error` 判斷、`subtype` 判斷、環境變數白名單、CLI 英文通知過濾、開場事件必要性、`_last_success` 鍵名，每一種都會讓測試失敗。
    - 全部 188 項在 Mac 上通過。
  - **真 CLI（Mac，Claude Code 2.1.183，空的設定資料夾，未登入）：**
    - 開場事件的工具正好是 `StructuredOutput`、`WebFetch`、`WebSearch`，`mcp_servers` 為空。
    - `ClaudeAgent.health()` 判定未登入；繞過預檢執行時，得到「Claude 尚未登入」；沒有記下 CLI 的英文訊息，工作資料夾仍是空的。
  - **本機網頁（Chrome 預覽、假 CLI、已登入）：**
    - 手機寬度：選單的 Claude 顯示「已登入」並可選；交辦後顯示「已交給 Claude」、Claude 頭像、成果與建議下一步，工作過程是「Claude 正在整理內容。」「搜尋：…」。
    - 桌面寬度：狀態列有 Claude，任務顯示「執行者：Claude · Anthropic」。
    - console 沒有錯誤。
  - **NOT RUN：** 已登入的真 Claude 任務（要等 P2 登入）、VPS、iPhone 實機、Mac 原生 App、條款查證。
- 2026-10-28｜Claude｜P0｜完成（只改文件）
  - YUI：主力是 Claude、OpenAI、Gemini，Gemma 不是重點；拍板 D15–D17。
  - VPS 唯讀實測：沒有 Claude Code、Gemini CLI；有 Node 22.22.1、系統 bwrap；Ubuntu 26.04 限制非特權 user namespace。
  - Mac 上確認 Claude Code 2.1.183、Gemini CLI 0.47.0 的無人值守參數、隔離設定資料夾與沙箱選項。VPS 上的行為待 P2／P3 實測。
  - 同日 Gemma 冷載入修正 `82f70d5`（未部署），紀錄 `reports/agent-hands/GEMMA-COLD-LOAD-2026-10-28.md`。
- 2026-10-26｜Claude｜接手 G0–G5
  - 規劃文件原樣 commit（`345a1ce`）。
  - Claude 負責 `office/browser_actions.py`、`office/browser_audit.py`、`office/tests/test_browser_actions.py`，以及 `office.py` 的 broker 路由與遷移。
- 2026-10-26｜Claude｜G4｜完成（Mac 本機真 Chrome 155 headless＋自動測試模擬；沒有 VPS、真 Codex、viewer、Mac App、iPhone）
  - 接手狀態機與 API（`/api/viewer/control`、`/api/viewer/state`、`/api/worker/browser/control-ack`、heartbeat 的 hold 欄位）。
  - worker 每 1 秒問控制狀態，停整個程序群組才回報停手，暫停不算時間，交還後由 broker 重新觀察。
  - 斷線、重啟不會自動交還；撤銷操作者即轉 held；舊模式任務不能接手（409）。
  - 修 G3 漏洞：快照名稱不再拿輸入框的值；密碼／驗證碼欄位在交還時讓 session 維持暫停。
  - 實測（本機）：停手確認 0.12–0.19 秒；接手等在途導航 1.73 秒。
  - 測試：完整測試組 170 項全過；mutation 21 組抓到 20 組，另 1 組是等價突變。
  - 紀錄見 `reports/agent-hands/G4-VERIFICATION-2026-10-26.md`。
  - ADR-002 要求 G3／G4 前先補 H3 缺項，這次依指示先做 G4，H3 缺項仍待補。
  - 部署時 release 要多包 `office/browser_control.py`。本則不授權部署。
- 2026-10-26｜Claude｜G3｜完成（Mac 本機真 Chrome 155 headless＋自動測試模擬；沒有 VPS、真 Codex、Mac App、iPhone）
  - broker 的手（CDP，固定 script、隔離 world、點擊前核對元素）、agent 唯一的 6 個瀏覽器工具（adapter）、worker 的每任務 proxy（lease 與控制世代只在 proxy 加）、office `--browser-cdp`。
  - broker 模式沒設定 adapter 就讓任務失敗，不退回 raw MCP。
  - 測試：完整測試組 146 項全過；真 Chrome 5 項，含整條路串起來（只有 Codex 是假的），合成網站從沒收到 `/logout`、`/delete`。
  - mutation 12 組抓到 10 組，另 2 組是等價突變（另一道牆仍在）。
  - 仍是只保證經過 broker 的路；同 UID 下 agent 可直連 proxy socket（限制與 adapter 相同），G0 旁路仍在。
  - 紀錄見 `reports/agent-hands/G3-VERIFICATION-2026-10-26.md`。
  - 部署時 release 要多包 `office/browser_cdp.py`、`office/hands/browser_adapter.py`；worker 加 `--adapter`、office 加 `--browser-cdp`。本則不授權部署。
- 2026-10-26｜Claude｜G1／G2｜完成（本機自動測試＋模擬；沒有真 Chrome、VPS、Mac App、iPhone）
  - broker（固定規則 browser-policy-1、先寫決策再派送、閘門內再檢查、重送不重派、結果不明不重送、封鎖與重啟核對）。
  - 只新增的操作紀錄與擁有者分頁 API。
  - `tasks.browser_mode` 在交辦時固定，預設 legacy。
  - 測試：22 項，完整測試組全過；14 組 mutation 全部被抓到。
  - 紀錄見 `reports/agent-hands/G1-G2-VERIFICATION-2026-10-26.md`。
  - 部署時 release 要多包 `office/browser_actions.py`、`office/browser_audit.py`。
- 2026-10-26｜Claude｜G0｜完成（VPS 唯讀實測）
  - 能力路徑表見 `reports/agent-hands/BROWSER-CAPABILITY-BASELINE.md`。
  - 第一輪有 3 項是引號造成的假結果，已重測更正。
  - 主要旁路：沙箱內的 shell 可以直連 CDP 9222、讀 Chrome profile 與 Codex 登入檔、連 X 桌面。
  - raw MCP 開放 32 個工具，含 evaluate_script、upload_file、take_heapsnapshot。
  - 封住這些旁路需要修改 D13，本次不做。
- 2026-10-26｜Codex｜規劃整合（YUI 要求）
  - 新增 ADR-002 與 CLAUDE-HANDOFF-2026-10-26，將瀏覽器控管、操作紀錄、接手屏障對應 H 任務與 G0–G5。
  - PRD 更新為 v0.4；D7 人親手做、D12 斷線維持暫停、D13 同 UID、D14 無網站白名單保留；對同 UID 旁路與第一階段保障明確限縮。
  - 修正 H2／H3 表頭摘要與已有 10 月 23–24 日紀錄的落差；不是重新驗證部署。
  - 僅改規劃文件；未執行產品測試、未部署、未傳送到其他 Claude 聊天。G 任務均未開始。
  - 文件檢查：新文件的 6 個相對連結、必要決策／任務標記、程式區塊成對與 `git diff --check` 通過；worktree 的 6 個變更均為 Markdown，另更新工作區根 README 的入口。

- 2026-10-23｜Claude｜H0｜v0.1 草案
  - 新增 PRD.md、HANDOFF.md。
  - 唯讀實測：Mac swap 7.07/8 GB、70 個 node 程序；VPS 2 vCPU、7.9 GB、沒有 swap、x86_64、只有 `neighbor` 使用者、沒有 Chrome／gh。
  - 確認辦公室 local 模式信任 loopback（PRD 5.8）。
- 2026-10-23｜Claude｜H0｜v0.2 草案
  - YUI 要求「工程做，使用者無感」，PRD 新增第 3 節體驗層：六樣可見元素、工程吸收清單、不能藏的四件事、互動預算、用到才設定、文案、禁用詞。
  - 唯讀實測 GitHub：macOS repo 公開；`main` 沒有保護；`macos-release` 沒有審核規則；`build.yml` 的 `free-release-check` 在 push 到 `main` 或 `codex/neko-cicd-updates` 時，會拿到簽章憑證和 Sparkle 私鑰。因此改成 GitHub App，由辦公室代為 push，而且只推 `neko/*`。
  - 撤回 v0.1 的「Chrome 登入 GitHub 網頁」。
  - 範圍拆成 v1a（H1–H5）和 v1b（H6–H9）。
  - 待 YUI 拍板 D1–D11。
- 2026-10-23｜YUI｜H0｜拍板｜D1–D11 全部照 PRD 推薦；指示開始 v1a，先做 H2 的 loopback 修補｜手機 PRD 的 D4（暫不通知）由本 PRD 的 D11 取代，已在手機 PRD 註記
- 2026-10-23｜Claude｜H2 loopback 修補｜完成（本機，未部署）
  - office 0.4.0：本機模式只開在私有 Unix socket `~/neighbor-office/run/office.sock`（600／700）；TCP 只認公網模式；新增 `--local-socket`、`--dev-tcp-local`（只限開發機）。
  - `open-office.command` 改成轉送到 socket；VPS 還是 0.3.0 時自動沿用 8421。`verify_live.py` 改走 socket。
  - 測試：新增 `tests/test_local_entry.py` 14 項；共用測試的本機請求改走 socket（`test_office.py`、`test_mobile.py` 的 helper）。全部 83 項通過；9 組 mutation 全部被抓到（含連接埠被占用時要回報原本的錯誤）。
  - VPS 唯讀確認：sshd 允許轉送到 Unix socket；`/home/neighbor` 750、`~/neighbor-office` 700，沒有額外 ACL。
  - 在 `/tmp` 隔離的暫時實例實測：TCP 本機 Host 回 421、Mac 經 SSH 轉送到 socket 回 200、socket 權限 `srw------- neighbor`、停止後自動移除。暫時資料夾已刪除，正式服務沒有動。
  - 下一步：部署 0.4.0（需 YUI 同意，照 `docs/mobile/DEPLOY.md` 第 7 點）；接著做 worker API。
  - 注意：VPS 桌面的 `neighbor-office.desktop` 捷徑部署後會失效，這是刻意的。
- 2026-10-23｜Claude｜H2 部署 0.4.0｜完成（YUI 同意）
  - `current` → `releases/public-20261023-52108bd`；備份 `backups/pre-52108bd-20261023T074835Z`（SQLite integrity ok）。
  - VPS 上 83 項測試通過；新增 `office/verify_public.py`，27 項全過。
  - 紀錄見 `reports/agent-hands/DEPLOY-0.4.0-2026-10-23.md`。
  - Mac 在合併 main 之前，要用這個分支的 `open-office.command`。
- 2026-10-23｜Claude｜H2 worker API｜完成（本機，未部署）
  - office 0.5.0：新增 hands 執行者，辦公室內建的 worker 不會領它。
  - worker socket 預設不開，用 `--worker-socket` 開啟，權限 660、資料夾不對其他人開放。它只提供 claim／heartbeat／events／complete，只回答 hands 任務本身。
  - 一次只發一件；租約 120 秒，重試 3 次後才標成中斷；辦公室重啟不會中斷 hands 任務。
  - 收回開關：`office.py hands-lock`；「先停一下」也會停掉 hands 任務。
  - 資料表新增 `attempts`、`heartbeat` 欄位，沒有改動既有資料。
  - 測試：`tests/test_hands.py` 18 項；全部 101 項通過；13 組 mutation 全部被抓到。
  - 契約見 PRD 9.1。
  - 手機介面把 hands 任務顯示成「Codex」，H5 再改。
  - 下一步：H1（需要 YUI 以 root 執行）→ 部署 0.5.0 並開啟 worker socket → H3。
- 2026-10-23｜Claude｜H2 worker lease｜完成（本機，未部署）
  - 原因：heartbeat、events、complete 原本只認任務編號。第 1 輪卡住超過 120 秒、任務被第 2 輪領走後，第 1 輪醒來仍能交出成果，也能替第 2 輪續租。
  - 修法：每次領取發一個新的隨機 `lease`，三個端點都要帶。沒帶回 400；舊的或猜的，heartbeat 回 `continue: false, superseded: true` 且不續租，events／complete 回 409、不留任何東西。擁有者看到的任務資料不含 lease。
  - 資料表只新增 `lease` 欄位；用 0.4.0 的資料庫實測遷移，既有任務保留。版本號維持 0.5.0（尚未部署過）。升級當下若有沒帶 lease 的 hands 任務，會在 120 秒後退回佇列、重新領取。
  - `hands_notes` 改在辦公室的鎖裡完成「檢查＋寫入」，跟 `hands_complete` 一樣。
  - 測試：`test_hands.py` 新增 FencingTests 3 項，既有測試改帶 lease；全部 104 項通過。7 組 mutation 全部被抓到：比對永遠成立、heartbeat 不查 lease、先續租再查、events／complete 不查、重新領取沿用舊 lease、不驗證格式、擁有者看得到 lease。
  - 契約見 PRD 9.1（v0.2.1）。
- 2026-10-23｜Claude｜H0｜ADR-001
  - 對照 nekonode-site 的 VPS-first PRD：沿用辦公室＋SQLite，不另做 FastAPI＋PostgreSQL。A01–A20 逐項對到 H 任務；新增工作列在 ADR 第 7 節。
  - 待 YUI 決定（ADR 第 5 節）：接手中斷線是否維持暫停（推薦維持）；程式與 Chrome 同一個使用者（推薦 v1 維持）；網站白名單（推薦 v1 不做）。
- 2026-10-23｜YUI｜H0｜拍板 D12–D14（ADR-001 第 5 節全部照推薦）
  - D12：只在看時關掉畫面不影響工作；接手中斷線維持暫停，按「交還」才繼續。
  - D13：v1 程式和 Chrome 同在 neko-hands；Chrome 要登入有價值的帳號時再加 `neko-runner`。
  - D14：v1 不做網站白名單。
- 2026-10-23｜Claude｜H0｜PRD v0.3
  - 第 6 節改寫接手與斷線：接手狀態存在辦公室；同時只有一台裝置接手；交還後先看再做；接手時間不算進 30 分鐘；斷線超過 2 分鐘算一件「等你」（D11 通知）；接手中由 worker 暫停整組 agent 程序並停止截圖；heartbeat 多回 `hold`。
  - 跟著改：3.3、3.7（新增「你接手到一半離開了」文案）、第 7 節、第 9 節、第 12 節、13.2（新增兩項驗收）；5.2 補 D13，5.9 補 D14，第 10 節新增 D12–D14。
  - H6 表格列改寫，依賴加上 H3（要用 worker 暫停 agent），檔案加 `hands_heartbeat` 的 `hold` 和 `office/tests/test_viewer.py`。H3 依賴加上 D13。
  - 只改文件，沒有改程式。
- 2026-10-23｜Claude｜H1｜完成（VPS 實機）
  - 經過：YUI 按了「H1 finished」，但實際上沒有執行；唯讀檢查發現 VPS 完全沒變。YUI 指示改由 Claude 自己操作。root 的 authorized_keys 收了 `neighbor_vps_ed25519`，Claude 以 root 執行 `setup-h1.sh`（SHA-256 `b2beb758…f7f83d12`），結束碼 0，21 個 OK。
  - 結果：
    - swap 4G。
    - `neko-hands`（uid 1001，只在 neko-hands、neko 群組，密碼已鎖，沒有 SSH 金鑰）。
    - `user-1001.slice` 記憶體上限 5G。
    - `/srv/neko-office`、`/srv/neko-handoff/{to-cat,from-cat}`。
    - 桌面 `:1` 改歸 neko-hands，systemd 開機啟動，只聽本機；neighbor 的桌面已關。
    - Chrome 156、CJK 字型。
  - 獨立複查：權限與群組；以貓咪身分做越權嘗試，全部失敗，辦公室 TCP 回 421／401；從外部掃描，只有 22、80、443。ADR A07、A11、A18 已更新證據。
  - VPS 上的資料夾改用 ASCII 名稱 `to-cat`／`from-cat`（PRD 5.7 已改）。
  - NOT RUN：重開機後是否保留、用螢幕共享實際看畫面、Chrome 在桌面上開啟（H3）。
  - 下一步：部署 0.5.0 並開 `--worker-socket /srv/neko-office/worker.sock`（服務設定是 neighbor 的 user unit，不需要 root），然後做 H3。
- 2026-10-23｜Claude｜部署 0.5.0｜完成（YUI 同意，實機）
  - `current` → `releases/public-20261023-11a383a`；備份 `backups/pre-11a383a-20261023T133923Z`。
  - unit 加上 `--worker-socket /srv/neko-office/worker.sock`；`worker.sock` 為 `srw-rw---- neighbor:neko`。
  - 104 項測試在 Mac 與 VPS 都通過；`verify_public.py` 27 項全過。
  - 跨使用者：neko-hands 能 claim，碰擁有者的路徑一律 404；`nobody` 連不上。
  - 紀錄見 `reports/agent-hands/DEPLOY-0.5.0-2026-10-23.md`。
- 2026-10-23｜Claude｜H3｜worker 與 VPS 設定（實機）
  - `office/hands/worker.py`：claim、跑 Codex（workspace-write＋網路、交回資料夾可寫、瀏覽器工具）、分批送步驟、每 30 秒 heartbeat、結構化結果。取消、暫停、收回或 lease 被取代時，結束整組程序。上限 30 分鐘／4 MB／2 GB。lease 和 socket 不進 agent 的環境或 prompt。
  - 10 項 worker 測試（真的辦公室＋假的 Codex），全部 114 項通過；5 組 mutation 全部被抓到。
  - office 0.5.1：`incomplete` 也顯示原因。尚未部署。
  - 實測決定（PRD U2）：Codex 0.163.0 的 workspace-write 沙箱在 VPS 上以 neko-hands 可用：工作區能寫、外面寫不了；`network_access=true` 才連得到網路。
  - Codex 內建的 browser_use 綁桌面 App，不採用；改用 chrome-devtools-mcp 1.12.0（零依賴）。
  - `office/hands/setup-h3.sh`（root）：Node 22.22.1、Codex 0.163.0（SHA-256 核對）、chrome-devtools-mcp 1.12.0（不跑安裝腳本），都由 root 擁有；`neko-chrome.service` 與 `neko-hands-worker.service` 以 neko-hands 執行，在 user-1001.slice 裡。
  - 第一次執行時，本機的輸出過濾器語法錯誤，中斷在 apt 之後；確認 dpkg 乾淨後重跑成功。
  - 獨立複查：兩個服務都在跑、開機會啟動；行程在 user-1001.slice；9222 只聽 127.0.0.1，外部掃描沒有回應；貓咪改不了工具。
  - 下一步：YUI 用裝置碼替貓咪的 Codex 登入 → 第一件真任務 → ADR 第 7 節的 H3 驗收（惡意網頁、惡意 README、連續 100 件、磁碟上限、D13 的說明）。
- 2026-10-23｜Claude｜部署 0.5.1｜完成（YUI 同意，實機）
  - `current` → `releases/public-20261023-f74a50a`；備份 `backups/pre-f74a50a-20261023T141025Z`。
  - VPS 上 114 項測試通過（含 worker 測試）；`verify_public.py` 27 項全過。
  - release 從這一版起包含 `office/hands`。
- 2026-10-23｜YUI／Claude｜H3｜Codex 裝置碼登入：Claude 在 14:07 UTC 啟動裝置碼登入，碼在聊天裡給 YUI。過了 7 分鐘仍未登入（裝置碼 15 分鐘後失效）。待 YUI 完成，或改用瀏覽器登入加 SSH 通道。
- 2026-10-24｜Claude｜H3｜第一件真任務（實機）
  - 貓咪的 Codex 經瀏覽器登入完成（YUI 本人按「Yui PAN」）。裝置碼兩次都逾時。
  - 第一次：瀏覽器工具被核准機制擋下，回報 incomplete。修正：`default_tools_approval_mode="approve"`。
  - 第二次：42 秒完成，標題、第一段文字、截圖都對。
  - 獨立確認時發現交回檔案只有貓咪讀得到，worker 遮罩已改成 027。
  - 紀錄見 `reports/agent-hands/H3-FIRST-TASK-2026-10-24.md`。剩下 ADR 第 7 節的 H3 驗收（惡意網頁與 README、連續 100 件、磁碟上限、重開機、D13）。
