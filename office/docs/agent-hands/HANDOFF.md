---
title: 貓咪的手：交接板
date: 2026-10-23
status: D1–D11 已拍板（2026-10-23，全部照推薦）；v1a 進行中，H2 loopback 修補先做
---

# 交接板

需求、決策、權限與體驗規則以 [PRD.md](PRD.md) 為準。本檔只記錄分工與進度。nekonode-site 分支 `docs/vps-agent-mvp-20261023` 的那份 VPS-first PRD 只當需求參考，**不拿來派工**；它的 A01–A20 對到哪個 H 任務，見 [ADR-001](ADR-001-office-sqlite-vs-vps-mvp-prd.md)。各 H 任務開工前，先看 ADR-001 第 7 節有沒有新增給它的項目。

## 分工

| ID | 任務 | 負責 | 擁有的檔案／範圍 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| H0 | PRD 與交接板 | Claude | `office/docs/agent-hands/*` | — | 完成（D1–D11 已拍板） |
| H1 | VPS 基礎：swap、`neko-hands`、Chrome、VNC 改歸 neko-hands、`/srv/neko-handoff`；worker 群組與 worker socket 的資料夾（neighbor 與 neko-hands 同屬一個群組，資料夾 2750） | Claude（依 YUI 指示以 root 執行）；腳本 `office/hands/setup-h1.sh` | VPS 系統設定 | D1、D2、D8 | **完成**（2026-10-23，VPS 實機）。見 `reports/agent-hands/H1-VERIFICATION-2026-10-23.md` |
| H2 | 辦公室安全底座：loopback 修補、worker API、「手」執行者、先停一下與收回開關 | Claude | `office/office.py`、`office/tests/test_local_entry.py`、`office/tests/test_hands.py` | D1 | **完成**。loopback 修補已部署（0.4.0）；worker API／hands 執行者／收回開關在本機完成（0.5.0，未部署，等 H1 建好群組後一起開） |
| H3 | worker＋Codex 登入＋瀏覽器 MCP；合成任務 | Claude＋YUI（登入） | `office/hands/*`（新增） | H1、H2、D9、D13 | **進行中**：worker 寫好並測過（`1af9d21`）；VPS 上 Chrome、worker、Codex、瀏覽器工具已裝好並在跑（`setup-h3.sh`）；等 YUI 替貓咪的 Codex 登入，再跑第一件真任務 |
| H4 | GitHub App（營運者建立）、辦公室代為 clone／push／開 Draft PR、鑰匙收回、越權測試 | Claude＋YUI | `office/github_app.py`（新增）、`office/tests/test_github_push.py`、驗證紀錄 `reports/agent-hands/` | H2、H3、D4 | 未開始 |
| H5 | 體驗層：自動轉交、三種卡片、鑰匙清單、文案清理、禁用詞掃描 | Claude | `office/static/*`（先在下方留言，與手機版協調）、`office/tests/test_copy.py` | H3、D10 | 未開始 |
| — | **v1a 完成點** | — | — | H1–H5 | — |
| H6 | 看看貓咪（noVNC＋WebSocket 轉接）、接手時自動停手。接手中斷線**維持暫停**，按「交還」才繼續；接手狀態存在辦公室；同時只有一台裝置接手；交還後先看再做；接手時間不算進 30 分鐘，斷線超過 2 分鐘算一件「等你」；接手中由 worker 暫停整組 agent 程序、停止截圖；heartbeat 多回 `hold`（PRD 第 6 節、D12） | Claude＋YUI | `office/static/viewer*`、`office.py` 的 viewer 端點與 `hands_heartbeat` 的 `hold`、`office/hands/*` 的暫停與恢復（H3 完成後接手）、`office/tests/test_viewer.py`（新增） | H3、H5、D6、D12 | 未開始 |
| H7 | 貓咪資料夾：Mac LaunchAgent＋rsync | Claude | `office/handoff-sync/*`（新增） | H1、D5 | 未開始 |
| H8 | 通知 | Claude＋YUI | `office/notify*`（新增） | H5、D11 | 未開始 |
| H9 | REVOKE.md、撤銷演練 | Claude＋YUI | `office/docs/agent-hands/REVOKE.md` | H4–H8 | 未開始 |

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
