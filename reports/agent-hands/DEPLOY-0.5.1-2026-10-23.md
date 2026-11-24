# 貓咪辦公室 0.5.1 部署紀錄（2026-10-23）

YUI 同意後，由 Claude 依同一套 release 流程部署。

| 項目 | 內容 |
|---|---|
| 內容 | hands 任務以 `incomplete` 結束時，工作狀態顯示 worker 給的原因（原本只有 `failed` 會顯示）。例如時間到，會顯示「超過 30 分鐘」 |
| release | `releases/public-20261023-f74a50a`，41 個檔案；`office.py` sha256 `966e72f1…`；`hands/worker.py` sha256 `ea3e4cac…`，與 `/opt/neko-hands/worker.py` 相同 |
| 打包修正 | 第一次只打包了 `office.py`、`static/`、`tests/`，VPS 上的 `test_hands_worker` 匯入失敗。刪掉那個沒用到的 release，加上 `office/hands` 重新打包 |
| 服務 | `active`、NRestarts=0；日誌：`Neighbor Office 0.5.1 … worker entry /srv/neko-office/worker.sock` |
| 部署前狀態 | 沒有進行中或排隊中的任務 |

## 驗證

- **自動測試：** VPS 上 114 項通過，其中 10 項 worker 測試第一次在 Linux 上跑：真的辦公室，配上假的 Codex。
- **實機：**
  - `verify_public.py --expect-version 0.5.1` 27 項全過。
  - `worker.sock` 為 `srw-rw---- neighbor:neko`。
  - `neko-hands-worker.service` 在辦公室重啟後仍在執行。
- **備份：** `backups/pre-f74a50a-20261023T141025Z`，integrity ok（tasks 25、devices 9、journal 9）。
- **回復：** `current` 指回 `releases/public-20261023-11a383a`，再重啟。
