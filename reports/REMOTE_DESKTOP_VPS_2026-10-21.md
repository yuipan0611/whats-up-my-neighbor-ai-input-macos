# 接手控制：真實 VPS 驗證紀錄（2026-10-21）

- 分支：`codex/neighbor-remote-agent`，基於 `a91b33c`。
- VPS：Hostinger KVM 2，Jakarta，Ubuntu 26.04 LTS，`srv2079497.hstgr.cloud`。
  - 帳號 `neighbor`：無 sudo，只接受金鑰 `~/.ssh/neighbor_vps_ed25519` 登入。
  - Mac 別名 `neighbor-vps`，`StrictHostKeyChecking yes`。
- 主機金鑰：首次連線前，使用者在 hPanel Web console 核對 ED25519 指紋 `SHA256:3eJre/9206DgAQw0Q3YSGg7y0bBKctL1PhXUElpGwko`。
- 設定方式：使用者以 root 執行 `scripts/vps-bootstrap-ubuntu.sh`，再以 neighbor 執行 `vncpasswd` 和 `vncserver :1 -localhost yes -SecurityTypes VncAuth`。

## 已驗證

| 項目 | 結果 |
|---|---|
| 金鑰登入 | `ssh -o BatchMode=yes neighbor-vps` 成功；`sudo -n` 被拒，確認沒有 sudo |
| VNC 只聽 loopback | Xtigervnc 只監聽 `127.0.0.1:5901` 與 `[::1]:5901`；從外部連 5901 連不到；ufw 只開 22 |
| 自動檢查 | `CHECK_WAIT=180 ./scripts/check-real-vps.sh` 結束碼 0，狀態依序為 `openingTunnel → probing → openingViewer → viewerOpened → stopped`，`tunnel closed after stop: true` |
| 登入後畫面與輸入 | 使用者在螢幕共享輸入 VNC 密碼，回報看得到 XFCE 桌面，滑鼠和鍵盤都能用。伺服器 log：連線 49588 完成像素格式協商，結束時記錄 `Framebuffer updates: 6`、`42 rects, 2.30 Mpixels, 30.4 KiB`（ZRLE） |
| 螢幕共享連線流程 | 跟 2026-10-20 在本機觀察到的一樣：第一條連線停在密碼框就被關掉，登入時重新連一條。協定是 RFB 3.3 |
| 探測對伺服器的影響（PRD 第 10 節） | 每次 12-byte 探測，TigerVNC 都記為 `Closing ...: Clean disconnection`。新增的 44 行 log 中，沒有任何含 auth 失敗字樣的行 |
| 預覽 App | 選「Linux VPS」、別名 `neighbor-vps` 後按「接手控制」：15901 由 ssh 監聽，螢幕共享開啟，面板顯示「已開啟『螢幕共享』…」。按「結束接手」：顯示「已結束接手，SSH 通道已關閉」，15901 沒有監聽，也沒有殘留的 ssh。預覽 App 這次沒有輸入密碼，登入後的畫面已由上一列的自動檢查驗證 |

## 未驗證

- 預覽 App 那一次沒有登入。它跟自動檢查用的是同一個 `RemoteDesktopHandoffController` 和 `SSHTunnelController`，差別只在 UI。
- ~~長時間連線與網路中斷~~：已由下方 T5d 補測通過。
- 第二使用者目標，以及 Vine Server。
- SETUP.md 2.9 節的 SSH 收緊與 systemd 開機自動啟動。

## 需要使用者

1. 在 hPanel Web console 以 root 執行 SETUP.md 2.9 節，關閉密碼登入、root 只准金鑰登入。執行完告訴 Claude，Claude 會從 Mac 確認只剩 `publickey`。
2. 選用：讓 VNC 開機自動啟動。在那之前，VPS 重開機後要再以 neighbor 執行一次 `vncserver :1 -localhost yes -SecurityTypes VncAuth`。
3. 決定第二使用者要用哪個 VNC 伺服器（PRD 第 10 節）。

## 補測：長時間連線與網路中斷（T5d，2026-10-21）

工具是 `scripts/check-real-vps-drop.sh` 加 `Tests/RemoteDesktopVPSDropCheck.swift`。它用 App 原本的控制器與 SSH 參數，透過使用者的 `neighbor-vps` 別名連線；啟動器換成記錄用的假元件，不打開螢幕共享，所以不需要人輸入。

| 項目 | 結果 |
|---|---|
| 長時間連線（`HOLD_SECONDS=600`） | 10 分鐘內每 10 秒檢查一次，共 59 次，全部通過：<br>• 狀態維持 `viewerOpened`<br>• 15901 有程式在監聽<br>• 經由通道的 RFB 探測成功 |
| 網路中斷 | 在 VPS 上只對這條通道新出現的那一個 `sshd-session` 送出 `kill -STOP`，模擬封包有去無回的斷線。依 App 的 `ServerAliveInterval=15`、`ServerAliveCountMax=2`，本機 ssh 在 **36.6 秒**後結束，面板狀態變成「SSH 通道已中斷，螢幕共享畫面會停止…」，15901 隨即釋放。<br>（30 秒短版試跑也得到相同結果，耗時 34.4 秒） |
| 清理 | 結束後，遠端 neighbor 的 sshd 程序清單和執行前完全一樣，使用者原本的 `pts/1` 工作階段沒有被碰到；本機沒有殘留 ssh |
| 試跑發現並修正 | 檢查程式的輸出被緩衝；被結束時，App 開的 ssh 會殘留。已讓輸出逐行送出，收到結束訊號時先收掉通道，腳本另外用精確參數再清一次 |

結論：長時間連線穩定；網路中斷時約 30～45 秒內會顯示「通道已中斷」，不會自動重連，符合 PRD 第 5 節。
