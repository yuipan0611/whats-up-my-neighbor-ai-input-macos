# Codex Cloud 開發指南

本指南說明如何以個人 Codex Cloud 環境，為公開儲存庫 `yuipan0611/whats-up-my-neighbor-ai-input-macos` 準備可審閱的小型變更。

## 快速開始

1. 使用自己的 ChatGPT／Codex 帳號登入，開啟 Codex Cloud 的環境設定，建立個人環境。
2. 透過平台提供的 GitHub 授權流程選取此儲存庫，確認存取範圍與網路設定；不需要把個人登入檔或 API 金鑰複製進儲存庫。
3. 儲存並發布環境，確認環境可啟動，再於任務中選用這個已發布的環境。實際介面名稱可能隨平台更新。
4. 交代明確任務：來源儲存庫與 main、允許修改的路徑、預期成果、禁止事項及驗收方式。要求先讀適用的 `AGENTS.md`、確認乾淨狀態、取得最新遠端 main 並記錄來源 SHA，再建立獨立分支；若分支已存在，選唯一後綴，不覆寫既有分支或修改。
5. 要求回報實際檢查結果；平台具備 GitHub 寫入能力時，提交變更並建立指向 main 的 Draft PR，交由人工審閱，不自動合併。無寫入能力時保留已驗證 diff 並回報，不繞過權限或複製登入憑證。

例如，第一個任務可以只新增本指南，並在 README 加入相對連結；不連帶修改 App、測試、版本、素材、workflow 或發行設定。

## 雲端與 Mac 的分工

任務送交雲端並開始執行後，即使自己的 Mac 關機，雲端任務仍可繼續；執行仍受平台資源、時限及任務狀態影響。Linux 雲端適合編輯文件、程式碼檢查與準備變更，但不能驗證 AppKit／macOS 原生 UI，也不能把 Linux 檢查當成 Mac 實測。

不要在 Linux 執行本專案不支援該平台的原生建置、測試或發布腳本。建置與離線回歸由 macOS CI 執行，實際使用行為則另外在 Mac 驗證。

## 現有 GitHub Actions CI

依 [`.github/workflows/build.yml`](../.github/workflows/build.yml)，`Build` workflow 在 `push` 與 `pull_request` 觸發。一般 `build` job 使用 GitHub `macos-14` runner，依序執行：

1. `./scripts/build.sh` 建置並驗證 App。
2. `./scripts/test-all.sh` 執行既有離線回歸測試。
3. `PACKAGE_EXISTING_BUILD=1 ./scripts/package-release.sh` 打包既有建置。
4. 上傳 `macos-development-installer` 開發用 artifact，包含 `dist/*.zip` 與 `dist/*.sha256`，保留七天；缺少檔案會報錯。

另有一個設為 `if: always()` 的上傳步驟，嘗試將 `build/cat-render/` 上傳為 `macos-cat-native-renders`；缺少檔案時警告。一般建置未開啟正式簽章模式時採 ad-hoc 簽章，開發包不會自動加入更新清單。

同檔的 `free-release-check` 是另一個受條件限制的 job：只在原儲存庫對 main 或 `codex/neko-cicd-updates` 的 push 執行，使用 `macos-14` 與 `scripts/release-macos.sh`。workflow 註解說明它不發布 release、tag 或 feed；它不會在一般 PR 事件執行。此指南只描述設定，不代表任何一次 CI 已通過，也不授權執行發布。

## 必須分開驗證的項目

即使 macOS CI 成功，下列項目也不能視為完成：

| 項目 | 另行驗證的範圍 |
|---|---|
| 麥克風 | 實機授權、輸入裝置與錄音行為 |
| 輔助使用權限 | 系統授權、拒絕與重新授權後的行為 |
| 貼上 | 真實目標 App 的焦點、游標與貼上結果 |
| 桌面互動 | 原生 UI、桌面貓、全螢幕、鎖定與休眠等情境 |
| 更新安裝 | 使用者選擇下載／安裝、升級流程與設定保留 |
| 簽章／公證 | 產物身分、驗簽及實際發行政策；開發包驗簽不等於正式簽章或 Apple 公證。目前免費發行方案沒有 Apple 公證 |

這些驗證應各自留下環境、版本、步驟與結果，不能用單一綠色 CI 狀態取代。

## 小任務驗收

- 範圍清楚：diff 只包含允許的檔案與必要改動，保留既有內容及相對連結，不順手修其他問題。
- 來源可追溯：記錄來源 main SHA、分支名稱、PR commit SHA 與 PR 連結；來源不同於任務預期時明確回報。
- 雲端檢查有證據：記錄 `git diff --check`、變更路徑、新連結目標可讀與文件對照實際 CI 設定的結果；標明哪些未執行。
- macOS CI 結果獨立記錄：以本次 PR commit 對應的 workflow 結果為準；尚未執行、執行中、失敗與成功須如實區分，不能由 Linux 檢查推定通過。
- Draft PR 經人工審閱：確認內容、檢查結果與待辦，合併與發布另行決定。

任務完成不代表已建立持續監控、背景維護或排程；這些需要另外明確設定與驗證。

## 資料流向與本次任務邊界

此公開程式碼、交給 Codex 的任務文字與相關結果，會由 OpenAI／GitHub 處理，包括雲端執行、commit、PR 與 CI 的相關內容。只提供完成任務所需的公開資料，留意公開 PR 與日誌可被他人閱讀。

私人錄音、剪貼簿內容、Keychain、App 設定與私人文件不在此文件任務的輸入範圍，也不應為了設定雲端環境而上傳。帳號登入由平台管理，不把個人登入檔或 API 金鑰加入儲存庫、任務文字或日誌。這裡描述的是開發任務資料流向；App 本身的資料處理請參閱 [PRIVACY.md](../PRIVACY.md)。
