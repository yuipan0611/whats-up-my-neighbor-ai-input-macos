# T5d 任務說明（給 Gemini／Antigravity）：真實 VPS 長時間連線與網路中斷

> 派工方式：`agy -p "請讀 docs/remote-desktop/tasks/T5d-real-vps-long-and-drop.md 並照做"`。

## 目的

`reports/REMOTE_DESKTOP_VPS_2026-10-21.md` 列出兩項尚未驗證：真實 VPS 上的長時間連線，以及網路中斷時會不會顯示「通道已中斷」。這次在使用者既有的 `neighbor-vps`（Ubuntu 26.04，帳號 neighbor，無 sudo）上實測。

- 全程不打開螢幕共享，改用記錄用的假啟動器，所以不需要人輸入密碼。
- 不需要 root，也不改任何系統設定。

## 只能新增這兩個檔案

不改既有檔案、不 commit、不執行終端機指令、不加註解。

### 1. `Tests/RemoteDesktopVPSDropCheck.swift`

- `@main enum RemoteDesktopVPSDropCheck`。
- 參數：
  - `--alias`：預設 `neighbor-vps`。
  - `--hold-seconds`：預設 600。
  - `--drop-timeout`：預設 120。
- `final class RecordingLauncher: RemoteViewerLaunching`：記錄收到的 URL，並在 main queue 上非同步回呼 `completion(true)`。
- 控制器：
  ```swift
  RemoteDesktopHandoffController(launcher: RecordingLauncher())
  ```
  其他參數都用預設值：真實的 `SSHTunnelController`（讀使用者的 `~/.ssh/config`）、真實探測、真實埠號檢查。
- 每次 `onStateChange` 都印出 `state: …`，並在每一行前面加上距離啟動的秒數，格式 `[t=12.3s]`。

**流程**

1. `start(.linuxVPS(hostAlias: alias))`，跑 RunLoop 直到 `.viewerOpened`，最多 30 秒。逾時就印 `final state`，以結束碼 1 結束。
2. 長時間連線階段，持續 `--hold-seconds`。每 10 秒做一次檢查，並印出 `alive t=… state=… listener=… probe=…`：
   - `controller.state == .viewerOpened`
   - `SystemLocalPort.isFree(port: 15901) == false`，代表 15901 仍有人在監聽。
   - 用 `SystemVNCProbe().probe(port: 15901, timeout: 3)` 經由通道探測，結果為 true。

   任一項失敗就印 `hold failed at t=…`，以結束碼 3 結束。
3. 長時間連線階段結束後：
   1. 印出 `HOLD_DONE`。
   2. 用 `FileManager.default.createFile(atPath: "<ready 檔路徑>", contents: nil)` 建立 ready 檔。路徑由 `--ready-file` 參數指定，必填。
   3. 進入等待中斷階段，跑 RunLoop，直到 state 變成 `.failed`，最多 `--drop-timeout` 秒。
4. 若變成 `.failed(message)`：
   1. 印出 `DROP_DETECTED after=<從 HOLD_DONE 起算的秒數>s message=<message>`。
   2. 再輪詢最多 5 秒，直到 `SystemLocalPort.isFree(port: 15901) == true`，並印出 `tunnel released: true/false`。
5. 結束碼：
   - 0：`message == RemoteDesktopHandoffController.tunnelLostMessage`，而且 tunnel released 為 true。
   - 4：等待中斷逾時。
   - 5：訊息不符，或埠號沒有釋放。
   - 結束前一律印出 `final state`。

### 2. `scripts/check-real-vps-drop.sh`

zsh，`set -euo pipefail`，`ROOT="${0:A:h:h}"`。`ALIAS="${VPS_ALIAS:-neighbor-vps}"`，`HOLD="${HOLD_SECONDS:-600}"`，`WORK="$ROOT/build/real-vps-drop"`，開始時清空並重建。

**遠端指令**

所有遠端指令都用：
```
ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" '<cmd>'
```

用下面這個遠端函式，列出 neighbor 擁有、而且不屬於這次查詢自己的 sshd 程序：

```sh
self=$(ps -o ppid= -p $$ | tr -d " ")
ps -u "$(id -u)" -o pid=,comm= | awk -v s="$self" '$2 ~ /^sshd/ && $1 != s {print $1}' | sort -n
```

**前置檢查**，失敗就以結束碼 3 結束：
- 金鑰登入可用。
- 遠端 `ss -ltn` 中，5901 只出現在 `127.0.0.1` 或 `[::1]`。
- 本機 15901 沒有人在聽。

**執行步驟**
1. 取得基準集合 A，用上面的遠端函式，存到 `$WORK/sshd-before.txt`。
2. 用 swiftc（`-swift-version 5`）編譯 `SSHTunnel.swift`、`RemoteDesktopHandoff.swift` 與 `Tests/RemoteDesktopVPSDropCheck.swift`，輸出到 `$WORK/drop-check`。
3. 背景執行：
   ```
   "$WORK/drop-check" --alias "$ALIAS" --hold-seconds "$HOLD" --ready-file "$WORK/ready" > "$WORK/drop-check.stdout" 2>&1 &
   ```
4. 等 `drop-check.stdout` 出現 `state: viewerOpened`，最多 40 秒。等到之後再等 2 秒，取得集合 B，存到 `$WORK/sshd-after.txt`。
5. 新程序 = B − A，用 `comm -13`。必須剛好有一個 pid，否則記錄原因，結束 drop-check，結束碼 6。這個 pid 就是通道在遠端的 sshd 程序，記為 `TUNNEL_PID`。
6. 等 `$WORK/ready` 出現，最多 `HOLD + 60` 秒。
7. 遠端執行 `kill -STOP $TUNNEL_PID`，記錄時間，並印出 `froze remote sshd $TUNNEL_PID`。
8. 等 drop-check 結束，最多 180 秒，取得它的結束碼。
9. **清理**，一律用 trap：
   - 遠端 `kill -CONT $TUNNEL_PID; kill $TUNNEL_PID`，失敗不中斷。
   - 本機結束 drop-check（如果還在跑）。
   - 最後再取一次集合 C，存到 `$WORK/sshd-final.txt`。

**摘要**
- `drop-check.stdout` 中所有 `alive` 行的數量，以及其中失敗的數量。
- `DROP_DETECTED` 那一行。
- `tunnel released`。
- drop-check 的結束碼。
- C 是否等於 A，代表遠端沒有殘留程序。
- 印出 `drop-check.stdout` 的最後 15 行。

**結束碼**
- 0：drop-check 結束碼 0，而且 C 等於 A。
- 4：其他情況。

## 安全限制

- 只能用使用者既有的 `neighbor-vps` 別名，不要讀或改 `~/.ssh/`。
- 遠端只能對**新出現、屬於 neighbor** 的那一個 sshd pid 送 STOP、CONT、TERM。不碰其他程序、不用 sudo、不改 VPS 設定，也不停止 VNC 伺服器。

## 完成時

列出兩個檔案，以及你不確定的地方。特別是 Ubuntu 26.04 的 sshd 程序名稱，可能是 `sshd` 或 `sshd-session`；awk 用 `^sshd` 可以同時比對到兩者。

## 補充：R5，試跑後的修正（2026-10-21）

用 `HOLD_SECONDS=30` 試跑時發現兩個問題。

1. **stdout 被緩衝。** drop-check 的輸出導向檔案時是區塊緩衝，腳本一直讀不到 `state: viewerOpened`，以為逾時。實際上 ready 檔已經建立，代表程式已經走到 HOLD_DONE。
2. **ssh 殘留。** 腳本用 kill 結束 drop-check 時，Swift 沒有執行 deinit，App 開的 ssh 通道（`-L 127.0.0.1:15901:...`）留在本機繼續跑。

請修改以下兩個檔案，只改這兩個，不加註解、不執行指令：

- `Tests/RemoteDesktopVPSDropCheck.swift`
  - `main()` 第一行加入 `setvbuf(stdout, nil, _IOLBF, 0)`。
  - 在 `start` 之前，對 SIGTERM 與 SIGINT 各做一次：
    1. 先 `signal(sig, SIG_IGN)`。
    2. 建立 `DispatchSource.makeSignalSource(signal: sig, queue: .main)`，事件處理為：印出 `signal received; stopping tunnel`，呼叫 `controller.stop()`，再 `exit(130)`。
    3. `resume()`，並把 source 存在一個陣列裡，讓它保持存活。
- `scripts/check-real-vps-drop.sh`
  - 在 cleanup 中結束 drop-check 之後，加一道保險：
    ```
    pkill -f -- "-L 127.0.0.1:15901:127.0.0.1:5901 -- $ALIAS" 2>/dev/null || true
    ```
    只比對這條確切的參數，不碰其他 ssh。
