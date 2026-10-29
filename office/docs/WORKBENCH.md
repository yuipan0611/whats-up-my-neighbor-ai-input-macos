# VS Code 與三家 Agent 工作台

本版從 VPS 正在使用的 `f74a50a` 建立，沒有把其他未部署的 Office 分支混入。官方網站的發布流程保持 branch → PR → Preview → 負責人確認。

## 使用

遠端桌面開「貓咪三家工作台」，是一般使用者執行的微軟桌面版 VS Code。VS Code 登入與 Copilot 是選用；可以直接使用檔案與終端。首次出現 Welcome 可選 Continue without Signing In。

Office 交辦選「三家協作 · NekoNode 官網」。Claude 先整理方案，Codex 在 Docker 複本處理與測試，Google Antigravity 使用 Gemini 檢查證據。每次只有一件協作工作。三家沒有通過實機登入與限制驗證前，工作會保留並說明原因，不改用付費 API key。

每階段的內容、版本與狀態保存在原 SQLite。下載修改檔與測試紀錄，可在工作過程中找到。VS Code 的 `tasks/` 有各任務的獨立階段目錄；`results/` 保存 Markdown 與完整 patch。終端機 → 執行工作 → 開啟三家 Agent，可手動接手各自的工作目錄。手動終端不是 Office 的自動協作工作階段。

## 權限與執行

- `neighbor` 擁有 Office、唯讀 GitHub Deploy Key 與 rootless Docker。`neko-hands` 只透過有任務憑據的 worker socket 交辦，Agent 不取得這個憑據。
- Claude 停用所有工具與工作區設定；Codex 使用唯讀模式、停用主機 shell 與其他整合，只開六個 project MCP 工具。讀寫與既定測試由 Office 在 Docker 內執行。
- Gemini 使用官方 sandbox、plan 模式與 PreToolUse 全工具拒絕規則。必須先完成無害寫入探針，證明工具被拒絕、檔案未寫入，才由 root 保存對應 CLI 與拒絕程式雜湊的驗收檔。未通過就不啟用自動操作。規則依據：[Google 官方 Hooks 文件](https://antigravity.google/docs/hooks)。
- 訂閱登入保留在 `neko-hands` 的各工具目錄，不搬 Mac 登入檔。建置容器只有程式碼複本，沒有登入資料、掛載資料夾、Docker socket 或特權。
- 容器為 UID 10001，2 CPU、2GB、512 程序上限，測試最多 600 秒。只有一個固定檢查指令，不接受 Agent 自選指令。Node.js 22、Python、Git 在同一映像。
- Docker 與專案複本使用獨立預留 16GiB ext4。rootless 網路防火牆阻擋主機、私有網段與 metadata，只放行必要 DNS 與公網。每次開新測試前檢查隔離；防火牆也隨 Docker 服務啟動。
- GitHub Deploy Key ID `167984892` 僅有 `yuipan0611/nekonode-site` 讀取權。修改只保存 VPS 的 `neko/*` 任務分支與 patch，本版沒有推送、開 PR、合併或發布入口。

固定測試：

```sh
npm ci --no-audit --no-fund && npx --no-install tsc --noEmit && npm run check:content && npm run test:content && node scripts/run-with-ts.mjs --test scripts/browser-speech.test.mjs && npm run build
```

沒有修改也能成功完成檢查，不會製造空提交。測試失敗、證據超過自動檢查容量、登入或額度問題、工具結果不完整，都保留已有結果。已開始但結果未知的模型階段或測試不會自動重跑；使用者核對後可建立接續任務。取消會停止該次模型程序與容器。

## 維運與回復

`workbench/install_system.py`、`install_agents.py`、`setup_desktop.py` 是安裝來源；rootless 防火牆須先放在 `/opt/neko-workbench/rootless-firewall.sh`。官方下載逐一比對雜湊。登入使用 `/opt/neko-workbench/login.py claude|google`，只在本人 Terminal 顯示連結／授權碼。

`workbench/deploy.py --release <release>` 只在 Office 沒有待辦時切換。先備份 SQLite、既有服務與 worker，短暫鎖定領取，更新程式與服務，再確認健康狀態；失敗自動回復舊程式。備份只留 VPS，沒有登入資料。回復時將未完成的協作任務標記中斷，避免舊 worker 當作一般任務執行；保留備份之後新增的資料，不盲目用舊資料庫覆蓋。

手動回復：以 root 執行 `python3 <新版>/workbench/deploy.py --rollback <備份目錄>`。驗收紀錄見 [工作台驗收](../../reports/workbench/VERIFICATION.md)。

## 已知驗收範圍

Docker 實機測試、私人來源官網檢查、三階段模擬測試，與三家本人帳號實際參與同一件任務，是分開的驗收。前面通過不能代替最後一項。整台 VPS 斷電重開、人工語音輸入與使用者操作 VS Code 尚需另行確認；程式的語音測試不代表麥克風實測。
