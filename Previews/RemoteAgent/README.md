# 遠端分身獨立預覽

本機示範原型，非正式 App 更新。三家 AI 均待遠端驗證。

從此分支根目錄執行：

```sh
./Previews/RemoteAgent/build-preview.sh
open "$PWD/build/remote-agent-preview/遠端分身預覽.app"
```

1. 點「填入範例」或自行輸入文字。
2. 選擇 AI 標籤；三種選項都使用相同固定示範，不會呼叫模型。
3. 點「執行示範」或按 ⌘ Return，約五秒後顯示結果。
4. 執行中可按「取消示範」或 Esc。取消不會產生完成結果。

示範不連網、不開瀏覽器、不控制桌面、不建立備忘錄、不錄音。任務與結果只存在記憶體；結束預覽即清除。只保存選擇的 AI 名稱於：

`~/Library/Application Support/tw.panh.NeighborRemoteAgentPreview/preferences.json`

預覽不註冊全域快捷鍵、不建立登入啟動項目、不讀取正式 App 的 Keychain／設定。使用現有核准 App 圖示，沒有改動圖片。

## 驗證

```sh
./scripts/test-agent-core.sh
./scripts/test-agent-preview.sh
./scripts/test-agent-ssh.sh
./scripts/test-remote-desktop.sh
```

另外有一支需要畫面的檢查，`test-all.sh` 不會執行它。它會啟動本機假 VNC 伺服器，並實際開啟「螢幕共享」：

```sh
CHECK_WAIT=90 ./scripts/check-screen-sharing-loopback.sh
```

密碼對話框出現時，輸入任意字元即可，假伺服器不驗證密碼。

要模擬 VPS 路徑時，執行下面這支。它會在 127.0.0.1:22922 用臨時金鑰跑一個一般使用者權限的 sshd，不碰 `~/.ssh`，也不需要 sudo：

```sh
CHECK_WAIT=10 ./scripts/check-vps-path-loopback.sh
```

重現八種原生畫面（只繪製本 App，不擷取桌面；包含接手中與窄版深色失敗兩張）：

```sh
"build/remote-agent-preview/遠端分身預覽.app/Contents/MacOS/NeighborRemoteAgentPreview" \
  --render-previews "$PWD/build/remote-agent-preview/renders"
```

側欄「接手控制」是面板唯一的真實連線入口：只在按下時建立 SSH 通道（VPS）或直接探測本機 5901（第二使用者），確認 VNC 伺服器有回應後，才開啟內建「螢幕共享」。規格見 `docs/remote-desktop/PRD.md`。任務示範本身仍然不連線。整體驗收及後續事項見 `docs/REMOTE_AGENT_PREVIEW.md`。
