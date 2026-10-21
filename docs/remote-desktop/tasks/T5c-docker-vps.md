# T5c 任務說明（給 Gemini／Antigravity）：Docker 版 Linux VPS 端到端，以及假伺服器持續監聽

> 派工方式：`agy -p "請讀 docs/remote-desktop/tasks/T5c-docker-vps.md 並照做"`。
> 使用者已於 2026-10-20 同意：啟動 Docker Desktop，下載 Debian 映像檔與 TigerVNC、xfce4 套件，用完刪除容器與映像檔。

## 背景：2026-10-20 實測發現

macOS「螢幕共享」連線時的實際流程：

1. 第一條連線協商到 VncAuth（RFB 3.3，伺服器送安全類型 2 與 challenge）後，跳出密碼框。
2. 使用者按「登入」時，它**關掉第一條連線**。
3. 接著**重新連一條新連線**，用密碼完成 VncAuth、ClientInit、ServerInit，然後開始要求畫面。

Claude 用「持續監聽」的原型證實了這個流程：第二條連線一路走到送出 48 張畫面，螢幕共享視窗也顯示了測試圖樣。現在的 `fake-rfb-server.py` 在第一條連線斷掉時就退出，所以螢幕共享會顯示「無法與 127.0.0.1:5901 通訊」。

## 只能新增或修改以下檔案

- 不改其他檔案、不 commit、不執行終端機指令、不加註解。
- 腳本需要的說明，寫在 log 或 echo 字串裡。

### A. 修改 `scripts/fake-rfb-server.py`：持續監聽

在 `main()` 的 accept 迴圈中，`ConnectionResetError`／`BrokenPipeError` 那個分支要改成：

- 如果這條連線**送出過至少一張畫面**：維持現在的行為，記錄 `client disconnected` 後以結束碼 0 退出。
- 否則：
  - 記錄 `client disconnected before any frame; still listening`。
  - 關閉這條連線，用 `continue` 繼續 accept。

做法：讓 `handle_client` 回報這條連線送出的畫面數，例如回傳值，或用一個可變的計數器傳進去。

整體逾時的行為不變。

### B. 新增 `scripts/docker-vps/Dockerfile`

```dockerfile
FROM debian:bookworm-slim
```

- 用 `apt-get update`，加上 `DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends`，安裝：
  - `openssh-server`
  - `tigervnc-standalone-server`
  - `tigervnc-common`
  - `xfce4`
  - `xfce4-goodies`
  - `dbus-x11`
  - `iproute2`
  - 最後清掉 apt 快取。
- 建立一般使用者 `neighbor`，shell 用 `/bin/bash`，不給 sudo。
- 建立 `/run/sshd`。
- `/etc/ssh/sshd_config.d/neighbor.conf` 寫入下面這些設定，每行一項：
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
  - `PermitRootLogin no`
  - `AllowTcpForwarding local`
  - `PermitOpen 127.0.0.1:5901`
  - `X11Forwarding no`
  - `AllowAgentForwarding no`
- 複製 `entrypoint.sh` 到 `/usr/local/bin/`，設為可執行，並作為 `ENTRYPOINT`。

### C. 新增 `scripts/docker-vps/entrypoint.sh`

POSIX sh，`set -eu`。完全照 `docs/remote-desktop/SETUP.md` 第 2 節做：

1. 從唯讀掛載的 `/run/neighbor/` 取得四個檔案，安裝後設定權限：

   | 來源 | 安裝到 | 擁有者與權限 |
   |---|---|---|
   | `ssh_host_ed25519_key` | `/etc/ssh/ssh_host_ed25519_key` | root，600 |
   | `ssh_host_ed25519_key.pub` | `/etc/ssh/ssh_host_ed25519_key.pub` | root，644 |
   | `authorized_keys` | `/home/neighbor/.ssh/authorized_keys` | neighbor，`.ssh` 700，檔案 600 |
   | `vnc-password`（一行明文） | `~neighbor/.vnc/passwd` | neighbor，600 |

   VNC 密碼的轉換方式：`su neighbor -c 'vncpasswd -f < /run/neighbor/vnc-password > ~/.vnc/passwd'`。
2. 照 SETUP.md 2.3 建立 `~neighbor/.vnc/xstartup`，內容如下，並設為可執行：
   ```sh
   #!/bin/sh
   unset SESSION_MANAGER
   unset DBUS_SESSION_BUS_ADDRESS
   exec startxfce4
   ```
3. 以 neighbor 身分執行 `vncserver :1 -localhost yes -SecurityTypes VncAuth`，與 SETUP.md 2.4 完全相同。
4. 用 `ss -ltn` 印出監聽中的埠。
5. 以前景執行 `/usr/sbin/sshd -D -e`，讓容器保持執行。

### D. 新增 `scripts/check-docker-vps.sh`

zsh，`set -euo pipefail`，`ROOT="${0:A:h:h}"`。風格照 `scripts/check-vps-path-loopback.sh`。

**變數**
- `CHECK_WAIT` 預設 90。
- `IMAGE=neighbor-vps-test:local`
- `NAME=neighbor-vps-test`
- `WORK="$ROOT/build/docker-vps"`

**前置檢查**
- `docker version` 能連到 daemon，否則結束碼 3。
- `127.0.0.1` 的 22923 和 15901 沒有人在聽，否則結束碼 3。
- 記錄螢幕共享原本有沒有在跑。

**準備**
1. 清空並重建 `$WORK`，設為 700。
2. 用 `ssh-keygen` 產生 `host_key` 與 `client_key`（ed25519，不設密碼）。
3. 用 `LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8` 產生 8 字元測試密碼，寫入 `$WORK/vnc-password`，權限 600。
   - **不要把密碼印到畫面上。**
4. 建立 `$WORK/mount/`，放入四個檔案：
   - `ssh_host_ed25519_key`、`ssh_host_ed25519_key.pub`（由 `host_key`、`host_key.pub` 複製而來）
   - `authorized_keys`（由 `client_key.pub` 複製而來）
   - `vnc-password`
5. `known_hosts` 寫入一行：`[127.0.0.1]:22923 ` 加上 `host_key.pub` 的前兩欄。
6. `ssh_config` 內容：
   ```
   Host 127.0.0.1
     Port 22923
     User neighbor
     IdentityFile "$WORK/client_key"
     IdentitiesOnly yes
     UserKnownHostsFile "$WORK/known_hosts"
     GlobalKnownHostsFile /dev/null
   ```

**建置與啟動**
1. `docker build -t "$IMAGE" "$ROOT/scripts/docker-vps"`。
2. `docker run -d --name "$NAME" -p 127.0.0.1:22923:22 -v "$WORK/mount:/run/neighbor:ro" "$IMAGE"`。
   - **只能**發布 22 到 127.0.0.1:22923。5901 不發布，跟真實 VPS 一樣不開防火牆。
3. 等 22923 開始監聽，最多 30 秒。
4. 再等 `docker exec "$NAME" ss -ltn` 出現 `127.0.0.1:5901`，最多 60 秒。

**SETUP.md 自我檢查**
- 印出 `docker exec "$NAME" ss -ltn` 中含 5901 的那幾行。
- 確認沒有出現 `0.0.0.0:5901` 或 `*:5901`。
- 把結果記成 `setup_self_check=pass` 或 `fail`。

**提示使用者**
- 用 echo 印出：「螢幕共享跳出密碼框時，請輸入 `$WORK/vnc-password` 檔案中的 8 字元密碼（可在另一個終端機執行 cat 查看），然後按登入。」
- 只印路徑，不印密碼。

**執行**
1. 用 swiftc（`-swift-version 5`）編譯 `SSHTunnel.swift`、`RemoteDesktopHandoff.swift` 與 `Tests/RemoteDesktopVPSLiveCheck.swift`。
2. 執行 `--ssh-config "$WORK/ssh_config" --hold "$CHECK_WAIT"`，輸出存到 `$WORK/live-check.stdout`。

**摘要**
- live check 的最終狀態，以及 `tunnel closed after stop`。
- `setup_self_check` 的結果。
- `docker logs "$NAME"` 是否出現 `Accepted publickey`。
- 印出 `docker logs "$NAME"` 的最後 20 行。

**清理**：一律用 trap。
1. `docker rm -f "$NAME"`。
2. 若 `KEEP_IMAGE` 不等於 1，執行 `docker rmi "$IMAGE" debian:bookworm-slim`，失敗不中斷。
3. 只有在原本沒在跑的情況下，才關掉螢幕共享。
4. 刪除私鑰、`vnc-password` 與整個 `mount/`。

**結束碼**
- 0：live check 結束碼 0、`setup_self_check=pass`、出現 Accepted publickey。
- 4：其他情況。
- 3：前置檢查失敗。

## 完成時

列出所有檔案，以及你不確定的地方。特別是 xfce4 在沒有 systemd 的容器中能不能啟動，以及 vncserver 在 entrypoint 中的執行身分。
