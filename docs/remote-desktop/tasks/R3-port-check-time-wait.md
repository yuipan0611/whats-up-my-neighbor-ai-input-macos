# R3 任務說明（給 Gemini／Antigravity）：15901 佔用檢查改為「有沒有人在監聽」

> 派工方式：`agy -p "請讀 docs/remote-desktop/tasks/R3-port-check-time-wait.md 並照做"`。

## 為什麼要改（2026-10-20 實測）

`scripts/check-vps-path-loopback.sh` 實際透過 SSH 轉送，讓螢幕共享連上 15901。之後執行 `controller.stop()`，ssh 也正常結束了。但 `SystemLocalPort.isFree(port: 15901)` 在之後 5 秒內一直回傳 false，雖然 `lsof` 確認已經沒有任何程式在監聽 15901。

原因如下：
- 剛斷掉的轉送連線會讓 `127.0.0.1:15901` 進入 TCP TIME_WAIT，大約 30 秒。
- 現在的實作用不設 `SO_REUSEADDR` 的 `bind`，在 TIME_WAIT 期間一定失敗。

對使用者的影響：結束接手後 30 秒內再按一次「接手控制」，會被誤報為「15901 已被其他程式佔用」。

這個檢查原本要擋的是：舊的 ssh 通道還在 15901 **監聽**。所以應該檢查「有沒有人在監聽」，而不是「能不能 bind」。

## 只能修改兩個檔案

- `Sources/NeighborAgentCore/RemoteDesktopHandoff.swift`
- `Tests/RemoteDesktopHandoffTests.swift`

不改其他檔案、不 commit、不執行終端機指令、不加註解。

### A. `SystemLocalPort.isFree(port:)` 改成用 connect 判斷

- port 不在 1024...65535 的範圍內時，回傳 false（不變）。
- 用 `socket(AF_INET, SOCK_STREAM, 0)` 建 socket，用 `defer` 關閉。
- 對 `127.0.0.1:port` 做阻塞式 `connect`。對 loopback 來說，結果會立即回來。
  - `connect` 回傳 0：有人在監聽，回傳 **false**。
  - `connect` 回傳 -1 且 `errno == ECONNREFUSED`：沒有人在監聽，回傳 **true**。
  - 其他失敗，包含 socket 建立失敗：保守處理，回傳 **false**。

### B. 新增測試情境（放在既有的 real port check 測試後面）

`check("real port check: a port left in TIME_WAIT without a listener counts as free")`

1. 建立 `LoopbackServer(greeting: Data("RFB 003.008\n".utf8))`，並記下 port。
2. 用 `SystemVNCProbe().probe(port:timeout:)` 連一次，等它完成。這樣會建立一條真實連線。
3. 呼叫 `server.close()`。伺服器端會先關閉已接受的連線再關 listener，伺服器那一端的 port 因此進入 TIME_WAIT。
4. 跑 0.2 秒 RunLoop。
5. 斷言 `SystemLocalPort.isFree(port: port) == true`。

這個情境在舊的 bind 實作下必須失敗，Claude 會用舊實作驗證這一點。

既有的 `real port check reports a held port as busy and a released one as free` 保持不變，新實作也必須通過。

## 完成時

列出改動，並說明 TIME_WAIT 測試在你看來是否可能不穩定。

## 補充：R3b，第一版測試沒有重現 bug，請改寫

Claude 驗證發現：第一版的 TIME_WAIT 測試在**舊的 bind 實作**下也會通過。

原因是 TIME_WAIT 只會出現在先關閉連線的那一方。`SystemVNCProbe` 讀完就關，所以先關的是客戶端，TIME_WAIT 落在客戶端的臨時埠，伺服器的埠沒有受影響。實測時則是 ssh（伺服器端）在螢幕共享還連著時先關。

Claude 的原型證實，下面的順序可以重現：舊實作得到 `isFree=false`，新實作得到 `true`。請把 `real port check: a port left in TIME_WAIT without a listener counts as free` 改寫成這個順序：

1. `let server = try LoopbackServer(greeting: nil)`，記下 `port`。
2. 建立客戶端並等它連上（最多 2 秒）：
   ```swift
   let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
   client.start(queue: .main)
   ```
   用 RunLoop 輪詢 `client.state == .ready`。
3. 再跑 0.1 秒 RunLoop，讓伺服器接受這條連線。
4. `server.close()`：伺服器先關閉已接受的連線與 listener，這時客戶端仍然連著。
5. 跑 0.2 秒 RunLoop 後，執行 `client.cancel()`。
6. 再跑 0.3 秒 RunLoop。
7. 斷言 `SystemLocalPort.isFree(port: port) == true`。

只改這個測試情境，不改其他地方，不加註解。
