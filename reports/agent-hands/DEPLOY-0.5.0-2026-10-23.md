# 貓咪辦公室 0.5.0 部署紀錄（2026-10-23）

YUI 同意後，由 Claude 依 `office/docs/mobile/DEPLOY.md` 的 release 流程部署。沒有使用 `deploy.sh`，也沒有改 Caddy、DNS、UFW 或 SSH。唯一的設定變更是 neighbor 的 user unit 多了 `--worker-socket`。

## 變更

| 項目 | 內容 |
|---|---|
| 內容 | hands 執行者、worker API v1（含每一輪的 lease）、收回開關（`office.py hands-lock`）。見 PRD 9.1 |
| 新 release | `releases/public-20261023-11a383a`，內容是 `git archive 11a383a` 的 `office.py`、`static/`、`tests/`；37 個檔案的 SHA-256 一致；`office.py` 前 16 碼 `f7fca5d249f8c55e` |
| 程式來源 | 分支 `claude/agent-hands-prd` 的 `11a383a`，**尚未合併 main**。部署前 Claude 重新審過另一個 session 寫的 lease 修改（`6562486`） |
| 服務設定 | `~/.config/systemd/user/neighbor-office.service` 的 ExecStart 加上 `--worker-socket /srv/neko-office/worker.sock` |
| 服務 | `active`、NRestarts=0；日誌：`Neighbor Office 0.5.0 listening on loopback:8421 for https://office.nekonode.cloud; local entry …/run/office.sock; worker entry /srv/neko-office/worker.sock` |
| 資料表 | 新增欄位 `attempts`、`heartbeat`、`lease`；新增設定 `hands_locked=0`；既有資料不動 |
| 部署前狀態 | 25 件任務，沒有進行中或排隊中的任務 |

## 備份與回復

- 備份：`~/neighbor-office/backups/pre-11a383a-20261023T133923Z`
  - SQLite 用 online backup 取得，integrity ok（tasks 25、devices 8、journal 9）。
  - 另外複製了 inbox、journal、tasks；部署前的 unit 檔；`previous-current.txt`。
- 回復：
  1. `current` 指回 `releases/public-20261023-52108bd`。
  2. 把 unit 換回備份裡的版本，`systemctl --user daemon-reload`，再重啟。
  - 多出來的欄位不影響 0.4.0。

## 驗證

- **自動測試：**
  - Mac 上 104 項通過。
  - VPS 上同一個 release 104 項通過（Python 3.14.4）。
- **實機，從 Mac：** `verify_public.py --expect-version 0.5.0` 27 項全過。撤銷後，開著的 WSS 在 0.1 秒內以 4401 關閉。
- **實機，VPS 上：**
  - `worker.sock` 為 `srw-rw---- neighbor:neko`，群組由資料夾的 setgid 帶進來。
  - 本機 socket 仍為 `srw------- neighbor:neighbor`。
- **實機，跨使用者**（root 以 runuser 執行）：
  - **neko-hands 連 worker socket：**
    - `POST /api/worker/claim` 回 200 `{"task": null, "paused": false, "locked": false}`。
    - `GET /api/tasks`、`GET /api/journal`、`POST /api/command` 都回 404。
    - 拿不存在的任務送 heartbeat 回 404。
  - **`nobody` 連 worker socket：** PermissionError，連不上。
  - **neko-hands 試其他入口：** 連本機 socket 得到 PermissionError；冒充本機打 TCP 回 421。
- **測試裝置：** `verify_public.py` 用的短暫測試裝置已撤銷。

配對碼、cookie、token、VNC 密碼沒有出現在本文件或輸出中。

## NOT RUN

- 一件真的 hands 任務從頭到尾跑完。要等 H3 的 worker 寫好；目前只有 104 項離線測試涵蓋。
