# 接續工作：本人登入與三家完整實機驗收

截至 2026-10-29，Office `0.6.0-workbench.1` 已部署，204 項離線／VPS 測試、9 項真實 Docker 測試、27 項公網與配對檢查通過。Codex 已經真實透過 project MCP 跑完私人官網的 Docker 檢查（66.429 秒、exit 0、沒有修改）。三家完整任務尚未完成，不能宣稱已完成。

本人目前看得到兩個 Mac Terminal 的登入連結／帳號選項。Claude 的官方登入狀態仍未成功，Google 尚未確認。登入由本人完成；授權碼只貼回原 Terminal，不能讀取、複製或輸出登入資料。既有本人授權包含安裝與部署 Office、執行這些驗收，不包含發布官網。

## 固定位置

- SSH 管理員：`ssh -i /Users/panh.c/.ssh/neighbor_vps_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes root@31.97.108.187`。一般 SSH 別名 `neighbor-vps` 是 neighbor，沒有 sudo。
- `current` → `/home/neighbor/neighbor-office/releases/workbench-20261029-v1`。
- 回復備份：`/home/neighbor/neighbor-office/backups/workbench-20261028T165913Z`，留在 VPS。
- 設定：`/home/neighbor/neighbor-office/workbench.json`，由 neighbor 保管；不要輸出私鑰內容。
- 官方工具：`/opt/neko-workbench/claude/claude`、`/opt/neko-workbench/google/agy`、`/opt/neko-hands/codex/codex-x86_64-unknown-linux-musl`。
- worker 模組：`/opt/neko-hands/`，root 所有；不要把程式碼所在的 neighbor 家目錄開放給 neko-hands。
- Desktop 使用者：neko-hands UID 1001。`HOME=/home/neko-hands`、`XDG_RUNTIME_DIR=/run/user/1001`、`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus`。不繼承 root 的 runtime。
- rootless Docker：neighbor UID 1000，`DOCKER_HOST=unix:///run/user/1000/docker.sock`。資料區 `/home/neighbor/neighbor-office/sandbox-storage`。

## 下一步

1. 本人完成登入後，確認 Claude 的官方 `auth status` 與 Google 的官方 `/usage`；只判斷狀態，不輸出帳號或憑證。不要假定登入連結開了就代表成功。Claude 另須沿用 `Team.phase` 的工具停用參數，完成一份真實官網檢查方案；Google 以下一步探針作單家模型驗證。`/usage` 不是模型任務，不能代替真實驗收。
2. 以 neko-hands 執行 `/usr/bin/python3 -I /opt/neko-hands/verify_google_policy.py`（帶上述 HOME／runtime／DBus）。這是使用 Gemini 真實模型、官方 PreToolUse 全工具拒絕規則的無害寫入探針。只有 `verified=true`、檔案未寫入、確實出現拒絕紀錄且沒有 ERROR 才能通過。若沒有工具嘗試或模型／額度／登入錯誤，就停止並保留證據，不偽造成功。
3. 由 root 核對探針結果、CLI／gate 雜湊後，將驗收結果保存為 root 所有、不可由群組或其他帳號寫入的 `/opt/neko-workbench/google-review-verified.json`。生產版 `review_policy.verified()` 會再比對目前檔案雜湊。未通過就不要建立驗收檔。
4. 三家的單獨真實任務都確認後，以 neighbor 執行 `python3 -I /home/neighbor/neighbor-office/current/workbench/verify_collaboration.py --start`。它從原 Office 對話 API 交辦，將 UUID 先保存於 `data/workbench-acceptance/collaboration-request.json`，重送仍是同一件，不會無限建立新工作。
5. 之後不加 `--start` 只讀取進度。完整報告在 `data/workbench-acceptance/collaboration-live.json`。必須看到同一任務的 Claude、Codex、Gemini 三段真實輸出、測試證據與 completed，才更新驗收為完成。未知結果不自動重跑，不反覆修正；需要人工決定就保留工作。
6. 更新 VERIFICATION.md 與來源雜湊，保存本機提交；官網依舊需要 PR、Preview 與負責人確認，本工作台沒有推送或發布入口。

若要重新開登入入口，root 執行 `python3 /opt/neko-workbench/login.py claude|google`，透過本人可見的互動 SSH Terminal，不要在工具輸出中捕捉授權連結或授權碼。

## 已有證據

- 登入不足的真實對話任務：`417d10ef-996a-44dd-9096-2fa4c76714b1`，incomplete，明確提示 Claude 尚未登入，沒有模型階段／官網容器。
- Codex 單家驗證：`/home/neko-hands/workbench/probes/e8b7efb0-1d76-41aa-ac58-d882101c16a8/result.json`；本機副本 `codex-real-acceptance.json`。控制資料庫是隔離的 `sandbox-storage/acceptance/codex-*/data/`，不影響原生活紀錄。Claude 前置階段為明確模擬、Google 未呼叫，不能誤算三家成功。
- 重驗工具 `verify_codex.py` 須由 root 從 `/opt/neko-workbench/verify_codex.py` 執行；它分別降為 neighbor、neko-hands，以相同權限邊界測試。沒有讀取或搬移登入檔。
- 全 VPS 斷電重啟、本人實際操作三個 VS Code 終端與麥克風仍未驗收。語音程式測試不能當作麥克風實測。
