# Office 主線整合核驗

日期：2026-10-29。依使用者指示先整合 main，Claude／Google 本人登入與三家完整實機任務留待稍後。

## 保留的來源

| 來源 | 保留功能 |
|---|---|
| `claude/agent-hands-prd` `a2da608` | 私有入口、worker／lease、瀏覽器 broker／接手／未知結果核對、Claude／Gemini 個別 adapter、一般／ZIP 上傳、runner、H4 離線契約 |
| `codex/vscode-agent-workbench` `fc96b91` | 已部署 VS Code／三家協作、rootless Docker、唯讀私有官網來源、測試證據與 patch、取消／重啟不盲目重跑 |
| `codex/vps-browser-session-foundation` `515f9ee` | 獨立持久 Chrome、profile 與生命週期限制 |
| `codex/vps-browser-viewer-takeover` `57fbdbf` | 私有 viewer、裝置認證與接手、真 Chrome／noVNC 測試及專用 CI |
| `codex/office-tracing-step1` `af3f40e` | 選配追蹤、元件替換測試 |
| `codex/office-portable-observability` `0421639` | 中性追蹤事件、Phoenix／Jaeger 實際雙後端驗證與 CI |
| `codex/office-portability-step1b` `8d86405` | TaskObserver／opaque handle／標準庫邊界測試 |
| `codex/neighbor-office-v1` `4080a3b` | 手機聊天、來源附件與原有 Office 歷史；較新的實作保留，不重新啟用已取代的獨立 Mac RemoteAgent 原型 |

精確 SHA 與祖先關係見 [branch-inventory.json](branch-inventory.json)。採用保留父分支歷史的 merge，讓 Git 知道上述成果已納入。原工作樹與分支保持原狀；整合後 `git log --all --not HEAD -- office` 沒有遺漏的 Office commit。

## 必要的相容修正

- 統一 Office 初始化參數，並保留各 provider、broker、一般 runner、workbench、viewer 與追蹤的開關。legacy sandbox 沒開時，不因啟用 workbench 而開放舊 runner 路由。
- 保留工作台的 workflow 與 browser_mode，三家協作不會被誤標為使用 Chrome 的 broker 工作。
- 同時保留個別 Claude／Gemini 與三家協作選項、對應名稱及隱私說明，以及修改檔／測試紀錄下載。
- 兩套已測試追蹤介面透過標準庫 adapter 相容，元件替換仍可使用 opaque handle；Codex 原始內容先轉為允許的 metadata 才交給通用 TracePort。
- viewer 的獨立測試 socket 不覆蓋新版共用 fixture 的 Office socket；Mac 測試暫存路徑先解析實際位置。隔離 E2E fixture 明確使用開發入口，正式預設仍拒絕 TCP 本機模式。
- 部署工具依候選版本檢查與回復，不重複加既有服務選項；保留 browser adapter 的安裝與備份。

## 驗證

- 整合後本機完整回歸：443 項，382 通過、61 項按環境明確略過，166.449 秒。
- 新增追蹤契約相容／敏感內容排除測試另行通過。
- Browser proxy 6 項、observation portability 8 項、workbench 12 項及回復測試通過。
- 保留所有來源功能的測試與兩份 Office／Browser CI；CI 會另驗選配 SDK、真 Chrome／noVNC、Phoenix／Jaeger、macOS 建置與既有回歸。
- `node --check`、Python 語法檢查、`git diff --check` 通過。
- 相對整合前 `origin/main`，`Sources/`、`Resources/`、Mac 建置與發布腳本及既有 build／release 工作流程沒有差異。
- GitHub 對應 head 的 CI／主線合併結果待更新。

## 執行與驗收範圍

這次是來源與主線整合。VPS 目前沿用先前已驗證的 `0.6.0-workbench.1`；沒有切換尚未實機啟用的 viewer、broker 或追蹤服務。先前 Codex／Docker／公網實機證據保留在 [工作台驗收](../workbench/VERIFICATION.md)。本人登入及三家同一件任務驗收依使用者要求延後，不能將合併或 mock 視為成功登入。

官網沒有推送、合併或發布；Mac 的版本／build／發行檔沒有改動。
