# R2 任務說明（給 Gemini／Antigravity）：假 VNC 伺服器支援 RFB 3.3 與 3.7 握手

> 派工方式：`agy -p "請讀 docs/remote-desktop/tasks/R2-rfb33-handshake.md 並照做"`。

## 為什麼要改

2026-10-20 15:59 執行 `scripts/check-screen-sharing-loopback.sh` 的實測 log 如下：

```text
connection accepted from 127.0.0.1:53566
server version sent: RFB 003.008
client version: RFB 003.003
security types sent: [1] (None)
```

macOS「螢幕共享」回覆的是 **RFB 3.3**。依 RFC 6143 附錄 A：

- **3.3**：由伺服器決定安全類型，送出一個 **u32**，而不是清單。
- **3.7**：伺服器送清單；SecurityResult 只在 VncAuth 之後送，None 不送。
- **3.8**：伺服器送清單；SecurityResult 一律要送。

我們的伺服器不管客戶端版本，一律送 3.8 格式的清單，所以握手卡住。

## 只能修改 `scripts/fake-rfb-server.py`

不改其他檔案、不 commit、不執行終端機指令。不要加註解；log 字串本身就說明了每一步。

依客戶端版本選協定（`RFB 003.889` 是 Apple 的版本號，當成 3.8 處理）：

| 客戶端版本 | 安全類型協商 | VncAuth（選 2） | SecurityResult |
|---|---|---|---|
| `003.003` | 伺服器送 u32 big-endian：`none` 送 1，`vncauth` 送 2；不讀客戶端選擇 | 送 16 bytes challenge，讀 16 bytes 回應，不驗證 | 只在 VncAuth 後送 u32 0；None 不送 |
| `003.007` | 照現在的清單流程 | 同上 | 只在 VncAuth 後送 u32 0；None 不送 |
| `003.008`、`003.889`，以及其他版本 | 照現在的清單流程 | 同上 | 一律送 u32 0 |

每個分支都要寫 log：

- `protocol: 3.3`（或 `3.7`、`3.8`）
- 3.3 寫 `security type chosen by server: 1`（或 `2`）
- 3.7／3.8 維持原本的 `client selected security type: N`

之後的 ClientInit、ServerInit 與訊息迴圈完全不變。

## 完成時

說明你改了哪些函式，以及你對 3.3 中 VncAuth 分支有沒有不確定的地方。
