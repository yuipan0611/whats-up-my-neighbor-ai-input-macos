---
title: 貓咪的手：VPS 工作區與權限（v1）
date: 2026-10-23
status: 草案；D1–D9 待 YUI 拍板，拍板前不改程式、不動 VPS
branch: claude/agent-hands-prd（基於 main 5705004）
related:
  - office/README.md（貓咪辦公室現況）
  - office/docs/mobile/PRD.md（手機直連與 API 契約 v1）
  - worktrees/neighbor-remote-agent/docs/remote-desktop/PRD.md（VNC 接手控制，2026-10-21 真 VPS 驗證）
---

# PRD：貓咪的手（VPS 工作區與權限）v1

## 0. 一句話

**眼睛和耳朵留在你的 Mac 帳號，做事的手放在 VPS 的受限工作區，第二個 Mac 帳號以後再說。**

v1 要做到：VPS 上的貓可以用**自己的 Chrome**（只登入你挑選的帳號）操作網頁，在 GitHub 開 PR，並在交接資料夾裡讀寫檔案。你隨時可以從 Mac 看它在做什麼，所有不可逆的動作都由你本人完成。

## 1. 為什麼要做

### 1.1 Mac 記憶體：已實測（2026-10-23 中午）

| 指標 | 數值 | 白話 |
|---|---|---|
| 實體記憶體 | 8 GB（M1） | — |
| swap 使用 | **7.07 GB／8 GB** | 已經在大量借用硬碟當記憶體，所以會覺得卡 |
| 累計 pageouts | 2,302,168 | 長期一直在把記憶體搬到硬碟 |
| node 程序 | **70 個** | 同一個 MCP 伺服器被每個 AI session 各開一份：`node_repl` 12、`server.mjs` 10、`searchconsole-mcp` 6、`xcodebuildmcp` 5… |
| 前幾名 | Claude（13 個程序）、Codex（17 個）、Chrome（28 個） | 單一程序都不大，是「數量」堆起來 |

結論：你的感覺是對的，但兇手不是哪個功能太重，而是**閒置的 AI session 沒關，每個都帶著一整套 MCP 伺服器常駐**。所以把長任務搬上 VPS 是對的方向，但 Mac 本身也要做清理（第 8 節）。

### 1.2 VPS：已實測（2026-10-23，唯讀）

- Hostinger，x86_64，**2 vCPU、7.9 GB RAM、沒有 swap**，硬碟可用 87 GB。
- 只有一個一般使用者 `neighbor`（不在 sudo 群組）。正在執行：`neighbor-office.service`（貓咪辦公室）和 Caddy（https://office.nekonode.cloud）。
- 已安裝 TigerVNC 與 XFCE（10-21 驗證過「接手控制」）。**Chrome／Chromium、`gh`、node 都還沒有裝。**
- 辦公室目前的 Codex 是**唯讀**：不能執行 shell、不能操作電腦、不能改外部系統（office/README.md「執行者」一節）。

### 1.3 現在缺什麼

辦公室已經能「想」和「寫」，但還沒有「手」：它不能用瀏覽器登入網站、不能 push 程式、也不能把檔案交回給你。這份 PRD 補上這一塊，並且先把權限設計好再動手。

## 2. 三分工架構

```
┌──────────── 你的 Mac（你的帳號） ────────────┐
│ 眼睛耳朵：口述輸入、會議字幕、你允許的畫面     │
│ 介面：貓咪面板、「交給貓」、VNC 檢視器         │
│ ~/Neko交接/給貓/   ~/Neko交接/貓交回/          │
└──────────────┬───────────────────────────────┘
               │ 只有 Mac 主動連 VPS（SSH 別名 neighbor-vps）
               │ VPS 上沒有任何能連回 Mac 的鑰匙
┌──────────────▼──────── VPS ───────────────────┐
│ 大腦（使用者 neighbor）                        │
│   貓咪辦公室：佇列、任務、生活紀錄、手機配對    │
│ 手（新使用者 neko-hands，沒有 sudo）           │
│   worker：從辦公室領任務 → Codex＋瀏覽器工具   │
│   自己的 Chrome profile（只登入名單上的帳號）  │
│   workspace/、交接資料夾、GitHub token         │
│ 窗戶：VNC 桌面 :1 = neko-hands 的桌面          │
│   你從 Mac「只看」或「接手」                   │
└──────────────┬───────────────────────────────┘
               │ 只能透過「限縮過的憑證」碰雲端
        GitHub（指定 repo）、貓咪專用 Google 帳號…
```

**第二個 Mac 帳號（Second Self 模式）不在 v1。** 啟用條件見第 11 節。

### 2.1 跟 Second Self 的差別

| | Second Self | 貓咪的手 v1 |
|---|---|---|
| 在哪裡做事 | 同一台 Mac 的第二個使用者 | VPS 的第二個 Linux 使用者 |
| 佔用你的 Mac 記憶體 | 會（第二個桌面＋Chrome） | 不會 |
| Mac 闔上蓋子後 | 停止 | 繼續做 |
| 登入狀態 | 複製你 Chrome 的 cookie | **不複製**；你在 VPS Chrome 親手登入名單上的帳號（第 5.5 節） |
| 看它在做什麼 | VNC／畫面串流 | VNC（已驗證）＋任務截圖時間軸 |
| 能操作 Mac 專用軟體 | 能 | 不能（這是第二個 Mac 帳號的用途） |

## 3. 範圍

### 3.1 v1 要做

1. VPS 新增 Linux 使用者 `neko-hands`，讓「手」跟「大腦」分開。
2. 辦公室新增執行者 `hands`：由 neko-hands 的 worker 領取任務，用 Codex 加上瀏覽器工具執行，可以使用 shell 和網路，範圍限於自己的工作區。
3. neko-hands 的 Chrome 在 VNC 桌面上執行（不是 headless），所以你看得到。
4. 帳號與憑證按照第 5 節的名單與等級發放。
5. 交接資料夾：Mac → VPS 是單向推送，VPS → Mac 由 Mac 主動拉回。
6. 看見它：Mac 的「只看／接手」兩種模式，加上手機可以看任務步驟截圖。
7. 停止與收回：一鍵暫停、一鍵收回權限，以及撤銷演練。
8. 前置修補：辦公室對 loopback 也要驗證身分（第 5.7 節）。

### 3.2 v1 不做

- 不複製 Mac Chrome 的 cookie、密碼或鑰匙圈。
- 不讓 VPS 連回 Mac，不掛載 Mac 的家目錄、桌面或整個 Obsidian vault。
- 不做 L3 核准卡。v1 的不可逆動作一律由你本人執行（第 5.3 節）。
- 不把 VNC 開到公網，手機即時畫面延後到 v2。
- 不做第二個 Mac 帳號、Mac 上的 VM 或 Docker Desktop。
- 不同時執行 Gemma 和瀏覽器任務。
- 不接 Claude／Gemini 執行者（之後沿用同一套權限即可接上）。

## 4. 你會怎麼用（三個例子）

**例 1：在外面用手機叫它開 PR**
手機輸入「把 nekonode-site 的 Roadmap 補上 10 月進度，開 PR」→ 辦公室排進佇列 → neko-hands 在 `workspace/` clone，切出 `neko/roadmap-oct` 分支並修改 → push → 開 **Draft PR** → 回報 PR 連結和截圖 → 你在手機看 PR，**由你自己合併**。

**例 2：去已登入的網站下載資料**
「到 X 網站下載上月報表，放到貓交回」→ neko-hands 的 Chrome（你先前親手登入過 X）→ 下載 → `貓交回/` → Mac 醒著時自動拉回 `~/Neko交接/貓交回/`。

**例 3：登入過期**
它不會自己輸入密碼。任務停在「需要你登入 X」→ 你在 Mac 按「接手控制」，在 VPS 的 Chrome 登入 → 回到辦公室按「繼續」。

## 5. 權限設計（本版核心）

### 5.1 五條原則

1. **權限鎖在憑證上，不靠 prompt。** 它會讀網頁，網頁內容可能誘導它（prompt injection，就是網頁裡藏指令騙 AI 照做）。「它不會這樣做」不算保護，「它做不到」才算。
2. **給它自己的帳號，再分享它需要的東西。** 像請助理：不給你的主帳號，給它自己的帳號，加上一個共用資料夾。
3. **單向信任：只有 Mac 連 VPS。** 最壞情況是 VPS 被入侵，損失上限是 VPS 上那幾個限縮帳號，你的 Mac 本機不受影響。
4. **可逆的自動做，不可逆的你來做，錢和帳號安全永遠不碰。**
5. **每個動作都留痕跡：** 任務事件、瀏覽器步驟截圖，以及每次使用憑證的紀錄。

### 5.2 身分隔離（Linux 使用者）

| 使用者 | 擁有什麼 | 不能做什麼 |
|---|---|---|
| `neighbor`（既有） | 辦公室服務、`office.sqlite3`（含生活紀錄）、手機配對、辦公室用的 Codex 登入、Mac 的 SSH 入口 | — |
| `neko-hands`（新增，沒有 sudo） | worker、自己的 `CODEX_HOME`（你登入一次）、Chrome profile、`workspace/`、GitHub token、VNC 桌面 | 讀不到 neighbor 的家目錄（700）、生活紀錄、配對 cookie 和 SSH 金鑰；不能用 sudo |

任務交接方式：neko-hands 的 worker 只能透過辦公室的 **worker 專用 API**（第 9 節）取得「這一件任務＋明確選取的附件」，然後寫回結果和步驟。worker 憑證**只能**呼叫這幾個端點，讀不到生活紀錄列表，也不能交辦新任務。

### 5.3 動作分級

| 等級 | 動作 | 例子 | v1 怎麼處理 | 由什麼強制 |
|---|---|---|---|---|
| **L0 讀** | 讀取 | 公開網頁、`給貓/`、自己的 workspace | 自動 | — |
| **L1 自己範圍內寫** | 寫在自己的地盤 | workspace、`貓交回/`、本機草稿 | 自動，留下紀錄 | 檔案權限 |
| **L2 對外但可復原** | 改了還能退回 | push 到 `neko/*` 分支、開 Draft PR、在共用 Drive 資料夾新增檔案 | 自動，完成後通知你 | token 範圍＋main 分支保護 |
| **L3 對外不可逆／代表你發言** | 做了就收不回 | 合併 PR、刪除雲端資料、寄信或發訊息、發文、接受條款、改帳號設定 | **v1 一律由你本人做**：它只產生「待你處理」卡片，寫明步驟和連結 | 憑證本身沒有這些權限 |
| **L4 永遠不碰** | 金錢與帳號安全 | 銀行、券商、prop firm、交易所、加密錢包、密碼管理器、Apple ID、主 Google 帳號、2FA、改密碼 | 根本不放上 VPS | 憑證不存在 |

> 交易相關帳號（券商、prop firm、TradingView 下單）一律列 L4。就算之後要讓 AI 協助交易，也應該走既有的 webhook → 風控引擎路線，不給瀏覽器 agent 登入狀態。

### 5.4 帳號與憑證清單

| 帳號 | v1 給法 | 範圍 | 存放 | 到期 | 撤銷 |
|---|---|---|---|---|---|
| **GitHub** | Fine-grained personal access token | Resource owner `yuipan0611`，**Only select repositories**（D4）；Contents 讀寫、Pull requests 讀寫、Metadata 唯讀。**不給** Administration、Workflows、Secrets | `~neko-hands/.config/neko/github-token`（600），由 git credential helper 使用 | 30 天 | GitHub → Settings → Developer settings → Fine-grained tokens → Revoke |
| **GitHub 分支保護** | 每個放進範圍的 repo 的 `main` | 必須經過 PR、禁止 force push、禁止刪除 | GitHub repo 設定 | — | — |
| **VPS Chrome** | 你透過 VNC 接手，**親手登入** | 只登入 D3 名單上的網站 | `~neko-hands/chrome-profile/`（700） | 跟各網站 session 一樣 | 各網站「登出所有裝置」，加上刪除 profile |
| **Google** | **新開一個貓咪專用 Google 帳號** | 你把指定的 Drive 資料夾分享給它（編輯者） | 只存在 VPS Chrome | — | 取消分享，或停用該帳號 |
| **Codex（手用）** | neko-hands 自己的 `CODEX_HOME`，你用裝置碼登入 | 你的 ChatGPT 方案額度 | `~neko-hands/.codex/` | 依 OpenAI | `codex logout`，或到 ChatGPT 裝置管理撤銷 |
| 其他（Notion、各種 SaaS） | v1 不給 | 之後逐個加進 D3 名單，並標上等級 | — | — | — |

**為什麼不給 Workflows 權限：** 能改 `.github/workflows/` 就能在 GitHub Actions 裡執行任意程式，讀取 repo 的 secrets。少了這個權限，它只能改程式碼，不能改 CI。

**⚠️ 合併就上線的 repo：** nekonode-site 的 `main` 一合併就部署正式站。假如 token 有 Contents 寫入權限、`main` 卻沒有設保護，它就可以直接 push 到 `main`，**等於可以直接改正式網站**。私人 repo 在 GitHub 免費方案可能不能設分支保護（U1）。確認能設保護之前，**這類 repo 不放進 token 範圍**。

### 5.5 為什麼不複製 Mac Chrome 的 cookie

你的需求是「讓它在很多網站都是登入狀態」，這點可以做到，但不要用複製 cookie 的方式：

1. **只能全給，不能挑。** 主 profile 的 cookie 包含所有已登入的網站：Gmail、銀行、Claude、ChatGPT、券商後台。複製時沒辦法只給其中一部分。
2. **全部交給一個會讀網頁的 agent。** 它一旦被網頁誘導，損失就是全部。換到 VPS 或 VM 也解決不了，因為問題出在**授權範圍**，不在機器。
3. **技術上也不穩。** Mac Chrome 的 cookie 用鑰匙圈裡的金鑰加密，搬到 Linux 之前得先把那把金鑰拿出來。從雅加達的新 IP 使用時，網站也可能要求重新驗證，或發出異常登入通知。
4. **替代做法效果一樣：** 你在 VPS 的 Chrome 親手登入一次，cookie 就留在 neko-hands 的 profile，之後一直有效。同樣是「已登入」，但只登入你挑的那幾個網站。

### 5.6 交接資料夾

| 位置 | 誰能寫 | 方向 |
|---|---|---|
| Mac `~/Neko交接/給貓/` → VPS `/srv/neko-handoff/給貓/` | 只有 Mac（經 `neighbor`） | Mac 推過去；neko-hands **唯讀** |
| VPS `/srv/neko-handoff/貓交回/` → Mac `~/Neko交接/貓交回/` | 只有 neko-hands | Mac 拉回來；**不刪除 Mac 上的檔案**，同名檔先備份再覆蓋 |
| VPS `~neko-hands/workspace/` | neko-hands | 自由區：git clone、下載、暫存 |

- 同步方式（v1）：Mac 透過既有的 `neighbor-vps` 執行 rsync，可以手動按，Mac 醒著時也會每 5 分鐘自動跑一次（launchd）。之後若需要即時雙向同步，再評估 Syncthing 的「只送／只收」資料夾。
- `/srv/neko-handoff/` 用群組權限控管：`給貓/` 只有 neighbor 能寫，`貓交回/` 只有 neko-hands 能寫，兩邊都能讀。
- 它需要 Obsidian 筆記時，你把**複本**放進 `給貓/`，不直接開放整個 vault。
- 既有的手機附件上傳（辦公室 inbox）照舊。

### 5.7 前置修補：辦公室信任 loopback 的問題

**現況（已讀程式碼確認）：** `office.py` 的 `boundary()` 只要看到 Host 是 `127.0.0.1:8421` 而且沒有轉送標頭，就判定為 local 模式。`authenticate()` 在 local 模式什麼都不檢查，`/api/bootstrap` 會直接回傳 token（約第 1153、1180、1237 行）。

**現在為什麼沒事：** VPS 上只有 `neighbor` 一個使用者，能碰到 loopback 的只有你的 SSH 通道。

**加入 neko-hands 之後：** 一個會讀網頁的 agent 和辦公室共用同一個 loopback。它只要對 `127.0.0.1:8421` 發一個請求，就能拿到 token，讀取所有任務和生活紀錄，還能交辦新任務。

**修法（H2 擇一，推薦 A）：**
- A. 辦公室的本機入口改成只有 neighbor 能開的 Unix socket（`~neighbor/neighbor-office/run/office.sock`，權限 600），Mac 的 SSH 通道改轉送到這個 socket（OpenSSH 支援把 TCP 轉送到 Unix socket）。Caddy 的公網入口另外處理。
- B. local 模式也要求一個只有 neighbor 讀得到的本機憑證檔。

**這一項沒完成之前，不建立 neko-hands。**

### 5.8 網路

- v1 不限制 neko-hands 的出站連線，因為它需要上網。
- 它碰得到的本機服務：辦公室（修補後只能用 worker 憑證）、Ollama `127.0.0.1:11434`（無害）。
- Chrome 的除錯埠只綁 `127.0.0.1`。理論上 neighbor 也連得到，但 neighbor 本來就是權限更高的一方，可以接受。
- v2 再考慮用 iptables owner match 擋掉 neko-hands 的 SMTP 等出站連線。

### 5.9 停止與收回

| 動作 | 怎麼做 | 效果 |
|---|---|---|
| 暫停 | 手機或 Mac 辦公室的「暫停」（已存在） | 取消正在執行的任務，保留佇列 |
| 收回權限 | VPS 上執行 `neko-hands-lockdown`（以 neighbor 身分透過 systemd 觸發） | 停止 worker 和 Chrome，token 檔改名後移走，關閉 VNC 桌面 |
| 外部撤銷清單 | 寫在 `docs/agent-hands/REVOKE.md`（H7 產出） | GitHub token 撤銷、Google「登出所有裝置」、Codex 登出 |

v1 驗收時要**實際演練一次**完整撤銷，然後再恢復。

## 6. 看見它在做什麼

| 模式 | 從哪裡 | v1 | 怎麼做 |
|---|---|---|---|
| **只看** | Mac | ✅ | TigerVNC 的**唯讀密碼**：`vncpasswd` 可以另外設一組 view-only 密碼，用它連進去只能看，滑鼠和鍵盤都沒有作用 |
| **接手** | Mac | ✅（已存在） | 既有「接手控制」：15901 → 5901，使用完整密碼（8 個字元以內） |
| **步驟截圖** | 手機／Mac | ✅ | 每個瀏覽器步驟存一張截圖到任務，辦公室的「工作過程」直接顯示 |
| **即時畫面** | 手機 | ❌ v2 | noVNC 經由 Caddy＋配對 cookie；把 VNC 開到公網的風險要另外評估 |

- 你接手時，它會被擠開：v1 的規則是**先按暫停，再接手**，避免兩邊搶滑鼠。
- VNC 桌面改歸 neko-hands（D2）。辦公室本身不需要桌面，原本 VPS 桌面上的「貓咪辦公室」捷徑改成在 neko-hands 桌面上開網頁版。

## 7. 執行者 `hands`

- 執行者：neko-hands 自己登入的 Codex CLI，開啟 shell 和網路，工作目錄限定在 `workspace/<任務 UUID>/`。OS 使用者本身就是沙箱邊界。
- 瀏覽器工具：Chrome DevTools MCP 或 Playwright MCP，連到 VNC 桌面上已經開著的 neko-hands Chrome（U3 要實測哪一個在這台 VPS 上可行）。
- 一次只跑一件 `hands` 任務。Gemma 和 `hands` 互斥，其中一個執行時，另一個在佇列等。
- 上限：每件任務 30 分鐘（可調）、事件 4 MB。超過就停止，保留部分成果。
- 原本的 `codex`（唯讀）和 `gemma` 執行者不變。

## 8. 記憶體與資源預算

### 8.1 Mac（今天就能做，不用等 v1）

1. **封存閒置的 Claude Code 和 Codex session。** 每個 session 都帶著自己那套 MCP 伺服器，關掉 session，它的 node 程序才會結束。
2. 停用沒在用的 MCP，例如 `searchconsole-mcp`、`xcodebuildmcp` 不做 iOS 時可以關。
3. Mac 上不跑 Docker Desktop（它會預留一整塊 Linux VM 記憶體）、本機大模型或第二個 macOS 帳號。
4. 長時間任務一律交給 VPS。Mac 闔上蓋子後，VPS 繼續做；本機的感知功能跟著暫停。

### 8.2 VPS（8 GB、沒有 swap）

| 項目 | 估計 | 備註 |
|---|---|---|
| 系統＋辦公室＋Caddy | 約 1.8 GB | 實測目前已用 1,795 MB |
| XFCE＋TigerVNC | 0.3–0.5 GB | 估計，H1 實測 |
| Chrome（少量分頁） | 1–2 GB | 估計，H3 實測 |
| Codex CLI | 0.2–0.4 GB | 估計 |
| Gemma 3 4B（開啟時） | 約 3–4 GB | **不與瀏覽器任務同時執行** |

- 建議加 **4 GB swapfile**（D8，需要 root，由你執行）。沒有 swap 時，記憶體一用完，Linux 就會直接砍掉程序，可能砍到辦公室服務。

## 9. 介面契約（概要，H2 定稿）

| 端點 | 用途 | 憑證 |
|---|---|---|
| `POST /api/worker/claim` | 領取下一件 `hands` 任務：交辦文字＋選取的附件路徑 | worker 憑證 |
| `POST /api/worker/events` | 回寫步驟（含截圖檔名） | worker 憑證 |
| `POST /api/worker/complete` | 回寫結果或部分成果、需要你處理的 L3 卡片 | worker 憑證 |
| `POST /api/worker/heartbeat` | 存活訊號；超過 2 分鐘沒有訊號，任務標成中斷 | worker 憑證 |

- worker 憑證：只能呼叫上面 4 個端點，與頁面 token、裝置 cookie 互不相通。
- 任務新增欄位：`executor='hands'`、`needs_human`（L3 卡片內容）、`screenshots[]`。資料表遷移只能加欄位，不能動既有資料。

## 10. 決策（待 YUI 拍板）

| # | 問題 | 推薦 | 其他選項 |
|---|---|---|---|
| D1 | 手用哪個身分 | **新使用者 `neko-hands`** | 沿用 `neighbor`：較簡單，但手能讀到生活紀錄 |
| D2 | VNC 桌面歸誰 | **neko-hands**（你看到的就是它的桌面） | 兩個桌面：多吃 0.3–0.5 GB |
| D3 | VPS Chrome 第一批登入哪些網站 | **GitHub 網頁＋貓咪專用 Google 帳號** | 你指定；每加一個都標上 L 等級 |
| D4 | GitHub token 範圍 | **先放 macOS repo＋一個測試 repo**；nekonode-site 等確認能設保護再放 | 你指定 |
| D5 | 交接資料夾 | **`~/Neko交接/` 加 rsync 單向同步** | Syncthing 雙向即時：維護成本較高 |
| D6 | 手機怎麼看 | **v1 先用步驟截圖** | 即時 noVNC：要把畫面開上公網 |
| D7 | L3 動作 | **v1 一律由你本人做** | v1 就做手機核准卡：工作量約多一倍 |
| D8 | VPS swap | **加 4 GB**（你用 root 執行，指令由我提供） | 不加：記憶體不夠時程序會被直接砍掉 |
| D9 | 執行者 | **v1 只用 Codex** | 同時接 Claude Code（要另外登入、另外付費） |

## 11. 什麼時候才需要第二個 Mac 帳號

以下**三項同時成立**才做：

1. 要操作的軟體**只有 Mac 版**，而且沒有 API 或網頁版可用。
2. 這件事需要在你使用 Mac 的同時進行，不能等你離開。
3. Mac 的記憶體負擔得起（目前 8 GB、swap 已用滿，**現階段不符合**）。

到時候沿用本 PRD 的權限設計：標準使用者、只開放交接資料夾、只登入名單上的帳號。

## 12. 實作順序（詳見 HANDOFF.md）

| 階段 | 內容 | 誰 |
|---|---|---|
| H0 | 本 PRD＋交接板；D1–D9 拍板 | Claude＋YUI |
| H1 | VPS 基礎：swap、建 neko-hands、安裝 Chrome、VNC 改歸 neko-hands、`/srv/neko-handoff` 權限 | YUI 用 root 執行，Claude 提供逐行指令並驗證 |
| H2 | 辦公室：loopback 修補（5.7）、worker API、`hands` 執行者、測試 | Claude |
| H3 | neko-hands worker、Codex 登入（你本人）、瀏覽器 MCP 接上 Chrome；跑合成任務 | Claude＋YUI |
| H4 | GitHub token＋測試 repo 端到端：clone → 分支 → Draft PR；**驗證** token 不能合併、刪除或改 workflow | Claude＋YUI |
| H5 | 交接資料夾：Mac launchd＋rsync；驗證 VPS 連不回 Mac | Claude |
| H6 | 只看模式、步驟截圖、手機驗收 | Claude＋YUI |
| H7 | 收回權限腳本、REVOKE.md、完整撤銷演練 | Claude＋YUI |

## 13. 驗收清單

- [ ] 以 neko-hands 身分讀不到 `~neighbor/`、`office.sqlite3` 和生活紀錄（實際執行 `cat` 必須失敗）。
- [ ] 從 VPS 本機對 `127.0.0.1:8421` 發未帶憑證的請求，拿不到 token。
- [ ] worker 憑證呼叫 `/api/sync`、`/api/tasks`（交辦）、`/api/devices` 一律被拒絕。
- [ ] 用 GitHub token 嘗試 push 到 `main`、合併 PR、刪除分支保護、修改 `.github/workflows/`，**全部失敗**。
- [ ] 用 GitHub token push 到 `neko/*`、開 Draft PR 成功。
- [ ] 從 VPS 嘗試 SSH 或連線回 Mac 失敗（找不到任何金鑰或位址）。
- [ ] `給貓/` 對 neko-hands 唯讀；`貓交回/` 拉回 Mac 時不刪除 Mac 上的既有檔案。
- [ ] 用唯讀密碼連 VNC 時，滑鼠和鍵盤沒有作用；用完整密碼可以接手。
- [ ] 手機看得到瀏覽器步驟截圖。
- [ ] 同時交辦 Gemma 和 `hands` 時，只有一個在執行。
- [ ] 撤銷演練：暫停 → 收回 → 外部撤銷 → 確認失效 → 恢復。
- [ ] 辦公室原有 69 項測試全部通過，既有任務和生活紀錄完整保留。

## 14. 未確認事項

| # | 問題 | 怎麼確認 |
|---|---|---|
| U1 | 你的 GitHub 方案能不能替私人 repo 設分支保護（nekonode-site） | 到 repo Settings → Branches 試設 |
| U2 | Codex CLI 0.163.0 的 workspace-write 模式能不能開網路，或要用哪個參數 | H3 在 VPS 實測 |
| U3 | Chrome DevTools MCP 和 Playwright MCP，哪個能在這台 VPS 上被 Codex 使用，並連上已開著的 Chrome | H3 實測 |
| U4 | Chrome 在 2 vCPU、8 GB 上的實際記憶體用量和速度 | H3 量測 |
| U5 | 從雅加達 IP 登入貓咪專用 Google 帳號會不會要求手機驗證 | H3 你登入時就知道 |
| U6 | macOS 螢幕共享用 TigerVNC 唯讀密碼連線時，是否真的完全無法操作 | H6 實測 |

## 15. 回復方式

- 全部是**新增**，沒有改動既有路徑：`hands` 執行者和 worker API 都可以獨立關閉，原有的 `codex`／`gemma` 照常運作。
- 要回到今天的狀態：停用 neko-hands 的服務、鎖定該使用者（不刪除，保留紀錄以便追查）、撤銷所有 token、Mac 停用 launchd 同步。
- 辦公室資料表遷移前先備份 SQLite（沿用 DEPLOY.md 的 release 流程）。
