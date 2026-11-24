# VPS 工作瀏覽器：觀看與私人接管

這是接續 `browser-workspace.md` 的第二個切片。程式可獨立啟動，也可掛在既有 Office 配對入口後；**本文件不表示已部署到正式 VPS**。目前的 Codex／Gemma 任務執行器尚未呼叫 browser controller。

## 使用方式與行為

已配對的手機／電腦開啟同源 `/browser/`，預設只能觀看。按「接管」後，其他觀看連線先關閉，Agent 新操作被擋住，已開始的操作排空後才開放輸入。使用者在這個 Chrome 內登入，不搬運 Mac 的 Cookie。

「交還 Agent」會撤銷本次控制連線，回到允許可信 adapter 使用的狀態。這個按鈕只交還**瀏覽器的控制權**，不表示目前已連接 LLM，也不會替既有 Office 任務自動增加瀏覽器能力。

關閉觀看頁面不關閉 Chrome。人工接管途中關頁、切到背景或斷線，會保留私人暫停；同一個配對裝置可再次接管，再明確交還。其他裝置不能搶看未完成的登入畫面。尚未建立控制 WebSocket 的接管在 30 秒後也會轉私人暫停。這個計時不是已連線接管的強制工作期限。

手機有「鍵盤」與 Tab／Esc／退格／Enter 輔助鍵。輸入走 RFB 按鍵，沒有剪貼簿同步、帳密表單、輸入草稿或錄影。Chromium 的窄螢幕測試不能取代實體 iPhone／Safari 的軟鍵盤、中文 IME 與觸控驗收。

## 元件與可替換的界線

| 元件 | 責任 | 對外接點 |
| --- | --- | --- |
| Office | 現有 Cookie、Origin、page token、裝置撤銷 | 原 HTTPS/WSS 網址 |
| `browser_proxy.py` | 固定 Unix upstream、注入已驗證裝置、二進位 WS relay | 選配 `--browser-socket` |
| `BrowserController` | epoch、單一控制者、私人暫停、Agent 操作閘門 | 可信單一 asyncio loop 內的方法 |
| aiohttp gateway | 固定 API、noVNC 靜態資產、RFB WS transport | `0700` 目錄中的 `0600` Unix socket |
| TigerVNC 兩個程序 | 同一 X display 的伺服器端唯讀／控制 | 各自的 `0600` Unix RFB socket |
| Xvfb＋Google Chrome | 一個專用畫面、一份持久 profile | 私有 Xauthority，Chrome sandbox 開啟 |
| noVNC 1.7.0 | 手機／桌面的標準 RFB client | 同源頁面，無 CDN |

這一版沿用現有 Office 的 Linux/systemd 部署布局，先驗證較小的工作瀏覽器；不需要在 M1 安裝 Docker Desktop，也不需要整套 XFCE。未加入未驗證的 Docker image。日後容器化時保留相同 RFB／Unix gateway 介面，另做 profile volume 重建、Chrome sandbox 與資源限制驗收。

Office 本身仍只需要 Python 標準庫。aiohttp、Playwright、Chrome 及 X server 在獨立服務與獨立 memory cgroup 裡；未設定 `--browser-socket` 時，browser 功能回 `browser_disabled`，原聊天與任務路徑照常。

## 控制權與隱私的實際範圍

狀態是 `paused → handoff → human → handoff → agent`。初始是可觀看的 `paused`。每次交接更新 epoch；舊 Agent 操作與舊 WebSocket 無法用相同裝置身分重新生效。伺服器只接受一條 control stream，同一手機開兩個頁籤也不例外。

控制 WebSocket 每次轉送都重新檢查 lease；release 關閉該次獨立 RFB stream，下一次不共用舊 stream。觀看用另一個 TigerVNC 程序，`AcceptKeyEvents=0`、`AcceptPointerEvents=0`，不能靠改前端 `viewOnly` 取得輸入權。兩端都禁止 resize；有剪貼簿實作的版本顯式禁用收送。

Office 不轉送外部 `X-Neko-Device`、Cookie、Authorization 或 page token。Gateway 只接受同 UID 的 Unix peer。裝置撤銷／到期在已建立 viewer stream 上至多約一秒重新檢查，並與原本任務 socket 分開計數。

**私人暫停是 Neko controller 的合作邊界，不是防止同 UID 的惡意程式。** 同 UID／root、可讀 profile 或 Xauthority、可連控制 socket 的程式可以繞過它。未來允許 Agent 任意執行 shell 時，必須放到不同 UID／容器，且不掛入 profile、runtime directory 或 Docker socket。瀏覽器內網頁自身的 JavaScript／network activity 也不會因 handoff 暫停。

不寫入 DOM、畫面、URL、鍵盤或 Cookie 的 trace。私人狀態目前是程序內狀態，服務重啟後回初始暫停；不要把它當作跨重啟的登入鎖。Chrome profile 仍持久；網站是否要求重新登入由網站決定。若裝置被撤銷時留在私人暫停，這一版需要可信服務管理者結束該 browser service 後重新開啟，沒有提供其他手機搶占私人 session 的操作。

## VPS 部署接點

沿用已存在的 `neighbor` user service，先建立新 release 並驗證，最後才切換 `current` symlink；保留 `neighbor-office/data`。不要用會覆寫舊 SSH 版本的 `office/deploy.sh` 更新公網版，也不要把 Chrome 放入 Office 現有的 1 GB cgroup。

一般使用者的 prerequisites：Python venv、官方 Google Chrome、`Xvfb`、`xauth`、TigerVNC scraping server。Ubuntu binary 通常叫 `X0tigervnc`，上游叫 `x0vncserver`；不使用 distro 的 wrapper 腳本。以正式 VPS 的實際版本與 Chrome sandbox 啟動結果為準。

```sh
sudo apt-get install --no-install-recommends xvfb xauth tigervnc-scraping-server python3-venv
python3 -m venv "$HOME/.local/share/nekonode-browser-venv"
"$HOME/.local/share/nekonode-browser-venv/bin/python" -m pip install --require-hashes \
  "$HOME/neighbor-office/current/requirements-browser.txt"
```

Google Chrome 應使用官方 Linux 安裝包及其系統整合；本模組不自動安裝瀏覽器，也不以 `--no-sandbox` 補救環境問題。不要用 root 執行此服務。

兩個範例檔是可審閱的部署配置，尚未自動安裝：

- `services/neighbor-browser.service.example`：獨立瀏覽器服務，runtime 在 `%t/neighbor-browser`，profile 在 `%h/.local/share/nekonode-browser-profiles`。
- `services/neighbor-office-browser.conf.example`：只為原 Office 增加固定 socket 接點；安裝前比對目前 `ExecStart`，保留現有 origin/model/data。

瀏覽器 unit 的 `MemoryHigh=1500M`、`MemoryMax=2500M` 與 `CPUQuota=150%` 是初始保護上限，**不是量測出的需求**。既有 8 GB VPS 若同時啟用 Gemma 4B 與多分頁 Chrome，仍需量測總 memory pressure；不要把移到 VPS 理解成資源無限。profile、socket 或 runtime parent 權限不符會拒絕啟動，不自動 chmod 使用者既有目錄。

從部署後的 canonical release 目錄手動試跑（保持另一個 shell 可停止）：

```sh
"$HOME/.local/share/nekonode-browser-venv/bin/python" -I \
  "$HOME/neighbor-office/current/browser_service.py" \
  --profile-root "$HOME/.local/share/nekonode-browser-profiles" \
  --profile-id personal --runtime-dir "$XDG_RUNTIME_DIR/neighbor-browser"
```

沒有新公開 port；Caddy 繼續把 Office origin 的 HTTP/WSS 轉到原本 loopback Office。TLS、既有配對、Host 與 Origin 檢查仍由原入口處理。Mac／手機都是 client，關機不應影響 systemd 服務；正式 VPS 的 user lingering、reboot、自動啟動及負載測試仍需在該主機實測。

### TigerVNC 版本處理

已查證上游 1.16.2 提供所需 Unix RFB、唯讀、single-client 與 clipboard flags。Ubuntu 24.04 的 1.13.1 x0vncserver 尚未實作 clipboard，不能盲目傳新版 flags；runtime 僅對這個已核實舊版省略它們，未知缺少禁用能力的版本拒啟。

所有版本先以 `UseSHM=0` 啟動。這是為避開舊版 x0vncserver 的 MIT-SHM 權限路徑；新版 1.16.2 已修正。此設定不表示舊套件其他問題已全面審核，後續可升級固定版本再評估效能。來源：

- [TigerVNC 1.16.2 manual](https://github.com/TigerVNC/tigervnc/blob/v1.16.2/unix/x0vncserver/x0vncserver.man)
- [1.13.1 clipboard 未實作的 source](https://github.com/TigerVNC/tigervnc/blob/v1.13.1/unix/x0vncserver/x0vncserver.cxx)
- [MIT-SHM 權限修正](https://github.com/TigerVNC/tigervnc/commit/0b5cab169d847789efa54459a87659d3fd484393)
- [Ubuntu CVE-2026-34352 狀態](https://ubuntu.com/security/CVE-2026-34352)
- [noVNC 1.7.0 API](https://github.com/novnc/noVNC/blob/v1.7.0/docs/API.md)

## 測試與驗收

```sh
python3 -I -m unittest discover -s office/tests -v
NEKO_VIEWER_E2E=1 "$HOME/.local/share/nekonode-browser-venv/bin/python" -I \
  -m unittest discover -s office/tests -p 'test_browser_viewer_e2e.py' -v
```

預設 suite 包含 stdlib proxy 身分／Origin／token／撤銷、controller 競態、子程序清理；aiohttp gateway tests 在 SDK 可用時執行。真實 viewer E2E 需顯式開啟，缺 Chrome／Xvfb／TigerVNC 時會失敗，不能以 skipped 當成功。

真實 E2E 使用本機合成站點，經 Office → Unix gateway → TigerVNC → 同一個 headed Chrome；驗證 RFB 解碼畫面、繞過前端只讀仍無法輸入、私人接管、重複控制者拒絕、真鍵盤作用到原 profile、斷線保留 Chrome、重新連線不自動接管、明確交還與 390 px 排版。沒有外部帳號、真實登入憑證或生產 profile。

正式驗收仍需：目標 VPS Chrome sandbox／systemd／重新開機、實體手機觸控與 IME、真正網站手動登入、工作負載與 memory pressure，以及後續受控 LLM browser adapter。Docker 容器重建持久性需在實際容器化切片另驗，不能由這次程序重啟測試推定。
