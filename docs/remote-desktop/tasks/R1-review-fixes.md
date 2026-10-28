# R1 任務說明（給 Gemini／Antigravity）：獨立審閱後的修正批次

> 派工方式：`agy -p "請讀 docs/remote-desktop/tasks/R1-review-fixes.md 並照做"`。

這批修正來自獨立審閱與 Comment Sicko。規格以本文件為準；其他背景見 `docs/remote-desktop/PRD.md`。你**不能執行終端機指令**，所以 Swift 寫完後由 Claude 編譯與測試。請照現有程式風格寫：

- 四格縮排的 Swift 5。
- 執行緒用 `precondition(Thread.isMainThread)`，不要改成 `@MainActor`。
- 不加註解。

## 只能修改這五個檔案

1. `Sources/NeighborAgentCore/RemoteDesktopHandoff.swift`
2. `Previews/RemoteAgent/RemoteDesktopHandoffModel.swift`
3. `Previews/RemoteAgent/RemoteAgentView.swift`
4. `Previews/RemoteAgent/PreviewRenderer.swift`
5. `Tests/RemoteDesktopHandoffTests.swift`

不要碰 `SSHTunnel.swift`、`docs/`、`scripts/`。不 commit、不切分支。

## A. `RemoteDesktopHandoff.swift`

**A1. 15901 已被佔用時直接失敗**

審閱發現的 bug：如果先前的 ssh 通道沒有結束，它還佔著 15901。這時新的一次接手會在探測時通過，結果開到錯的 VPS。

修法：
- 新增：
  ```swift
  enum SystemLocalPort {
    static func isFree(port: Int) -> Bool
  }
  ```
  實作方式：
  - 用 POSIX `socket(AF_INET, SOCK_STREAM, 0)` 建 socket，**不設** `SO_REUSEADDR`。
  - `bind` 到 `127.0.0.1:port`。`bind` 回傳 0 就是空著。
  - 不論成功或失敗都要 `close(fd)`。
  - port 不在 1024...65535 的範圍內時，回傳 false。
- `RemoteDesktopHandoffController.init` 加一個參數 `isLocalPortFree: @escaping (Int) -> Bool = SystemLocalPort.isFree(port:)`，位置放在 `schedule` 前面，並存成 property。
- 新增常數：
  ```swift
  static let portInUseMessage = "本機 127.0.0.1:15901 已被其他程式佔用，可能是先前沒有結束的 SSH 通道。請用「lsof -nP -iTCP:15901」找出並結束它，再按一次「接手控制」。"
  ```
- `start(_:)` 的順序：
  1. 檢查 `alreadyActive`。
  2. 驗證別名。
  3. 只有 `.linuxVPS` 才呼叫 `isLocalPortFree(RemoteDesktopTarget.vpsLocalPort)`。回傳 false 時：
     - 設定 `self.target = target`。
     - `transition(.failed(Self.portInUseMessage))`，然後 `return`。
     - 不建立通道、不探測、不丟例外、不設定 generation。
  4. 照原本流程繼續。
  - `.macSecondUser` 絕不呼叫這個檢查，因為 5901 本來就應該有伺服器在聽。

**A2. 每次探測不能超過 10 秒期限**

在 `attemptProbe` 呼叫 prober 之前，加入：

```swift
let remaining = deadline.timeIntervalSince(now())
guard remaining > 0 else { end(.failed(Self.probeTimeoutMessage(for: target))); return }
```

這一段需要 `target`，用 `guard let target` 取得。逾時參數改成 `min(Self.probeAttemptTimeout, remaining)`。

**A3. 用明確的方法驗證別名**

- 在本檔新增：
  ```swift
  extension SSHTunnelConfiguration {
    func validate() throws { _ = try arguments() }
  }
  ```
- `start` 改用 `if let configuration { try configuration.validate() }`。

**A4. 拿掉 `attemptProbe` 裡多餘的保護**

把：
```swift
let cancel = …
if generation == token, state == .probing, pendingRetry == nil { cancelProbe = cancel }
```
改回直接寫 `cancelProbe = prober.probe(…) { … }`。

理由：對已完成的探測呼叫 cancel 不會有任何效果，`SystemVNCProbe` 的 `finished` 旗標保證這一點。

**A5. `SystemVNCProbe` 裡的 `finish` 改用明確的結果型別**

- 新增：
  ```swift
  private enum Outcome {
    case answered(Bool)
    case cancelled
  }
  ```
- `finish` 改成接收 `Outcome`。只有 `.answered` 才回呼 completion。
- `finish` 第一行加入 `dispatchPrecondition(condition: .onQueue(queue))`，`queue` 先存成區域常數再讓 closure 捕捉。
- 呼叫端改成：
  - `.answered(…)`
  - `.answered(false)`
  - 逾時：`.answered(false)`
  - cancel：`.cancelled`

**A6. 啟動器參數改成可以測試的純函式**

- 在 `ScreenSharingLauncher` 新增：
  ```swift
  static func arguments(for url: URL) -> [String]?
  ```
  - 網址不符合 `isAllowedViewerURL` 時回傳 nil。
  - 否則回傳 `["-b", bundleIdentifier, url.absoluteString]`。
- `open` 改用它。拿到 nil 時走原本的失敗路徑。

**A7.** `openViewer` 裡 launcher completion closure 的第一行加入 `precondition(Thread.isMainThread)`。

## B. `RemoteDesktopHandoffModel.swift`

- 新增 `var canStop: Bool { state == .probing || state == .viewerOpened }`。
  - 原因：正在開啟螢幕共享時，結束已經攔不住視窗跳出來，所以這時不能按。
- `statusText`：當 `errorMessage != nil` 時回傳 nil。
  - 原因：避免舊的「已結束接手」和新的錯誤同時顯示。

## C. `RemoteAgentView.swift`

「結束接手」按鈕加上 `.disabled(!handoff.canStop)`，其他不動。

## D. `PreviewRenderer.swift`

- 拿掉 `readings` 計數器的寫法，改成具名的假時鐘：
  ```swift
  private final class FixtureClock {
    private(set) var now = Date(timeIntervalSince1970: 0)
    func schedule(_ delay: TimeInterval, _ item: DispatchWorkItem) {
      now = now.addingTimeInterval(delay)
      item.perform()
    }
  }
  ```
- `handoffFixture` 建立一個 clock，並傳入：
  - `schedule: clock.schedule`
  - `now: { clock.now }`
  - `isLocalPortFree: { _ in true }`

## E. `Tests/RemoteDesktopHandoffTests.swift`

**修改既有程式**
- `FakeProbe`：拿掉 `precondition(timeout == …)`，改成記錄 `timeouts: [TimeInterval]`。
- `Harness.init` 加一個參數 `portFree: Bool = true`，並傳給 controller 的 `isLocalPortFree`。
  - `Harness(allowTunnel: false)` 的語意維持不變。
- 「real probe: a closed port fails within the timeout」：timeout 改成 5，斷言 `seconds < 0.5`。
  - 原因：刪掉 `.waiting` 那個分支時，這個測試必須失敗。

**新增情境**：每個都用 `check("…")` 包起來，期望值依需求推導，不要拿程式算出來的結果當期望值。

1. `VPS fails fast when 15901 is already in use`
   - 條件：`Harness(allowTunnel: false, portFree: false)`。
   - 斷言：
     - `state == .failed(portInUseMessage)`。
     - `probe.ports` 是空的。
     - `launcher.urls` 是空的。
2. `second user mode never checks the local port`
   - 條件：`isLocalPortFree` 傳入一個會 `preconditionFailure` 的 closure。直接建立 controller，不用 Harness。
   - 斷言：`start(.macSecondUser)` 之後 `state == .probing`。
3. `no probe attempt may run past the 10 s deadline`
   - 做法：一直回答 false、執行 `time.runNext()`，直到 state 不再是 probing。
   - 斷言：
     - `probe.timeouts.count == 20`。
     - 每個 timeout 都 ≤ 2。
     - 最後三個依序是 `1.5, 1.0, 0.5`。
4. `stale SSH exit from a previous VPS run cannot end the next run`
   - 準備：兩個 `FakeSSHProcess`，由 `makeProcess` 依序取出。
   - 步驟：
     1. 第一次 start。
     2. 存下 `first.onExit`。
     3. `stop()`。
     4. 第二次 start。
     5. 呼叫存下來的 `late(255)`。
   - 斷言：
     - `state == .probing`。
     - `second.starts == 1`。
5. `Screen Sharing launcher builds only the fixed argument array`
   - `vnc://127.0.0.1:15901` 應得到 `["-b", "com.apple.ScreenSharing", "vnc://127.0.0.1:15901"]`。
   - `vnc://example.com:5901` 應得到 nil。
   - `vnc://u:p@127.0.0.1:5901` 應得到 nil。
6. `real probe sends nothing to the server`
   - 準備：`LoopbackServer` 新增 `receivedBytes`。每個連線都持續 `receive`，並累計收到的位元組數，在 main queue 上更新。
   - 步驟：對送出 RFB banner 的伺服器做探測，完成後再跑 0.2 秒 RunLoop。
   - 斷言：`receivedBytes == 0`。
7. `real probe: cancel after completion never calls back again`
   - 步驟：
     1. 對 RFB 伺服器探測，記錄回呼次數。
     2. 完成後呼叫回傳的 cancel。
     3. 再跑 0.3 秒 RunLoop。
   - 斷言：回呼次數 == 1。
8. `real port check reports a held port as busy and a released one as free`
   - 步驟：
     1. 建立 `LoopbackServer(greeting: nil)`。
     2. 確認 `SystemLocalPort.isFree(port: server.port) == false`。
     3. `close()`。
     4. 最多輪詢 2 秒。
   - 斷言：`isFree` 變成 true。
9. `panel: stop is disabled while the viewer is launching`
   - 準備：第二使用者模式。
   - 斷言：
     - probing 時 `canStop == true`。
     - 回答 true 後是 openingViewer，此時 `canStop == false`。
     - launcher 回傳 true 後是 viewerOpened，此時 `canStop == true`。
10. `panel: an invalid alias after a stop shows only the error`
    - 步驟：
      1. 先用第二使用者模式完成一次接手，再 `stop()`。
      2. 換成 VPS，別名設為 `"bad alias"`，執行 `start()`。
    - 斷言：
      - `statusText == nil`。
      - `failureMessage == SSHTunnelError.invalidAlias.errorDescription`。

## 完成時

在對話裡列出改了哪些檔案、新增了哪些測試，以及你不確定能否編譯的地方。Claude 會編譯、跑測試，有錯會再交回給你。
