# 貓咪辦公室公網部署紀錄（2026-10-22）

## 狀態

- `https://office.nekonode.cloud` 已部署；使用者以 iPhone Chrome 開啟配對頁，回報沒有安全警告，並已輸入只在 Mac Terminal 顯示的一次性配對碼進入辦公室。
- 真實 HTTPS 配對、Secure cookie、任務讀取、WSS 握手與裝置撤銷已用短暫測試裝置通過；測試裝置已撤銷。
- iPhone 已交辦一件無私人資料的短任務；VPS 顯示任務由執行中轉為完成。使用者指出成果位置太深與過程摘要出現英文；更新後，使用者確認點最新任務可直接看到三點繁體中文成果，且進度文字正常。使用者也確認鎖屏超過五分鐘後仍能看到完成成果與進度。

## 變更與回復點

- VPS：`31.97.108.187`。Hostinger DNS 加入 `office` A 記錄，TTL 300；`nekonode.cloud` A 與 `www` CNAME 保持原設定。
- 部署前備份：`/home/neighbor/neighbor-office/backups/pre-public-20261022T015730Z`，包含 app、SQLite 一致性備份、資料檔與舊服務單元。
- 正式服務：`neighbor-office.service` 使用 `--public-origin https://office.nekonode.cloud`，從 `/home/neighbor/neighbor-office/current` 啟動；目前指向 `releases/public-20261022-fix3`。原 `app` 未覆寫，可作回復參考。
- Caddy 2.6.2：`office.nekonode.cloud` → `127.0.0.1:8421`。舊 Caddyfile 備份為 `/etc/caddy/Caddyfile.pre-office-20261022`；新設定已通過 `caddy validate`。
- UFW 對外只允許 22／80／443；辦公室自身只監聽 `127.0.0.1:8421`。確認 root 金鑰與 Web Terminal 可用後才停用 SSH 密碼登入。
- 失敗回復：將 `current` 指回上一版，重啟 `neighbor-office.service`；若要撤回公網入口，還原 Caddyfile 與 DNS 記錄。資料還原前先停止服務並保留目前資料副本。

## 驗證

- 本機與 VPS 各 65 項 office 測試通過；JavaScript 語法、shell 語法與 diff 檢查通過。
- 權威 DNS 的兩個 nameserver 均解析 `office` 到 VPS；公開 TLS 憑證主體為 `office.nekonode.cloud`，有效期 2026-10-22 至 2027-01-20。HTTP GET 轉 HTTPS，HTTPS GET 返回配對頁。
- 匿名 `/api/session`、`/api/tasks` 返回 401，`/api/bootstrap` 返回 404；跨站 API 請求遭拒。從其他網站點入時，公開的配對頁仍能開啟。
- 短暫測試裝置經公開 HTTPS 配對返回 201，登入後 session／tasks 返回 200，WSS 握手返回 101 並收到 hello；撤銷後 WSS 以 4401 關閉，HTTP session 返回 401。
- Mac 原 SSH 通道可讀取本機模式的 bootstrap／tasks；主站 `https://nekonode.cloud` 仍正常回應。
- 實機驗收時，使用者指出完成成果在手機長列表下方難找；第二次更新將列表限制高度、點任務後帶至詳情，並將成果移到步驟紀錄前。VPS 與本機各 65 項測試重新通過，公開程式檔案雜湊一致，HTTPS／WSS 短暫裝置測試再次通過。
- 使用者再指出英文「思考」摘要與成果位置。第三次更新讓點選已完成任務時直接捲到成果，並將原始思考摘要在手機頁顯示為繁體中文狀態；原事件仍留在 SQLite 供追溯。重新用明確的三點「網頁配對」測試題目交辦，VPS 完成並輸出三點繁體中文，涵蓋 HTTPS 無警告、Mac 配對碼與鎖屏後成果／進度；沒有混淆成藍牙。使用者在 iPhone 確認位置、成果與進度文字正常。第三次更新本機與 VPS 各 65 項測試通過，WSS 短暫裝置測試再次通過。
- 使用者自行送出 GitHub 帳戶串接問題，因未指定目標服務而由 Codex 正確標為 `needs_input`；這不能作為任務完成驗收。另由 Codex 送出明確標示的「鎖屏驗收測試」公開短任務，VPS 顯示完成；使用者解鎖 iPhone 後確認成果與進度正常。
- 實際公開配對頁畫面：`public-pairing-390.png`（初次手機寬度）與 `public-pairing-live.png`（更新後正式頁）；DNS 設定畫面：`hostinger-office-dns.png`。

## 手機驗收與未測項目

1. 已完成：在 Mac 執行 `office/pair-iphone.command`，於 iPhone Chrome 配對並進入辦公室。
2. 已交辦兩件不含私人資料的短任務，VPS 均顯示完成；使用者在 iPhone 確認最新成果直接可見、過程文字符合繁體中文要求。
3. 已完成：使用者確認鎖屏超過五分鐘後成果與進度仍可讀取；期間由辦公室送出的公開短任務在 VPS 完成。
4. 未在這台 iPhone 實測：手動斷網重送與撤銷手機配對。短暫測試裝置的撤銷與重新連線已由公開 HTTPS／WSS 測試驗證；不要為測試撤銷使用者正在使用的手機。

配對碼、cookie 與 token 不記錄在本報告中。
