# 接手控制（VNC）驗證紀錄

日期：2026-10-20（台北）。分支 `codex/neighbor-remote-agent`。此交付是本機獨立預覽的功能，非正式 App 更新；未 push、未合併、未發布。

## 分工

| 工作 | 執行者 | 審閱與驗證 |
|---|---|---|
| PRD、交接板、核心狀態機、面板 UI | Claude | 由獨立審閱 agent 做對抗式審查；Comment Sicko 清理註解 |
| SETUP.md（T1） | Gemini（Antigravity `agy` CLI） | Claude 查證並修正事實 |
| 審閱修正（R1） | Gemini | Claude 編譯、測試，並做 mutation 測試 |
| 假 VNC 伺服器與 loopback 檢查工具（T5a、R2） | Gemini | Claude 修正腳本並實際執行 |
| VPS 路徑本機模擬（T5b）、TIME_WAIT 誤報修正（R3、R3b） | Gemini | Claude 先做原型，再做 mutation 驗證並實際執行 |

## 已驗證

| 項目 | 結果與實際範圍 |
|---|---|
| 離線測試 | `scripts/test-remote-desktop.sh` 32 情境通過。涵蓋：<br>• 狀態機、generation 擋舊回呼、15901 佔用、探測期限上限<br>• 啟動器參數、面板 model<br>• 7 種真實 loopback 探測與埠號檢查 |
| mutation 測試 | 拿掉埠號檢查、拿掉每次探測的期限上限、拿掉 `.waiting` 分支，三組都讓測試失敗 |
| 真實探測，無伺服器 | 對沒有伺服器的 5901，9.9 秒後顯示第二使用者的逾時文案，檢視器啟動 0 次 |
| 真實螢幕共享與 loopback | `scripts/check-screen-sharing-loopback.sh` 依序啟動本機假 RFB 伺服器、真實控制器、真實探測與 `open -b com.apple.ScreenSharing`：<br>• 控制器走完 `probing → openingViewer → viewerOpened`<br>• 螢幕共享**有連進** 127.0.0.1:5901，回覆 `RFB 003.003`<br>• 伺服器以 3.3 協定選擇安全類型 1（None）後，螢幕共享仍跳出「需要密碼來登入『127.0.0.1:5901』」 |
| 預覽 App 的 UI 點擊 | 使用者第二次授權後實際操作。步驟：<br>1. 在 5901 啟動假伺服器。<br>2. 在預覽 App 選「本機第二使用者」，按「接手控制」。<br>3. 面板顯示「已開啟『螢幕共享』…本 App 不保存密碼」，目標選單停用，按鈕變成「結束接手」。<br>4. 真實螢幕共享跳出 127.0.0.1:5901 的密碼框。<br>5. 按「結束接手」，面板顯示「已結束接手。螢幕共享視窗若仍開著，請自行關閉。」。<br>server.log 先記到 App 的探測，再記到螢幕共享以 RFB 3.3 連入 |
| VPS 路徑端到端（本機 sshd 模擬） | `scripts/check-vps-path-loopback.sh` 結束碼 0。<br>• 用一般使用者權限在 127.0.0.1:22922 跑臨時 sshd，金鑰是臨時產生的，不碰 `~/.ssh`。<br>• App 的 SSH 參數一字不改，只在最前面加 `-F`。<br>• 控制器依序走過 `openingTunnel → probing → openingViewer → viewerOpened`。<br>• sshd 接受金鑰，探測和螢幕共享都**經由 SSH 轉送**連到 5901，螢幕共享回覆 RFB 3.3。<br>• 按「結束接手」後 ssh 斷線，15901 立刻判定為空著，臨時私鑰已刪除 |
| 實測抓到並修正的 bug | 結束接手後，被轉送的連線讓 15901 進入 TIME_WAIT，大約 30 秒。舊的 bind 檢查在這段時間會誤報「15901 已被佔用」。現在改用 connect 判斷有沒有程式在監聽，並新增一個重現測試，舊實作在這個測試下會失敗 |
| 預覽圖 | 8 張，包含接手中與窄版深色失敗，皆已人工檢查 |
| 回歸 | 見文末的最終回歸結果 |

### 這次實測回答的未知數

- PRD 第 10 節擔心螢幕共享會拒絕連到同一台 Mac 的 loopback。實測顯示：對非 Apple 的 VNC 伺服器，它會連線，並一路走到登入步驟。
  - 這次只證明網路連線與 RFB 握手可以進行。真正的 Vine Server 在另一個使用者帳號裡是否可用，仍待真機驗證。
- 螢幕共享對非 Apple 伺服器使用 RFB 3.3。伺服器即使選 None，它仍會先要求密碼。

## 尚未驗證

- **登入之後的畫面傳輸。** 需要有人在密碼對話框輸入任意字元，假伺服器不會驗證：

  ```sh
  CHECK_WAIT=90 ./scripts/check-screen-sharing-loopback.sh
  ```

  依安全規則，Claude 不在系統 App 的密碼對話框代為輸入。
- **真實的第二使用者與真實的 VPS。**
  - 第二使用者：Homebrew 的 `vine-server` 自 2026-09-01 起停用（`fails_gatekeeper_check`），要用哪一個伺服器待使用者決定（PRD 第 10 節）。
  - VPS：需要連線資料。本機 sshd 模擬已經驗證 SSH 轉送這條路；真實 VPS 剩下的差異是網路、遠端的 TigerVNC 和主機指紋。

## 證據位置

| 證據 | 位置 | 進版控 |
|---|---|---|
| 檢查工具 | `scripts/fake-rfb-server.py`、`scripts/check-screen-sharing-loopback.sh`、`scripts/check-vps-path-loopback.sh`、`Tests/RemoteDesktopLiveCheck.swift`、`Tests/RemoteDesktopVPSLiveCheck.swift` | 是 |
| UI 點擊與 VPS 模擬的 log 與截圖 | `build/ui-check/`、`build/vps-loopback-check/` | 否 |
| 實測 log 與預覽圖 | `build/loopback-check/`、`build/remote-agent-preview/renders-handoff/` | 否 |
| Gemini 的執行紀錄 | `build/agy-*.log` | 否 |

## 最終回歸結果

- 基準 commit：見文末的最終回歸附記。
- 測試：`./scripts/test-all.sh` 的 27 組離線測試全部通過，接手控制那組是 32 個情境。
- 建置：`./scripts/build.sh` 通過，產物同時包含 x86_64 與 arm64。
- 正式 App：`Sources/GroqVoiceInput`、`Resources`、`scripts/build.sh` 與 `3101f03` 相比沒有差異（0 行）。
- 未安裝、未替換目前使用中的 App。

### 最終回歸附記

- 基準 commit：`8037c7a`。
- 測試：`./scripts/test-all.sh` 的 27 組全部通過，接手控制那組增為 33 個情境。
- 建置：`./scripts/build.sh` 通過，產物同時包含 x86_64 與 arm64。
- 正式 App：原始碼與 `3101f03` 相比沒有差異（0 行）。

## 2026-10-21 補充：Docker（Debian 12）端到端，以及 VNC 密碼 8 字元限制

真實 VPS（Hostinger、Ubuntu 26.04）的結果見 `REMOTE_DESKTOP_VPS_2026-10-21.md`。這一節是另一條平行的驗證。

### 做法

`scripts/check-docker-vps.sh` 用 Docker 跑 Debian 12，TigerVNC 1.12、xfce4、sshd 都照 SETUP.md 第 2 節設定。只把 sshd 開在 Mac 的 127.0.0.1:22923，VNC 只聽容器內的 loopback。App 的 VPS 路徑經由真的 SSH 通道連進去，最後由使用者在螢幕共享輸入密碼。

### 結果

| 測試 | 結果 |
|---|---|
| SETUP.md 自我檢查 | 5901 只聽 `127.0.0.1` 與 `[::1]` |
| 密碼 `neighbor1`（9 字元） | 使用者輸入完全相同的 9 個字元，TigerVNC 仍判定 `Authentication failure`。<br>• Claude 解出伺服器存的密碼是 `neighbor`，也就是前 8 個字。<br>• 用同一組密碼的標準 VncAuth 客戶端（Python 加 openssl DES）能登入，前 8 個字錯的對照組則失敗。<br>• 結論：螢幕共享不會像標準客戶端那樣把超過 8 字元的密碼截斷 |
| 密碼 `neighbor`（8 字元） | 一次登入成功。TigerVNC 記到 `Client pixel format depth 32`，送出 4 次畫面更新，螢幕共享顯示 xfce 桌面（截圖：`build/docker-vps-evidence/screen-sharing-xfce-desktop.jpg`） |
| 結束接手 | 15901 立即釋放，檢查腳本結束碼 0 |

### 順帶修正

- Debian 12 的 `vncpasswd` 在 `tigervnc-tools` 套件，SETUP.md 已明確列出。
- 螢幕共享登入時會重新連一條線，假伺服器原本在第一條連線結束時就退出，現在改為持續監聽，直到送出畫面的那條連線結束。修正後，螢幕共享登入後顯示了假伺服器的測試圖樣（上綠下灰），截圖在 `build/loopback-check/screen-sharing-after-login.jpg`。

### 過程中的溝通失誤

第 5 次測試前，Claude 把伺服器密碼改成 8 字元，但只在訊息中提了一句，使用者沒看到，所以仍然輸入 9 字元，該次測試等於沒有測到 8 字元。之後先跟使用者確認、說清楚，第 6 次才得到有效結果。以後改測試參數時，要先確認對方知道，再開始執行。

### 收尾

測試容器、`neighbor-vps-test:local` 與 `debian:bookworm-slim` 映像檔都已刪除，Docker Desktop 已關閉，臨時私鑰與密碼檔已刪除。
