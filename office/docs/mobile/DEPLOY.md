# 手機直連部署檢查單

狀態（2026-10-22）：公網 HTTPS／WSS 已部署。iPhone Chrome 開啟配對頁無憑證警告，已配對、交辦，並在鎖屏超過五分鐘後確認仍能看到完成成果與進度。手動斷網重送、撤銷這台 iPhone 尚未實測；自動測試已涵蓋重送與短暫測試裝置撤銷。詳細證據見 `reports/office-mobile/PUBLIC-DEPLOYMENT-2026-10-22.md`。

目前版本（2026-10-23 13:39 UTC 起）：`current` 指向 `releases/public-20261023-11a383a`，也就是 office 0.5.0（分支 `claude/agent-hands-prd` 的 `11a383a`，**尚未合併 main**）。這一版加上 worker 入口（`--worker-socket /srv/neko-office/worker.sock`）。上一版是 `releases/public-20261023-52108bd`（0.4.0）。部署紀錄見 `reports/agent-hands/DEPLOY-0.5.0-2026-10-23.md`。每次部署後，從 Mac 執行 `python3 -I office/verify_public.py --expect-version <版本>`，共 27 項。

上面的 iPhone 驗收是在 `fix3` 完成的；5f9c559 起的新聊天介面與附件，還沒在 iPhone 驗收。

## 架構

```text
iPhone Chrome
  → https://office.nekonode.cloud / wss://office.nekonode.cloud/api/ws
  → Caddy :443
  → 127.0.0.1:8421（neighbor-office.service，只認公網模式）

Mac（open-office.command）
  → SSH 轉送 127.0.0.1:18421
  → ~/neighbor-office/run/office.sock（本機模式；0.4.0 起，權限 600）
```

Caddy 設定範本在 `office/services/Caddyfile.public.example`。Caddy 的 `reverse_proxy` 會處理 WebSocket 升級；office 仍只監聽 VPS 本機位址。主網域 `nekonode.cloud` 不變。

## 已完成的公網檢查

1. 確認 `office/office.py`、`office/static/*` 與後端測試在同一個待部署 commit；執行全部 office 測試。比對 VPS 目前版本與待部署版本。
2. SSH 金鑰登入與 Hostinger Web Terminal 救援路徑已確認，之後才關閉 root 密碼登入。
3. 確認匿名連到 public Host 時，`/api/session` 回 401、`/api/tasks` 回 401、`/api/bootstrap` 回 404；錯誤配對碼不會洩漏有效碼是否存在，限速有效。
4. 確認正確 Origin、cookie 與 session token 都必要；跨站 POST 和 WebSocket 握手遭拒。撤銷裝置後 HTTP 與 WSS 都失效。
5. 確認 Caddy 設定不改寫 Host，並保留其管理的 `X-Forwarded-For`；不可把 office 直接綁到 `0.0.0.0`。

## 本次部署紀錄與後續更新

YUI 已同意部署 `office.nekonode.cloud`。本次使用 Hostinger DNS 與 VPS root 權限；備份保存在 VPS `~/neighbor-office/backups/pre-public-20261022T015730Z`。正式服務由 `~/neighbor-office/current` 指向已測試的版本；更新時建立新版本目錄、跑測試，再切換 symlink 與重啟服務。舊版 `office/deploy.sh` 會在發現公網服務時停止。

1. DNS `office` A 記錄指向 VPS `31.97.108.187`，TTL 300。主站 A 與 `www` CNAME 未改。
2. Caddyfile 使用 `office/services/Caddyfile.public.example`；已通過 `caddy validate`，Caddy 提供 TLS 並反向代理到 loopback。更新設定前，先備份現有 Caddyfile 並驗證新設定。
3. `neighbor-office.service` 使用 `office/services/neighbor-office-public.service.example`，含 `--public-origin https://office.nekonode.cloud`。更新程式時保留 `~/neighbor-office/data`，切換 `current` 後重啟並檢查健康狀態。
4. UFW 只開放 22／80／443；8421 維持 loopback。公開端已驗證 HTTPS 憑證、HTTP 轉 HTTPS、匿名 API 拒絕與 WSS 連線／撤銷。每次更新都重跑這些檢查。
5. 若更新失敗，將 `current` 指回上個版本並重啟服務；必要時使用上述備份還原資料。不要刪除使用中的資料目錄。
6. 2026-10-22 更新到 main `5f9c559`：切換前的備份在 `~/neighbor-office/backups/pre-5f9c559-20261022T070121Z`，回復時把 `current` 指回 `releases/public-20261022-fix3`。服務是使用者層級的 unit，重啟要用 `systemctl --user restart neighbor-office.service`。
7. **0.4.0（本機入口改為私有 socket）：2026-10-23 07:48 UTC 經 YUI 同意後部署**
   - **備份：** `~/neighbor-office/backups/pre-52108bd-20261023T074835Z`。
   - **檢查：** `verify_public.py` 27 項全過。
   - **回復：** `ln -sfn releases/public-20261022-5f9c559 current.new && mv -T current.new current`，再重啟。
8. **0.5.0（worker API、hands 執行者、收回開關；開啟 worker 入口）：2026-10-23 13:39 UTC 經 YUI 同意後部署**
   - **服務設定：** user unit 的 ExecStart 加上 `--worker-socket /srv/neko-office/worker.sock`。範本 `services/neighbor-office-public.service.example` 已同步。
   - **前提：** H1 建好的 `/srv/neko-office`，neighbor:neko，權限 2750。
   - **備份：** `~/neighbor-office/backups/pre-11a383a-20261023T133923Z`（含部署前的 unit 檔）。
   - **檢查：**
     - `verify_public.py` 27 項全過。
     - `worker.sock` 為 `srw-rw---- neighbor:neko`。
     - neko-hands 能 claim；碰擁有者的路徑一律 404。
     - 其他使用者連不上 worker socket。
   - **回復：**
     1. `ln -sfn releases/public-20261023-52108bd current.new && mv -T current.new current`。
     2. 把 unit 換回備份裡的版本。
     3. `systemctl --user daemon-reload`，再重啟。
     - 資料表多出的欄位不影響 0.4.0。
   - **服務設定不用改：** socket 預設放在 `--data` 旁邊的 `run/office.sock`。
   - **切換後檢查：**
     - `stat -c '%A %U' ~/neighbor-office/run/office.sock` 應為 `srw------- neighbor`。
     - VPS 上 `curl -H 'Host: 127.0.0.1:8421' http://127.0.0.1:8421/api/bootstrap` 應回 **421**。
     - 用 `curl --unix-socket` 連 socket 應回 200。
     - Mac 用新版 `open-office.command` 能開啟辦公室。
     - 再跑一次上方的公網檢查。
   - **Mac 舊通道：** 舊版 `open-office.command`（直接轉送到 8421）在切換後會拿到 421。新版會自動判斷：VPS 有 socket 就轉送到 socket，沒有就沿用 8421，所以 Mac 和 VPS 不用同時更新。
   - **VPS 桌面捷徑：** `~/Desktop/neighbor-office.desktop` 用的是 TCP 本機模式，切換後會失效，這是刻意的。H1 會把桌面交給貓咪的手（neko-hands）；那個桌面上的瀏覽器永遠不能進辦公室，也永遠不和辦公室配對。
   - **回復：** 把 `current` 指回 `releases/public-20261022-5f9c559` 並重啟。舊版不會用到 socket；`run/` 目錄留著也沒有影響。

## iPhone 配對

1. 在 Mac 執行 `office/pair-iphone.command`，配對碼只顯示在 Mac 的 Terminal，10 分鐘內有效。也可在 VPS 執行 `python3 -I ~/neighbor-office/current/office.py pair`。
2. iPhone Chrome 開啟 `https://office.nekonode.cloud`，輸入配對碼並完成配對。不要把配對碼、cookie 或 token 貼到聊天、截圖或紀錄。
3. 基本手機端到端驗收已完成；若要驗證手動斷網與這台手機的撤銷，依下方未測項目操作。

## 驗收證據與範圍

- 已驗證：外網匿名請求無法讀取任務、生活紀錄或取得操作權限。
- 已由使用者以 iPhone Chrome 驗證：配對、交辦、完成成果、繁體中文畫面，以及鎖屏超過五分鐘後成果與進度仍可讀取。測試期間由辦公室送出的公開短任務已在 VPS 完成。
- 已由自動測試驗證：同一 UUID 重送不產生第二筆任務；短暫測試裝置撤銷後 HTTP 回 401、WSS 關閉。Mac 經 SSH 18421 通道仍可使用。
- 尚未在這台 iPhone 實測：手動切斷網路後重送，以及撤銷手機配對。撤銷會讓目前手機失去存取權，需重新配對，因此不在日常驗收中直接操作。
