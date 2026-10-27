---
title: ADR-003：Claude 與 Gemini 接進辦公室（腦與手）
date: 2026-10-28
status: YUI 拍板 D15–D17；待實作；不是部署紀錄
baseline: claude/agent-hands-prd，02413fb
---

# ADR-003：Claude 與 Gemini 接進辦公室（腦與手）

## 1. 決定

YUI 於 2026-10-28 指示：辦公室的主力是 Claude、OpenAI、Gemini 三家，Gemma 本地模型不是重點。同日拍板三項：

| # | 問題 | 決定 | 沒選的 |
|---|---|---|---|
| D15 | 怎麼登入、怎麼付費 | **用現有訂閱登入官方 CLI**：Claude Code 用 Claude 訂閱，Gemini CLI 用 Google 帳號。跟 Codex 一樣，YUI 在 VPS 本人登入一次 | API 金鑰按量計費；混合 |
| D16 | 第一階段做到哪裡 | **腦和手都做** | 只做腦（唯讀文字與研究） |
| D17 | 先接哪一家 | **Claude 先**，Gemini 照同一套模式接 | Gemini 先；兩家一起 |

**改掉的舊決定：**
- PRD D9「手只用 Codex」：改成手可以用 Codex、Claude、Gemini。
- PRD 4.3「不接 Claude 或 Gemini 執行者」：刪除。

D1–D8、D10–D14 不變。特別是 D13（程式和 Chrome 同一個使用者）與 D14（不做網站白名單）照舊，所以新的手和 Codex 的手一樣，不能宣稱已全面隔離。

## 2. 現況（2026-10-28 實測）

| 廠商 | VPS 上 | 怎麼接 |
|---|---|---|
| OpenAI | 已接 | Codex CLI 0.163.0，用 ChatGPT 帳號登入。腦：`office.py` 的 `CodexAgent`，設定在 `~/neighbor-office/runtime/codex-home`，唯讀、可搜尋網路。手：`/opt/neko-hands/worker.py`，neko-hands 自己登入，`workspace-write`＋網路＋瀏覽器 MCP |
| Claude | 沒裝 | — |
| Gemini | 沒裝 | — |

- VPS 有 Node 22.22.1、系統 bwrap（`/usr/bin/bwrap`）。Ubuntu 26.04 開著 `apparmor_restrict_unprivileged_userns=1`。Codex 手的 `workspace-write` 沙箱目前能用。
- Mac 上查到的 CLI 能力：
  - **Claude Code 2.1.183：**
    - 無人值守：`-p`、`--output-format stream-json`、`--json-schema`。
    - 限制工具：`--tools`、`--allowedTools`、`--disallowedTools`，`--permission-mode dontAsk`。
    - 不讀別的設定：`--strict-mcp-config`、`--setting-sources`，`--no-session-persistence` 不留對話紀錄。
    - 隔離設定資料夾：`CLAUDE_CONFIG_DIR`。
    - 訂閱登入：`claude auth login --claudeai`，或 `claude setup-token`（長效 token）。
    - Linux 的 bubblewrap 沙箱：`sandbox.failIfUnavailable`、`allowUnsandboxedCommands`。
    - Linux 有單一原生執行檔：npm 套件 `@anthropic-ai/claude-code-linux-x64`。
  - **Gemini CLI 0.47.0：**
    - 無人值守：`-p`、`-o stream-json`。
    - 權限：`--approval-mode plan`（唯讀）、`--policy`（policy engine），`--allowed-mcp-server-names` 限制 MCP。
    - 隔離設定資料夾：`GEMINI_CLI_HOME`。
    - 沒有瀏覽器時的登入：`NO_BROWSER=true`。
    - 沙箱：程式內有 bwrap、gVisor、LXC 選項。
  - **以上是 Mac 上 `--help` 與執行檔字串的結果。** VPS 上的實際行為（沙箱能不能開、登入流程）待 P2／P3 實測。

## 3. 設計

### 3.1 共同原則

1. **只用官方 CLI，版本釘死。** 下載後比對雜湊，跟 `install_codex.py` 一樣；關掉自動更新（`DISABLE_AUTOUPDATER=1` 等）。不用 API 金鑰（D15）。
2. **每個執行者、每個使用者，各有一個設定資料夾**（權限 700），不讀使用者或專案設定，不留對話紀錄。成果只存在辦公室資料庫（跟 Codex 一樣）。
3. **成果格式一樣：** 都用現有的 `{kind, content, next_step}`，`kind` 只能是 `completed` 或 `needs_input`。辦公室驗證失敗就不標完成。
4. **上限一樣：** 15 分鐘（手 30 分鐘）、事件 4 MB、15 秒心跳、90 秒沒有新動作就提示可能卡住；取消時砍掉整個程序群組。
5. **沒登入、額度用完、CLI 壞掉，都走現有的 `needs_provider`：** 任務保留，介面說明要做什麼，不顯示原始錯誤。

### 3.2 腦（neighbor 使用者，`office.py`）

- 新增執行者 `claude`、`gemini`，介面跟 `CodexAgent` 一樣：`model`、`health()`、`run(task, check, progress, note)`。
- 讀串流、心跳、卡住提示、時間與容量上限、清理：從 `CodexAgent.run` 抽成共用的子程序執行器，三家共用，不複製三份。這是行為不變的重構，先靠現有 Codex 測試保護。
- **Claude 腦：**
  - 工具只留 `WebSearch`、`WebFetch`，其他一律拒絕。
  - 不載入任何 MCP，不讀設定，用 `--json-schema` 拿結構化成果。
  - 設定在 `runtime/claude-home`，工作目錄在 `runtime/agent-workspace`。
- **Gemini 腦：**
  - 唯讀（`--approval-mode plan`），policy 只放行 Google 搜尋與讀網頁，不載入擴充與 MCP。
  - 設定在 `runtime/gemini-home`。
  - CLI 沒有 schema 參數，所以在 prompt 要求 JSON，再由辦公室驗證。
- **附件（圖片、PDF 頁面）第一階段只給 Codex**，維持 `Store.submit` 現有的限制。Claude／Gemini 讀附件放到之後的版本。

### 3.3 手（neko-hands 使用者，`office/hands/worker.py`）

- hands 任務多一個欄位 `agent`，可以是 `codex`、`claude`、`gemini`，預設 `codex`，舊任務不變。worker 依 `agent` 組出對應的指令與事件解析。
- **沙箱至少要跟 Codex 的 `workspace-write` 一樣：** 只能寫工作區和交回資料夾，可以上網。
  - Claude：開 bubblewrap 沙箱，`failIfUnavailable: true`、`allowUnsandboxedCommands: false`。
  - Gemini：用 bwrap 沙箱。
  - **在 VPS 證明不了等價邊界的那一家，就不開它的手**，只開腦。
- **瀏覽器只接 broker 模式的受限 adapter**（`office/hands/browser_adapter.py`，ADR-002）。新的手不接 legacy 的原始瀏覽器 MCP，所以手的部分要等 G0–G4 上線。
- 一次只跑一件手的任務（PRD 第 7 節），不管是哪一家。

### 3.4 帳號與登入

| 帳號 | 放在哪裡 | 怎麼登入 | 撤銷 |
|---|---|---|---|
| Claude（腦） | `~neighbor/neighbor-office/runtime/claude-home`（700） | YUI 在 Claude 開好的 Terminal 分頁裡，用 SSH 跑 `claude auth login --claudeai`，在 Mac 瀏覽器同意後，把授權碼貼回 Terminal | `claude auth logout`，或到 claude.ai 撤銷 |
| Claude（手） | neko-hands 自己的設定資料夾（700） | 同上，另外登入一次 | 同上 |
| Gemini（腦／手） | 各自的 `GEMINI_CLI_HOME`（700） | `NO_BROWSER=true`，貼回授權碼 | 到 Google 帳號的第三方存取撤銷 |

- 授權碼、token 只由 YUI 本人輸入。Claude 不讀、不輸入、不寫進報告或聊天（交接板規則）。
- 登入前，先用確認問題講清楚：要開哪個分頁、貼什麼、多久會過期。

### 3.5 使用者看得到的

- 模型選單（「進階」，D10）多出 Claude、Gemini。預設仍是現有的自動判斷與 Codex，D10 不變。
- 沒登入時，交辦會變成「需要你登入」卡片，不會直接失敗。
- 新文案要過 PRD 3.8 的禁用詞掃描。
- Mac 原生 Preview 的模型選單在另一個 worktree（`worktrees/native-vps-desktop-preview`），屬於 P6，跟那邊的 session 協調。

## 4. 風險與尚未確認

- **額度共用：** 用訂閱登入，表示辦公室和 YUI 自己在 Mac 上用的 Claude Code／Gemini CLI 吃同一份額度。手的長任務可能先把額度用完。
- **條款：** 訂閱帳號給自己的伺服器無人值守使用，要在 P2 前查官方條款確認。Gemini 用個人 Google 帳號時，提示內容可能被拿去改善產品，要查清楚，必要時改用付費方案或關閉。查到的結果寫進 P2 的驗證紀錄。
- **沙箱：** Ubuntu 26.04 限制非特權 user namespace。Claude／Gemini 的 bwrap 能不能開，要在 VPS 實測，不能用 Mac 的結果代替。
- **D13 旁路照舊：** 同一個使用者底下，手仍可能直接連 CDP、讀 profile 與各家登入檔（見 G0 的能力盤點）。多一家 CLI，就多一份放在 neko-hands 底下的登入檔。
- **部署前提：**
  - G0–G4 還沒部署，新的手要等 broker 模式上線。
  - 只做腦的版本，可以從 HEAD 建 release，但會一起帶上 G0–G4 的程式。部署前要另外問 YUI。
- **Gemma：** 冷載入修正 `82f70d5` 在分支上，沒有部署（見 `reports/agent-hands/GEMMA-COLD-LOAD-2026-10-28.md`）。

## 5. 施工順序

| ID | 交付 | 依賴 | 驗收 |
|---|---|---|---|
| P0 | 本 ADR、PRD D15–D17、交接板 | — | 文件 commit |
| P1 | Claude 腦：共用子程序執行器＋`ClaudeAgent`＋`claude` 執行者＋網頁模型選單 | P0 | 假 CLI 的自動測試：成功、needs_input、格式錯、沒登入、卡住、逾時、取消、容量上限；現有 Codex 測試不變 |
| P2 | Claude 腦上 VPS：釘版安裝、YUI 登入、部署 | P1、YUI 同意部署 | VPS 測試全過；`verify_public.py`；一件真的 Claude 腦任務 completed；條款查證紀錄 |
| P3 | Claude 手：worker 的 `agent` 欄位＋Claude 指令＋沙箱＋受限 adapter；neko-hands 安裝與登入 | P2、G0–G4 部署 | 自動測試；VPS 實測沙箱寫不出工作區；一件真 Claude 手任務（合成網站） |
| P4 | Gemini 腦 | P1 | 同 P1／P2 |
| P5 | Gemini 手 | P3、P4 | 同 P3 |
| P6 | Mac 原生 Preview 模型選單 | P2 | 在 Mac App 裡交辦 Claude 任務成功 |

每段完成後，自動測試、模擬、實機（VPS／Mac／iPhone 分開）與 NOT RUN 分開記錄。合併 main、push、部署都要另外取得 YUI 同意。
