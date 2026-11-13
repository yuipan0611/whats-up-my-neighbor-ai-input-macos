# Groq 回應防崩潰修正（2026-11-13）

修正 Mac `feat/meeting-summary-diarized`（4eb1476）會議摘要的兩個崩潰入口。獨立 clone / fix 分支，Draft PR；不改聽寫、錄音、金鑰、版本、簽章設定或安裝中的 App。

## 問題與修正

1. `parseTimeString` 以前會接受 `inf`、`Infinity`、`1e309`；複合數值乘上單位或相加也可能變無限大。429 分支接著 `Int(ceil(waitSeconds))` 會觸發 Swift 致命錯誤；`1e100` 等極大有限值同樣無法轉 Int。
   - 純數字及每個複合數字都必須 finite。
   - 每次單位縮放/累加後再檢查 finite，阻擋中間運算溢位。
   - 自動重試排程前的最後護欄：等待值必須 finite、非負、**≤300 秒**，才做 UI 秒數轉換與排程。較長的有效等待時間直接回傳原有 HTTP 429 錯誤，**不提前重試**，讓使用者稍後手動重試。
   - 缺漏/無法使用的標頭維持原本 fallback 5 秒、最多重試 3 次；不能因為 Infinity 而建立無限等待。若有其他有效 reset 標頭，保留原有優先序/remaining 選擇規則。300 秒是本 App 的自動等待上限，不是宣稱 Groq 的服務上限。
2. `GroqModelSelector.selectModel` 使用 `Dictionary(uniqueKeysWithValues:)`，對重複 id 觸發致命錯誤。
   - 模型偏好只需確認 id 是否存在，改用 Set membership，不要求模型紀錄唯一。
   - 原本 active/whisper/guard 過濾與最大 context fallback 保留；沒有任意選擇某筆重複資料蓋掉另一筆。

官方標頭參考：[Groq rate limits](https://console.groq.com/docs/rate-limits)（查閱 2026-11-13）。此修正不更動端點、模型、temperature、API Key 或付費設定，驗證只用 URLProtocol 合成回應。

## 回歸測試

`Tests/MeetingSummarizerTests.swift` 直接編譯並呼叫正式 selector/parser/generateSummary：

- 重複模型 JSON：偏好選擇、無偏好時的最大 context、active 過濾都可完成。
- 非有限值與溢位：inf / Infinity / +inf / NaN / 1e309、巨大時數乘法與兩個有限值相加溢位均拒絕；無效 Retry-After 可回退到有效 reset。
- `Retry-After` 的 300.001 秒或 token/request reset 的 `1e100`：不排程等待、不送第二個 chat request、回報失敗；既有 `PRIOR_GOOD_SUMMARY` 保留。
- 非有限值的 fallback 及 300 秒邊界：注入即時 scheduler，不真的等；至多 3 次排程/4 個 chat request 後完成錯誤。既有正常 3 秒重試成功與取消等待測試保留。

實際 TDD red 證據（只有測試程序，不是已安裝 App）：

```text
Swift/NativeDictionary.swift:823: Fatal error: Duplicate values for key: 'openai/gpt-oss-120b'
Precondition failed: Nonfinite/overflow wait must be rejected: inf
Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max
```

修正後 focused command：

```text
$ ./scripts/test-meeting-summary.sh
Meeting summarizer tests passed (40 suites)
```

全部為離線合成模型/逐字稿與獨立暫存資料夾。沒有讀取真實 Key、真實會議、音檔或系統剪貼簿；沒有向 Groq 發出請求。完整 repo tests / build / CI 結果會附在 PR，失敗不省略。

## 未執行範圍

這是來源修正與驗證，不會覆寫目前安裝的 App；待 PM 審核及選定 QA build 後再安裝驗收。原有 App 的權限、bundle identity、LaunchAgent 和 VERSION 不變。未 merge、tag、release。

首次執行 test-all 在 test_release_contract.py:645 失敗：缺少先建置/取得的 Sparkle 工具（Build/fetch Sparkle before the offline suite）。先按 CI 順序做開發建置，再重跑；失敗記錄未省略。

建置與重跑實際結果：

```text
$ RELEASE_SIGNING=0 MAC_CODESIGN_IDENTITY=- BUNDLE_MEETING_DIARIZER=0 ./scripts/build.sh
AI語音輸入.app: valid on disk
AI語音輸入.app: satisfies its Designated Requirement
Built: .../build/AI語音輸入.app
$ lipo -archs build/AI語音輸入.app/Contents/MacOS/FreeVoiceType
x86_64 arm64
$ ./scripts/test-all.sh
All 39 offline test suites passed.
```

本機是未安裝的 ad-hoc 開發建置，略過 diarizer helper 打包；CI 沿用原建置流程做完整驗證，沒有改打包/簽章腳本。Swift 6.4 本機工具鏈仍印出原有 AppUpdateController 弱引用捕捉警告、x86_64 compatibility archive 警告，以及 MeetingDiarizationTests 的未使用結果警告；未為此擴大修改範圍。這些警告沒有使建置/39 套測試失敗。
