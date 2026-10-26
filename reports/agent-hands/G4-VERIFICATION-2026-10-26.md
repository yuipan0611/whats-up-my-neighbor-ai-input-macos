# G4 驗證紀錄：接手、停手確認、控制世代、交還前重新觀察（2026-10-26）

證據分類照 ADR-001 第 8 節：

- **自動測試＋模擬：** 真的 office、broker、接手狀態機、worker、adapter 程式；瀏覽器與 Codex 用假程式。
- **真 Chrome（Mac 本機）：** Google Chrome 155.0.8059.86 headless、暫存 profile、本機合成網站、虛構帳密。
- **NOT RUN：** 列在最後。

環境：macOS 27.0.1、Python 3.14.6。沒有動 VPS、沒有部署、沒有用真帳號或真網站。

## 實作

| 檔案 | 內容 |
|---|---|
| `office/browser_control.py`（新） | 接手狀態機（ADR-002 第 6 節）：agent_running → taking_control → human_control ⇄ human_disconnected → resuming → agent_running，任何一步都可能進 held。狀態存在 `browser_sessions`，用交易與 store lock 做 compare-and-swap |
| `office/browser_actions.py` | resuming 狀態只放行 take_snapshot（交還前的重新觀察），其他動作照樣擋 |
| `office/browser_cdp.py` | **順手修 G3 的漏洞：** 快照名稱以前會拿輸入框的 value。現在輸入框只用 label／placeholder／name；密碼與驗證碼欄位標成 `secret` |
| `office/office.py` | owner 路由 `POST /api/viewer/control`、`GET /api/viewer/state`；worker 路由 `POST /api/worker/browser/control-ack`；heartbeat 回覆加 `{hold, control_epoch, control_state}`；有人接手時不發新任務；撤銷操作者裝置（網頁、`/api/session/forget`、CLI）即轉 held |
| `office/hands/worker.py` | broker 模式的任務拆成多輪。每 1 秒問一次控制狀態（續租也在這裡），要停時停掉整個程序群組，確認群組清空才回報停手；暫停期間不算進 30 分鐘；交還後由 broker 重新觀察，新一輪 agent 只拿到遮蔽過的項目清單 |

### 規則

- **我來（take）：**
  1. 先把狀態切到 taking_control 並增加世代，從這一刻起 broker 不再派送新動作。
  2. 已經派送的動作等它做完（最多 5 秒）；等不到就轉 held，畫面顯示還在停手。
  3. 有 agent 在跑時，要等 worker 回報 `stopped`，辦公室再查在途動作表，才開放人工輸入。沒有 agent 時直接開放。
- **停手：**
  - worker 對整個程序群組送 SIGTERM／SIGKILL，確認群組裡沒有程序才回報。只停主程序不算。
  - 5 秒內沒確認，轉 held，**不會**自動開放輸入。
- **多裝置：**
  - 另一台按「我來」會換操作者並增加世代，原裝置的輸入與 ping 一律拒絕。
  - `input_allowed(device, epoch)` 是每批人工輸入要過的檢查：必須是目前操作者、目前世代，而且還連著。
- **斷線：** 操作者 15 秒沒 ping，轉 human_disconnected，不會因為時間到就交還；要重新連上，得再按一次「我來」。
- **重啟：** 辦公室重啟時，taking_control 與 resuming 轉 held，human_control 轉 human_disconnected，都不會回到 agent。
- **交還（return）：**
  1. 由已配對裝置明確送出，世代再加一，舊快照與舊目標全部失效。
  2. 還有任務在跑就進 resuming，由 broker 自己取新快照。worker 附上 snapshot_id 回報 `observed`，辦公室核對這張快照屬於同一個 session、同一件任務、目前世代，才回到 agent_running。
  3. 新快照裡還有密碼／驗證碼欄位就轉 held，請人完成。
  4. 交還同時清掉「結果待核對」的封鎖，紀錄寫 `reconcile_acknowledged`。
- **取消：** 暫停期間取消任務，worker 下一次心跳就結束這件；之後交還不會讓它復活。
- **舊模式任務：** legacy worker 不懂這套協定，所以舊模式任務在跑時，「我來」回 409，不假裝已接手。
- **同一個 operation_id：** 重送不會讓世代加第二次；內容不同回 409。
- **紀錄：** 接手事件寫進 `browser_audit_events`（control_requested／taken／held／disconnected／return_requested／released）。紀錄表壞了，接手仍會生效，broker 也不派送。

## 測試結果

**彙總：**
- 完整測試組 170 項全部通過。其中瀏覽器相關 56 項：G1／G2 22 項、adapter 5 項、G4 模擬 22 項、真 Chrome 7 項（G4 新增 2 項）。
- Mutation 21 組抓到 20 組：
  - take 不增加世代
  - take 不等 worker 停手
  - take 不等在途動作
  - ack 不比對世代
  - observed 接受舊快照
  - 敏感頁照樣交還
  - 停手逾時直接開放輸入
  - 斷線自動交還
  - 重啟後人控交回 agent
  - 輸入不查操作者
  - 接手中照樣派新任務
  - 撤銷不關輸入
  - 交還跳過重新觀察
  - resuming 放行任何工具
  - heartbeat 不帶控制欄位
  - 只停主程序
  - 暫停時間算進 30 分鐘
  - 辦公室連不上就放行
  - 殘留程序仍確認停手
  - 快照名稱含輸入值
- 另 1 組「ack stopped 不查在途」是**等價突變**：同一個請求前面的 `gate_clear` 已經查過在途動作表，單獨拔掉這一層，另一道牆還在。

### 自動測試＋模擬（`office/tests/test_browser_control.py`）

**狀態機（假時鐘）：**
- 沒有 agent 時直接接手，舊世代作廢。
- operation_id 冪等與衝突。
- 有 agent 時要等停手確認：舊世代、錯誤 lease 都不算數。
- 停手 5 秒沒確認轉 held，之後晚到的確認也不會開放輸入。
- 第二台接手後，第一台失去輸入。
- 斷線之後過了 24 小時仍是暫停。
- 交還時拒絕舊快照與「沒附快照」；交還後舊目標回 409。
- 交還時還在登入頁，轉 held。
- 重啟後每種中間狀態都維持暫停，也不發新任務。
- 撤銷操作者。
- 取消後交還，任務不會復活。
- 紀錄表壞掉時，接手照樣停住。
- 舊模式任務不能接手。
- 在途動作先做完，才記錄 control_taken；在途動作一直不結束，轉 held。
- 結果待核對的封鎖，要由人交還才解除。
- 任務被重新排隊後，新一輪要用新 lease 觀察。

**worker 整合（假 Codex 會開 adapter 與一個工具子程序）：**
- **接手時：**
  - Codex、adapter、工具子程序全部停掉。
  - 暫停 7 秒，比整件的時間上限 6 秒還長，期間 lease 持續續租，沒有任何呼叫碰到瀏覽器。
- **交還後：**
  - 第一個瀏覽器呼叫是 broker 的重新觀察。
  - 新一輪 agent 拿到交還說明，用舊目標點擊被拒（stale），重新觀察後完成任務。
  - lease 不在 agent 看得到的任何地方。
- **程序樹有殘留時：** 不回報停手，狀態轉 held。
- **暫停中取消：** worker 結束這件，交還後也不會出現第二輪。
- **worker 在暫停中死掉：**
  - 辦公室連不上時仍維持暫停，任務重新排隊。
  - 接手期間不發任務。
  - 交還之後新一輪領到任務，舊目標回 `stale_snapshot`，沒有碰到瀏覽器。
- **路由權限：** 只有擁有者能接手／交還、看狀態；worker socket 叫不到；本機入口叫不到 control-ack。

### 真 Chrome（Mac 本機，`office/tests/test_browser_chrome.py` 新增 2 項）

1. **在途動作與交還前重新觀察：**
   - **接手：**
     - 一個 2 秒才回應的導航還在進行時按「我來」：接手等它做完才回應（實測等了 1.73 秒），那個導航記為成功、沒有被撤回。
     - worker 確認停手後才開放輸入。
   - **人在登入頁：**
     - 人經由 CDP（模擬 viewer 的輸入）打開虛構登入頁，輸入虛構密碼。
     - 交還時重新觀察發現密碼欄位，轉 held。
     - 快照與資料庫檔案都找不到那個虛構密碼。
   - **再交還：**
     - 人改到說明頁再交還，重新觀察看到「回首頁」，回到 agent_running。
     - agent 用接手前的快照點擊，回 `stale_snapshot`。
   - **期間的網站紀錄：** 接手期間網站只收到人自己打開的兩個頁面。
2. **worker 整條路（只有 Codex 是假的）：**
   - 路徑：假 Codex → adapter → proxy → office → broker → 真 Chrome。
   - 接手後，Codex／adapter／工具子程序全部停掉，停手確認 0.19 秒。
   - 人把頁面換到說明頁再交還。新一輪拿到的交還說明含「回首頁」（交還後觀察到的頁面）。用舊目標點擊被拒，網站沒有收到 agent 的那次點擊。

### 實測數字（只代表這台 Mac、本機測試條件）

- 停手確認：模擬 0.12–0.13 秒，真 Chrome＋假 Codex 0.19 秒。測試的輪詢間隔設成 0.2 秒，正式預設是 1 秒，所以正式環境預期會比較慢。ADR 的 1 秒／5 秒仍是工程預算，不是已驗證的效能。
- 接手等在途動作：1.73 秒（合成網站故意延遲 2 秒）。

## 不能宣稱的

- **只保證經過 broker 的路。** G0 的旁路都還在：同 UID 下 agent 的 shell 可直連 CDP、讀 profile、連 X 桌面，也可以用 setsid 讓程序脫離群組，躲過「停整個群組」。要封住得改 D13，本次沒改。
- **viewer 還沒做：**
  - noVNC 畫面、「我來／交還」按鈕、人工輸入通道都沒做。
  - `input_allowed` 是給 viewer 每批輸入用的檢查，目前沒有接上任何真輸入；測試裡「人的操作」是用 CDP 模擬的。
- **D11 通知沒做：** 斷線超過 2 分鐘的「有 1 件等你」還沒做，目前只有 `waiting_seconds` 給畫面用。
- **真 Codex 沒驗證：** 沒驗證真 Codex 被 SIGTERM／SIGKILL 時的行為，也沒驗證重開後的 MCP 啟動時間。
- **背景網站照樣在跑：** 接手期間背景網站本身繼續執行，不代表網頁凍結。

## NOT RUN

- VPS（未部署；部署需另行授權）。
- 真 Codex 跑接手／交還。
- 有畫面的 Chrome 與 noVNC viewer、Mac App、iPhone 上的接手按鈕與輸入。
- D11 斷線通知。
- G5（撤銷、故障、回退演練）。
- H3 未完成項目。ADR-002 第 8 節寫「G3 與 G4 前先補 H3 現有缺項」，這次依指示先做 G4，H3 缺項仍待補：惡意內容（只用無害標記）、連續多件資源紀錄、2 GB 磁碟上限、重開機、A01、D13 註記。
