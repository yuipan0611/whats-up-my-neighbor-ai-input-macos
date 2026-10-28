# T5a 任務說明（給 Gemini／Antigravity）：本機假 VNC 伺服器與螢幕共享 loopback 檢查

> 派工方式：`agy -p "請讀 docs/remote-desktop/tasks/T5a-loopback-check.md 並照做"`。

## 目的

沒有真實 VNC 伺服器時，也能實際驗證這條路徑：

`RemoteDesktopHandoffController` → 真實探測 → 真實 `ScreenSharingLauncher` → macOS「螢幕共享」連到 `127.0.0.1:5901` → 開始要求畫面

同時回答 PRD 第 10 節的未知數：螢幕共享 App 會不會拒絕連到本機 loopback。

## 你只能新增這三個檔案（不要改其他任何檔案，不 commit，不執行終端機指令）

1. `scripts/fake-rfb-server.py`
   - Python 3，只用標準函式庫，可執行（第一行 `#!/usr/bin/env python3`）。
2. `Tests/RemoteDesktopLiveCheck.swift`
   - 一個 `@main enum RemoteDesktopLiveCheck`。
   - 用真實的 `RemoteDesktopHandoffController()`（預設的探測器、啟動器與時鐘）呼叫 `start(.macSecondUser)`。
   - 跑 `RunLoop.main` 直到 `state` 不再是 active，或超過 20 秒。
   - 印出最終 `state`。
   - `state == .viewerOpened` 時結束碼為 0，否則為 1。
3. `scripts/check-screen-sharing-loopback.sh`
   - zsh，`set -euo pipefail`，`ROOT="${0:A:h:h}"`，風格照 `scripts/test-remote-desktop.sh`。

## fake-rfb-server.py 規格（RFB 3.8，依 RFC 6143）

**參數**
- `--port`：預設 5901。
- `--log`：log 檔路徑，必填。
- `--timeout`：整體秒數，預設 60。
- `--security`：`none` 或 `vncauth`，預設 `none`。

**連線範圍**
- 只綁 `127.0.0.1`，不接受其他位址。
- 一次只服務一個連線。
- 第一個連線結束後，或逾時，就退出。

**握手流程**，每一步都寫一行 log（時間戳加事件），並 flush：
1. 送出 `RFB 003.008\n`。
2. 讀 12 bytes 的客戶端版本，原樣記錄。客戶端可能是 Apple 的 `RFB 003.889\n`，照常接受。
3. 送出安全類型清單，格式為 1 byte 數量加類型。`none` 模式送 `[1]`，`vncauth` 模式送 `[2]`。
4. 讀客戶端選的 1 byte 類型。
   - 選 2：送出 16 bytes 隨機 challenge，讀 16 bytes 回應，不驗證，只記錄「收到回應」。
5. 送出 SecurityResult，u32 big-endian 0。
6. 讀 ClientInit，1 byte。
7. 送出 ServerInit：
   - u16 寬 640、u16 高 400。
   - 16 bytes 像素格式：bpp 32、depth 24、big-endian 0、true-colour 1、red/green/blue-max 皆為 255、red-shift 16、green-shift 8、blue-shift 0、3 bytes padding。
   - u32 名稱長度，加名稱 `neighbor loopback check`。

**之後的訊息迴圈**：讀 1 byte 類型，依類型讀完整個訊息並記錄。

| 類型 | 訊息 | 後續 bytes |
|---|---|---|
| 0 | SetPixelFormat | 3 padding、16 bytes 格式；之後的畫面必須照這個格式編碼 |
| 2 | SetEncodings | 1 padding、u16 數量、數量 × s32；記錄清單 |
| 3 | FramebufferUpdateRequest | u8 incremental、u16 x、u16 y、u16 w、u16 h |
| 4 | KeyEvent | 7 bytes |
| 5 | PointerEvent | 5 bytes |
| 6 | ClientCutText | 3 padding、u32 長度、內容 |
| 其他 | 不支援 | 記錄 `unknown message type N`，然後關閉連線 |

**處理 FramebufferUpdateRequest**
- 回覆一個 FramebufferUpdate：
  - 類型 0、1 padding、u16 數量 1。
  - 一個矩形，涵蓋整個 640×400，encoding 0（Raw）。
- 像素依目前的像素格式編碼：
  - 支援 bpp 8、16、32 與 big／little endian。
  - 顏色先依 max 縮放，再依 shift 組合。
- 圖樣為上下兩塊固定顏色：上半深綠，下半淺灰。
- incremental 為 1 時，先等 0.5 秒再回覆。
- 每送一張畫面，記錄 `frame N sent`。

**錯誤處理**：對方斷線時，記錄 `client disconnected`，並以結束碼 0 退出。其他例外記錄後以結束碼 2 退出。

## check-screen-sharing-loopback.sh 規格

1. 檢查 `127.0.0.1:5901` 必須沒有人在聽（`lsof -nP -iTCP:5901 -sTCP:LISTEN`）。有人在聽就印出原因，結束碼 3。
2. 記錄執行前「螢幕共享」是否已經在跑：`pgrep -x "Screen Sharing"`。
3. 背景啟動 `fake-rfb-server.py --port 5901 --log "$ROOT/build/loopback-check/server.log" --timeout 60`，等它開始監聽，最多 5 秒。
4. 用 swiftc 編譯並執行 `Tests/RemoteDesktopLiveCheck.swift`，搭配：
   - `Sources/NeighborAgentCore/SSHTunnel.swift`
   - `Sources/NeighborAgentCore/RemoteDesktopHandoff.swift`
   - 輸出放 `$ROOT/build/loopback-check/`。
5. 檢視器開啟後，最多等 30 秒，直到 server.log 出現 `FramebufferUpdateRequest`。
6. 印出摘要：
   - 控制器最終狀態。
   - 客戶端版本。
   - 客戶端選的安全類型。
   - 有沒有收到 FramebufferUpdateRequest。
   - 送出幾張畫面。
   - 最後 20 行 server.log。
7. 清理：
   - 結束假伺服器。
   - 只有在第 2 步時螢幕共享原本沒在跑，才用 `osascript -e 'quit app "Screen Sharing"'` 關掉它。
8. 結束碼：
   - 0：收到 FramebufferUpdateRequest。
   - 4：螢幕共享沒有連進來。
   - 5：連進來但沒有要求畫面。

## 限制

- 只新增上面三個檔案。不改 `Sources/`、`Previews/`、`docs/` 底下任何既有檔案，也不改 `HANDOFF.md`。Claude 會更新交接板。
- 不 commit、不切分支、不執行終端機指令。Claude 會執行並驗證。
- 不碰任何密碼或金鑰；`vncauth` 模式不驗證密碼。

## 完成時

列出三個檔案路徑，並說明你不確定的 RFB 細節。
