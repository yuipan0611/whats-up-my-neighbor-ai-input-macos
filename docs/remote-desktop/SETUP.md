# 遠端分身「接手控制」（VNC）環境設定手冊

這份文件說明如何為遠端分身的「接手控制」功能準備 VNC 伺服器環境。支援的遠端目標為 **Linux VPS** 與 **同一台 Mac 的本機第二使用者**。

---

## 1. 這顆按鈕做什麼、不做什麼

### 這顆按鈕做什麼
- **一鍵開啟檢視器**：在遠端分身預覽面板點擊「接手控制」，App 會確認本機連接埠上的 VNC 伺服器訊號（RFB 探測），確認就緒後透過系統指令開啟 macOS 內建的「螢幕共享」（`Screen Sharing.app`）。
- **建立安全通道（僅限 VPS）**：若目標為 Linux VPS，App 會自動以系統 SSH 建立本地轉送通道（`127.0.0.1:15901 → 遠端 127.0.0.1:5901`），流量全程加密。

### 這顆按鈕不做什麼
- **不安裝或啟動伺服器**：App 不會在遠端機器或本機帳號中自動安裝或啟動 VNC 伺服器，使用者須依本文手動設定。
- **不讓 AI 操作桌面**：本功能僅供**人類使用者接手控制**（例如處理登入、驗證碼或確認），不提供任何讓 AI 自動打字或點擊桌面的 API。
- **不讀取、輸入或保存 VNC 密碼**：App 不經手任何 VNC 密碼；密碼一律由使用者在 macOS「螢幕共享」彈出的系統視窗中手動輸入。
- **不對外開放非 loopback 埠**：所有連線僅綁定本機迴路（`127.0.0.1`），不直接對公網暴露 VNC 連接埠。

---

## 2. Linux VPS 設定（TigerVNC + XFCE4）

### 2.1 安裝套件
在 Debian / Ubuntu VPS 上安裝 TigerVNC 伺服器與 XFCE4 桌面環境：

```bash
sudo apt update
sudo apt install -y tigervnc-standalone-server tigervnc-tools xfce4 xfce4-goodies
```

> `vncpasswd` 在 Debian 12 屬於 `tigervnc-tools` 套件。`tigervnc-standalone-server` 只把它列為 Recommends，如果 apt 設定了不安裝 recommends，就會出現 `vncpasswd: command not found`，所以上面明確列出來。2026-10-20 已在 Debian bookworm 容器中實測。

### 2.2 設定 VNC 密碼
以執行分身的使用者身分執行：

```bash
vncpasswd
```
依提示輸入密碼（會詢問是否設定 view-only 唯讀密碼，通常選 `n`）。
> [!IMPORTANT]
> **VNC 密碼請設定為 8 個字元以內（必要）。** 傳統 VNC 認證（DES challenge-response）只用密碼的前 8 個字元。標準客戶端遇到較長的密碼會自動截斷，但 **macOS 螢幕共享不會**。
>
> 2026-10-20 在 Debian 12 容器中實測：
> - 伺服器密碼設為 `neighbor1`（9 字元）時，螢幕共享輸入同樣的 9 個字元，每次都被 TigerVNC 判定 `Authentication failure`。用同一組密碼的標準 VncAuth 客戶端則能登入。
> - 改成剛好 8 個字元後，螢幕共享一次就登入成功。
>
> 密碼強度因此受限，但連線全程經過 **SSH 加密通道**，外界無法竊聽密碼或畫面資料。

### 2.3 配置桌面環境啟動檔
建立或編輯 `~/.vnc/xstartup`：

```bash
mkdir -p ~/.vnc
cat << 'EOF' > ~/.vnc/xstartup
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup
```

### 2.4 啟動 TigerVNC 伺服器
執行以下指令啟動 display `:1`（對應 TCP port 5901）：

```bash
vncserver :1 -localhost yes -SecurityTypes VncAuth
```

- `-localhost yes`：強制伺服器僅監聽本機 loopback 介面（`127.0.0.1` / `::1`），拒絕所有公網直接連線。
- `-SecurityTypes VncAuth`：只提供標準 VNC 密碼認證。依 Debian 的 tigervncserver(1)，加上 `-localhost` 時預設本來就是 `VncAuth`。明確寫出來，是為了避免日後改了預設或設定檔而混入 `TLSVnc` 等 TigerVNC 擴充類型；macOS 螢幕共享是否支援這些擴充類型**未確認**，Apple 沒有公開文件說明。

### 2.5 防火牆設定
**絕對不要在防火牆（如 UFW、iptables 或雲端服務商的安全組）開放 TCP 5901 連接埠**。所有通訊皆經由 SSH 加密通道轉送至遠端本機 loopback。

### 2.6 自我檢查
在 VPS 終端機執行：

```bash
ss -ltn | grep 5901
```
確認輸出中的監聽位址為 `127.0.0.1:5901` 或 `[::1]:5901`，**不能**出現 `0.0.0.0:5901` 或 `*:5901`。

### 2.7 Mac 端的 `~/.ssh/config` 別名範例
在 Mac 上的 `~/.ssh/config` 設定 VPS 別名（請替換 `<佔位符>`，不要使用真實敏感資訊）：

```ssh-config
Host <your-vps-alias>
    HostName <your-vps-host-or-ip>
    User <your-remote-username>
    Port 22
    IdentityFile ~/.ssh/<your-ssh-key-file>
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

App 面板在選擇「Linux VPS」時，只需輸入此別名 `<your-vps-alias>`。

### 2.8 Ubuntu 26.04 實測與一次性設定腳本（2026-10-21）

在 Hostinger KVM 2（Ubuntu 26.04 LTS）上照本節實際設定，並以真實螢幕共享端到端通過，紀錄見 `reports/REMOTE_DESKTOP_VPS_2026-10-21.md`。

- `scripts/vps-bootstrap-ubuntu.sh`：在全新 VPS 上以 root 執行一次。它會：
  - 建立**無 sudo**、只能用指定金鑰登入的 `neighbor` 帳號。
  - 安裝 2.1 節的套件，外加 `dbus-x11`。
  - 寫入 2.3 節的 xstartup。
  - 啟用 ufw，只開 22。
  - 印出主機金鑰指紋。
  
  腳本裡的 `PUBKEY` 換成自己的公鑰。從 Mac 執行時，首次連線的指紋要先在服務商的 Web console 核對：
  ```bash
  ssh root@<vps-ip> 'bash -s' < scripts/vps-bootstrap-ubuntu.sh
  ```
- 2.1 節的套件名稱在 Ubuntu 26.04 都存在。
- Ubuntu 26.04 的 `vncpasswd` 把密碼檔寫在 `~/.config/tigervnc/passwd`，不是 `~/.vnc/passwd`；`vncserver` 會自動找到它。log 仍在 `~/.vnc/<hostname>:1.log`。
- 預設解析度是 1920x1200。要改的話，啟動時加 `-geometry 1440x900`。
- 設定完成後，在 Mac 執行 `CHECK_WAIT=120 ./scripts/check-real-vps.sh`，會依序做三件事：
  1. 前置檢查：金鑰登入、5901 只監聽在 loopback。
  2. 開通道並打開螢幕共享。
  3. 結束後確認 15901 已釋放。

### 2.9 收緊 SSH 與開機自動啟動 VNC（root，在 2.8 驗證通過之後）

一定要先確認 `ssh <alias>` 能用金鑰登入，而且服務商的 Web console 可以救援。在 Web console 以 root 執行：

```bash
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-neighbor-hardening.conf
sshd -t && systemctl reload ssh
```

用 Mac 確認：`ssh -o PreferredAuthentications=none root@<vps-ip>` 的錯誤訊息應該只剩 `(publickey)`。

開機自動啟動 VNC，要先停掉手動啟動的那一個：

```bash
su - neighbor -c 'vncserver -kill :1'
echo ':1=neighbor' >> /etc/tigervnc/vncserver.users
systemctl enable --now tigervncserver@:1
```

`-localhost` 與 `SecurityTypes` 改寫在 `/etc/tigervnc/vncserver-config-defaults`，或 neighbor 的 `~/.config/tigervnc/config`，各寫一行：`localhost=yes`、`SecurityTypes=VncAuth`。啟動後一樣用 2.6 節自我檢查。這段 systemd 設定**尚未實測**。

---

## 3. Mac 第二使用者設定（本機隔離環境）

### 3.1 建立第二使用者帳號
1. 打開 macOS「系統設定」>「使用者與群組」。
2. 點擊「加入帳號」，選擇建立**一般使用者**（標準帳號，**切勿給予管理員權限**）。
3. 登入該帳號一次以完成初始化設定，並確保在系統中已啟用「快速切換使用者」（Fast User Switching）。

### 3.2 為什麼不使用 macOS 內建螢幕共享伺服器（Port 5900）？
macOS 內建的「遠端管理／螢幕共享」伺服器（預設監聽 5900）分享的是**當前前景登入的使用者螢幕**。若在主帳號下連線至本機 5900，畫面仍會是主使用者本身，無法實現背景獨立分身的視覺隔離。

### 3.3 安裝與設定 Vine Server
在第二使用者帳號下安裝並設定獨立的 VNC 伺服器：

> [!WARNING]
> **Homebrew 已停用 `vine-server`**（2026-10-20 查 `https://formulae.brew.sh/api/cask/vine-server.json`）：`disabled: true`，停用日期 2026-09-01，原因 `fails_gatekeeper_check`。因此 `brew install --cask vine-server` **會失敗**。

Vine Server 目前沒有通過 macOS Gatekeeper 檢查的版本。第二使用者情境要用哪一個 VNC 伺服器，屬於**待使用者決定**的安全取捨（見 PRD 第 10 節）：

| 選項 | 代價 |
|---|---|
| 從上游 GitHub release（`stweil/OSXvnc` V5.3.2）手動下載 Vine Server，並自行允許開啟 | 要繞過 Gatekeeper，執行一個未通過檢查的 App，而且它還要拿到「螢幕錄製」與「輔助使用」權限。風險最高 |
| 改用其他有簽章、支援背景使用者工作階段的 macOS VNC 伺服器 | 需要另行評估產品與授權，本文件未查證 |
| 先只用 Linux VPS 目標 | 第二使用者情境暫緩 |

App 端不受影響。只要 `127.0.0.1:5901` 上有任何回應 RFB 的 VNC 伺服器，「接手控制」就能使用。

若仍選擇 Vine Server，設定重點如下：
- **Port**：`5901`，避免與系統預設的 5900 衝突。
- **只允許本機連線**：上游文件（OSXvnc.html）說明有 `-localhost` 選項，啟用後連線時必須寫 `127.0.0.1`，不能寫 `localhost`。偏好設定視窗中對應的勾選項目名稱**未確認**。
- **VNC 密碼**：設定一組 VNC 連線密碼。

### 3.4 系統權限授權（強權限提示）
在第二使用者帳號下，打開「系統設定」>「隱私權與安全性」：
- **螢幕錄製（Screen Recording）**：授予 Vine Server 權限（允許擷取該帳號桌面）。
- **輔助使用（Accessibility）**：授予 Vine Server 權限（允許轉送滑鼠與鍵盤操作）。

> [!CAUTION]
> 「螢幕錄製」與「輔助使用」屬於 macOS 高權限設定，能讀取畫面與模擬輸入。因此必須在**非管理員的第二使用者**帳號中執行，以限制權限擴散風險。

---

## 4. 排錯指南

### 4.1 快速 RFB 訊號測試
在 Mac 終端機測試 VNC 連接埠是否正常回傳 RFB 協定橫幅：

- **Linux VPS（在 App 建立 SSH 通道後，或手動建立暫時通道時）**：
  ```bash
  nc -w 2 127.0.0.1 15901 </dev/null | head -c 12
  ```
- **本機第二使用者**：
  ```bash
  nc -w 2 127.0.0.1 5901 </dev/null | head -c 12
  ```

正常輸出應顯示類似：`RFB 003.008\n`（格式為 `RFB ddd.ddd\n`）。

### 4.2 常見問題與 App 錯誤文案對照

| 失敗情境 | 可能原因 | 排查與修復方式 | App 對應錯誤文案 |
|---|---|---|---|
| **本機 15901 被佔用** | 先前的 SSH 通道沒有結束（例如 App 被強制結束），或其他程式佔用 15901 | 執行 `lsof -nP -iTCP:15901` 找出並結束該程式。 | 「本機 127.0.0.1:15901 已被其他程式佔用，可能是先前沒有結束的 SSH 通道。請用「lsof -nP -iTCP:15901」找出並結束它，再按一次「接手控制」。」 |
| **SSH 別名錯誤** | `~/.ssh/config` 找不到該別名，或別名格式不合法 | 檢查別名字元（僅允許英數字元、減號、底線與小數點），確認在 `~/.ssh/config` 中已正確定義。 | `別名不合法` 或「SSH 通道沒有建立成功或已結束。請檢查 SSH 別名、金鑰登入與主機指紋後，再按一次「接手控制」。」 |
| **主機指紋（Host Key）變更或未確認** | 首次連線未接受指紋，或遠端金鑰變更被 `StrictHostKeyChecking=yes` 攔截 | 手動於終端機執行 `ssh <別名>` 確認主機指紋已寫入 `~/.ssh/known_hosts`。 | 「SSH 通道沒有建立成功或已結束。請檢查 SSH 別名、金鑰登入與主機指紋後，再按一次「接手控制」。」 |
| **VPS 伺服器未啟動 / 轉送失敗** | 遠端 TigerVNC 伺服器未在 5901 監聽，或 SSH 連線逾時 | 在遠端執行 `ss -ltn | grep 5901` 確認伺服器狀態；確認 VPS 防火牆未阻擋 SSH (22)。 | 「找不到 VNC 伺服器：127.0.0.1:15901 在 10 秒內沒有回應 VNC 訊號。請確認遠端已啟動 VNC 伺服器，並檢查 SSH 別名與主機指紋。」 |
| **第二使用者伺服器未啟動** | Vine Server 未啟動，或第二使用者帳號已登出 | 確認第二使用者帳號已登入且處於背景，Vine Server 已啟動且監聽 5901。 | 「找不到 VNC 伺服器：127.0.0.1:5901 在 10 秒內沒有回應 VNC 訊號。請確認第二使用者已登入，且 VNC 伺服器已啟動並只允許本機連線。」 |
| **安全類型不相容** | 伺服器只提供 macOS 螢幕共享不使用的安全類型（例如只開 `TLSVnc`） | 啟動時加上 `-SecurityTypes VncAuth`，或在 `~/.vnc/config` 設定。 | App 端顯示「已開啟螢幕共享」，但 macOS 螢幕共享彈出「不相容的安全類型」對話框且無法顯示畫面。 |
| **密碼輸入錯誤** | 在螢幕共享登入視窗輸錯 VNC 密碼，或 VNC 密碼超過 8 個字元 | 重新輸入密碼。若伺服器密碼超過 8 個字元，就算輸入完全正確，螢幕共享也會一直失敗（見 2.2 節），請用 `vncpasswd` 改成 8 個字元以內。 | 由 macOS 螢幕共享視窗直接提示密碼錯誤並要求重試（App 本身不接觸密碼）。 |

---

### 4.3 螢幕共享登入時會重新連線

實測發現，螢幕共享第一次連線只用來問出驗證方式並跳出密碼框。按下「登入」後，它會關掉這條連線，**再開一條新連線**帶著密碼登入。TigerVNC 等真實伺服器會持續監聽，所以不受影響。如果自己寫測試用的伺服器，記得不要在第一條連線結束時就退出。

### 4.4 本機驗證工具

- `scripts/check-docker-vps.sh`：用 Docker 跑 Debian 12、TigerVNC、xfce4、sshd，設定照本文件第 2 節，用來當成真實的 Linux VPS，從頭到尾驗證一次。
  - 需要 Docker Desktop。
  - 結束時會刪除容器。
  - 設定 `KEEP_IMAGE=1` 時保留映像檔。
  - `VNC_TEST_PASSWORD` 可以指定測試密碼，記得 8 個字元以內。

## 5. 官方查證來源與文件依據

本文件之設定與技術依據整理自以下官方與上游文件：

1. **TigerVNC 命令列參數與 SecurityTypes**：
   - Debian Manpages - tigervncserver(1): [https://manpages.debian.org/testing/tigervnc-standalone-server/tigervncserver.1.en.html](https://manpages.debian.org/testing/tigervnc-standalone-server/tigervncserver.1.en.html)
   - Debian Manpages - Xvnc(1): [https://manpages.debian.org/testing/tigervnc-standalone-server/Xvnc.1.en.html](https://manpages.debian.org/testing/tigervnc-standalone-server/Xvnc.1.en.html)
   - TigerVNC 官方 GitHub 專案：[https://github.com/TigerVNC/tigervnc](https://github.com/TigerVNC/tigervnc)
2. **Vine Server 本機連線設定**：
   - 上游說明文件 OSXvnc.html（`-localhost` 選項，以及必須使用 `127.0.0.1`）：[https://github.com/stweil/OSXvnc/blob/master/OSXvnc.html](https://github.com/stweil/OSXvnc/blob/master/OSXvnc.html)
   - 偏好設定視窗中的勾選項目名稱：未找到官方依據（未確認）。
3. **Homebrew Cask 套件名稱**：
   - Vine Server Cask: [https://formulae.brew.sh/cask/vine-server](https://formulae.brew.sh/cask/vine-server)（2026-10-20 查 API：`disabled: true`，2026-09-01 起停用，原因 `fails_gatekeeper_check`；**無法安裝**）
   - TigerVNC Cask: [https://formulae.brew.sh/cask/tigervnc](https://formulae.brew.sh/cask/tigervnc)（2026-10-20 查 API：1.16.2，未停用；`tigervnc-viewer` 在 API 已查無此 cask）

---

## 6. 未確認事項（待真機驗證）

以下項目依 PRD 第 10 節規範，尚未經實機驗收，維持「未確認」狀態：

1. **macOS「螢幕共享」連至本機 loopback（第二使用者）的相容性 [部分確認]**：2026-10-20 用 `scripts/check-screen-sharing-loopback.sh` 和本機假 RFB 伺服器實測，螢幕共享會連進 `127.0.0.1:5901`，並跳出密碼對話框，所以 loopback 沒有被擋。登入後的畫面傳輸，以及真正的 Vine Server 是否可用，仍待驗證。原本的說明如下：
   macOS 內建螢幕共享通常會拒絕連線至自己的 loopback（連向同一使用者）。連線至同一台 Mac 另一個使用者帳號監聽的 Vine Server（`127.0.0.1:5901`）是否會被 macOS 系統機制攔截，目前尚未在實機上確認。若被攔截，備用方案為安裝第三方檢視器（Homebrew cask `tigervnc`）。
2. **RFB 探測中斷對伺服器認證計數的影響 [TigerVNC 已確認]**：
   App 的探測機制在讀取前 12 位元組（`RFB 003.00x\n`）後即主動關閉 TCP 連線。2026-10-21 在 Ubuntu 26.04 的 TigerVNC 實測，log 記為 `Closing ...: Clean disconnection`，沒有認證失敗字樣。其他 VNC 伺服器（例如 Vine Server）仍未確認。
