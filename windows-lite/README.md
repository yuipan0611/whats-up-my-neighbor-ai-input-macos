# NekoNode / NekoChat Windows Lite

Windows 10/11 x64，桌面貓咪、好友文字聊天、全系統語音輸入與聊天語音草稿。與 macOS Swift App 並存，不含 AI Agent 或遠端控制。

## 同學安裝：一個安裝檔

1. 在 PR 的 **NekoChat Windows Lite** Actions 下載 `nekochat-windows-lite-setup`，解開 GitHub artifact ZIP，雙擊 `NekoChat-Setup-win-x64.exe`。
2. 按 **安裝並啟動**。安裝到目前使用者的 `%LOCALAPPDATA%\Programs\NekoChat.WindowsLite`，建立開始功能表捷徑，隨即開啟 App。內含 .NET 與房間服務，**不需另外安裝 Python、.NET、Git，也不用執行指令或改 JSON**。
3. 在「開始使用」填自己的 Groq API Key，按儲存，即可在記事本以 `Ctrl + Alt + Space` 測試語音。文字聊天不需要 Groq Key。

這是尚未簽署的試用安裝檔。學校若阻擋，請交由教室管理者審核，不需停用安全機制。安裝不要求管理員，不設自動啟動、不改防火牆。更新前需從貓咪右鍵選單離開舊版；個人設定與 OS 憑證保留，舊程式資料夾保留在同一 Programs 目錄的 `.nekochat-previous-*` 供復原。

## 兩台互傳：建立／加入房間

1. 兩台連上可互連的教室網路。
2. A 在「開始使用」按 **建立房間**，再按 **複製邀請碼**，私下交給 B。A 的 App 會啟動已內建的房間服務，產生兩組不同帳號／憑證與雙向好友授權；只綁定本機及私有 IPv4，不寫房間設定檔。
3. B 貼到 **同學給你的邀請碼**，按 **加入房間**。App 自動找出位址、驗證房間並設定收件人，無需填 IP、帳號或好友 ID。
4. B 開啟聊天頁傳送「你好」，A 的貓咪頭上應出現文字氣泡；A 點氣泡即可回覆。
5. A 按 **離開房間**或離開 App，內建服務停止，房間邀請與連線立即失效。B 的 App 會顯示斷線；重新測試時 A 建立新房間並交付新邀請碼。離開房間不影響本機語音輸入。

每個測試房間限房主加一位同學；一個身分同時一條連線。邀請碼含該房間客人的高強度憑證，等同加入授權，請只交給要測試的同學，不貼公開群組／repo。沒有 Groq Key 或房主憑證。房間憑證在目前使用者的 Windows 認證管理員暫存，離開時移除；房間政策僅在服務記憶體。受邀同學離開後，房主仍開著時該邀請碼可以重新加入；房主關閉後失效。

Windows 可能詢問房間服務的網路存取權，請依學校規範允許教室網路。相同 Wi-Fi 不保證電腦能互連；AP/VLAN 隔離時仍需管理者協助或使用已部署的 VPS WSS。此版本不自動開放公開連接埠、不繞過學校網路，也沒有新部署 VPS。

## 語音測試

- **全系統輸入**：點進記事本的文字欄，`Ctrl + Alt + Space` 開始錄音，再按一次停止。原視窗／程序／可編輯控制項仍有焦點且未按修飾鍵時才送入 Unicode 文字事件，不按 Enter。焦點改變、密碼／唯讀欄位、UI Automation 不支援、換行或輸入限制時，改複製或保留最近轉錄供手動貼上；請確認欄位實際結果。
- **聊天語音**：按「語音草稿」開始、再按停止。辨識文字先成草稿，確認後手動傳送給已配對同學，不會自動送出。
- `Esc`／取消按鈕／貓咪右鍵可取消；錄音最長 60 秒。快捷鍵衝突會提示，需處理衝突後重開 App。
- 到 Windows 麥克風設定允許桌面 App 使用麥克風。語音需要能連到 Groq；LAN 聊天成功不代表學校允許 Groq 網路。
- Groq Key 僅存 Windows 認證管理員；錄音只在記憶體，送到固定 Groq HTTPS transcription 端點，不寫錄音檔、不傳給房間服務。Provider 為可替換的 `ITranscriptionProvider`，目前使用 `whisper-large-v3`。
- 最近轉錄與有限聊天紀錄只在記憶體，退出即清除。複製文字／邀請碼後，Windows 剪貼簿歷程可能保留，請自行管理。WSS 是傳輸加密，非端到端加密；LAN 只在明確選擇房間／LAN 模式時使用可信私有網路 WS。

## 管理者與開發者

「進階連線」保留原有 LAN／VPS 手動設定。VPS 必須 WSS，不能略過 TLS 驗證；不得拿 Office／VNC URL 代替聊天端點。原有獨立 Relay 與憑證／好友設定見 `nekochat/relay/README.md`，同學的一鍵房間不需要這些步驟。

原始碼開發需 Windows .NET 10 SDK；教室房間需使用 CI 完整套件內的 `Relay/NekoChatRelay.exe`。只 `dotnet run` 而未放入 Relay 時，語音與手動連線仍可使用，建房會提示缺少內建元件。

```powershell
dotnet run --project windows-lite/NekoChat.Tests -c Release
dotnet build windows-lite/NekoChat.Windows -c Release -p:RestoreLockedMode=true
dotnet build windows-lite/NekoChat.Installer -c Release
```

Windows CI 將 Python 服務凍結為獨立執行檔，發佈自帶 runtime 的 WPF App，再嵌入單一 Setup.exe。CI 在移除 Python／dotnet 的 PATH、指定不存在的 DOTNET_ROOT 後實測 App、房間互傳、結束撤銷與安裝包驗證／解壓縮；詳見工作流程與 `nekochat/docs/VALIDATION.md`。另外保留 `nekochat-windows-lite-trial` portable ZIP，不需要重新執行 PowerShell 安裝腳本。

## JSON／外觀相容

直接複用 `Examples/CatAppearance/*.json` 的九種版本 2 外觀與原版 SVG；PNG 由既有 Swift 繪製器匯出。右鍵可匯入 `cat.config.json`（版本 1/2）：支援 `appearance.preset`、`seed`、16 個部位的 `color`／`pattern`／`patternColor`，以及設定資料夾內的相對 PNG `image`。PNG 上限 5 MB、2048×2048；JSON 64 KiB。不下載 URL，不讀設定資料夾以外的圖片。

預設九種花色使用原生匯出的圖片；自訂部位使用相同解剖座標與原生虎斑遮罩繪製，邊緣與抗鋸齒可能有細微差異。WPF 只顯示靜態坐姿；macOS 的走路／拎起動畫、招呼 triggers、字型、氣泡配置與冷卻秒數不在此 MVP 範圍。匯入外觀此次啟動有效，內建花色選擇會記住。

macOS 開發者修改原生素材後可重生：`./windows-lite/tools/export-cat-assets.sh`；不更動原始 Swift 或 SVG。Windows 建置直接使用已提交素材，不需要 Swift。

## 驗證與已知限制

CI 包含獨立房間服務與安裝器測試、Linux Relay／C# 真實 WebSocket 整合、Windows WPF／花色／憑證與流程畫面。CI 不代表實體教室網路、麥克風或任意前景 App 的實機驗收。

手動驗收：見儲存庫 `nekochat/docs/LAN-TEST.md`。本機與 CI 的實際結果記錄於 `nekochat/docs/VALIDATION.md`；未經互動式 Windows 使用者驗證前，請視為試用 MVP。macOS App 尚未接上 NekoChat；現有 Office／VPS remote 協議不相容，不能拿 Office URL 當聊天 Relay。

移除：先離開 App，在設定按刪除 Groq Key／Relay 憑證，刪除安裝資料夾、開始功能表捷徑及 `%LOCALAPPDATA%\NekoChat.WindowsLite`。也可在 Windows 認證管理員刪除 `NekoChat.WindowsLite/` 開頭的 Generic Credentials。解除安裝不撤銷 Relay 憑證；請管理者刪除帳號或輪替 token 後重啟 Relay。
