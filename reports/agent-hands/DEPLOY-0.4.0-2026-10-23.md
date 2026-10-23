# 貓咪辦公室 0.4.0 部署紀錄（2026-10-23）

YUI 同意後，依 `office/docs/mobile/DEPLOY.md` 第 7 點的 release 流程部署。沒有使用 `office/deploy.sh`，也沒有改 Caddy、DNS、UFW、SSH 或 systemd unit。

## 變更

| 項目 | 內容 |
|---|---|
| 為什麼 | 修補辦公室的 loopback 信任：本機模式原本接受任何經 `127.0.0.1` 送來、帶本機 Host 的請求。加入貓咪的手（另一個 Linux 使用者）之前必須先修。見 `office/docs/agent-hands/PRD.md` 5.8 |
| 新 release | `~/neighbor-office/releases/public-20261023-52108bd`，內容是 `git archive 52108bd` 的 `office/office.py`、`static/`、`tests/`；36 個檔案的 SHA-256 與 commit 完全一致 |
| 程式來源 | 分支 `claude/agent-hands-prd` 的 `52108bd`，**尚未合併 main** |
| `current` | `releases/public-20261022-5f9c559` → `releases/public-20261023-52108bd`（以 `mv -T` 原子切換） |
| 服務 | `systemctl --user restart neighbor-office.service`；`active`、NRestarts=0；日誌：`Neighbor Office 0.4.0 listening on loopback:8421 for https://office.nekonode.cloud; local entry /home/neighbor/neighbor-office/run/office.sock` |
| `office.py` 雜湊（前 16 碼） | `0625e1fc7c74c556` |
| 部署前狀態 | 25 件任務，沒有進行中或排隊中的任務，重啟沒有中斷任何工作 |

## 備份與回復

- 備份：`~/neighbor-office/backups/pre-52108bd-20261023T074835Z`
  - `data/office.sqlite3`：用 SQLite online backup API 取得一致性副本，`integrity_check` 為 ok（tasks 25 列、devices 6 列）。
  - `data/inbox`、`data/journal`、`data/tasks` 的複本；`previous-current.txt`；service unit 副本。
- 回復：

  ```bash
  ssh neighbor-vps 'cd ~/neighbor-office && ln -sfn releases/public-20261022-5f9c559 current.new && mv -T current.new current && systemctl --user restart neighbor-office.service'
  ```

  舊版不使用 socket，`run/` 留著也沒有影響。

## 驗證

- **部署前（release 內）：** `py_compile` 通過；在 VPS（Python 3.14.4）上跑 `python3 -I -B -m unittest discover -s tests`，**83 項全部通過**。
- **部署後：** 從 Mac 執行 `python3 -I office/verify_public.py --expect-version 0.4.0`，**27 項全部通過**：
  - **公網：**
    - HTTP 以 308 轉到 HTTPS；TLS 憑證有效；配對頁 200。
    - 匿名請求：`/api/session`、`/api/tasks`、`/api/health`、`/api/sync` 都回 401，`/api/bootstrap` 回 404，WSS 握手回 401；跨站 POST 回 403。
    - 靜態檔的 MIME 類型正確。
  - **短暫測試裝置：**
    - 配對回 201；cookie 帶 `__Host-` 前綴，並設 Secure、HttpOnly、SameSite=Strict。
    - `session`、`tasks`、`health`（版本 0.4.0）都回 200；WSS 回 101 並收到 hello。
    - 用 VPS CLI 撤銷後，開著的 WSS 在 0.6 秒內以 **4401** 關閉；之後 `session` 與新的 WSS 都回 401。
  - **本機入口（0.4.0 新增）：**
    - socket 權限為 `srw------- neighbor`。
    - 在 VPS 上帶本機 Host 打 loopback TCP，回 **421**。
    - socket 的 `/api/health` 回報 0.4.0。
    - `open-office.command` 會選擇 socket；Mac 經 SSH 轉送到 socket，`/api/health` 回 200。
- **部署後狀態：**
  - 服務日誌沒有錯誤；`data/` 權限仍是 700／600。
  - 測試裝置 `deploy-check-074948` 與 `deploy-check-075023` 都已撤銷。第一次執行時，腳本誤把重播的舊事件當成關閉訊號，已修正；第二次全數通過。
  - 「我的手機」仍是使用中。

配對碼、cookie 與 token 沒有記錄在本文件或輸出中。

## 部署後的影響

1. **Mac：** 要用這個分支的 `office/open-office.command`（`worktrees/neko-agent-hands/office/`），它會轉送到 socket。`macos/` 主線上的舊版會轉送到 8421，現在會拿到 421，合併到 main 後才會恢復。
2. **VPS 桌面捷徑：** `~/Desktop/neighbor-office.desktop` 用的是 TCP 本機模式，現在已失效，這是刻意的。H1 會把桌面交給 neko-hands，那個桌面永遠不能進辦公室，也不和辦公室配對。
3. **手機：** 經 `https://office.nekonode.cloud` 的手機使用不受影響。
