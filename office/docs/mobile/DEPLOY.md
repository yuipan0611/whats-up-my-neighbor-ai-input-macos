# 手機直連部署檢查單

狀態（2026-10-22）：公網 HTTPS／WSS 已部署。iPhone Chrome 開啟配對頁無憑證警告，已配對、交辦，並在鎖屏超過五分鐘後確認仍能看到完成成果與進度。手動斷網重送、撤銷這台 iPhone 尚未實測；自動測試已涵蓋重送與短暫測試裝置撤銷。詳細證據見 `reports/office-mobile/PUBLIC-DEPLOYMENT-2026-10-22.md`。

## 架構

```text
iPhone Chrome
  → https://office.nekonode.cloud / wss://office.nekonode.cloud/api/ws
  → Caddy :443
  → 127.0.0.1:8421（neighbor-office.service）
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

## iPhone 配對

1. 在 Mac 執行 `office/pair-iphone.command`，配對碼只顯示在 Mac 的 Terminal，10 分鐘內有效。也可在 VPS 執行 `python3 -I ~/neighbor-office/current/office.py pair`。
2. iPhone Chrome 開啟 `https://office.nekonode.cloud`，輸入配對碼並完成配對。不要把配對碼、cookie 或 token 貼到聊天、截圖或紀錄。
3. 基本手機端到端驗收已完成；若要驗證手動斷網與這台手機的撤銷，依下方未測項目操作。

## 驗收證據與範圍

- 已驗證：外網匿名請求無法讀取任務、生活紀錄或取得操作權限。
- 已由使用者以 iPhone Chrome 驗證：配對、交辦、完成成果、繁體中文畫面，以及鎖屏超過五分鐘後成果與進度仍可讀取。測試期間由辦公室送出的公開短任務已在 VPS 完成。
- 已由自動測試驗證：同一 UUID 重送不產生第二筆任務；短暫測試裝置撤銷後 HTTP 回 401、WSS 關閉。Mac 經 SSH 18421 通道仍可使用。
- 尚未在這台 iPhone 實測：手動切斷網路後重送，以及撤銷手機配對。撤銷會讓目前手機失去存取權，需重新配對，因此不在日常驗收中直接操作。
