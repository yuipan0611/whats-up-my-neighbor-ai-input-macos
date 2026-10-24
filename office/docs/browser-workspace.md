# VPS 持久 Chrome：獨立實驗元件

日期：2026-10-24（Asia/Taipei）。本文件記錄 Agent Zero 評估後的第一個實作切片，並非正式 VPS 已完成部署的宣告。

## 決定

採用「VPS 上的真實 Chrome、專用持久 profile、使用者與 Agent 操作同一 session」的方向。第一步只完成可獨立驗證的瀏覽器生命週期與 profile 管理，下一步才串接已認證的觀看／接管入口。現有 Office 任務、SQLite 事件、HTTP/WebSocket、Codex/Gemma 執行者不依賴 Agent Zero 的內部類別。

Agent Zero 是值得採用的工程參考，也可在日後透過 adapter 作為可選執行者。這一切片使用官方 Playwright 呼叫 Google Chrome，沒有複製 Agent Zero 的程式碼、沒有重造瀏覽器自動化引擎，也沒有把整套 A0 scheduler、memory、UI 帶入產品。

## 查證的 Agent Zero 版本與容易忽略的差異

上游：`agent0ai/agent-zero`，tag `v2.14`，commit `ff2a5b9c9c4e490ba38dd7c313e779510bb2071a`。以下為文件與原始碼檢查；未在本次環境啟動 Agent Zero。

| 問題 | 實際查證 | 對 NekoNode 的決定 |
| --- | --- | --- |
| Mac 合蓋是否讓雲端停止 | A0 CLI 操作的是 CLI 所在主機；Mac CLI/Chrome 停止時，那項本機能力不可用。CLI 也支援 Linux，放在 VPS 是可行的設計推論 | 讓 browser runtime 與必要資料常駐 VPS；本機 bridge 保留為可選能力 |
| 要不要搬 Cookie | A0 有獨立 Docker Browser；host browser 可使用本機 profile，但不是把那台 Chrome 搬到雲端 | 在 VPS 的專用 Chrome 內登入；不匯出日常 Mac Cookie 或 Keychain |
| 是否用 VNC | `interactive_view.py` 與 Desktop session 實際使用 Xvfb/Xpra；Desktop 是 XFCE | 顯示串流採獨立 adapter，後續比較 Xpra/noVNC；第一步不需要完整桌面 |
| 只掛 `/a0/usr` 是否足夠 | `runtime.py` 的 profile 在 `/a0/tmp/browser/sessions/shared`，不在 README 推薦掛載的 `/a0/usr` | profile 必須有明確持久磁碟。restart 與 container recreation 分開驗收 |
| per-context 是否帳號隔離 | `default_config.yaml` 明寫兩種 tab scope 共用 Chromium runtime/sign-in profile | profile ID 與 task/chat ID 分離；不同身分使用不同 profile |
| host browser 是否有即時畫面 | Browser guide 說 live Canvas 是 Docker Browser；host browser 只回結果／截圖到聊天 | 不把 host bridge 當成已完成的手機直播方案 |
| 能不能直接抽 browser plugin | runtime 依賴 A0 的 helpers、plugin config、AgentContext、Canvas/Xpra 等 | 先用自己的薄介面包成熟 driver，不直接複製整包 plugin |

若另做 A0 試用實例，依此版本原始碼推論應另外掛載 `/a0/tmp/browser/sessions`；只掛所需子目錄，不以空 volume 覆蓋可能包含 browser binary 的整個 `/a0/tmp`。這個 mount 建議仍須做容器重建實測，不能當成已驗證部署配方。

## 這一切片的程式

`office/browser_workspace/` 可獨立匯入或用 CLI 啟動。Office server 沒有 import 它，未裝 Playwright 時既有辦公室仍能執行。

| 檔案 | 責任 |
| --- | --- |
| `ports.py` | 標準庫 Protocol、不可變 `PageSnapshot`、固定錯誤 code |
| `profiles.py` | 專用資料樹、權限檢查、profile ID、OS 程序鎖 |
| `playwright_provider.py` | 選配 Playwright adapter，啟動及關閉 Google Chrome |
| `__main__.py` | 可信操作者使用的獨立 CLI，等待關窗或停止訊號 |

最小介面：

```python
class BrowserSessionProvider(Protocol):
    async def start(self) -> None: ...
    async def navigate(self, url: str) -> PageSnapshot: ...
    async def current(self) -> PageSnapshot: ...
    async def close(self) -> None: ...
```

核心不取得 Playwright Page/BrowserContext、Cookie 或 CDP endpoint。`PageSnapshot` 只包含 URL/title，仍屬可能敏感的網站資料；未來接入事件前必須另外決定是否保存，不能直接全量寫入 trace。CLI 不列印它們。

這個介面只固定目前需要的能力。換 driver 時需通過相同生命週期／profile 測試；Protocol 的結構符合不代表其他 provider 已實作或所有行為等價。`viewer_ref`、接管 lease、element operations 留待各自真正接入時增補，沒有預造通用 Agent 框架。

### 已實作的邊界

- 預設 headed、`channel="chrome"`、顯式 `chromium_sandbox=True`；沒有 `--no-sandbox` 或任意 flags 入口。
- 專用 profile root 必須是 Git 之外的絕對路徑，當前服務 UID 所有，權限 `0700`。拒絕 root/祖先 symlink、未標記的既有非空目錄、過寬權限及 lock hardlink。
- 每個 profile 使用獨立目錄與 `flock`；第二個 owner 被拒絕，重複 `start()` 不會釋放第一個 owner 的鎖。鎖檔不 unlink，避免兩個 inode 各自被鎖。
- 正常關閉保留 profile；啟動失敗清理資源。若關閉結果不明，回固定錯誤並保留鎖，不把資料交給下一個程序。
- CLI 不提供 HTTP/CDP 網路服務、Cookie 匯出、截圖、錄影或 trace。登入等待期間只等待瀏覽器關閉事件，不持續讀取頁面。
- `navigate()` 只接受無 userinfo 的 HTTP(S)，且不自動重送失敗操作；它不是網域 allowlist 或授權 broker。

### 實際限制

這是可信開發者使用的 lab，**尚不能直接交給任意 LLM 或 code runner 使用**。同 UID 可讀 profile；`flock` 是合作程序的單機鎖，不是多人授權或分散式 fencing。profile 內仍有敏感登入資料，`0700` 不代表靜態加密；正式部署還需專用 UID、持久磁碟／金鑰方案與執行環境隔離。

瀏覽器重啟後的持久 Cookie、localStorage、IndexedDB 可用合成站點驗證；session-only Cookie、sessionStorage、網站到期／撤銷、裝置綁定登入等不能因此保證長期可用。正常關閉後重開與斷電／強制殺程序也不同，未測情況不標記通過。

現在沒有 viewer、私密登入模式的 server 仲裁、Agent/human 控制權交接、遠端 gateway、資源配額或容器配置。CLI 等待期間不讀 DOM，不能當成整個產品已通過私密接管的驗收。

## 本機實驗啟動方式

適用 Linux VPS 的**一般使用者**；先安裝官方 Google Chrome，headed 模式必須有可用的 DISPLAY。這個 CLI 不會替使用者裝 Docker、修改 DNS、開埠或部署服務。不要使用 root 啟動 Chrome；sandbox 不可用時應修正執行環境。

在 repo 根目錄安裝選配依賴：

```sh
NEKO_BROWSER_VENV="$HOME/.local/share/nekonode-browser-venv"
python3 -m venv "$NEKO_BROWSER_VENV"
"$NEKO_BROWSER_VENV/bin/python" -m pip install --require-hashes -r office/requirements-browser.txt
```

先確認在 VPS 的既有私有桌面／DISPLAY 能看到 Chrome，再啟動：

```sh
cd office
"$NEKO_BROWSER_VENV/bin/python" -m browser_workspace \
  --profile-root "$HOME/.local/share/nekonode-browser-profiles" \
  --profile-id personal
```

若指定路徑的祖先為 symlink，先由部署者選擇真正的 canonical path；不要為了啟動而降低檢查。`--url` 只適合不含秘密的測試網址，因為命令列可能被程序列表或 shell history 看見。初期建議先用合成站點，不接真帳號。

手動關閉該 Chrome 或 Ctrl-C 會關閉 runtime、保留資料。同一個 profile 再啟動會用同一資料目錄；另一個 `--profile-id` 使用另一份資料。瀏覽器能啟動不代表網站已登入，程式沒有自動宣稱 authenticated。

自動測試可用 `--headless`。未來遠端觀看必須對應這一個 Chrome 程序，不能另外啟動另一個 Chrome 視窗登入並假設 Agent 自動共用。

## 驗證

不需要第三方 SDK 的既有辦公室及 profile 測試：

```sh
python3 -I -m unittest discover -s office/tests -v
```

真正 Chrome 的驗證使用本機 HTTP 合成帳號站點，無外部網站與真實憑證。每次驗證重新建立 Python provider 程序與 Chrome，確認持久 Cookie、localStorage、IndexedDB 保留；另一 profile 看不到；測試登出後不再顯示登入成功。另測第二程序拒絕、重複啟動、啟動失敗的 lock 清理。

```sh
NEKO_BROWSER_E2E=1 NEKO_BROWSER_HEADLESS=0 \
  xvfb-run -a "$NEKO_BROWSER_VENV/bin/python" -I -m unittest discover \
  -s office/tests -p 'test_browser_chrome_e2e.py' -v
```

沒有 `NEKO_BROWSER_E2E=1` 時真 Chrome 測試明確 skip；設為 1 後 Chrome/SDK 缺失必須 fail，不能偷偷改用 fake 或 Chromium。CI 記錄實際 `google-chrome --version`，使用 headed Chrome + Xvfb，且不提供 `--no-sandbox`。

`.github/workflows/browser-workspace.yml` 只讀 repository、無憑證持久化、無發布或部署。CI 不上傳 profile、截圖或登入狀態。每次以 PR 最新 commit 的 checks 判斷，不沿用前一個 commit 的綠燈。

本次環境沒有 Google Chrome/Xpra/Docker；本機的單元與回歸測試、CI 的真 Chrome 結果、正式 VPS 的驗收要分開記錄。具體結果見本分支 PR 的最新 checks。

## 下一切片的驗收

1. 用同一個 Chrome 的顯示 session 接 Xpra 或 noVNC adapter，經既有 owner 認證入口觀看；不公開 CDP/VNC 埠。
2. Agent 與人類只有一位操作者；接管先取消／排空在途操作，再給人工輸入。接管中斷線維持暫停。
3. 手機／Mac 關頁不停止 VPS 已接收工作；重新連線仍是相同任務／瀏覽器 session。
4. 正式持久磁碟掛載後，實測重啟服務、重啟主機、刪除重建容器，分別記錄結果。
5. 遇網站過期/MFA 切換 waiting_auth，人工在同一 session 處理，再明確交還。

完成上述後才接入已授權網站的工具操作；DOM 標註、多 Agent 狀態側欄、LibreOffice Cowork 可再依實際需求逐項接入。A0 完整執行器若接入，透過 adapter 把其 Socket.IO/事件轉成 NekoNode 自有 TaskEvent，保留產品 task ID 與重連游標；不讓 UI 直接依賴 A0 protocol。

## 來源與授權

Agent Zero 為 MIT。未來複製其實質 code 需保留 notice、來源檔案與上游 commit；其容器內的 Xpra、Xpra HTML5、XFCE、Chromium、LibreOffice 等有各自授權，不會因 A0 採 MIT 而全部變成 MIT。這一切片只參考設計，未複製其 code。

- [A0 v2.14 原始碼](https://github.com/agent0ai/agent-zero/tree/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a)
- [Browser guide](https://github.com/agent0ai/agent-zero/blob/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a/docs/guides/browser.md)
- [CLI Connector guide](https://github.com/agent0ai/agent-zero/blob/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a/docs/guides/a0-cli-connector.md)
- [Browser runtime](https://github.com/agent0ai/agent-zero/blob/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a/plugins/_browser/helpers/runtime.py)
- [Browser defaults](https://github.com/agent0ai/agent-zero/blob/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a/plugins/_browser/default_config.yaml)
- [Browser display](https://github.com/agent0ai/agent-zero/blob/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a/plugins/_browser/helpers/interactive_view.py)
- [Desktop session](https://github.com/agent0ai/agent-zero/blob/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a/plugins/_desktop/helpers/desktop_session.py)
- [A0 LICENSE](https://github.com/agent0ai/agent-zero/blob/ff2a5b9c9c4e490ba38dd7c313e779510bb2071a/LICENSE)
- [Playwright BrowserType](https://playwright.dev/python/docs/api/class-browsertype)
- [Playwright authentication](https://playwright.dev/python/docs/auth)
- [Chrome 專用 remote-debugging profile](https://developer.chrome.com/blog/remote-debugging-port)
- [既有 VPS-first PRD](https://github.com/yuipan0611/nekonode-site/blob/docs/vps-agent-mvp-20261023/docs/plans/vps-agent-mvp-prd.md)

本分支從 `main@218c06d3826560e339b6fe9ce4cf68749f55fd7d` 開出，不相依於尚未合併的 observability PR #23/#25。現有 tracing 介面可在未來獨立接入；本次不更改它們的分支。
