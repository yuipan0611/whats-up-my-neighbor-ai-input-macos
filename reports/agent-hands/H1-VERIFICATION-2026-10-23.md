# H1 驗證紀錄：VPS 基礎設定（2026-10-23）

H1 是 PRD 第 12 節裡需要 root 的 VPS 設定。腳本在 `office/hands/setup-h1.sh`（commit `d0c1c2e`）。

## 誰執行、怎麼執行

- **原本的安排：** YUI 用 root 貼兩行指令。YUI 按了「H1 finished」，但實際上沒有執行。Claude 唯讀檢查時發現 VPS 完全沒有變化，也沒有半套：沒有使用者、沒有資料夾、沒有 swap，neighbor 的桌面還開著。
- **改由 Claude 執行：** YUI 指示「這種東西你應該自己操控電腦確認」，改由 Claude 在這台 Mac 上以 root 執行。
  - 第一次直接用 `ssh root@…` 被拒（publickey），因為沒有指定金鑰。
  - root 的 authorized_keys 收了 `~/.ssh/neighbor_vps_ed25519`，改成 `ssh -i ~/.ssh/neighbor_vps_ed25519 -o IdentitiesOnly=yes root@31.97.108.187` 就能登入。
- **執行步驟：**
  1. 把腳本複製到 `/root/setup-h1.sh`，SHA-256 與 commit 一致：`b2beb75855b387377f58ab8e489429782c3756ff273d8162bf44c9f6e7f83d12`。
  2. 執行 `bash /root/setup-h1.sh 2>&1 | tee /root/neko-h1.log`，**結束碼 0**。
- **紀錄位置：** 輸出存在 VPS 的 `/root/neko-h1.log`；報告在 `/srv/neko-office/h1-report.txt`（沒有密碼）。

## 結果

證據分類照 ADR-001 第 8 節：**實機**表示在真的 VPS 或從真的 Mac 執行。H1 都是設定，沒有自動測試。

### 腳本自己的檢查（實機，root 在 VPS 上）

報告 21 個 OK、0 個 FAIL：環境、swap、帳號、記憶體上限、資料夾、VNC、字型、Chrome，以及第 7 節共 10 項「用貓咪的身分檢查」。

### Claude 獨立複查（實機，不依賴腳本的輸出）

| 項目 | 結果 |
|---|---|
| 帳號 | `neko-hands` uid 1001，群組只有 `neko-hands`、`neko`；`passwd -S` 為 L（已鎖）；`sudo -l` 回「not allowed」；`~/.ssh/` 只有桌面 ssh-agent 自己建的 `agent/` 資料夾，沒有 authorized_keys；家目錄 750 |
| 群組 | `neko` 的成員是 neko-hands、neighbor |
| swap | `/swapfile` 4G 已啟用；swappiness 10；`/etc/fstab` 有這一行 |
| 記憶體上限 | `user-1001.slice`：MemoryHigh 4294967296、MemoryMax 5368709120、CPUWeight 50；linger 已開；目前用量約 198 MB |
| 資料夾 | `/srv/neko-office` drwxr-s--- neighbor:neko；`vnc-password` -rw------- neighbor（只檢查權限，沒有讀內容）；`/srv/neko-handoff` drwxr-x--- root:neko；`to-cat` drwxr-s--- neighbor:neko；`from-cat` drwxr-s--- neko-hands:neko |
| 桌面 | `tigervncserver@:1` 已設為開機啟動，目前在跑；`Xtigervnc :1` 屬於 neko-hands，參數含 `-localhost=1 -SecurityTypes VncAuth`；`xfce4-session` 在跑；neighbor 的桌面已經沒有了；只監聽 `127.0.0.1:5901`、`[::1]:5901`；本機連 5901 回 `RFB 003.008` |
| VNC 安全規則 | `/etc/tigervnc/vncserver-config-mandatory` 末尾有 `$localhost = "yes"`、`$SecurityTypes = "VncAuth"`；`vncserver.users` 是 `:1=neko-hands` |
| Chrome | Google Chrome 156.0.8078.47；套件庫由 Google 的套件自己建立：`google-chrome.sources`（deb822，Signed-By `/usr/share/keyrings/google-chrome.gpg`），沒有和我們的設定衝突；`fonts-noto-cjk` 已安裝 |
| 用貓咪的身分（root 以 runuser 執行） | 列 `/home/neighbor`、讀 `office.sqlite3`、讀 VNC 密碼、列 `/root`、寫 Docker socket，全部失敗；打辦公室 TCP：本機 Host 回 421、通道 Host 回 421、公網 Host 沒配對讀 `/api/journal` 回 401 |
| 辦公室 | 0.4.0，`worker_running` true |
| 記憶體 | 7935 MB 中用了 860 MB（關掉 neighbor 1920×1200 的桌面後，比 H1 前少）；swap 4095 MB，0 使用 |

### 從外部掃描（實機，從這台 Mac 連 VPS 公網 IP，ADR-001 A18）

只有 22、80、443 開著。5900、5901、6001、9222、8421、2019、11434、65529 在 3 秒內都沒有回應：防火牆直接丟掉封包，所以不是「拒絕連線」，而是完全沒有回應。

## 過程中的觀察

- 安裝套件後，Ubuntu 的 needrestart 列出幾個可以重啟的服務：`networkd-dispatcher`、`systemd-logind`、`unattended-upgrades`，以及 neighbor 底下的幾個服務（含 `neighbor-office.service`）。它只是列出來，**沒有真的重啟任何服務**，辦公室沒有中斷。這些服務等下一次重開機時自然會換成新版。
- neighbor 是在 H1 才加進 `neko` 群組的，目前在跑的 neighbor 服務還沒拿到這個群組。這不影響 0.5.0：worker socket 由 `/srv/neko-office` 的擁有者（neighbor）建立，靠資料夾的 setgid 拿到 `neko` 群組。H7 若要讓辦公室**服務本身**讀 `from-cat`，就需要重開機，或重啟 neighbor 的 user manager。

## NOT RUN（還沒驗證的）

- **重開機之後：** swap、貓咪的桌面、記憶體上限是否都還在。屬於 ADR A03 的一部分，安排在 H3 或下一次維護時重開機確認。
- **用螢幕共享實際看到貓咪的桌面：** 目前只確認了 RFB 有回應，YUI 還沒用 Mac 看過畫面。
- **Chrome 在貓咪的桌面上開啟、能否用 sandbox 執行、記憶體用量：** 屬於 H3（PRD U3、U4）。
- **Chrome 除錯埠開始監聽後的外部掃描：** H3 開始監聽 9222 之後，要再掃一次。
