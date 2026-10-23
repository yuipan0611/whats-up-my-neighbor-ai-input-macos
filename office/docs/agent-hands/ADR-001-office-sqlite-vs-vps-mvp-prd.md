---
title: ADR-001：沿用貓咪辦公室＋SQLite，並對照 VPS-first PRD 的 A01–A20
date: 2026-10-23
status: 採用（2026-10-23）；第 5 節三項差異待 YUI 決定
compares:
  - 本資料夾 PRD.md（貓咪的手 v0.2.1）
  - yuipan0611/nekonode-site 分支 docs/vps-agent-mvp-20261023（commit 1fcd539）的 docs/plans/vps-agent-mvp-prd.md 與 claude-vps-agent-handoff.md
---

# ADR-001：沿用貓咪辦公室＋SQLite

## 1. 背景

2026-10-23 出現兩份描述同一套系統的計畫：

| | 貓咪的手（本資料夾） | VPS-first Agent MVP（nekonode-site） |
|---|---|---|
| 作者 | Claude，YUI 拍板 D1–D11 | ChatGPT |
| 狀態 | 0.4.0 已部署；0.5.0 的 worker API 寫好、未部署；下一步 H1 | 只有文件，施工單寫明「不能把本文件存在等同已派工」 |
| 後端 | 既有的 `office.py`（Python 標準庫） | 沒有既有實作時用 FastAPI |
| 任務資料 | SQLite | PostgreSQL |

ChatGPT 那份是在**看不到本分支**的情況下寫的（本分支沒有 push），所以它的第 0 節寫「尚未在已讀取的遠端文件中找到完整 always-on PRD」。它自己的規則是「優先沿用現有已驗證的實作；若保留既有後端，須寫 ADR 說明映射，並保留本文件的行為與安全驗收」。這份 ADR 就是那份映射。

## 2. 決定

1. **繼續用辦公室**：`office.py`＋SQLite＋辦公室既有的 WebSocket，不另做 FastAPI＋PostgreSQL 的 `services/agent-runtime/`。
2. **施工基準只有一份**：本資料夾的 PRD.md 和 HANDOFF.md。nekonode-site 那份改當「需求參考」，它的「一段式啟動提示詞」**不要拿去派工**，否則會在官網 repo 做出第二套系統。
3. **它的 A01–A20 收進來**：每一項都對到 H1–H9（第 6 節）。對不上的，在第 5 節說明是刻意不同還是要補。

## 3. 為什麼

| 理由 | 說明 |
|---|---|
| PostgreSQL 解決的問題我們沒有 | SKIP LOCKED 是讓多個 worker 同時領工作時不打架。兩份 PRD 都規定一次只跑一件「手」的任務（本 PRD 第 7 節；對方 TASK-04）。辦公室在同一個程序裡用鎖加上 SQLite 交易，就能做到一次只發一件。 |
| VPS 記憶體已經很緊 | 實測 2 vCPU、7.9 GB、沒有 swap（PRD 1.2）；Chrome 估 1–2 GB，Gemma 約 3–4 GB。多一個常駐資料庫，就多一份記憶體、備份和升級。對方用 4 vCPU／8 GiB 當起點，而且寫明 VPS 規格還沒核實。 |
| 已經部署、已經測過 | 0.4.0 已上線，`verify_public.py` 27 項全過；0.5.0 有 104 項離線測試。換技術就要重做對方的 M1。 |
| 持久性要求一樣做得到 | 先存檔再回覆、同一個任務編號不重複建立、事件序號補進度、租約與重試、每一輪的 lease，都已經在辦公室裡（第 6 節 A01、A02）。 |

## 4. 元件對照

| 對方的元件 | 在我們這邊 | 狀態 |
|---|---|---|
| 任務 API（`POST /v1/tasks` 等） | `/api/command`、`/api/tasks`、`/api/sync?after=` | 已有 |
| WS 事件信封與 sequence | `events.seq`＋`/api/ws`，hello 帶 `latest_seq` | 已有 |
| idempotency key | 用戶端產生的任務 UUID；同一個 ID、內容不同回 409 | 已有 |
| Worker 的 lease、heartbeat、fencing | `/api/worker/*`：租約 120 秒、重試 3 次、每一輪都有新的 `lease` | H2 完成（未部署） |
| Policy broker／Grant | GitHub App 的臨時鑰匙＋辦公室代為 push（PRD 5.4、5.6） | H4 |
| Browser broker＋headed Chrome | neko-hands 的 Chrome，跑在 VNC 桌面上（PRD 7） | H1、H3 |
| noVNC 觀看／接管 | 「看看貓咪」，經辦公室的 WebSocket 轉接（PRD 6） | H6 |
| 檔案 broker（input 唯讀、output 讀寫） | `/srv/neko-handoff/給貓`（唯讀）、`貓交回`（PRD 5.7） | H1、H7 |
| 無憑證的 code runner | neko-hands 手上沒有 GitHub 鑰匙；但程式和 Chrome 在同一個使用者底下 | 部分，見 5.2 |
| 私有入口（Tailscale） | Caddy＋已配對裝置的 cookie；本機模式只開在 Unix socket | 已有（0.4.0） |
| Mac 感知 helper | v1 不新增；眼睛和耳朵用現有的 App 功能 | 不在 v1 |

## 5. 刻意不同、待 YUI 決定的三件事

### 5.1 接手中斷線，要不要自動交還（對方 A06）

- **本 PRD 第 6 節：**「按『交還』或關掉，貓咪從原處繼續」，等於關掉畫面就算交還。
- **對方：** 接手中斷線，維持暫停，不自動交還。
- **風險：** 你在手機上輸入驗證碼時剛好斷線，貓咪就會立刻接著點。
- **推薦：** 改成對方的做法。「關掉只在看的畫面」不影響工作；「接手中斷線」維持暫停，回來後按一次「交還」。這不違反 13.2「重新登入後交還，不需要再按『繼續』」：交還本來就是你按的那一下。
- 決定後改 PRD 第 6 節與 H6。

### 5.2 跑程式和 Chrome 在同一個 Linux 使用者底下（對方 A11）

- **本 PRD：** neko-hands 同時跑 Codex、npm／pip 安裝腳本和 Chrome。GitHub 鑰匙、生活紀錄都碰不到（在 neighbor），但**貓咪 Chrome 的登入狀態碰得到**。
- **對方：** 程式要在沒有任何登入狀態的 runner 裡執行。
- **為什麼 v1 可以接受：** 貓咪的 Chrome 只登入貓咪自己的帳號（D3），外洩的損失有上限。
- **以後要分開的條件：** 貓咪的 Chrome 需要登入任何有價值的帳號。到時候新增第三個使用者 `neko-runner`，專門跑安裝和測試。
- **推薦：** v1 維持現狀，並在 H3 驗收裡寫明「安裝腳本讀得到貓咪 Chrome 的 profile」這件事。

### 5.3 不做網站白名單（對方 A07 的 domain 與上傳目的地）

- **本 PRD 5.9：** v1 不限制出站連線。網站這邊真正的控制是「登入的是誰的帳號」。
- **對方：** 要有 origin allowlist，並攔下未授權的上傳目的地。對方也承認白名單擋不住「在同一個允許的網站裡把資料傳出去」。
- **推薦：** v1 維持不做。v2 先用 iptables 擋 SMTP 這類出站連線（PRD 5.9 已列）。

## 6. A01–A20 對照

狀態：✅ 已完成且有測試｜🟡 部分完成｜⬜ 已在 H 計畫、還沒做｜➕ 這份 ADR 新增到 H 任務｜↔ 刻意不同（第 5 節）｜— 不在 v1

| ID | 要驗證什麼 | 對到 | 狀態 | 現有證據／要補的 |
|---|---|---|---|---|
| A01 | 關頁、Mac 離線後，任務照做；重連後補事件、不重送 | 既有辦公室、H2、H3 | 🟡 | 已有：`test_office.test_same_request_does_not_repeat`、`test_mobile.test_reconnect_after_seq_has_no_gap_or_duplicate`、`test_stale_cursor_and_bad_parameters`。還差：H3 用真的 worker，在 Mac 合上的情況下跑完一件 hands 任務。 |
| A02 | 重複送出、worker 當機或租約過期，都不會有兩個 worker 同時造成副作用；結果不明時轉人工核對 | H2、H4 | 🟡 | 已有：`test_hands` 的 LeaseTests、FencingTests（每一輪有自己的 lease；舊的一輪不能續租、不能寫步驟、不能交成果）。➕ H4：push 和開 PR 要能重送（固定分支 `neko/<任務短碼>`；開 PR 前先查同一個分支是不是已經有 PR；超時就標「待核對」，不要再開一次）。 |
| A03 | VPS 重啟後任務能恢復、profile 保留；登入失效時等你登入 | H2、H3、H5 | 🟡 | 已有：`test_hands.test_office_restart_keeps_the_worker_task`（含重啟後 lease 仍然有效）、`test_office.test_restart_keeps_queue_and_marks_active_interrupted`。⬜ H3：worker 以 systemd 常駐，重開機後 Chrome profile 還在。⬜ H5：「需要你登入」卡片。 |
| A04 | 改前端、偽造輸入、直接連 VNC／CDP、換 session ID，都拿不到控制權 | H1、H6 | ↔ | VNC 和 Chrome 除錯埠只綁 127.0.0.1（PRD 5.9），網際網路連不到；看畫面要已配對裝置（PRD 6）。「只看」只在畫面這一層切換，不做伺服器強制：只有你一個使用者，看的人就是你（PRD 6）。neko-hands 自己連得到 VNC／CDP，這是 5.2 的範圍。 |
| A05 | 接手時還在跑的瀏覽器動作、兩台裝置搶控制、舊 worker 復活：同時只有一個操作者 | H2、H6 | 🟡 | 已有：舊的一輪打不了 worker API（FencingTests）。➕ H6：接手時由 worker（我們寫的程式，不是 LLM）暫停整組 agent 程序，因為 agent 能直接連 Chrome 的除錯介面，光「請它停」攔不住。➕ H6：同一時間只有一台裝置能接手。 |
| A06 | 接手中斷線維持暫停；關掉只在看的畫面不停工作；交還後重新觀察，不重播舊指令 | H6 | ↔ | 見 5.1，待 YUI 決定。 |
| A07 | 未授權的 repo、分支、路徑、網站、上傳目的地、拿 token、碰 Docker socket，一律被拒 | H1、H4 | ⬜／↔ | ⬜ H4：只推 `neko/*`、擋 `.github/workflows/`、App 只裝在勾選的 repo（PRD 13.1 已列）。⬜ H1：neko-hands 不在 docker、sudo 群組。↔ 網站與上傳目的地見 5.3。 |
| A08 | 路徑穿越、symlink／hardlink、壓縮檔逃逸、批准後換檔、版本衝突 | 既有辦公室、H7 | 🟡 | 已有：資料目錄和附件拒絕符號連結。⬜ H7：同步時不跟隨連結、不刪 Mac 上的檔案、同名先備份。「批准後換檔」不適用：v1 不覆寫你的原檔。 |
| A09 | 假冒擁有者、批准重播／過期／換參數／跨任務、撤銷後舊授權，全部被拒 | 既有辦公室、H4、H9 | 🟡 | 已有：`test_mobile.test_cookie_origin_and_token_all_required`、`test_revoke_forget_and_expiry`、`verify_public.py`（撤銷後 WSS 以 4401 關閉）。批准重播不適用：D7 規定收不回的事由你本人按，v1 沒有「批准後由貓咪代按」。⬜ H4、H9：鑰匙收回後立即失效。 |
| A10 | 惡意網頁或 README 要它上傳 token、擴權；秘密不進 prompt、log、成果 | H1、H3、H4 | ⬜ | 原則 5.1-2：手上沒有長期鑰匙，就沒東西可以上傳。⬜ PRD 13.1：neko-hands 的環境裡找不到 GitHub 鑰匙。➕ H3：準備一頁含惡意指令的測試網頁，加上一個含惡意指令的測試 README，當成合成任務來跑。 |
| A11 | npm／Python 安裝腳本讀不到 profile、token、控制平面、雲端 metadata | H1、H3 | 🟡／↔ | ⬜ H1：用 neko-hands 身分 `cat` 讀 `~neighbor/` 必須失敗（PRD 13.1）。worker socket 只回答這件 hands 任務本身（`test_hands.BoundaryTests`）。↔ 讀得到貓咪 Chrome 的 profile，見 5.2。➕ H3：測 Hostinger 有沒有雲端 metadata 端點、能不能連。 |
| A12 | 不同帳號、不同工作區的資料與登入狀態不混用；登入和接手時不錄步驟、不記鍵盤 | H3、H6 | ➕ | ⬜ H3：每件任務有自己的 `workspace/<任務 UUID>/`。v1 只有一個貓咪 profile，帳號分開的部分不適用。➕ H6：你接手時停止每一步的截圖，避免拍到驗證碼。 |
| A13 | 停止在網路操作途中生效：不再產生新的副作用；收不回的要標明，不能回報假成功 | H2、H3、H4 | 🟡 | 已有：`test_hands` 的 StopTests 和 `test_cancel_stops_the_worker_and_keeps_no_result`（停止後 heartbeat 回 `continue: false`，events、complete 回 409，不留成果）。⬜ H3：worker 收到 `continue: false` 就結束 agent。⬜ H4：push 結果不明時標「待核對」（同 A02）。 |
| A14 | 從交辦到檔案或 draft PR 的完整一條路，附真的測試輸出；不能拿模擬當完成證據 | H3、H4、H5 | ⬜ | 這就是 v1a 的完成點。 |
| A15 | 連續 100 件短任務後，記憶體、分頁、程序、暫存、log 回到原本的水準；沒跑 24 小時測試就標未驗收 | H3 | ➕ | ➕ H3 驗收：連續 100 件合成任務，前後記錄記憶體、Chrome 分頁數、程序數、暫存和 log 大小。24 小時長跑另列，沒跑就寫 `NOT RUN`。 |
| A16 | Mac 記憶體壓力下會降級、不殺其他 App；錄音、掉網、helper 重啟、原本的貼上流程不退化 | — | — | v1 不新增 Mac 感知 helper（PRD 4.3、8.1）。以後做 Mac bridge 或會議字幕常駐時再套用。 |
| A17 | 只有舊副本時顯示時間和版本；Mac 睡著時不假裝拿得到新檔；寫回衝突不覆蓋 | H7 | 🟡 | ⬜ H7：拉回時同名檔先備份、不刪 Mac 上的檔案。➕ H7：貓咪引用「交給貓咪」的檔案時，附上最後同步時間。貓咪本來就只看得到已同步的副本，所以不會「假裝拿得到新檔」。 |
| A18 | HTTP／WS 越權、Origin／CSRF、票券重播、撤銷的裝置、從網際網路掃埠，一律預設拒絕 | 既有辦公室、H2、H6 | 🟡 | 已有：`test_office.test_cross_origin_and_rebinding_rejected`、`test_mobile.test_revoke_forget_and_expiry`、`test_local_entry`（14 項）、`verify_public.py` 27 項（跨站 POST 403、匿名 401、撤銷後 4401、本機 TCP 421）。➕ H1 之後：從外部掃 VNC 和除錯埠，必須連不到。⬜ H6：viewer 的 WebSocket 要套同樣的檢查。 |
| A19 | 費用、步數、時間、磁碟超過上限就停或等待，不會無限重試；取消不靠前端開著 | H2、H3 | 🟡 | 已有：重試 3 次就停，取消在伺服器端（`test_hands.test_silent_worker_is_retried_then_reported`）。⬜ H3：每件最多 30 分鐘、事件最多 4 MB（PRD 7）。➕ H3：工作區設磁碟上限。模型費用：Codex 用你的 ChatGPT 方案額度，沒有每件預算，不適用。 |
| A20 | Chromium 自動測試和真的 Chrome 實測分開列；桌機和手機分開列；沒測的不能標通過 | 全部 | ➕ | 收進 HANDOFF 的共用規則（見第 8 節）。 |

## 7. 因此新增到 H 任務的工作

| H | 新增 | 來自 |
|---|---|---|
| H2 | worker API 每一輪的 `lease`（已完成，0.5.0 部署前的契約修改） | A02、A05 |
| H3 | 惡意網頁和 README 的合成任務；雲端 metadata 測試；工作區磁碟上限；連續 100 件任務的資源記錄；驗收寫明「安裝腳本讀得到貓咪 Chrome 的 profile」 | A10、A11、A15、A19、5.2 |
| H4 | push 和開 PR 可以安全重送；結果不明標「待核對」 | A02、A13 |
| H6 | 接手時由 worker 暫停整組 agent 程序；同時只有一台裝置能接手；接手時停止截圖；斷線行為依 5.1 的決定 | A05、A06、A12 |
| H7 | 引用同步檔案時附上最後同步時間 | A17 |
| H1 之後 | 從外部掃 VNC 和除錯埠，必須連不到 | A18 |

## 8. 證據規則（採用對方 A20 與第 12 節的要求）

每一份驗收紀錄都要分開標示：

- **自動測試**：附指令、結束碼、通過幾項。
- **模擬**：例如假的 GitHub adapter、測試網站。
- **實機**：VPS、Mac、iPhone 分開寫。
- **沒測**：寫 `NOT RUN`。

Chromium 的結果不能寫成 Chrome 的結果。

## 9. 什麼時候重新評估這個決定

符合任何一項，就重新考慮 PostgreSQL 或獨立的任務服務：

- 需要兩個以上的「手」同時跑。
- 要開放給自己以外的使用者。
- SQLite 的寫入鎖在實測中造成明顯延遲。
- 任務資料要讓 VPS 以外的服務直接讀寫。

辦公室的資料表很簡單，到時候搬到 PostgreSQL 不難。
