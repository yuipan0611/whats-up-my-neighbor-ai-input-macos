# T5b 任務說明（給 Gemini／Antigravity）：用本機 sshd 模擬 VPS，做「接手控制」VPS 路徑端到端檢查

> 派工方式：`agy -p "請讀 docs/remote-desktop/tasks/T5b-vps-path-loopback.md 並照做"`。

## 目的

還沒有 VPS 資料時，也要實際走過 VPS 這條路的每一段：真的 ssh 程序、真的 `-L 127.0.0.1:15901:127.0.0.1:5901` 轉送、真的 RFB 探測、真的「螢幕共享」，以及「結束接手」會關掉通道。

做法是在本機用一般使用者身分跑一個臨時 sshd，只聽 `127.0.0.1:22922`，金鑰全部是臨時產生的，用它代替 VPS。「遠端」的 VNC 伺服器則用 `scripts/fake-rfb-server.py` 在 5901 扮演。

Claude 已用原型證實這套做法可行：sshd 以一般使用者身分執行時，金鑰登入成功，15901 的轉送也建立起來。

## 只能新增這兩個檔案

不改既有檔案、不 commit、不執行終端機指令。不要加註解，log 字串本身就說明了每一步。

### 1. `Tests/RemoteDesktopVPSLiveCheck.swift`

- 一個 `@main enum RemoteDesktopVPSLiveCheck`。
- 參數 `--ssh-config <path>`（必填）與 `--hold <seconds>`（預設 20）。
- 新增 `final class ConfiguredSSHProcess: SSHProcessRunning`：
  - 內部持有一個 `SystemSSHProcess` 和設定檔路徑。
  - `onExit` 轉接到內部的那一個。
  - `start(arguments:)` 呼叫 `inner.start(arguments: ["-F", configPath] + arguments)`。
  - `stop()` 轉呼叫 `inner.stop()`。
  - App 的 SSH 參數陣列一字不改，只在最前面加上 `-F`。
- 用以下方式建立控制器：
  ```swift
  RemoteDesktopHandoffController(makeTunnel: {
      SSHTunnelController(makeProcess: { ConfiguredSSHProcess(configPath: path) })
  })
  ```
  其餘參數都用預設值：真實探測、真實啟動器、真實埠號檢查。
- 呼叫 `start(.linuxVPS(hostAlias: "127.0.0.1"))`。每次 `onStateChange` 都印出 `state: …`。
- 跑 `RunLoop.main`，直到 state 不再是 active，或變成 `.viewerOpened`，最多 25 秒。
- 若到達 `.viewerOpened`：
  1. 印出 `viewer opened; holding tunnel for N s`，然後繼續跑 RunLoop N 秒。這段時間通道必須維持，螢幕共享要經由它連線。
  2. 期間如果 state 變成 failed，印出來並以結束碼 3 結束。
  3. 呼叫 `controller.stop()`。
  4. 最多 5 秒內輪詢 `SystemLocalPort.isFree(port: 15901)`，直到變成 true。
  5. 印出 `tunnel closed after stop: true/false`。
- 結束碼：
  - 0：曾到達 viewerOpened、hold 期間沒有失敗、stop 後 15901 釋放。
  - 1：沒到達 viewerOpened。
  - 3：hold 期間失敗。
  - 4：stop 後 15901 沒有釋放。
  - 結束前一律印出 `final state: …`。

### 2. `scripts/check-vps-path-loopback.sh`

zsh，`set -euo pipefail`，`ROOT="${0:A:h:h}"`，風格照 `scripts/check-screen-sharing-loopback.sh`。

**前置檢查**
- `127.0.0.1` 的 22922、15901、5901 都不能有人在聽，用 `lsof -nP -iTCP:<port> -sTCP:LISTEN` 檢查。被佔用就印出是誰佔用，結束碼 3。
- 記錄執行前「螢幕共享」是否在跑：`pgrep -x "Screen Sharing"`。

**工作目錄**
- `WORK="$ROOT/build/vps-loopback-check"`。開始時先清空並重建，權限設為 `chmod 700`。

**產生臨時金鑰與設定**
- 用 `ssh-keygen -q -t ed25519 -N "" -f "$WORK/host_key"` 產生主機金鑰，`client_key` 同樣方式產生。
- `cp client_key.pub authorized_keys`，並設為 `chmod 600`。
- `sshd_config` 內容逐行如下，路徑都在 `$WORK` 底下：
  ```
  ListenAddress 127.0.0.1:22922
  HostKey $WORK/host_key
  PidFile $WORK/sshd.pid
  AuthorizedKeysFile $WORK/authorized_keys
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  UsePAM no
  PermitRootLogin no
  AllowTcpForwarding local
  PermitOpen 127.0.0.1:5901
  AllowAgentForwarding no
  X11Forwarding no
  PermitTTY no
  StrictModes no
  ```
- `known_hosts` 只有一行：`[127.0.0.1]:22922 ` 加上 `host_key.pub` 的前兩欄。
- `ssh_config` 內容：
  ```
  Host 127.0.0.1
    Port 22922
    User <whoami 的結果>
    IdentityFile $WORK/client_key
    IdentitiesOnly yes
    UserKnownHostsFile $WORK/known_hosts
    GlobalKnownHostsFile /dev/null
  ```

**啟動與執行**
1. 用 `/usr/sbin/sshd -t -f "$WORK/sshd_config"` 檢查設定。
2. 背景啟動 `/usr/sbin/sshd -D -e -f "$WORK/sshd_config" > "$WORK/sshd.log" 2>&1 &`，等 22922 開始監聽，最多 5 秒。
3. 背景啟動 `python3 -I "$ROOT/scripts/fake-rfb-server.py" --port 5901 --log "$WORK/server.log" --timeout $(( CHECK_WAIT + 60 ))`，等 5901 開始監聽，最多 5 秒。`CHECK_WAIT` 預設 20。
4. 用 swiftc（`-swift-version 5`）編譯 `SSHTunnel.swift`、`RemoteDesktopHandoff.swift` 與 `Tests/RemoteDesktopVPSLiveCheck.swift`，輸出到 `$WORK/RemoteDesktopVPSLiveCheck`。
5. 執行 `"$WORK/RemoteDesktopVPSLiveCheck" --ssh-config "$WORK/ssh_config" --hold "$CHECK_WAIT"`，輸出存到 `$WORK/live-check.stdout`，並記下結束碼。

**摘要**
- live check 的最後 `final state` 與 `tunnel closed after stop`。
- `sshd.log` 是否出現 `Accepted publickey`。
- `server.log` 是否出現 `probe connection disconnected`，代表探測經由通道到達。
- `server.log` 是否出現 `client version:`，代表螢幕共享經由通道連進來。印出那一行。
- 以上兩個 log 各印最後 15 行。

**清理**：一律用 `trap … EXIT INT TERM`。
- 結束 sshd（用 pid 檔）與假伺服器。
- 只有在執行前沒在跑的情況下，才用 `osascript -e 'quit app "Screen Sharing"'` 關掉螢幕共享。
- 刪除 `$WORK/host_key`、`$WORK/client_key` 兩個私鑰，log 保留。

**結束碼**
- 0：live check 結束碼為 0、出現 Accepted publickey、出現 client version。
- 4：其中任一項不成立。
- 3：前置檢查失敗。

## 安全限制

- 不讀、不改使用者的 `~/.ssh/`。所有 ssh 和 sshd 設定都用 `-F` 或 `-f` 指向 `$WORK`。
- sshd 只聽 `127.0.0.1`，只接受 `$WORK` 裡臨時產生的金鑰，只允許轉送到 `127.0.0.1:5901`。
- 不用 sudo，不改系統設定（包括「遠端登入」），不碰鑰匙圈。

## 完成時

列出兩個檔案路徑，以及你不確定的地方。
