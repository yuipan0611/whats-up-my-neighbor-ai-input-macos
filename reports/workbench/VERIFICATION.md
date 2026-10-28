# 遠端工作台驗收

日期：2026-10-29（台灣）。本文件區分環境、模擬串接與本人帳號實際協作。

## 已安裝

| 項目 | VPS 實機證據 |
|---|---|
| 微軟官方桌面 VS Code | 1.143.1；`neko-hands` 一般使用者啟動，已見正常 Welcome 畫面 |
| Claude Code | 官方 2.1.183，下載雜湊核對 |
| Google Antigravity CLI | 官方 1.4.9，SHA-512 核對；明確選 Gemini 模型 |
| Codex | 沿用原 VPS 官方 CLI 0.163.0 與個別登入目錄 |
| rootless Docker | 29.9.1；neighbor、systemd cgroup、rootless／seccomp／cgroupns |
| 測試映像 | Node.js 22、Python、Git；`sha256:285ed310b6507cade45fda23fcc421e2dbf5e0ad94e70dfce02dfc20dd91356e` |
| 有界資料區 | 預留 16GiB ext4，Docker 與專案複本共用；主機仍有約 62GiB 可用 |
| 私有來源 | `yuipan0611/nekonode-site`，專用唯讀 Deploy Key ID 167984892 |
| VS Code 工作區 | `/home/neko-hands/workbench/貓咪三家工作台.code-workspace`，三個具名終端工作與獨立目錄 |

「unable to write your data」的原因是管理員啟動時繼承了 `/run/user/0`；啟動器已依一般使用者 UID 指定自己的 runtime 與資料目錄。未用放寬整個家目錄權限的方式處理。

## 已通過

- 原部署基準：114 項離線測試通過。
- 新版本機完整測試：204 項，195 通過，9 項 Linux Docker 實機測試略過。最後 runtime 路徑修正另以 12 項協作契約測試通過。
- Linux 真實 Docker：9／9 通過，包含一次執行／保存 patch、非 root／資源限制／無掛載／無登入資料與 socket、逾時、取消、非零退出保存紀錄、指令參數不被當成 shell、斷線後建立結果核對、公網 registry 可達、主機／gateway／metadata 封鎖。
- 真實私有官網複本：固定 commit `0df2d65187275198146435ac418b199c36dc4ddc`、221 個輸入檔；型別、內容檢查與測試、語音測試、正式建置全通過，退出碼 0，69.919 秒，沒有修改。此項模型階段明確使用模擬，**不是三家協作驗收**。完整證據：[private-docker-acceptance.json](private-docker-acceptance.json)。
- Codex 單家真實驗收：已用既有訂閱登入、唯讀模式與 project MCP，實際啟動 Docker 執行完整官網檢查；退出碼 0，66.429 秒，沒有修改。原生 CLI、MCP、Office lease 與 Docker 的整條路徑已驗證。Claude 只是這次獨立測試的模擬前置階段，Google 未呼叫，**仍不能算三家驗收**。證據：[codex-real-acceptance.json](codex-real-acceptance.json)。
- 協作契約 12 項：階段順序、結果未知不重跑、已完成階段不重做、UUID 重送、取消與連線失效不重排、路徑／機密拒絕、三階段串接與完整 patch 核對、未分類錯誤停止並清理。
- Agent 串流與參數 6 項：官方輸出格式、ERROR 但退出碼為零仍拒絕、不完整回覆拒絕、API key 不繼承、Agent 不取得任務憑據、Codex 只開 project MCP。
- 回復測試：保留備份後新增資料、回復服務／worker／版本、將未完協作標記中斷，避免舊版誤執行。
- Google 工具拒絕程式測試：拒絕寫檔工具，稽核只記工具名，不記敏感參數。

## Office 切換與對外檢查

- 已部署並運作：`0.6.0-workbench.1`，`neighbor-office` 與 `neko-hands-worker` 服務均 active。
- VPS 完整測試：204 項，195 通過、9 項 Docker 實機另測；207.491 秒。最後補上的下載端點核對與 runtime 修正，以 12 項協作測試在 VPS 再驗通過（3.910 秒）。
- 公網、配對、撤銷、WebSocket、本機私有入口、Mac SSH 通道：27／27 通過，TLS 驗證保持開啟。
- 真實交辦入口的登入不足測試已通過：任務 `417d10ef-996a-44dd-9096-2fa4c76714b1` 保存為 incomplete，對話窗明確顯示 Claude 尚未登入；相同 UUID 重送維持同一件，沒有啟動官網容器或模型階段。Codex 的既有本人登入另已確認有效。
- 程式檔案與本機來源逐一核對：93 檔無差異，安裝的 worker／協作 helper 也一致。雜湊清單見 [source-manifest.json](source-manifest.json)。
- 新版本目錄：`/home/neighbor/neighbor-office/releases/workbench-20261029-v1`。
- 切換前備份：`/home/neighbor/neighbor-office/backups/workbench-20261028T165913Z`（UTC，即台灣 10 月 29 日 00:59），只留 VPS；包含資料庫、舊服務與 worker。保留原本的暫停／權限開關值。

## 尚待完成

- Claude 與 Google 的本人登入尚未確認成功。已開 Terminal 登入入口；授權碼只由本人貼回原 Terminal，不進聊天或報告。
- Google 官方工具拒絕規則的真實模型探針尚未執行；驗收檔未建立，自動協作會拒絕啟動。
- 三家實際參與同一件任務、從 Office 對話窗回報完整成果：未執行，不能宣稱完成。
- 全 VPS 斷電重開、使用者實際操作三個 VS Code 終端、麥克風語音輸入尚未驗收。已測的是程式重啟／回復契約、Docker 服務重啟後隔離與語音程式測試。

工作分支為 `codex/vscode-agent-workbench`，基於實際已部署 `f74a50a`。目前沒有推送或合併網站，也沒有更動 Caddy、DNS、Mac 正式 App 或其他分支。所有登入檔、Deploy Key 私鑰與 SQLite 備份只留 VPS。
