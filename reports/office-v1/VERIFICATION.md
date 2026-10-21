# 貓咪辦公室第一版：真實 VPS 驗證

日期：2026-10-21（Asia/Taipei）。完整交辦到摘要存檔的實測為 32.77 秒。本文件描述實際部署的獨立 VPS 原型。

## 結果

使用者層服務已在真實 VPS 執行：自然語言交辦、UTF-8 文字收件匣、背景佇列、SQLite 進度與來源快照、Markdown 成果、取消、暫停／恢復及重啟恢復。入口是 VPS 桌面「貓咪辦公室」或 Mac 的 SSH 網頁。Mac 正式 App 與既有遠端預覽未修改。

## VPS 規格與選型

- Ubuntu 26.04.1 LTS，x86_64，Python 3.14.4，SQLite 3.46.1。
- 分配 **2 vCPU**；宿主 CPU 顯示 AMD EPYC 9354P 32-Core Processor，不代表本 VPS 有 32 核。
- RAM 7.7GiB（方案約 8GB），無 swap。開始檢查時約 7.0GiB available。
- 根磁碟 96GB，初始可用約 93GB；部署後容量見 `runtime-state.txt`。
- 未暴露 NVIDIA／DRM GPU 裝置；實際 Ollama `/api/ps` 顯示 CPU 推論（size_vram=0）。
- 原有 XFCE、TigerVNC 與 Docker 保留；新增服務只聽 127.0.0.1:8421 與 127.0.0.1:11434，VNC 仍為 loopback 5901。

選用 **Gemma 3 4B Q4_K_M**，Ollama **0.40.7 CPU 執行環境**。模型 digest：`68ceab7e468a31c988b44d5a4984a0e21f58c4f7158c6ce29c1804babac38df7`，模型下載 3,350,272,403 bytes。官方來源：<https://ollama.com/library/gemma3:4b>、<https://docs.ollama.com/capabilities/structured-outputs>。

Ollama 壓縮套件由官方 GitHub release 下載，核對 SHA256 `7f082e625b4c334df84ed1558fe282d6d8091fe3545790aef30b3a9c50d44d41` 後，只解出 CPU 執行環境及必要函式庫。Gemma 模型經 Ollama 驗證下載 digest。安裝不使用 sudo，不改 SSH 或防火牆。

## 模型實測

這是小範圍驗收，非一般能力評分。最終相同提示與 9 個測試指令（附來源／缺來源、短文、新聞、價格研究、版本查詢、進度等）：

| 項目 | Gemma 3 1B | Gemma 3 4B |
|---|---|---|
| 模型原始任務分類 | 6/9 | 9/9 |
| 短摘要生成時間（不含派工） | 約 7.2 秒 | 約 16.8 秒 |
| 小林交稿日／預算／未決事項 | 有遺漏，曾誤稱會議負責人 | 此驗收筆記正確保留 |

原始結果見 `benchmark-gemma3-1b.json`、`benchmark-gemma3-4b.json`。`benchmark-gemma3-4b-initial.json` 是較早、含多餘檔名欄位的提示版本，不能當成最終版本的分數。

模型仍可能誤判。程式另檢查缺少來源及未接通的外部工具需求；模型不能選任意檔案或執行 shell。來源只能由使用者選取或在原始指令明確指出。這些檢查屬第一版有限動作的保護，不宣稱能辨識所有自然語言。

推論設定：8K context、最多 512 output tokens、2 threads、一次一個模型與任務。輸入總 UTF-8 bytes 限 7,000；過長要求分段，輸出達上限標為部分內容。CPU 配額 180%，模型服務記憶體上限 5,500MiB；cgroup 用量含檔案快取，曾達上限而進行回收，不等同模型 RSS。完整桌面與模型同時執行時仍有可用 RAM，詳見 runtime-state。

## 驗證證據

- 本機與 VPS 的 24 項離線行為測試通過：`offline-tests.txt`、`deploy-tests.txt`。
- 新服務的本機 HTTP 測試包含同源寫入、防路徑逃逸、符號連結拒絕、純文字顯示、結果下載、冪等交辦、取消、來源快照、重啟、佇列與第二服務不干擾第一服務。
- 真模型端到端檢查通過：`live-verification.json`，包括上傳後獨立讀回、同一編號不重跑、摘要成果檔獨立讀回、缺資料追問、外部任務只存交接單、執行中取消、暫停佇列與完成成果跨服務重啟保留、恢復後完成，以及重啟時把執行中任務標為中斷。
- 已中斷本次工作頁面的 SSH 通道：`tunnel-detach.json` 記錄中斷後任務仍為 running、正在生成文字。該任務後來 completed，成果與來源快照均已保存。
- 原既有 AgentCore 基準 16 個場景通過；此分支的原生 App、預覽與 SSH/VNC 來源相對基準沒有修改。
- 網頁實際輸入另建立任務 `920e2c06-288c-4af1-a75a-570d1e9d1019`：三個待辦的負責人與 10月25／26／27 日均正確保留，成果檔 SHA256 與 HTTP 回傳內容一致。見 `ui-verification.json`、`deployment-hashes.json`、`final-health.json`。
- 網頁真實交辦與成果畫面另存 `office-completed.png`，視覺預覽仍待使用者實際使用回饋。

## 常駐、檔案與回復

VPS `~/neighbor-office/app/` 是程式，`~/neighbor-office/data/` 是任務與成果，`~/neighbor-office/runtime/` 是 Ollama／模型與 Firefox 專用 profile。

`neighbor-office.service` 與 `neighbor-ollama.service` 為使用者層服務，已 enable；neighbor 本人執行 `loginctl enable-linger` 成功，讀回 `Linger=yes`。已驗證服務重啟及工作頁面斷線；**沒有重開整台 VPS，也沒有登出目前的 VNC 桌面**。

停用可用 `systemctl --user stop neighbor-office neighbor-ollama`；不會刪除任務資料。要停用下次啟動，再執行 `systemctl --user disable neighbor-office neighbor-ollama`。沒有變更舊 App 或原 SSH/VNC 設定，因此無須回滾正式 App。

## 還未完成的部分

- 原生 Mac 貓咪面板尚未連到本服務；目前用獨立辦公室網頁。
- 外部大模型、三家供應商登入、上網研究、桌面操作未串接。這類任務只建立待處理交接單，不會顯示已完成。
- 只驗證人工建立的短中文資料與指定指令；長文件、自然口語的廣泛穩定性、使用者日常驗收尚未完成。
- 沒有 push、merge、公開發布，也沒有替換正式 App。程式留在隔離 worktree，供使用者檢視。
