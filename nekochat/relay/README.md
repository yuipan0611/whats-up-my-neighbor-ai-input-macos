# NekoChat Relay

獨立的 FastAPI WebSocket 服務。與 `office/office.py` 完全分離，不連接 AI Agent、SSH 或遠端桌面。單一程序、最多 100 個帳號、每個帳號一條連線，即時文字轉發，不儲存訊息。不使用廣播式共用房間；每則訊息要求雙向好友授權。

## 同學的一鍵房間

Windows Lite 已新增內建房間模式：安裝包內含獨立的 `Relay/NekoChatRelay.exe`，由 App 的「建立房間」啟動，透過匿名管線傳入僅含憑證 hash 的雙方政策。綁定 loopback 與指定私有 IPv4，以 stdin EOF 偵測擁有者關閉並結束。政策不寫檔；邀請碼僅包含客人憑證，房主明確分享即授權該同學，雙方好友在記憶體內自動配置。對外仍為原本 NekoChat v1 WebSocket 協議。

同學不需要以下 Python／手動設定流程。下列內容保留給自行管理 LAN／VPS 的管理者。

## 教室 Windows 主機（管理者手動模式）

在 clone 的儲存庫根目錄開 PowerShell，使用 Python 3.12+：

```powershell
python -m venv nekochat/.venv
./nekochat/.venv/Scripts/python -m pip install -r nekochat/relay/requirements.txt
./nekochat/.venv/Scripts/python -m nekochat.relay.provision "$env:USERPROFILE/NekoChatRelay" alice bob --mode lan
notepad "$env:USERPROFILE/NekoChatRelay/relay.json"
```

產生器要求新資料夾位於儲存庫外，`relay.json` 只有 token SHA-256；每位同學各有一個 `*.credential.txt` 個人 token。將 alice 的 `friends` 設為 `["bob"]`、bob 的設為 `["alice"]`，存檔。透過可信的私下管道各自交付個人憑證；不可公布、提交 Git、放 URL 或與 Groq Key 混用。第一次產生時好友清單為空，預設禁止傳訊。Windows 的檔案 ACL 由目前使用者資料夾繼承；請確認其他同學無法讀取該主機的憑證檔。Unix 建檔採 0700/0600。

```powershell
$env:NEKOCHAT_CONFIG = "$env:USERPROFILE/NekoChatRelay/relay.json"
./nekochat/.venv/Scripts/python -m uvicorn nekochat.relay.app:from_env --factory --host 0.0.0.0 --port 8765 --workers 1 --ws websockets-sansio --ws-max-size 16384 --no-proxy-headers --no-access-log
```

透過 Windows 設定只對需要的私人網路授權 Python 的 TCP 8765 入站（可能需要管理員協助）；不要直接開到網際網路或改動學校防火牆。用主機的私有 IPv4 位址讓兩位同學連線。若同 Wi-Fi 仍無法互連，可能是 AP／VLAN 用戶端隔離；同意的替代路徑是 VPS WSS，不是繞過學校限制。

macOS／Linux 啟動：

```sh
python3 -m venv nekochat/.venv
nekochat/.venv/bin/python -m pip install -r nekochat/relay/requirements.txt
nekochat/.venv/bin/python -m nekochat.relay.provision "$HOME/NekoChatRelay" alice bob --mode lan
# 先編輯外部 relay.json，加入雙向 friends。
export NEKOCHAT_CONFIG="$HOME/NekoChatRelay/relay.json"
nekochat/.venv/bin/python -m uvicorn nekochat.relay.app:from_env --factory --host 0.0.0.0 --port 8765 --workers 1 --ws websockets-sansio --ws-max-size 16384 --no-proxy-headers --no-access-log
```

## VPS（自行部署的範例，這個 PR 不操作現有 VPS）

1. 用 `--mode vps` 建立**獨立**的外部設定、帳號與憑證，設定雙向好友。不要重用 Office token、Groq Key、LAN 明文網路中用過的 token。
2. Python 虛擬環境與套件同上；用非 root 服務帳號執行，設定檔只供該帳號讀取。
3. Uvicorn 僅綁 loopback，唯一 worker：

```sh
export NEKOCHAT_CONFIG=/path/outside/repo/relay.json
nekochat/.venv/bin/python -m uvicorn nekochat.relay.app:from_env --factory --host 127.0.0.1 --port 8765 --workers 1 --ws websockets-sansio --ws-max-size 16384 --proxy-headers --forwarded-allow-ips 127.0.0.1 --no-access-log
```

4. 由本機反向代理提供有效 TLS。例如 Caddy 使用已由管理者準備好的獨立網域：

```caddyfile
chat.your-domain.example {
    @chat path /nekochat/v1/ws
    reverse_proxy @chat 127.0.0.1:8765
    respond 404
}
```

僅信任實際本機反向代理的 forwarded scheme；不得設 `--forwarded-allow-ips '*'` 或公開 Uvicorn 連接埠。VPS policy 在應用層也要求 `wss` scheme；直接 WS 被拒絕。反向代理應覆寫不可信的 forwarded headers，且不要記錄 Authorization 或訊息內容。此範例未設定存取日誌；自行新增代理日誌時注意保護敏感資料。不得以 Office/VNC 網址代替本協議端點。

## 撤銷與操作

變更好友、刪除帳號或輪替 token hash 後**重啟 Relay**，使既有連線立即中斷並重新驗證。設定僅在啟動時載入。以 Python `secrets.token_urlsafe(32)` 生成新 token；只將 SHA-256 放 server config，個人 token 透過私下管道交付。不要在命令列參數傳 token（可能出現在程序清單）。停止 Relay 不保留任何待送訊息。不能使用多 worker／多副本；連線狀態只在單程序記憶體。

不提供公開註冊／搜尋使用者／自動好友要求；MVP 由管理者明確授權。個人 token 是目前帳號的持有者憑證；遺失需撤銷輪替。限制每條連線的封包大小、速率與 idle timeout，但這不是大規模公開服務的完整 DDoS 防護。

## 測試

```sh
python -m pip install -r nekochat/relay/requirements-dev.txt
python -m pytest nekochat/relay/tests -q
python -m nekochat.relay.protocol
```

C# 與真實 Relay 整合：先 `dotnet run --project windows-lite/NekoChat.Tests -c Release` 建置，再設定 `NEKOCHAT_DOTNET` 為 dotnet 執行檔路徑執行 pytest；未設定時該項明確 skip。測試自建 localhost Relay，使用假憑證，無外部服務／秘密。通訊細節見 `../protocol/README.md`。
