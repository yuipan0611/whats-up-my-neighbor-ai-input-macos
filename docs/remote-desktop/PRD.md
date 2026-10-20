# PRD：遠端分身「接手控制」（VNC）

## 1. 文件資訊

| 欄位 | 內容 |
|---|---|
| 產品 | 遠端分身預覽（`tw.panh.NeighborRemoteAgentPreview`） |
| 功能 | 接手控制：一鍵用 macOS「螢幕共享」開啟遠端桌面 |
| 文件版本 | 0.1 |
| 日期 | 2026-10-20 |
| 狀態 | Approved／實作中 |
| 分支 | `codex/neighbor-remote-agent`，基於 `b2b887f` |
| 平台 | macOS 13 以上，只限獨立預覽；正式 App 不載入 |
| 交接板 | [HANDOFF.md](HANDOFF.md)：分工、檔案所有權、進度 |

## 2. 需求來源

使用者想把 [23jmo/second-self](https://github.com/23jmo/second-self) 的 VNC 部分放進自己的專案。second-self 的「VNC」其實由四塊組成：

| 區塊 | second-self 做法 | 本版 |
|---|---|---|
| 即時畫面小窗 | `VNCPipView.swift`：URLSession 讀 MJPEG（`:8421/stream`） | 不做 |
| **接手控制按鈕** | `open -a TigerVNC --args localhost:5901` | **做** |
| 遠端 VNC 伺服器 | 第二個 macOS 帳號裡跑 Vine Server `:5901` | 只提供設定文件（[SETUP.md](SETUP.md)） |
| 遠端操作 API | Python + PyAutoGUI 點擊／打字 | 不做 |

遠端目標兩種都要支援：**Linux VPS**，以及**同一台 Mac 的第二使用者**。

**授權：** second-self repo 沒有 LICENSE，依預設保留所有權利。本功能不複製它的任何檔案或程式碼，只參考「用按鈕開 VNC 檢視器」這個想法（想法不受著作權保護），實作全部自行撰寫。

## 3. 使用者與情境

使用者把工作交給遠端分身。分身做到一半，遇到需要本人親自處理的步驟，例如登入、雙重驗證，或送出前要人看一眼。這時使用者按「接手控制」，直接看到並操作遠端桌面，處理完再交回去。

成功的標準：

- 一個按鈕就能開出遠端桌面。
- 失敗時說得出是哪一段出問題：SSH、VNC 伺服器或檢視器。
- 不會在伺服器沒開的情況下開出一個空白的檢視器。

## 4. 產品決策

### 4.1 支援的行為

- 面板側欄「執行環境」下方新增「接手控制」區（側欄在內容超出視窗高度時可捲動），內容包括：
  - 目標選擇：`Linux VPS`／`本機第二使用者`。
  - 選 VPS 時，顯示「SSH 主機別名」欄位。只接受 `~/.ssh/config` 裡既有的別名，規則沿用 `SSHTunnelConfiguration`。
  - 按鈕「接手控制」、狀態文字，以及進行中才出現的「結束接手」。
- VPS 流程：用系統 SSH 開本機轉送 `127.0.0.1:15901 → 遠端 127.0.0.1:5901`，確認是 VNC 伺服器之後，開啟 `vnc://127.0.0.1:15901`。
- 第二使用者流程：不開 SSH，確認 `127.0.0.1:5901` 是 VNC 伺服器之後，開啟 `vnc://127.0.0.1:5901`。
- 檢視器固定用 macOS 內建「螢幕共享」（`com.apple.ScreenSharing`）。
- 開啟之前先做 RFB 探測：讀伺服器送來的前 12 bytes，必須是 `RFB ddd.ddd\n` 格式。
- 「結束接手」只停掉本 App 自己開的 SSH 程序。結束預覽 App 時也會自動停止。
- 主機別名只存在記憶體，不寫入偏好檔。

### 4.2 不支援的行為

- 即時畫面小窗或 MJPEG 串流。
- AI 透過 API 點擊、打字或控制桌面。
- 自動在遠端安裝或啟動 VNC 伺服器、自動建立 macOS 使用者。
- 保存、輸入或傳送 VNC 密碼。密碼只由使用者在「螢幕共享」的對話框輸入。
- 讓使用者自由輸入主機、IP、埠或 URL；也不產生非 `127.0.0.1` 的 VNC 網址。
- 對外開放 5901，或繞過 SSH 主機驗證。
- 斷線自動重連或自動重試接手。
- TigerVNC 等第三方檢視器（列為備案，見第 10 節）。
- 整合進正式語音輸入 App。

## 5. 使用流程與狀態

```text
[接手控制]
  ├─ Linux VPS：開 SSH 通道 → 探測 127.0.0.1:15901 → 開螢幕共享
  └─ 第二使用者：探測 127.0.0.1:5901 → 開螢幕共享
[結束接手] → 停掉自己開的 SSH（螢幕共享畫面跟著中斷）
```

| 狀態 | 意思 | 面板顯示 |
|---|---|---|
| `idle` | 尚未接手 | 按鈕可按 |
| `openingTunnel` | 正在啟動 SSH（只有 VPS） | 「正在建立 SSH 通道…」，「結束接手」停用 |
| `probing` | 正在確認 VNC 伺服器 | 「正在確認 VNC 伺服器…」，可按「結束接手」 |
| `openingViewer` | 探測通過，正在啟動螢幕共享 | 「正在開啟螢幕共享…」，「結束接手」停用，因為 `open` 已送出，結束也攔不住視窗出現 |
| `viewerOpened` | 已開啟螢幕共享 | 成功文案；可按「結束接手」 |
| `stopped` | 使用者結束 | 回到可按 |
| `failed(訊息)` | 任一段失敗 | 錯誤文案；按鈕可再按 |

規則：

- SSH `processRunning` **不算成功**。只有 RFB 探測通過，才進入「開檢視器」。
- VPS 開通道前，先用 `connect` 確認本機 15901 **沒有程式在監聽**：連線被拒才算空著。剛結束的連線留下的 TIME_WAIT 不算佔用。如果被佔用，例如被上次沒有結束的 ssh 佔著，直接進入 `failed`，不建立通道也不探測，避免探測到舊通道後開到錯的主機。
- 新一次接手開始後，舊的回呼一律忽略，用 generation token 做到，與 `SSHTunnel.swift` 相同。
- 任何失敗都會停掉本次的 SSH 程序，不自動重試。

## 6. 文案

| 情境 | 文字 |
|---|---|
| 成功 | 已開啟「螢幕共享」。VNC 密碼請在螢幕共享視窗輸入；本 App 不保存密碼。 |
| 探測逾時（VPS） | 找不到 VNC 伺服器：127.0.0.1:15901 在 10 秒內沒有回應 VNC 訊號。請確認遠端已啟動 VNC 伺服器，並檢查 SSH 別名與主機指紋。 |
| 探測逾時（第二使用者） | 找不到 VNC 伺服器：127.0.0.1:5901 在 10 秒內沒有回應 VNC 訊號。請確認第二使用者已登入，且 VNC 伺服器已啟動並只允許本機連線。 |
| SSH 無法建立，或在開啟螢幕共享前就結束 | SSH 通道沒有建立成功或已結束。請檢查 SSH 別名、金鑰登入與主機指紋後，再按一次「接手控制」。 |
| SSH 在接手中結束 | SSH 通道已中斷，螢幕共享畫面會停止。請確認連線後再按一次「接手控制」。 |
| 無法開啟螢幕共享 | 無法開啟「螢幕共享」。請確認系統內建 App 可用後再試。 |
| 重複啟動 | 接手控制已在進行中，請先結束。 |
| 本機 15901 被佔用（只有 VPS） | 本機 127.0.0.1:15901 已被其他程式佔用，可能是先前沒有結束的 SSH 通道。請用「lsof -nP -iTCP:15901」找出並結束它，再按一次「接手控制」。 |
| 別名不合法 | 沿用 `SSHTunnelError.invalidAlias` 的既有文字。 |
| 常駐提醒 | 需先在遠端啟動 VNC 伺服器，設定見 docs/remote-desktop/SETUP.md。 |
| 結束（VPS） | 已結束接手，SSH 通道已關閉。 |
| 結束（第二使用者） | 已結束接手。螢幕共享視窗若仍開著，請自行關閉。 |

## 7. 技術規格（介面契約）

### 7.1 埠與網址

| 目標 | SSH | 探測埠 | 檢視器網址 |
|---|---|---|---|
| Linux VPS | `-L 127.0.0.1:15901:127.0.0.1:5901 -- <alias>` | 15901 | `vnc://127.0.0.1:15901` |
| 本機第二使用者 | 無 | 5901 | `vnc://127.0.0.1:5901` |

VPS 的本機埠用 15901，避免跟第二使用者的 5901 撞埠。網址只由 `127.0.0.1` 和程式內的整數常數組成。

### 7.2 RFB 探測

- 一次嘗試：連到 `127.0.0.1:{port}`，讀剛好 12 bytes，然後關閉連線。每次最多等 `min(2 秒, 距離期限的剩餘時間)`，所以整體不會超過 10 秒。
- 判定成功的條件：資料符合 `^RFB \d{3}\.\d{3}\n$`。
- 重試：每 0.5 秒試一次，從開始算起最多 10 秒。轉送剛建立時還沒就緒，所以需要重試。
- 不送出任何資料，不進行 VNC 認證。

### 7.3 檢視器啟動

- 執行 `/usr/bin/open`，參數陣列為 `["-b", "com.apple.ScreenSharing", url]`，不經過 shell。參數由純函式 `ScreenSharingLauncher.arguments(for:)` 產生；網址不合規時回傳 nil，就不執行。
- `open` 回傳非 0 視為失敗。

### 7.4 程式結構

| 檔案 | 責任 |
|---|---|
| `Sources/NeighborAgentCore/RemoteDesktopHandoff.swift`（新增） | `RemoteDesktopTarget`、`RFBBanner`、`VNCServerProbing`＋`SystemVNCProbe`（Network.framework）、`RemoteViewerLaunching`＋`ScreenSharingLauncher`、`RemoteDesktopHandoffController`（狀態機）。只依賴 Foundation、Network |
| `Sources/NeighborAgentCore/SSHTunnel.swift`（**不改**） | 以 `SSHTunnelConfiguration(hostAlias:localPort:15901, remotePort:5901)` 重用 |
| `Previews/RemoteAgent/RemoteDesktopHandoffModel.swift`（新增） | 面板用的 ObservableObject；別名只存在記憶體 |
| `Previews/RemoteAgent/RemoteAgentView.swift`、`PreviewMain.swift`、`PreviewRenderer.swift`、`build-preview.sh`（修改） | UI、結束時 `stop()`、新增兩張預覽圖、加入編譯清單 |
| `Tests/RemoteDesktopHandoffTests.swift`、`scripts/test-remote-desktop.sh`（新增） | 離線測試；`test-all.sh` 自動納入 |

## 8. 安全與隱私

- 沿用既有 SSH 參數的安全限制，包括：`BatchMode`、`StrictHostKeyChecking=yes`、不轉送 agent 或 X11、不執行遠端命令。
- 只連 loopback，不碰 Keychain，不需要新的 TCC 權限（麥克風、螢幕錄製、輔助使用都不用）。
- VNC 伺服器端的強權限（第二使用者帳號的「螢幕錄製」與「輔助使用」）由使用者依 [SETUP.md](SETUP.md) 自行授權，App 不代辦。
- 不記錄伺服器回應內容，也不把 SSH 的 stderr 寫入記錄。

## 9. 驗收標準

**離線（`./scripts/test-remote-desktop.sh`）**

- [ ] URL 只會是 `vnc://127.0.0.1:<port>`。
- [ ] 非法別名在建立任何程序之前就被拒絕。
- [ ] VPS 的通道參數為 15901→5901。
- [ ] 探測成功後才開檢視器。
- [ ] 探測逾時：狀態變失敗，停掉通道，不開檢視器。
- [ ] 探測中 SSH 斷線：狀態變失敗。
- [ ] 探測中按「結束接手」：晚到的成功回呼被忽略。
- [ ] 重複啟動被拒絕。
- [ ] 第二使用者模式不建立 SSH 程序。
- [ ] 檢視器啟動失敗：狀態變失敗，並停掉通道。
- [ ] 接手中 SSH 斷線：顯示「通道已中斷」。
- [ ] RFB 解析：接受 `RFB 003.008\n`，拒絕 `HTTP/1.1`、長度不足、`RFB 3.8\n`。
- [ ] 15901 被佔用時 VPS 直接失敗；第二使用者模式不做這個檢查。
- [ ] 每次探測的逾時不超過剩餘期限（最後三次依序為 1.5、1.0、0.5 秒）。
- [ ] 上一次 VPS 執行留下的 SSH 結束回呼，不會中斷下一次。
- [ ] 啟動器參數固定為 `-b com.apple.ScreenSharing <url>`，不合規網址不產生參數。
- [ ] 真實探測不送任何資料給伺服器；完成後再呼叫取消，也不會再次回呼；連線被拒時 0.5 秒內回報。
- [ ] 真實埠號檢查：被佔用的埠回報忙碌，釋放後回報空著；伺服器端先關、留下 TIME_WAIT 時也回報空著（舊的 bind 實作會在這裡誤報）。
- [ ] 面板：`openingViewer` 時不能按「結束接手」；結束後若輸入不合法別名，只顯示錯誤。
- [ ] 用真實 loopback 監聽器測 `SystemVNCProbe` 三種情況：回 RFB → 成功；回 HTTP → 失敗；沒有監聽 → 在逾時內失敗。

**回歸**

- [ ] `./scripts/test-all.sh` 全部通過（26 組變 27 組）。
- [ ] `./scripts/build.sh` 通過。
- [ ] 正式 App 的 `Sources/GroqVoiceInput`、`Resources`、`scripts/build.sh` 與 `3101f03` 相比沒有差異。

**預覽與本機**

- [ ] `build-preview.sh` 通過；8 張預覽圖（含淺色、深色、窄版）沒有破版。
- [ ] 5901 沒有伺服器時按「接手控制」：顯示探測逾時文案，而且**不開**螢幕共享。

**真機（需要使用者配合）**

- [ ] 第二使用者裝好 Vine Server 後，按按鈕會開出螢幕共享，並看到該帳號的桌面。
- [x] VPS 依 SETUP.md 設定後，透過別名接手成功（2026-10-21，Hostinger Ubuntu 26.04；見 `reports/REMOTE_DESKTOP_VPS_2026-10-21.md`）。

## 10. 未確認事項

- **螢幕共享 App 連同一台 Mac 的 loopback：已部分確認（2026-10-20 實測）。** 以本機假 RFB 伺服器測試：螢幕共享會連進 127.0.0.1:5901，使用 RFB 3.3，即使伺服器選 None 仍會跳出密碼對話框。這表示 loopback 沒有被擋。登入後的畫面傳輸已在 2026-10-21 由真實 VPS 確認：使用者看到 XFCE 桌面，滑鼠鍵盤可用，伺服器 log 記到 42 個畫面區塊。仍待確認的只剩真正的 Vine Server 在另一個帳號裡是否可用。另外，用本機 sshd 模擬 VPS 時，SSH 轉送這條路也已端到端走通。見 `reports/REMOTE_DESKTOP_HANDOFF_2026-10-20.md`。
  - 如果被擋：加入 TigerVNC Viewer 當備援（cask 名稱為 `tigervnc`，2026-10-20 查 Homebrew API；舊名 `tigervnc-viewer` 已查無），bundle ID 以安裝後的 Info.plist 為準。
- **待使用者決定：第二使用者要用哪一個 VNC 伺服器。** Homebrew 的 `vine-server` 自 2026-09-01 起停用，原因是 `fails_gatekeeper_check`，`brew install` 會失敗。可選的做法有三種：
  - 手動下載並繞過 Gatekeeper。風險最高，因為它還要拿到螢幕錄製與輔助使用權限。
  - 改用其他有簽章的 VNC 伺服器，需另行評估。
  - 先只用 VPS。

  App 端不需要修改：任何在 127.0.0.1:5901 回應 RFB 的伺服器都能用。詳見 [SETUP.md](SETUP.md) 第 3.3 節。
- **macOS 螢幕共享與 TigerVNC 伺服器的相容性：已確認（2026-10-21）。** Ubuntu 26.04 的 TigerVNC 以 `-SecurityTypes VncAuth` 啟動，螢幕共享走 RFB 3.3，密碼登入後可正常操作。
- 探測讀完開頭訊息就斷線：TigerVNC 記為 `Clean disconnection`，沒有認證失敗（2026-10-21 確認）。Vine Server 仍未確認。

## 11. 後續（不在本版）

- 即時畫面小窗（MJPEG 或 VNC 縮圖）。
- AI 分身與人同時操作同一個桌面時的交接協定，例如接手時暫停 agent。
- 整合進正式 App 的黑貓選單。
