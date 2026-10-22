---
title: 貓咪辦公室：iPhone Chrome 直連 VPS
date: 2026-10-22
status: 已拍板（N2＋W＋CLI 配對＋暫不通知）。後端與手機頁面本機完成；public HTTPS/WSS 與 iPhone 實機尚未部署驗收
branch: codex/neighbor-office-v1（基於 e0cb2f3；VPS 上執行的是 75bc990）
owners: Claude 負責 office/office.py 與後端測試；Codex 負責 office/static/* 與手機頁面（2026-10-22 確認）
---

# 貓咪辦公室：iPhone Chrome 直連 VPS

## 1. 一句話

YUI 人在外面時，用 iPhone Chrome 打開貓咪辦公室交辦工作。關掉手機後，VPS 照樣把工作做完；重新打開時，從 SQLite 的 `events.seq` 把錯過的狀態補回來。

## 2. 決策

**YUI 已於 2026-10-22 拍板**：

- **D1 = N2**：公網 HTTPS/WSS。
- **D2 = W**：WebSocket。
- **D3 = VPS CLI**：用 `office.py pair` 產生配對碼。
- **D4 = 暫不做通知。**

N1（Tailscale）與 S（SSE）保留在下文，作為日後替代方案的紀錄。**若第 5–7 節的細節與第 13 節衝突，以第 13 節「API 契約 v1」為準。**

原本的選項表：

| 編號 | 決定 | 選項 |
|---|---|---|
| D1 | 網路路線 | **N1 Tailscale 私網**、**N2 公網 HTTPS/WSS**。兩者可以先後做，也可以只做一條（第 4 節） |
| D2 | 即時通道 | **W：WebSocket（WSS）**，YUI 提出的路線；**S：SSE＋HTTP POST**，較簡單的替代方案（第 5 節）。兩者的補狀態契約相同 |
| D3 | 配對碼從哪裡產生 | Mac 預覽 App 按鈕、VPS 指令 `office.py pair`，或兩者都做 |
| D4 | 完成通知 | 先不做；Telegram bot；或 Web Push（iOS 條件未確認，見第 11 節） |

## 3. 現況（2026-10-22 唯讀核對）

| 項目 | 狀態 |
|---|---|
| 服務 | `neighbor-office.service`（systemd user），`Linger=yes`，只聽 `127.0.0.1:8421`。VPS 上的檔案與 `75bc990` 的 SHA-256 一致 |
| 對外 | 只開 22，沒有 443，也沒有反向代理 |
| 資料 | SQLite WAL。`tasks`、`events(seq AUTOINCREMENT)`、`handoffs`、`journal`、`settings(paused)` |
| 事件 | 任務的狀態變更（`_change`）和步驟（`note`：thinking/message/tool）**都會寫進 events**，各自有遞增的 seq |
| 不在 events 的變更 | `settings.paused`、新增生活紀錄、上傳檔案。這三種只能靠整份重抓得知 |
| 冪等 | `POST /api/command` 帶用戶端產生的 UUID `id`：相同 UUID 加相同內容，保持同一筆；內容不同就拒絕 |
| 前端 | 每 2 秒輪詢 `/api/tasks`（整份），每 15 秒輪詢 `/api/health` |
| 認證 | 只靠 loopback、Host 白名單、Origin 檢查。`GET /api/bootstrap` 會把寫入 token 交給任何連得到它的人。**這在公網上是漏洞** |
| VPS 安全 | root 仍接受密碼登入（SETUP 2.9 尚未執行） |

## 4. 網路路線（並列）

### N1：Tailscale 私網

```text
iPhone（Tailscale App 開著）→ Chrome → https://<vps>.<tailnet>.ts.net
  → tailscale serve（TLS 終止）→ 127.0.0.1:8421
```

- 優點：
  - 不開公網連接埠，也不用買憑證。
  - 只有加入 tailnet 的裝置連得到。
- 代價：手機要開著 Tailscale；需要 Tailscale 帳號。
- 前置（root，由 YUI 執行）：
  - 安裝 tailscale。
  - `tailscale up`，登入 YUI 的帳號。
  - `tailscale serve` 指向 8421。
- 未確認：`tailscale serve` 是否原樣轉送 WebSocket upgrade，以及長連線的 SSE。實作前用官方文件查證，再實測。

### N2：公網 HTTPS/WSS

```text
iPhone Chrome → https://office.nekonode.cloud（A 記錄 → 31.97.108.187）
  → Caddy :443（Let's Encrypt）→ 127.0.0.1:8421
```

- 優點：任何網路都能直接打開，不用另裝 App。
- 代價：伺服器直接暴露在公網，所以第 7 節的配對與 cookie **必須先完成**。
- 前置：
  1. **SSH 收緊（SETUP 2.9）先做。**
  2. YUI 在 hPanel 新增 DNS 記錄。這不影響目前指向 Vercel 的 `nekonode.cloud` 主網域。
  3. root 安裝 Caddy，ufw 開 80 和 443。
- Caddy 的 `reverse_proxy` 會轉送 WebSocket upgrade；SSE 要確認不被緩衝（`flush_interval -1`）。這兩點以 Caddy 官方文件為準，實作前查證。

### 兩條路線共通

- office 仍然只聽 `127.0.0.1:8421`，**不改成聽 0.0.0.0**。
- Host 白名單改成設定檔加上預設值：`127.0.0.1:8421`、`127.0.0.1:18421`，再加上選定的網域。Origin 要等於 `https://<該網域>`。
- 兩條路線**都要求裝置配對**（第 7 節）。認證只有一套，N1 等於多一層網路保護。

## 5. 即時通道（並列，共用第 6 節的補狀態契約）

### 共同的事件格式

```json
{"seq": 182, "task_id": "uuid 或 \"_office\"", "at": "ISO8601", "status": "running|completed|thinking|...", "message": "..."}
```

- 事件只告訴手機「哪一件任務、在 seq 幾變了什麼」。成果全文、plan、metrics 仍然要另外 `GET /api/tasks/<id>` 取得，避免推大量文字。
- 新增**辦公室層級事件**，`task_id` 填 `"_office"`，`status` 為 `paused`、`resumed`、`journal_added`、`file_added` 其中之一。這樣第 3 節「不在 events 的變更」也有 seq 可補。後端寫入時與原本的變更放在同一個 transaction。

### W：WebSocket（YUI 提出）

- 端點：`GET /api/ws?after=<seq>`，以 HTTP Upgrade 升級。伺服器以 stdlib 實作 RFC 6455 握手與文字訊框，不加第三方相依。
  - 只實作需要的部分：文字訊框、ping/pong、close。
  - 每條連線一個執行緒，阻塞在條件變數上，等新的 seq。
- 方向（v1）：**伺服器 → 手機只推事件**。交辦、取消、交接、暫停一律照舊走 HTTP POST，所以寫入路徑只有一條，UUID 冪等與 CSRF 檢查也只需要一套。手機 → 伺服器只送 ping，以及 `{"ack": <seq>}`（選用，只用來記錄裝置最後讀到哪裡）。
  - 若 YUI 要讓 WS 也能交辦，列為 v2，訊息格式與 POST body 相同，也必須帶 UUID。
- 安全：
  - 瀏覽器的 WebSocket **不受 CORS 保護**，所以 upgrade 時必須檢查 Origin，否則有跨站 WebSocket 劫持的風險。
  - 認證靠 cookie，因為瀏覽器的 WebSocket API 不能自訂 header。
  - 每台裝置最多 2 條連線；閒置 60 秒沒有 pong 就關閉。
- 手機端：
  - 斷線後指數退避重連，間隔 1、2、4… 最多 30 秒。
  - 每次重連都帶 `after=<最後 seq>`。
  - 切回前景時（`visibilitychange`）立即重連。

### S：SSE＋HTTP POST（較簡單的替代方案）

- 端點：`GET /api/stream`，`Content-Type: text/event-stream`。每個事件寫成 `id: <seq>` 加 `data: <json>`，每 10 秒送一行心跳 `: ping`。
- 瀏覽器重連時會自動帶 `Last-Event-ID`；伺服器把它當成 `after`，也接受查詢參數 `?after=`。
- 寫入照舊走 POST。
- 要改的地方：`Handler.setup()` 目前把每條連線的逾時設成 15 秒，SSE 路徑要排除這個逾時。
- 比 W 少的工作：不用寫握手與訊框，也不用另做 Origin 劫持防護（EventSource 只能 GET，寫入仍有 token 加 Origin 檢查）。

### 比較

| | W：WebSocket | S：SSE＋POST |
|---|---|---|
| YUI 需求的對應 | 直接對應「WSS」 | 功能相同，協定不同 |
| 後端實作量 | 握手、訊框、ping/pong、Origin 劫持防護 | 一個長連線回應加心跳 |
| 斷線補狀態 | 自己帶 `after` | 瀏覽器自動帶 `Last-Event-ID` |
| 經過 Caddy／tailscale serve | 需要轉送 upgrade | 需要不緩衝 |
| 失敗退路 | 退回 2 秒輪詢 `/api/sync` | 同左 |

不論選哪一個，**正確性都不依賴長連線**：長連線只負責「快」，補狀態一律靠第 6 節的 `/api/sync`。

## 6. 補狀態契約（W 與 S 共用）

新增 `GET /api/sync?after=<seq>&limit=500`，回傳：

```json
{"latest_seq": 230, "events": [...], "truncated": false, "paused": false}
```

手機的流程：

1. 第一次打開：`GET /api/tasks`、`/api/journal`、`/api/files` 取得整份快照，記下 `latest_seq`。
2. 打開長連線（W 或 S），帶 `after=latest_seq`。
3. 每收到一個事件：
   - `seq <= 已處理的 seq` 就丟掉，因為可能重複收到。
   - 否則更新畫面，並對該 `task_id` 重抓 `GET /api/tasks/<id>`；同一件任務 1 秒內只抓一次。
4. 斷線、或從背景回來：先 `GET /api/sync?after=<已處理 seq>` 補齊，再重開長連線。
5. `truncated: true` 表示落後超過 limit：放棄增量，回到步驟 1 重抓整份快照。
6. 已處理的 seq 存在記憶體與 `localStorage`。讀寫要包 try/catch；讀不到就當第一次打開。

伺服器的保證：

- seq 嚴格遞增。寫入都在同一把鎖、同一個 transaction 裡，所以不會出現「看得到 seq 231，卻看不到 230」的情況。
- events 不刪除。`note()` 每件任務最多 400 筆的上限維持不變。

## 7. 認證與配對（N1、N2 都要）

1. **產生配對碼（D3）**：8 位數字，10 分鐘有效，只能用一次。伺服器只存雜湊。
2. **配對頁**：手機輸入配對碼和裝置名稱，送 `POST /api/pair`。
   - 成功時，在新增的 `devices` 表建一筆：`id`、`name`、`secret_hash`、`created`、`last_seen`、`last_seq`、`revoked`。
   - 回應設定 cookie：`__Host-office=<device_id>.<secret>`，屬性 `HttpOnly; Secure; SameSite=Strict; Path=/`，30 天，每次使用都延長。
3. **寫入**：
   - 照舊檢查 `X-Office-Token`，但 token 改成綁定該裝置的 session，`GET /api/session` 只發給帶有效 cookie 的請求。
   - `/api/bootstrap` 在非 loopback 的 Host 下回 404。Mac 經 SSH 通道進來時 Host 是 loopback，行為不變。
4. **限速**：同一 IP 每 10 分鐘最多 5 次配對失敗，超過就鎖 10 分鐘。
5. **撤銷**：`POST /api/devices/<id>/revoke`，只能從 loopback（也就是 Mac）呼叫。撤銷後該裝置的 WS／SSE 連線立即斷開。
6. Mac 經 18421 通道進來的流程不變：loopback Host 不需要配對。

## 8. 手機離線時繼續工作

這一項已經成立，不用改：

- 交辦送出時就寫入 SQLite。worker 執行緒和手機連線沒有關係。
- systemd 加上 linger，所以 VPS 重開機後服務會自動起來。

行為補充：

- 手機在送出時斷線：重送同一個 UUID，伺服器保持同一筆，不會重複執行。
- 服務重啟：進行中的工作改成 `interrupted` 並寫入事件，手機補狀態時會看到。
- Codex 登入過期：`/api/health` 的 `provider.authenticated` 會變成 false。手機頁要顯示提示；重新登入要由人完成，可以透過接手控制的 VNC。

## 9. 介面契約與檔案所有權

| 端點 | 新增或修改 | 負責 |
|---|---|---|
| `GET /api/sync?after=` | 新增 | Claude（office.py） |
| `GET /api/ws?after=`（W）或 `GET /api/stream`（S） | 新增，依 D2 二選一或都做 | Claude |
| `POST /api/pair`、`GET /api/session`、`POST /api/devices/<id>/revoke` | 新增 | Claude |
| `_office` 事件（paused/resumed/journal_added/file_added） | 新增 | Claude |
| Host 白名單與 Origin 設定化（`--public-origin`） | 修改 | Claude |
| 手機版面、配對頁、補狀態流程、長連線、重連、退回輪詢 | 新增或修改 `office/static/*` | Codex |
| 測試 | `office/tests/test_mobile.py`（後端） | Claude |
| 網路前置（tailscale 或 Caddy、DNS、ufw、SSH 收緊） | VPS root 與 hPanel | YUI |

規則：一個檔案只有一個負責人。要改對方的檔案，先在 HANDOFF.md 留言。不 push、不部署，部署要另外取得 YUI 同意。

## 10. 驗收標準

**後端離線測試（Claude）**：2026-10-22 全部通過（`8576550`，62 項）
- [x] `/api/sync`：
  - `after=0` 回傳全部事件；`after=latest` 回傳空。
  - 超過 limit 時 `truncated=true`。
  - 回傳的 seq 嚴格遞增、沒有缺號。
- [x] 暫停、恢復、新增生活紀錄、上傳檔案時，各自產生一筆 `_office` 事件。
- [x] W：
  - 握手時 `Sec-WebSocket-Accept` 正確。
  - Origin 不符就拒絕；沒有 cookie 就拒絕。
  - 斷線後帶 `after` 重連，不漏事件也不重複。
- [ ] ~~S：`Last-Event-ID` 與 `after` 等價；心跳按時送出；長連線不被 15 秒逾時切斷。~~ 不適用：D2 選了 W，沒有實作 S。
- [x] 配對：
  - 錯誤碼次數限速有效。
  - 過期或已用過的配對碼被拒絕。
  - 撤銷後 cookie 失效，長連線也被關閉。
- [x] 非 loopback 的 Host 呼叫 `/api/bootstrap` 回 404；loopback 的行為不變。
- [x] 重送相同 UUID 不會建立第二筆。
- [x] 原本的 38 個測試全部通過。

**本機整合（Codex，2026-10-22）**：新版 office.py 的隔離本機服務，加上 Chrome 實際 WebSocket，顯示「已連上 VPS · 即時」；暫停／恢復即時更新。另以模擬 API 驗證 390px 配對頁與配對後的切換。見 `reports/office-mobile/LOCAL-VERIFICATION.md`。這不能代替下面的 public 驗收：本機是 http，cookie 的 Secure 屬性與 wss 都沒有走到。

**實機（尚未進行；要等 M5 部署並取得 YUI 同意）**
- [ ] 手機配對後交辦一件工作，接著鎖定手機 5 分鐘以上，工作照樣在 VPS 完成。
- [ ] 重新打開頁面，補回期間所有步驟與完成狀態，沒有缺漏、沒有重複。
- [ ] 飛航模式下送出，恢復網路後重送，結果只有一筆。
- [ ] Mac 經 18421 通道使用辦公室的流程不受影響。

## 11. 未確認（實作前要查證或實測）

- iOS 版 Chrome 切到背景後，WebSocket 或 EventSource 多久會被系統中斷。正確性不依賴這一點，但會影響「看起來即時」的程度。
- iOS 上用 Chrome「加入主畫面」後能不能收 Web Push（D4）。
- `tailscale serve` 是否轉送 WebSocket upgrade 和 SSE。
- Caddy 轉送 SSE 時需要哪些不緩衝設定。

## 13. API 契約 v1（前端依此實作；2026-10-22 定稿）

### 13.1 兩種模式

| 模式 | 判定方式 | 認證 |
|---|---|---|
| local | Host 屬於 `{127.0.0.1, localhost}:{伺服器埠, 18421}`，**而且**請求沒有 `X-Forwarded-For`、`X-Forwarded-Host`、`Forwarded` 任何一個標頭 | 與 v0.2 相同：`GET /api/bootstrap` 取 token，不用配對 |
| public | 伺服器以 `--public-origin https://office.nekonode.cloud` 啟動，而且 Host 完全等於 `office.nekonode.cloud` | cookie 加配對 |

- 不符合上面任何一種的請求，一律回 421。
- 帶有 `X-Forwarded-*` 標頭卻使用 loopback Host，也回 421。這是為了防止經過反向代理的請求冒充本機。

### 13.2 public 模式下不需要 cookie 的路徑

- `GET /`，以及 `GET /<檔名>`：檔名符合 `^[a-z0-9][a-z0-9-]*\.(js|css|svg|png|webmanifest)$`，對應 `office/static/` 下的一般檔案（不能是符號連結）。前端新增靜態檔不必通知後端。
- `GET /api/session`
- `POST /api/pair`

其餘 `/api/*` 都要帶有效的 cookie，否則回 `401 {"error": "...", "pair_required": true}`。`GET /api/bootstrap` 在 public 模式回 404。

### 13.3 寫入規則（public 模式的所有 POST）

以下三項都要滿足：

- `Origin` 必須完全等於 `https://office.nekonode.cloud`，**不能省略**。
- `Content-Type: application/json`
- `X-Office-Token: <token>`。token 由 `GET /api/session` 取得；`POST /api/pair` 不需要 token。

錯誤回應：

- token 不對（例如服務重啟過）：`403 {"error": "頁面已過期，請重新整理。", "token_expired": true}`。前端重新呼叫 `GET /api/session`，然後重試一次。
- Origin 不符：`403`，**沒有** `token_expired` 欄位。

local 模式的規則與 v0.2 相同。

### 13.4 Session 與配對

**`GET /api/session`**

- `200`：
  ```json
  {"mode": "public", "device": {"id": "uuid", "name": "YUI iPhone"}, "token": "...", "version": "0.3.0", "latest_seq": 230}
  ```
  回應同時重新發一次 cookie，有效期往後延 30 天。
  local 模式回 `{"mode": "local", "device": null, ...}`，其餘欄位相同。
- `401 {"error": "需要先配對這台裝置。", "pair_required": true}`

**`POST /api/pair`**，body `{"code": "12345678", "name": "YUI iPhone"}`

- `code`：8 位數字字串。
- `name`：去掉頭尾空白後 1–40 字。

| 回應 | 內容 |
|---|---|
| `201` | `{"device": {...}, "token": "...", "version": "0.3.0", "latest_seq": N}`，同時設定 cookie |
| `400` | 格式不對 |
| `403` | `{"error": "配對碼不正確或已失效。"}`。錯誤、過期、已用過、已作廢，**都回同一句話** |
| `429` | `{"error": "...", "retry_after": 秒數}`，並帶 `Retry-After` 標頭 |
| `404` | local 模式 |

**`POST /api/session/forget`**：撤銷自己這台裝置並清除 cookie，回 `200 {"ok": true}`。

**Cookie**：

```text
__Host-office=<device_id>.<secret>; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=2592000
```

前端讀不到 cookie，也不需要讀。

**配對碼（D3）**：

- 在 VPS 上執行 `python3 -I office.py pair`，會印出 8 位數配對碼和到期時間。
- 有效 10 分鐘，只能用一次。產生新的配對碼時，舊的未用配對碼一律作廢；同一組配對碼累計失敗 10 次也作廢。
- 限速：同一個用戶端 IP 在 10 分鐘內失敗 5 次，就鎖 10 分鐘。IP 取 `X-Forwarded-For` 最右邊那一個，也就是 Caddy 實際看到的位址。

**裝置管理**（只能在 VPS 上用 CLI，或在 local 模式下呼叫）：

- CLI：`office.py devices` 列出裝置；`office.py revoke <device_id>` 撤銷裝置。
- HTTP（local 模式）：`GET /api/devices`、`POST /api/devices/<id>/revoke`。
- 撤銷後：HTTP 請求立即回 401；已連上的 WebSocket 在 2 秒內以 close code 4401 關閉。
- 有效期：裝置的 `last_seen` 超過 30 天就失效。`last_seen` 只在帶 cookie 的 HTTP 請求時更新（最多每 60 秒一次）；WebSocket 流量**不會**延長有效期。所以長時間開著的 WebSocket，在有效期結束時也會在 2 秒內以 4401 關閉。前端每次回到前景都會呼叫 `/api/sync`，正常使用時有效期會一直往後延。

### 13.5 補狀態：`GET /api/sync?after=<int ≥ 0>&limit=<1–1000，預設 500>`

```json
{"latest_seq": 230, "events": [Event, ...], "more": false, "stale": false, "paused": false}
```

- `Event` 的格式：
  ```json
  {"seq": 182, "task_id": "uuid 或 \"_office\"", "at": "ISO8601", "status": "...", "message": "..."}
  ```
- `events` 依 seq 由小到大排列，最多 `limit` 筆。
- `more: true`：後面還有事件。用最後一筆的 seq 當 `after` 再呼叫一次。
- `stale: true`：`after` 比 `latest_seq` 還大，代表資料庫換過。這時 `events` 為空，前端要重抓整份快照。
- `task_id = "_office"` 的事件，`status` 只會是 `paused`、`resumed`、`journal_added`、`file_added` 其中之一；`message` 只是一句說明，不含生活紀錄原文。
- `GET /api/tasks` 的回應新增 `latest_seq` 欄位，與任務清單在同一個 transaction 中讀取，所以兩者一致。

### 13.6 WebSocket：`wss://office.nekonode.cloud/api/ws?after=<seq>`

**握手**

- public 模式：cookie 有效，而且 Origin 完全等於 public origin。
- local 模式：Origin 若有帶，必須等於 `http://<Host>`。
- 握手失敗時回一般的 HTTP 錯誤，不會升級：

  | 狀態碼 | 原因 |
  |---|---|
  | 401 | 未配對或裝置已撤銷 |
  | 403 | Origin 不符 |
  | 400 | 握手標頭不正確 |
  | 426 | 不是 WebSocket 請求 |

  瀏覽器端只會看到連線失敗。前端應該接著呼叫 `GET /api/session`，判斷是不是需要配對。

**伺服器送出的訊息**（文字訊框，內容是 JSON）

1. 一連上先送：
   ```json
   {"type": "hello", "latest_seq": N, "paused": bool, "version": "0.3.0"}
   ```
2. 補送積壓的事件：`after` 之後的每一筆，依序送出：
   ```json
   {"type": "event", "event": Event}
   ```
   - 如果積壓超過 500 筆，或 `after > latest_seq`，改送一則 `{"type": "resync", "latest_seq": N}`，然後從 N 開始接續即時事件。收到 `resync` 時，前端要重抓整份快照。
3. 之後有新事件就即時送出，格式同第 2 點。

**心跳**：伺服器每 20 秒送一個 ping 控制訊框，瀏覽器會自動回 pong。60 秒內沒有收到用戶端的任何訊框，伺服器就以 4000 關閉連線。

**用戶端可以送的訊息**：選用的 `{"type": "ack", "seq": N}`，伺服器記為該裝置最後讀到的位置。其他文字一律忽略。單一訊息上限 4096 bytes。

**指令不走 WebSocket**：交辦、取消、交接、暫停照舊用 POST。

**Close code**

| 代碼 | 意思 | 前端要做什麼 |
|---|---|---|
| 1001 | 伺服器關閉 | 重連 |
| 1002 | 協定錯誤 | 重連 |
| 1009 | 訊息太大 | 重連 |
| 4000 | 閒置逾時 | 重連 |
| 4008 | 同一裝置開了第 3 條連線，最舊的那條被關掉 | 重連 |
| 4401 | 未授權或裝置已撤銷 | **不要重連**，改進配對畫面 |

**前端流程**

1. 第一次打開：先 `GET /api/session`。
2. 依序抓 `GET /api/tasks`（裡面有 `latest_seq`）、`/api/journal`、`/api/files`。
3. 開 WebSocket，帶 `?after=<latest_seq>`。
4. 收到事件時，丟掉 seq 小於或等於已處理 seq 的；其餘依 `task_id` 重抓 `GET /api/tasks/<id>`，同一件任務 1 秒內最多抓一次。
5. 斷線時以退避間隔重連（1、2、4… 最多 30 秒），每次都帶已處理的 seq。
6. 頁面回到前景時：先 `GET /api/sync?after=` 補齊（`more` 為 true 就繼續抓，`stale` 為 true 就重抓整份），再開 WebSocket。

### 13.7 其他

- public 模式的 CSP 加上 `connect-src 'self' wss://office.nekonode.cloud`。
- `VERSION` 改為 `0.3.0`。
- 部署時 service 的 ExecStart 要加 `--public-origin https://office.nekonode.cloud`。**這次不部署。**
- Caddy 必須保留原本的 Host（這是預設行為），也必須附上 `X-Forwarded-For`（也是預設）。

## 12. 不做

- 不改 8421 的監聽位址，不在本文件拍板前部署。
- 不讓手機頁直接操作 VPS 桌面（那是 VNC 接手控制的範圍）。
- 不把生活紀錄自動送給模型（維持 office v2 原規則）。
