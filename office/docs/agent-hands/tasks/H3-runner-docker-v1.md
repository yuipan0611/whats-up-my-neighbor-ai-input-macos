# 任務：runner 第一個真 provider：本機 Docker（v1 施工單）

- 日期：2026-10-28
- 狀態：YUI 2026-10-28 同意實作。**單元測試層已完成**（`3e90c1b`、其後的辦公室接線 commit）；沒有安裝、沒有部署、沒有啟動 Docker。第 5.2 節的防火牆、映像、真 Docker 測試尚未做，見 HANDOFF。
- 前置：runner 已接進 `office.py`（`abc4ff1`，只做啟動復原＋健康狀態）。程式碼見 `office/runner.py`。

## 1. YUI 的決定（2026-10-28）

| 項目 | 決定 |
|---|---|
| 輸入來源 | 選項二：辦公室自己 clone 綁定的 repo，用固定 commit（`source_rev`）取檔 |
| 第一個 provider | 本機 Docker（不另付費、資料不出 VPS） |
| 安全原則 | **只守兩條紅線：檔案改壞、刷卡。** 其他限制可以放寬，包括執行時的網路 |
| 之後才做 | 服務容器（資料庫等）、非 git 任務的 outputs 資料夾、E2B |

因為 YUI 選了「權限放寬」，原本草案的「0＋1 級（執行時斷網）」**作廢**：執行時預設可以連外網，白名單代理不再需要。

## 2. 紅線一：檔案改壞

「改壞」指：YUI 的檔案、主機上的檔案、辦公室資料庫、主線程式碼被改掉或弄壞，而且收不回來。

| 防線 | 做法 | 狀態 |
|---|---|---|
| 沙盒只拿到複本 | 輸入是從辦公室 clone 複製進容器的檔案；**不掛載任何主機資料夾** | 要寫 |
| 結果只能落在任務分支 | patch 只 commit 到 `neko/<任務短碼>`；`GitTarget` 拒絕其他分支名稱 | 已有 |
| 主線只有人能動 | 辦公室不 merge、不刪分支、不打 tag；合併由 YUI 在 GitHub 上按 | 已有（H4） |
| 可以回退 | 每次結果是一個獨立 commit，`git revert` 即可；commit 訊息帶 `Neko-Run: <run_id>` | 已有 |
| 不重複套用 | 套用前先查分支上有沒有同一個 `Neko-Run`；當機重啟也不會套兩次 | 已有 |
| 容器碰不到主機 | 非 root 使用者、`--cap-drop ALL`、`--security-opt no-new-privileges`、**不掛 Docker socket、不用 `--privileged`、不用 `--network host`** | 要寫 |
| hands 碰不到 Docker | 由辦公室的使用者跑 **rootless Docker**；`neko-hands` 不加入 docker 群組（docker 群組等於 root） | 要寫＋安裝需同意 |
| 磁碟不會被塞滿 | 容器可寫空間上限、映像與已結束容器定期清理；辦公室資料庫所在的磁碟保留至少 2GB，不足就拒絕開新沙盒 | 要寫 |

磁碟那一條看起來不像「改壞檔案」，但磁碟滿了 SQLite 會寫入失敗，辦公室的紀錄可能壞掉，所以算在這條線裡。

## 3. 紅線二：刷卡

「刷卡」指：任何會讓 YUI 被收費的事，包括付費服務按量計費、在網站上付款。

| 防線 | 做法 | 狀態 |
|---|---|---|
| provider 本身不計費 | 本機 Docker 沒有按次收費；E2B 等付費服務 v1 不接 | 本設計 |
| 沙盒裡沒有任何憑證 | 輸入排除清單擋掉 `.env`、金鑰、`.netrc`、`.npmrc`、`auth.json`、`credentials*`、Chrome profile、Cookies、Login Data；**容器不帶任何環境變數裡的金鑰**。沒有卡號、沒有登入，開了網路也刷不到 YUI 的卡 | 排除清單已有；環境變數要寫 |
| 容器連不回主機 | 封鎖容器連到主機、VPS 內網（10/8、172.16/12、192.168/16、100.64/10）、雲端 metadata（169.254.169.254）。主機上的 Chrome 除錯埠、Ollama 雖然只聽 127.0.0.1，仍明文封鎖 | 要寫 |
| 不能改 CI | patch 改到 `.github/workflows/` 一律拒絕（GitHub Actions 可能用到付費分鐘數與 repo secrets） | H4 已有；runner 要補 |
| 流量費用 | 開外網後，程式可以大量下載或上傳。VPS 方案有沒有超量計費**待查**；先以每次執行時間上限（預設 10 分鐘）壓住 | 待查 |

**沙盒以外、和刷卡最相關的風險（runner 管不到，要講清楚）：** 貓咪的 Chrome。

- 經過 broker 的動作，付款類網址（`pay`、`checkout`、`purchase`、`order`……）一律停下等人（ADR-002 R6），這部分已有。
- 但 D13 同 UID 旁路還在：`neko-hands` 的 shell 可以直接連 Chrome 除錯埠，繞過 broker。
- **所以規則是：貓咪的 Chrome 不登入任何存了信用卡的帳號、不儲存付款方式。** 真的需要時，照 PRD 5.2 先拆出 `neko-runner` 使用者。

## 4. 放寬的項目（相對於先前草案）

| 項目 | 先前 | v1 |
|---|---|---|
| 執行時網路 | 斷網 | **可連外網**（但連不回主機和內網，見第 3 節） |
| 安裝套件 | 只能在建映像時 | 執行時也可以 `pip`／`npm install` |
| 預先建映像 | 安全必要 | 只是加速用；有基本映像就能跑 |
| 容器內檔案系統 | 唯讀 | 可寫（容器用完即丟） |
| patch 含二進位檔 | 拒絕 | 允許（仍只落在任務分支，可回退）— `runner.patch_problems` 要改 |

不放寬（因為直接關係到兩條紅線）：輸入排除清單、任務分支限制、`.github/workflows/` 禁改、不掛主機資料夾、不帶憑證。

資源上限這次不改：每次 10 分鐘、送進去 500 個檔案／20MB、帶回 log 1MB＋patch 4MB。之後可以按任務調整。

## 5. 怎麼接（實作要點）

### 5.1 `DockerRunner`（`office/runner_docker.py`，只用標準函式庫＋`docker` 指令）

| `Runner` 方法 | Docker 做法 |
|---|---|
| `create(run_id, labels)` | `docker create --label neko_run=<run_id> ...`（旗標見 5.2），容器先不啟動 |
| `find(run_id)` | `docker ps -a --filter label=neko_run=<run_id>`：create 回應遺失時用來找回 |
| `upload` | `docker cp` 把清單上的檔案放進 `/work`；先在容器內建一個基準 commit，之後才能算 patch |
| `execute` | 啟動並執行指令，逾時就 `docker kill`；回傳結束碼、秒數、是否逾時 |
| `status` | `docker inspect`：running／paused／exited；找不到就是 gone |
| `collect` | 取回 log 與容器內 `git diff --binary`（相對於基準 commit） |
| `pause` | `docker pause` |
| `destroy` | `docker rm -f`；找不到不算錯 |

`docker` 指令本身失敗、逾時、daemon 連不上，對應到 `RunnerUnknown`／`RunnerFailed`／`RunnerGone`，**任何情況都不退回主機直接執行**。

### 5.2 容器旗標（初稿，待實測）

```
--user 10001:10001 --cap-drop ALL --security-opt no-new-privileges
--pids-limit 512 --memory 2g --cpus 2 --storage-opt size=5G（不支援就改成定期檢查）
--network neko-runner（自建 bridge，主機防火牆封鎖連回主機與內網）
不加 -v / --mount、不加 --privileged、不加 --network host、不掛 /var/run/docker.sock
環境變數只給 HOME、PATH、LANG、CI=1
```

### 5.3 辦公室的 clone

- 位置：`<data>/../repos/<owner>__<repo>`（bare clone）＋每件工作一個工作樹 `<data>/../runs-worktrees/<任務短碼>`，checkout 在 `neko/<任務短碼>`。
- v1 只用**合成的測試 repo 或公開 repo**；私有 repo 要等 GitHub App（H4）。
- repo 綁定沿用 H4 的 `github_tasks`（一件工作一個 repo），不另開一套。

### 5.4 worker 路由（只在 worker socket）

- `POST /api/worker/run/start`：`{task_id, lease, paths, command}`。repo、commit、分支都由辦公室決定，worker 帶了就 400（和 H4 同規則）。
- `POST /api/worker/run/status`：`{task_id, lease}`，回傳狀態、結束碼、log 摘要。
- 發布：驗證通過就自動 commit 到任務分支（紅線一靠分支＋人工合併守住，不需要每次問）。

### 5.5 取消或收回時立刻清掉

`store.cancel`、`hands_locked` 生效時，辦公室立刻清掉該任務的容器，不等下一次呼叫或重啟。

## 6. 測試計畫

| 層級 | 內容 | 需要同意 |
|---|---|---|
| 單元 | 用假的 `docker` 指令（測試裡的腳本）測每個方法的成功、失敗、逾時、回應遺失 | 不用 |
| 紅線一 | 主機上放金絲雀檔案，跑完確認沒被改；main 分支 commit 數不變；patch 只出現在 `neko/*` | 不用（單元層）；真 Docker 要同意 |
| 紅線二 | 金絲雀金鑰不在容器裡；容器連 `host.docker.internal`、169.254.169.254、主機 127.0.0.1 埠都失敗；容器環境變數沒有金鑰 | 真 Docker 要同意 |
| 放寬項目 | 容器能連外網、能 `pip install` 一個小套件 | 真 Docker 要同意 |
| 真 Docker（Mac） | 在 Mac 的 Docker Desktop（已安裝 29.6.1，目前沒啟動）跑一次合成 repo 的完整流程 | **要 YUI 同意啟動 Docker Desktop** |
| VPS | 安裝 rootless Docker、設防火牆 | **要 YUI 另外同意**，v1 不做 |

Mac 的 Docker Desktop 是跑在虛擬機裡，「連回主機」的行為和 VPS 不同；Mac 測過不代表 VPS 也成立，兩邊要分開記。

**2026-10-28 Mac 實測：** 功能 8 項全過；但容器連得到 Mac 上只聽 127.0.0.1 的服務（經 `host.docker.internal`／`192.168.65.254`）與家裡路由器。Mac 不能跑真任務；VPS 要先裝防火牆並重跑量測。細節見 HANDOFF。

## 7. 不在 v1

E2B、服務容器（資料庫）、outputs 資料夾、私有 repo、VPS 部署、網頁／App 介面。

## 8. 回退

新增 `runner_docker.py` 與路由；`main()` 要加 `--sandbox docker` 才會啟用，不加就和現在一樣（`office.runs` 是 `None`）。回退只要拿掉啟動參數或 revert commit。容器都帶 `neko_run` 標籤，`docker rm -f $(docker ps -aq --filter label=neko_run)` 可以一次清光。

## 9. 待 YUI 回答

1. 這份的兩條紅線和放寬清單對不對？
2. 可以開始寫程式（單元測試層，不碰真 Docker）嗎？
3. 寫完要在 Mac 啟動 Docker Desktop 跑真測試時，會再問一次。
