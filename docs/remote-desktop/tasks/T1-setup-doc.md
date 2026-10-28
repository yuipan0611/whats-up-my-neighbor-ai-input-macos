# T1 任務說明（給 Antigravity）

> 派工方式：在 Antigravity 輸入「請讀 docs/remote-desktop/tasks/T1-setup-doc.md 並照做」。

你負責交接板上的任務 T1：在目前這個 worktree（`neighbor-remote-agent`，分支 `codex/neighbor-remote-agent`）**只新增一個檔案** `docs/remote-desktop/SETUP.md`，用繁體中文撰寫。

開始前請先讀完這兩份：
1. `docs/remote-desktop/HANDOFF.md`：分工、規則、回報格式。
2. `docs/remote-desktop/PRD.md`：功能規格。埠號、網址、流程以第 7 節為準，不要更動。

## SETUP.md 要寫的內容

1. **這顆按鈕做什麼、不做什麼**：只開檢視器；不安裝伺服器；不讓 AI 操作桌面；不保存 VNC 密碼。
2. **Linux VPS 設定**
   - 安裝 TigerVNC 伺服器（Debian／Ubuntu 套件 `tigervnc-standalone-server`）與 `xfce4`。
   - 用 `vncpasswd` 設定密碼。
   - 以 `vncserver :1 -localhost yes -SecurityTypes VncAuth` 啟動：只聽 localhost，並使用 macOS 螢幕共享相容的 VncAuth。
   - 防火牆不開 5901。
   - 自我檢查：`ss -ltn | grep 5901`。
   - 說明 VncAuth 密碼只有前 8 字有效，傳輸由 SSH 加密。
   - Mac 端的 `~/.ssh/config` 別名範例，主機名稱與帳號用 `<佔位符>`，不要寫真實值。
3. **Mac 第二使用者設定**
   - 用「系統設定」建立**一般使用者**（不要給管理員）。
   - 該帳號登入一次，並開啟「快速切換使用者」。
   - 在該帳號安裝 Vine Server（`brew install --cask vine-server`），設定：埠 5901、只允許本機連線、VNC 密碼。
   - 在該帳號授權「螢幕錄製」與「輔助使用」，並說明這是強權限。
   - 說明為什麼不用內建螢幕共享伺服器（5900）：它分享的是目前前景的使用者。
4. **排錯**
   - `nc -w 2 127.0.0.1 15901 </dev/null | head -c 12`（第二使用者改用 5901）應該看到 `RFB 003.00x`。
   - 依序列出常見失敗原因：SSH 別名、主機指紋、伺服器沒啟動、安全類型不相容、密碼錯誤。
   - 每一項對應 PRD 第 6 節中 App 會顯示的哪一句錯誤文案。
5. **未確認事項**：照 PRD 第 10 節寫，不要寫成已驗證。

## 查證要求

以下三點請用官方或上游文件查證，並在文件附上來源連結：
- TigerVNC 的 `-localhost`、`-SecurityTypes VncAuth` 參數寫法，以及與 macOS 螢幕共享的相容性。
- Vine Server「只允許本機連線」設定的實際名稱。
- Homebrew cask 名稱：`vine-server`、`tigervnc-viewer`。

查不到依據的內容，標註「未確認」。

## 限制（務必遵守）

- 只新增 `docs/remote-desktop/SETUP.md`，不改其他任何檔案。唯一的例外：在 `HANDOFF.md` 的「進度紀錄」最後加一行回報。
- 不 commit、不切換分支、不 stash、不 push。
- 不在任何機器上安裝或執行 VNC 伺服器，不建立使用者，不連線 VPS。

## 完成時

依 HANDOFF.md 的回報格式加一行進度紀錄，並在對話裡列出：檔案路徑、每個查證點的來源連結、仍標為「未確認」的項目。
