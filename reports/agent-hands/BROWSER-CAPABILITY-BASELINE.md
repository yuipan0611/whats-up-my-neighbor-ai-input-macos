# G0：瀏覽器能力路徑與基準盤點（2026-10-26）

ADR-002 第 3 節要求先列出貓咪實際上能用哪些路徑碰到瀏覽器與系統，再談 broker 管得到什麼。本文件全部是**實機唯讀探測**（VPS，2026-10-26）：只測「能不能讀／能不能連」，沒有讀出任何檔案內容、cookie 或登入資料，沒有改任何服務設定。

## 1. 基準版本（VPS 現況）

| 項目 | 值 |
|---|---|
| 辦公室 | `releases/public-20261023-f74a50a`（0.5.1） |
| worker | `/opt/neko-hands/worker.py` sha256 前 16 碼 `9bc1bb9d76fb8873`（legacy：直接設定 browser MCP，自動核准） |
| Codex CLI | 0.163.0 |
| 瀏覽器工具 | chrome-devtools-mcp 1.12.0，32 個工具 |
| Chrome | 156.0.8078.47，`--remote-debugging-port=9222`（只聽 127.0.0.1） |
| 服務 | `neko-chrome`、`neko-hands-worker`、`tigervncserver@:1` 都在跑 |

## 2. 探測方法

用 root 以 `runuser -u neko-hands` 執行兩組相同的探測：

- **A. Codex 沙箱內：** `codex sandbox`，workspace-write＋網路開啟。等於 agent 跑 shell 指令時拿到的能力。
- **B. 沙箱外、同一個 neko-hands 帳號：** 等於 MCP 伺服器、worker，以及任何逃出沙箱的程序。

第一輪用 shell 包 Python 一行指令，測 worker socket、X 桌面、程序記憶體三項。結果連沙箱外都顯示「不行」，跟 worker 實際能連上 worker socket 矛盾，判定是引號造成的**假結果**。改用獨立的腳本檔重測，下表採用重測結果。

## 3. 能力路徑表

| 路徑 | A 沙箱內 | B 同帳號 | broker 能管嗎 | 現況說明 |
|---|---|---|---|---|
| 瀏覽器工具（raw MCP，32 個） | 經 Codex 呼叫 | 是 MCP 本身 | **G1／G3 改成受限 adapter 後可以** | 現在開放 `evaluate_script`（任意 JS）、`upload_file`、`fill`、`press_key`、`get_network_request`、`take_heapsnapshot`、`screencast_*` 等，全部自動核准 |
| Chrome 除錯埠 CDP `127.0.0.1:9222` | **可以連** | 可以 | **不能** | agent 的 shell 可以直接用 CDP 完整控制 Chrome，完全不經任何 broker。**第一階段最大的旁路** |
| Chrome profile（Cookies 等） | **可讀**，不可寫 | 可讀可寫 | 不能 | D13 的已知取捨：程式和 Chrome 同帳號。只測可讀，沒有讀內容 |
| 貓咪的 Codex 登入檔 | **可讀**，不可改 | 可讀可改 | 不能 | agent 的 shell 讀得到自己的登入憑證；配上開放的網路，就有外送的可能 |
| X 桌面 `:1` socket＋`.Xauthority` | **可連**、可讀 | 可連、可讀 | 不能 | 有能力直接對桌面送滑鼠鍵盤事件，繞過 viewer 的「單一控制者」。目前沒有 xdotool，但網路開放，可以自己下載工具 |
| worker socket | **可連** | 可連 | 已知限制 | 只回答這件 hands 任務本身（H2）；lease 擋得住舊輪次，擋不住惡意 agent（PRD 9.1） |
| 對 worker／Chrome 送信號 | 不行（沙箱有自己的程序視野） | **可以** | 不能 | 逃出沙箱的同帳號程序，可以停掉或干擾 worker 與 Chrome |
| 讀其他程序的記憶體 | 不行 | 不行 | — | 系統的 ptrace 限制有效 |
| 寫工作區外的檔案 | 不行，只有工作區與交回資料夾可寫 | 可以 | — | Codex 沙箱有效 |
| 外網 | 可以 | 可以 | 不能（D14） | 不做網站白名單 |
| 雲端 metadata | 不行 | 不行 | — | Hostinger 沒有開放（跟 H1 結果一致） |
| neighbor 家目錄 | 不行 | 不行 | — | H1 的隔離有效 |

## 4. 結論：第一階段能承諾什麼

- **broker 能保證的只有一件事：** 經過受限 adapter 的瀏覽器動作，會先檢查規則並留下紀錄。G1／G2 做的就是這一段。
- **broker 擋不住的：** agent 的 shell 可以直接連 CDP、讀 Chrome profile、讀 Codex 登入檔、連 X 桌面。所以即使 G3 把 raw MCP 換成 adapter，「所有瀏覽器動作都受控」仍然**不成立**。任何驗收紀錄都不能這樣寫。
- **要真的封住，得另外設計（需要修改 D13，本次不做）。** 候選方向，尚未評估資源與相容性：
  1. Chrome 改用另一個系統帳號執行，CDP 只透過 pipe 或只有 broker 能開的 socket 提供。
  2. 讓 Codex 沙箱裡的程序連不到 127.0.0.1:9222 和 X socket，例如利用 Codex 的網路代理設定，或用網路命名空間。
  3. Codex 登入檔與 Chrome profile 搬到 agent 讀不到的位置，由 worker 或 broker 代用。
  - 光是「藏起連接埠」或「在 prompt 裡叫它別用」都不算數。

## 5. 對 G1–G5 的影響

- **G1／G2：** 照計畫做。測試只能宣稱「broker 路徑」的保證。
- **G3：** adapter 只開放固定工具。`evaluate_script`、`upload_file`、`take_heapsnapshot`、`screencast_*`、`get_network_request` 等不直接給 agent。即便如此，第 3 節的 CDP 旁路仍然存在，要在驗收紀錄寫明。
- **G4：** 接手時要停的不只 Codex 的程序樹。只要 X 桌面和 CDP 還對貓咪開放，「單一控制者」就只能保證 broker 路徑與 viewer 這一端。

## 6. H3 未完成項目（本次沒有重跑）

以下仍是 **NOT RUN**，不因為本次盤點而算通過：惡意網頁與惡意 README（先前的做法被安全機制中斷，之後改用無害標記的方式）、連續多件的資源紀錄、2 GB 磁碟上限的實機觸發、重開機後是否保留、Mac 闔蓋（A01）、D13 的說明。
