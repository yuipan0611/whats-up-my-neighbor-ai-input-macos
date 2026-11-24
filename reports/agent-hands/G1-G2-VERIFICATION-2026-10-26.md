# G1／G2 驗證紀錄：瀏覽器動作 broker 與可信任紀錄（2026-10-26）

證據分類照 ADR-001 第 8 節：本文件全部是**自動測試＋模擬**，用假瀏覽器和虛構資料，在 Mac 本機執行。**沒有真 Chrome、沒有 VPS、沒有 Mac App 或 iPhone 實測**，也沒有部署。

## 實作

| 檔案 | 內容 |
|---|---|
| `office/browser_actions.py` | broker：固定工具表與規則（`browser-policy-1`）、請求格式驗證、lease／控制世代／暫停／模式檢查、快照目標解析、先寫決策再派送、每個瀏覽器一道派送閘門（閘門內再檢查一次世代與頁面版本）、重送不重派、結果不明不重送、結果寫不進去就封鎖、重啟時把沒有結果的動作轉成 unknown |
| `office/browser_audit.py` | 資料表 `browser_sessions`、`browser_snapshots`、`browser_actions`、`browser_audit_events`（只新增、應用層沒有修改或刪除的路徑）；網址只記 origin；provenance 分成 broker_observed／worker_reported／human_control_event |
| `office/office.py` | 只新增欄位 `tasks.initiator_kind`、`tasks.browser_mode`，可重跑；worker-only 路由 `POST /api/worker/browser/action`；擁有者路由 `GET /api/tasks/<id>/actions?after=&limit=`；模式在交辦時固定，預設 legacy；`python3 -I` 下自己把程式所在資料夾加進匯入路徑 |

**規則摘要：**
- **允許：** 讀取類（快照、文字、截圖）。
- **一般導航：** http／https 允許；javascript:、file:、網址裡帶帳密一律拒絕；看起來像動作的路徑（logout、delete、checkout、pay、send、merge…）交人處理。
- **點擊：** 只有指向可導航網址的連結可以；按鈕交人處理。
- **交人處理：** 輸入、送出、上傳、下載。
- **拒絕：** 任意 script、網路流量、記憶體快照、錄影，以及未知工具。

順序：停止或舊 lease → 控制狀態 → 拒絕 → 交人處理 → 允許；沒有符合的規則就不執行。

## 測試（自動測試＋模擬）

- `office/tests/test_browser_actions.py` 22 項全部通過，完整測試組全部通過（Mac，Python 3.14）。
- **涵蓋 ADR-002 第 8 節適用於 G1／G2 的負向案例：**
  - 同一個 action_id 不重派；換參數回 409。
  - 舊 lease、舊世代、接手中、暫停或收回、legacy 模式，都不派送。
  - 未知工具與 raw 工具拒絕。
  - 導航換代後，舊目標不派送；舊世代的快照不能用。
  - 決策寫不進去就不派送（503）。
  - 逾時記為 unknown，之後不重送；明確失敗記為 failed，不會變成成功。
  - 結果寫不進去就封鎖整個 session；重啟後把沒有結果的動作轉成 unknown 並封鎖。
  - 派送中有人要接手：接手等派送完成；已經通過檢查、還在等閘門的動作，在接手後不會被派送。
  - 擁有者用 cursor 分頁查詢；worker socket 看不到歷史；本機入口叫不動 worker 路由；broker 模式關閉時路由回 404。
  - 舊資料庫遷移後保留舊任務，可以重跑。
- **敏感值：** 直接掃資料庫檔案的位元組，確認沒有輸入文字（虛構密碼）、query、fragment，也沒有 lease。
- **Mutation：** 14 組全部被抓到，包括：重送再派送、換參數照舊回覆、不檢查世代、接手中照樣派送、派送前不再檢查、舊目標照樣派送、未知工具放行、動作型網址當讀取、按鈕可點、紀錄存完整網址、重啟不轉成 unknown、結果寫不進去不封鎖、不檢查 lease、逾時當成功。

## 不能宣稱的

- 這些只證明**經過 broker 的動作**受控。G0 實測：agent 的 shell 仍能直連 CDP、讀 Chrome profile 與 Codex 登入檔、連 X 桌面，所以「所有瀏覽器動作都受控」**不成立**。
- 目前 VPS 上跑的仍是 legacy worker（直接用 raw MCP、自動核准）。broker 還沒接上真的 Chrome（G3），也沒有部署。

## NOT RUN

- 真 Chrome 的 broker 派送（G3）。
- 接手狀態機與 viewer（G4）。
- 撤銷與回退演練（G5）。
- VPS、Mac App、iPhone 的任何實測。
- H3 的未完成項目（見 G0 報告第 6 節）。
