# G3 驗證紀錄：受限瀏覽器 adapter 接上 broker 與真 Chrome（2026-10-26）

證據分類照 ADR-001 第 8 節，本文件分三類：

- **真 Chrome（Mac 本機）：** Google Chrome 155.0.8059.86 headless，每次用新的暫存 profile，只開本機合成網站（127.0.0.1 隨機埠）與虛構資料。
- **自動測試＋模擬：** 真的 office、broker、worker、adapter 程式；Codex 用假程式代替，瀏覽器用假瀏覽器。
- **NOT RUN：** 沒做的，列在最後。

環境：macOS 27.0.1、Python 3.14.6。沒有動 VPS、沒有部署、沒有用真帳號或真網站、沒有讀任何真秘密。

## 實作

| 檔案 | 內容 |
|---|---|
| `office/browser_cdp.py`（新） | broker 自己的手：標準庫 WebSocket＋DevTools。只做固定操作（列可操作目標、讀可見文字、截圖、導航、點連結），script 寫死在檔案裡，不收 agent 給的 script。快照與讀取在**隔離的 JavaScript world** 執行，頁面改寫 DOM 方法騙不到它。點擊前再核對元素：必須是 `<a>`，且 scheme＋host＋path 跟快照時相同，否則不點 |
| `office/hands/browser_adapter.py`（新） | broker 模式下 agent 唯一的瀏覽器工具：stdio MCP server，6 個固定工具（observe_page、read_page、screenshot、open_url、click、type_text），參數不收額外欄位。每次呼叫產生新的 action_id，送到 worker 的 proxy。交人處理時回一段話叫 agent 停下、在成果寫明要使用者按哪裡；失敗就是失敗，**沒有退回 raw 工具的路** |
| `office/hands/worker.py` | 新增 `BrokerProxy`：每件 broker 任務一個 Unix socket，放在 0700 暫存資料夾。只收 5 個欄位，由 proxy 加上 task_id、lease、當下的控制世代再轉給 office；回覆不含 lease。broker 模式卻沒設定 adapter：任務直接記為失敗，不啟動 agent。新參數 `--adapter` |
| `office/browser_actions.py` | 快照目標多保留 role／href／index；新增 `state()` 回傳目前控制世代 |
| `office/office.py` | worker-only 路由 `POST /api/worker/browser/state`（沒設定 broker 時 404）；啟動參數 `--browser-cdp http://127.0.0.1:<port>`，只接受 loopback，沒給就維持 legacy，給了之後**新交辦**的「手」任務才是 broker 模式 |

## 測試結果

完整測試組 146 項全部通過。其中瀏覽器相關 32 項：G1／G2 22 項、adapter 5 項、真 Chrome 5 項。

### 真 Chrome（Mac 本機，暫存 profile＋合成網站）

`office/tests/test_browser_chrome.py`，5 項通過：

1. **讀取、導航、點連結：**
   - 合成首頁故意改寫 `document.querySelectorAll`，快照仍列出 說明／登出（link）、刪除帳號（button）、搜尋（textbox）。
   - 點「說明」成功，讀到說明頁文字；用舊快照再點，回 409 `stale_target`。
   - 截圖存成 PNG。
2. **有效果的操作交人處理：**
   - 點「登出」連結、點「刪除帳號」按鈕、在搜尋框輸入，都是 `needs_human`／`not_dispatched`。
   - `evaluate_script`、`take_heapsnapshot` 回 403；`javascript:` 網址回 403。
   - 合成網站的伺服器紀錄證實**從沒收到** `GET /logout` 或 `POST /delete`。
3. **同一份文件裡元素換位置：**
   - 頁面在快照後插入一個指向 `/logout` 的連結，佔掉原本的位置；文件版本（loaderId）不變，所以世代檢查擋不到。
   - 點擊前的元素核對擋下了這次點擊，結果為 `failed`，伺服器沒收到 `/logout`。
4. **第二道牆：** 直接叫 CDP 這一層點按鈕，會拋出 BrowserFailed，伺服器沒收到 `/delete`。
5. **整條路串起來（只有 Codex 是假的）：**
   - 路徑：假 Codex → 真 adapter → worker proxy → office worker socket → broker → 真 Chrome → 合成網站。
   - 依序：開首頁（允許）、觀察（允許）、點「登出」（needs_human，agent 收到停止訊息）、點「說明」（允許，真的換頁）、讀頁面（讀到說明頁文字）。
   - 紀錄表決策依序 allow、allow、needs_human、allow、allow。
   - 伺服器有收到 `/docs.html`，沒有收到 `/logout`；任務以 incomplete 結束。

測試結束後確認沒有殘留的 Chrome 程序，也沒有殘留的 proxy socket 資料夾。

**啟動煙霧測試（真程序）：**
- `office.py --browser-cdp http://example.com:9222` 拒絕啟動（不是 loopback）。
- 接本機暫存 Chrome 啟動，印出 `browser broker ON`。
- 同一個 worker 路由：開 broker 時回「找不到這件工作」，沒開時回「瀏覽器 broker 模式沒有開」。
- 程序與暫存資料夾都已清掉。

### 自動測試＋模擬（假 Codex 啟動真 adapter）

`office/tests/test_browser_adapter.py`，5 項通過：

- 假 Codex 依 worker 給的 `-c mcp_servers.browser.*` 設定啟動 adapter，`tools/list` 剛好只有那 6 個工具。
- 一件任務裡依序：開網址（允許）、觀察（允許）、點按鈕（`needs_human`，agent 收到「使用者親手做」）、叫 `evaluate_script`（工具不存在，錯誤）、開 `javascript:`（拒絕，`scheme_not_allowed`）。
  - 假瀏覽器只收到 navigate 與 take_snapshot。
  - 紀錄表的決策依序是 allow、allow、needs_human、deny。
- agent 看到的設定、參數、環境變數裡沒有 lease，也沒有 raw MCP 的指令。
- broker 模式沒設定 adapter：任務記為失敗（「瀏覽器的受限工具沒有設定」），agent 沒啟動，瀏覽器沒被叫。
- 直接連 proxy socket：
  - 正常請求回 200，回覆不含 lease。
  - 自帶 `control_epoch`、`task_id`、`lease` 一律 400。
  - 這一項重要，因為同 UID（D13）時 agent 的 shell 可以直接連這個 socket。
- adapter 連不上 proxy：回錯誤、不執行；多帶參數在送出前就被擋。

### Mutation

12 組裡 10 組被抓到：

- needs_human 當成功
- adapter 不檢查參數
- adapter 多一個 raw 工具
- 沒 adapter 時退回 raw
- broker 模式仍用 raw MCP
- proxy 不檢查欄位
- lease 漏進 agent 環境變數
- proxy 把 lease 回給 agent
- 點擊前不核對元素
- 快照不用隔離 world

另 2 組是**等價突變**，單獨拔掉時另一道牆還在：

- **「proxy 讓 agent 自帶 epoch」**：欄位檢查先擋下，`control_epoch` 根本進不來。
- **「CDP 這層按鈕也可點」**：元素核對要求 `<a>`，仍會擋下。

## 不能宣稱的

- **只保證經過 adapter／broker 的那條路。**
  - G0 的旁路都還在：agent 的 shell 可直連 CDP、讀 Chrome profile 與 Codex 登入檔、連 X 桌面。
  - 現在多了一條：同 UID 下 agent 可以直接連 proxy socket。這條路受的限制跟 adapter 相同，但它本身也是旁路。
  - 要封住這些旁路得改 D13（同 UID），本次沒改。
- 真 Chrome 是 Mac 上的 headless Chrome 155，不是 VPS 上那個有畫面、有登入狀態的 Chrome 156。
- 「needs_human 卡片」目前只做到兩件事：agent 收到停止訊息，紀錄表寫入 needs_human（擁有者可用 `GET /api/tasks/<id>/actions` 查）。App／網頁上的卡片還沒做。

## NOT RUN

- 真的 Codex 透過 adapter 跑完整任務（本機沒有已登入的 Codex 可用於此，且這則不授權動 VPS）。
- VPS 部署與 VPS 上的真 Chrome（未部署；部署時 release 要多包 `office/browser_cdp.py`、`office/hands/browser_adapter.py`，worker 服務要加 `--adapter`，office 服務要加 `--browser-cdp http://127.0.0.1:9222`）。
- needs_human 在 Mac App／iPhone 上的卡片顯示。
- G4（接手屏障）、G5（撤銷與回退）。
- H3 未完成項目：惡意內容（只用無害標記）、連續多件資源紀錄、2 GB 磁碟上限、重開機、A01、D13 註記。
