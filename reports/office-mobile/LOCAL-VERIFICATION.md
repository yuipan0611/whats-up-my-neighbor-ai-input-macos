# 手機 Chrome 直連：本機驗證

日期：2026-10-22。分支：`codex/neighbor-office-v1`。後端最新 commit：`f7abf66`；前端與部署範本仍為本機未提交修改。

這是部署前的歷史檢查紀錄；目前公網狀態請見 `PUBLIC-DEPLOYMENT-2026-10-22.md`。

## 已驗證

- `python3 -I -m unittest discover -s office/tests -q`：64 項通過，包含已建立的 WebSocket 在裝置配對期限結束後關閉。測試使用獨立暫存資料，不觸及 VPS 的正式辦公室資料。
- `node --check office/static/app.js` 與 `git diff --check`：通過。
- 以本機模擬 API 在 390px 寬瀏覽器預覽：配對頁完整顯示，測試碼成功後切換到辦公室；這只驗證前端流程與版面，不代表真正 VPS 已配對。
- 以本機隔離資料庫和實際 `office.py` 服務開啟辦公室：瀏覽器顯示「已連上 VPS · 即時」；按下暫停／恢復後，介面狀態和回應立即更新。測試服務與暫存資料已關閉並清理。
- 查詢 DNS：`office.nekonode.cloud` 目前沒有 A 記錄；`nekonode.cloud` 主網域仍指向 Vercel。

## 尚未驗證

- Caddyfile 尚未在 VPS 上以 `caddy validate` 驗證；本機未安裝 Caddy。
- 尚未設定 DNS、SSH、UFW、Caddy 或部署 `neighbor-office.service`。VPS 上的舊版服務尚未變更。
- 尚未在真正的 HTTPS/WSS 公網路徑或 iPhone Chrome 上做配對、鎖屏續跑、斷線補進度與撤銷測試。

部署步驟及真機驗收條件見 `office/docs/mobile/DEPLOY.md`。
