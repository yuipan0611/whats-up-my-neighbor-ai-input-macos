# Neko：GCP Codex 開發試跑

這是一套待完成帳號設定與雲端驗證的試跑工具。它讓開發工作在 GCP 執行，
由 GitHub 建立 Draft PR，再交給 GitHub macOS runner 建置與離線測試。
整條遠端流程啟動後不需要個人 Mac 保持開機。此目錄存在不代表流程已部署或驗證成功。

**資料流向：**公開 GitHub 程式碼與任務文字會送往 GCP（預設美國 `us-central1`）與 OpenAI API；
修改檔與工作紀錄存入私有 GCS bucket，核准範圍內的文件修改會出現在公開 GitHub Draft PR。
請勿將私人 PRD、錄音、個人文件、Keychain、簽章憑證或 App 設定放入任務。
API 用量另行計費。GitHub macOS 離線測試不涵蓋真機麥克風、權限、UI 或更新安裝。

## 第一個小任務

固定任務寫在 `pipeline.py#PROMPT`：新增繁體中文的 `docs/CLOUD_DEVELOPMENT.md`，
並在 `README.md` 加上入口，說明 Linux 開發、macOS CI、真機驗證與發布的差別。
雲端任務只能交回這兩個路徑的文字修改，不可刪除檔案、變更執行權限或新增符號連結。
本次基礎設施 PR 與稍後真正由 Codex 產生的文件 PR 是兩項不同證據。

## 執行流程與權限

1. 受信任的 GitHub workflow 固定來源 main SHA 與任務 ID，透過 OIDC 取得短效 GCP 身分。
2. Cloud Run Job 只讀取固定 GitHub 倉庫、執行 Codex，將 patch 與狀態保存至私有 GCS。
3. 根程序持有 Secret Manager 掛載金鑰與官方 Responses proxy。Codex 以獨立使用者執行，
   不繼承 OpenAI、GitHub 或 GCP 環境憑證；工具指令使用 `workspace-write` 且關閉網路。
4. 獨立 GitHub publisher job 驗證任務摘要、來源 SHA、檔案範圍與檔案類型，建立單一 Draft PR。
   它沒有 OpenAI 金鑰或 GCP 身分，也不執行產生的文件內容。
5. macOS job 對 PR 的確切 commit 執行 `scripts/build.sh`、`scripts/test-all.sh`，
   最後將通過或失敗的 check 附到該 commit。沒有合併、發布或本機安裝步驟。

這是受限的文件試跑，尚未開放任意 issue 文字或外部 webhook 驅動程式修改。
不得因為 prompt 寫了「不要」就認定任意程式執行安全；擴大任務範圍前須重新檢查隔離與權限。

## 快速啟動

需求：Python 3.11+、Git、已登入的 Google Cloud CLI、GitHub 倉庫管理權限，
以及**已連結帳單的專用 GCP 專案**。OpenAI 金鑰透過安全設定流程提供，不貼在聊天、
指令參數或 GitHub Actions secrets；本工具不會複製個人 Codex 登入檔。

在倉庫根目錄先查看計畫；以下名稱是範例，換成自己的專案與全球唯一 bucket 名稱：

```sh
python3 tools/cloud-agent/quickstart.py provision \
  --project example-neko-project --project-number 123456789012 \
  --bucket example-neko-private-results
```

確認計畫後，加入 `--apply` 才會建立 API、私有儲存、三個用途分開的 service account、
空 Secret Manager secret，以及僅接受此 Neko 倉庫與指定 workflow 的 OIDC 設定。
腳本遇到既有資源會停止，不會自動接管，也不會自動刪除或回滾資源。
若中斷，先確認最後成功步驟，再接續尚未完成的指令，勿盲目整段重跑。

先在沒有模型金鑰的狀態測試 Cloud Run 實際隔離相容性：

```sh
python3 tools/cloud-agent/quickstart.py check-runtime \
  --project example-neko-project --bucket example-neko-private-results
```

此計畫需加 `--apply` 才建置容器與執行最多 2 分鐘的 probe job。它不掛載金鑰、
不呼叫模型，會驗證可在工作區寫入、工作區外寫入被擋，以及連往已知運行的本機測試服務被擋。
也會建立不掛載金鑰的 audit job，供 GitHub 驗證固定 SHA checkout、GCS 狀態保存與取回；
audit job 只做公開倉庫盤點，不修改程式、不建立 PR。
若失敗，先解決 runtime 相容性；不要繼續付費模型試跑或繞過 sandbox。

通過後，安全設定流程將專用 OpenAI 金鑰存成 Secret Manager 的版本，使用該**版本編號**部署：

```sh
python3 tools/cloud-agent/quickstart.py deploy \
  --project example-neko-project --bucket example-neko-private-results \
  --secret-version 1
```

同樣先檢查計畫，再加 `--apply`。容器由 Cloud Build 建置，Mac 不需要啟動 Docker。
每項工作固定一個 task、2 vCPU、8 GiB、最多 20 分鐘、平台自動重試次數 0；
Codex 呼叫另有 9 分鐘上限。這些限制不能保證 API 消費的硬上限。

GitHub repository variables（沒有私密金鑰）：

| 變數 | 內容 |
| --- | --- |
| `NEKO_GCP_PROJECT` | 專用 project ID |
| `NEKO_GCP_REGION` | `us-central1` |
| `NEKO_GCP_JOB` | `neko-agent` |
| `NEKO_GCP_BUCKET` | 私有結果 bucket |
| `NEKO_GCP_GITHUB_SA` | `neko-agent-github@PROJECT.iam.gserviceaccount.com` |
| `NEKO_GCP_WIF_PROVIDER` | `projects/NUMBER/locations/global/workloadIdentityPools/neko-agent/providers/github` |
| `NEKO_GCP_PILOT_ENABLED` | 完成上述設定與驗證後才設 `true`；預設停用 |
| `NEKO_GCP_PREFLIGHT_ENABLED` | 設 `true` 僅啟動不用模型金鑰的 sandbox 與 audit 檢查；模型開關仍獨立控制 |

GitHub Settings → Actions → General 需允許 Actions 建立 PR。這不會自動合併或核准 PR。
基礎設施未合併前，可在受信任的 `codex/neko-cloud-pilot` 分支 push 啟動，
或重跑該分支既有的 Actions 執行；合併後可在 main 使用 Run workflow。
workflow 沒有定時排程，所以不會自行產生週期費用或持續修改程式碼。
啟用任何一項雲端開關後，符合條件的分支 push 會產生 Cloud Run 用量；需要完全停止後續雲端執行時，
將 `NEKO_GCP_PREFLIGHT_ENABLED` 與 `NEKO_GCP_PILOT_ENABLED` 都設為 `false`。

給其他開發者使用時：雲端資源腳本可沿用，但這份 pilot 刻意鎖定 Neko。
須先修改 `quickstart.py` 的倉庫數字 ID／擁有者 ID／workflow 路徑，
`pipeline.py` 的倉庫與固定任務，以及 workflow 的倉庫／分支條件，再重新測試。
單改專案名稱不會授予其他倉庫存取權。

## 驗證與復原

```sh
python3 -m unittest discover -s tools/cloud-agent/tests -v
```

GitHub 的 `validate` job 另外建置固定 Codex/proxy `0.163.0` 容器、檢查 CLI 參數與 Linux sandbox；
它不提供金鑰、不呼叫模型。CI Docker 測試允許容器建立內部 namespace，沒有掛載宿主憑證。
**該測試通過仍不代表 Cloud Run runtime 的 sandbox 已通過**。
Cloud Run 必須先通過實際 sandbox preflight 才呼叫模型；失敗就停止，不會降級成無隔離執行。
若 Cloud Run 不相容，下一步是另驗證 GCP Linux VM，而不是自動繞過 sandbox。

GCS `requests/ID.json` 是不可覆寫的輸入；`tasks/ID/` 保存狀態、lease、private log 與 patch。
同一個已完成的 ID 不會再次呼叫 Codex。失敗需檢查紀錄後才可手動重試，
活躍 lease 會阻擋同一個任務的重複執行。不同 ID 不是全域序列佇列。
PR 分支以任務 ID 命名；重試只接受相同 tree 與來源 parent，不 force push，不建立重複 PR。
若來源 main 已移動而輸入不再一致，啟動新任務，不把舊 ID 指向新內容。

若要停用，將 `NEKO_GCP_PILOT_ENABLED` 與 `NEKO_GCP_PREFLIGHT_ENABLED` 都設為 `false`；已開始的 Cloud Run 工作需另行取消。
這不會刪除結果、容器、secret 或儲存資源；閒置儲存仍可能計費。

## 官方依據

- [Codex 非互動模式與金鑰 proxy](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Cloud Run 執行環境](https://docs.cloud.google.com/run/docs/configuring/execution-environments)
- [Cloud Run Jobs secrets](https://docs.cloud.google.com/run/docs/configuring/jobs/secrets)
- [GitHub 與 GCP OIDC](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-google-cloud-platform)
- [GitHub workflow 觸發限制](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)

`costs.py` 保留先前比較的參數試算，並非帳單預測或最新報價保證；部署前以供應商當期價格為準。
