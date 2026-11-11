---
title: M2 說話者辨識整合設計（Mac）
date: 2026-11-12
owner: Ben
status: 設計稿，未寫 App 程式
based_on: docs/spikes/2026-11-diarization-s1.md；Tom 的 M1 PR #47（head 12f28fe）；AGy 的 M3 PR #48（head 5dd6968）
tags: [design, diarization, meeting-notes, m2]
---

# M2 說話者辨識整合設計（Mac）

這份只是設計，不改任何 App 程式。每一題先給**建議方案**，再給**替代方案**與取捨。數字來自 S1 報告和本次補做的實測（硬體：Apple M1、8 核心、8 GB；資料：AMI ES2002a，CC BY 4.0，英文）。

## 0. 先看結論

| # | 問題 | 建議 | 一句話原因 |
|---|---|---|---|
| 1 | 音檔保留 | 說話者辨識完成才刪**整場**的段檔；失敗就保留並標在 frontmatter，不自動刪 | 辨識需要整場音檔；磁碟只要約 28 MB／小時 |
| 2 | 分段處理 | 第一版：**整場串接後辨識一次**；等待時間不能接受再升級成逐段 | 準確率相同（96.6% vs 96.4%），但逐段會產生多餘的說話者標籤（9 個 vs 4 個），且要多寫配對邏輯（§2 實測）|
| 3 | 選人數 | **會議結束時**選，預設上次的選擇 | 結束時才知道真的有幾個人；辨識本來就在結束後才開始 |
| 4 | 逐字稿格式 | 兩階段：先出純文字逐字稿，辨識完成後**重新產生** `transcript.md`，舊版備份 | 摘要與使用者永遠只看一個 `transcript.md` |
| 5 | 改名 | frontmatter 放對照表，改名後重新產生（不用文字取代）| 不會誤改逐字稿內容裡的 "Speaker 1" |
| 6 | 打包 | CLI 與 dylib **隨 App 打包並簽章**，只有模型第一次使用時下載 | 下載可執行檔會碰到公證與隔離問題 |
| 7 | 摘要 | 等說話者辨識結束（或使用者略過）才產生；可選「先出不含說話者的摘要」| 避免摘要用到之後會被改寫的逐字稿 |

**M1 必須配合改的兩件事**（這是這份設計最重要的發現）：
1. M1 目前每段辨識成功就**刪掉段檔**，而且只存 `[hh:mm:ss] 文字`，沒有「結束時間」也沒有「字級時間」。說話者對齊需要這兩樣，所以 M1 要新增一個旁路檔 `segments.jsonl`（§4），並且在開啟說話者辨識時**不要刪段檔**（§1）。
2. M1 的段與段之間「約有 0.3–0.5 秒沒錄到」（frontmatter 的 `chunk_gap`）。串接音檔時要用 M1 已經算好的每段 `offset` 補上靜音，否則 1 小時（12 段）會累積約 5 秒的時間漂移，對齊會逐漸變差（§2）。

---

## 1. 音檔保留與清理

**現況（M1 #47）**：每段辨識成功 → `removeItem(chunk-NNN.m4a)`；失敗才保留；App 中途結束 → 還沒處理的段保留並標記 `status: interrupted`。

**建議方案：狀態寫進 frontmatter，辨識完成才刪**

新增兩個 frontmatter 欄位：

```yaml
diarization: off | pending | running | done | failed | skipped
audio: kept | deleted
```

流程：

| 時間點 | 動作 |
|---|---|
| 開會前 | 使用者可選「辨識說話者」（預設開）。關閉 = M1 原行為（辨識成功即刪該段）。|
| 每段 Groq 辨識成功 | 寫入 `segments.jsonl`；**不刪段檔**（只在 `diarization != off` 時）。|
| 會議結束、所有段辨識完 | `diarization: pending`，詢問人數（§3）。|
| 說話者辨識成功、新逐字稿寫入成功 | 先驗證新逐字稿，再刪全部段檔，`audio: deleted`，`diarization: done`。|
| 說話者辨識失敗 | `diarization: failed`、`audio: kept`，段檔保留，選單出現「重試說話者辨識」與「刪除音檔」。**不自動刪。**|
| 使用者選「略過」| `diarization: skipped`，依 M1 規則刪段檔。|

**App 中途結束／當機**：M1 已把狀態標成 `interrupted`。啟動時掃描所有會議資料夾：
- `diarization: running` 或 `pending` 且資料夾仍有段檔 → 視為未完成，**提示**「有一場會議還沒完成說話者辨識：繼續／略過並刪除音檔」。**不自動處理，也不自動刪除。**
- `status: interrupted` → 同上，同時說明最後一段可能不完整。
- 沒有段檔、frontmatter 說 `audio: kept` → 不一致，只在逐字稿加一行警告，不修復。

**磁碟用量**（AAC 44.1 kHz／單聲道／64 kbps，Emily 已定）：

| 項目 | 數字 | 依據 |
|---|---|---|
| 音檔 | **約 28 MB／小時** | 實測 63 分鐘 = 29.2 MB |
| 3 小時會議 | 約 85 MB | 線性外推 |
| `segments.jsonl` | 估計 < 1 MB／小時 | 一小時約 9,000 字，含字級時間每字約 60 位元組（**估計，沒量**）|
| 辨識時暫存 | 0（工具直接讀段檔，記憶體內串接）| — |
| 辨識時記憶體 | 峰值約 252 MB（63.6 分鐘）| 實測；21 分鐘以下更低 |

**隱私變動（需要 Emily／老闆確認）**：M1 的承諾是「辨識成功就刪音檔」，開啟說話者辨識後音檔會**保留到會議結束後的處理完成**，失敗時甚至一直保留。這要寫進 `PRIVACY.md` 與開始會議的提示。

**替代方案**：
- *A. 結束時先串接成一個 `meeting.m4a`，再刪段檔。* 好處：之後重試只吃一個檔；壞處：多一次編碼與約 28 MB／小時的暫存，而且串接本身會失敗。沒有明顯好處，不建議。
- *B. 辨識成功就刪（M1 原行為），說話者辨識另外靠「即時錄兩份」。* 壞處：兩份錄音、麥克風同時被兩個東西讀，風險高，不建議。
- *C. 失敗超過 7 天自動刪。* 較省空間，但會議錄音是敏感資料，「自動刪」與「永久留」都是政策決定。**保守選擇：不自動刪、只提示。**

---

## 2. 分段處理：整場串接 vs. 逐段辨識再對人

**建議方案：整場串接，辨識一次。**

做法：依 M1 已有的每段 `offset`，把各段解碼成 16 kHz 單聲道 PCM，**在段與段之間補上實際的缺口時間長度的靜音**，串成一條整場時間軸，交給 `meeting-diarizer`。輸出的時間就是會議相對時間，可直接與 `segments.jsonl` 對齊。

實測（同一份 AMI 21 分鐘音檔，切成 5 分鐘段，人數 = 4；準確率是我寫的簡化指標，不是正式 DER）：

| 做法 | 歸屬正確率（4 位真人）| 最後的說話者標籤數 | 處理時間 |
|---|---|---|---|
| 整場串接，人數 = 4（S1 §4.3，WAV）| 96.6% | **4** | 337 秒 |
| 逐段（每段 5 分鐘）各自辨識，每段人數 = 4，再用聲紋中心配對 | 96.4% | **9**（多出的 5 個標籤合計只有 12 秒，佔 1.3%）| 258 秒（含算聲紋中心）|
| 逐段，每段用 auto（門檻 1.0），再配對 | 96.3% | **13**（多出的 9 個合計 17 秒，佔 1.8%）| 174 秒 |

怎麼讀這張表：
- **準確率沒有差別**：兩種做法對 4 位主要說話者的歸屬都是 96% 左右。我原先預期逐段會明顯較差，**這份資料沒有顯示出來**。
- **差別在標籤碎裂**：逐段配對會產生多餘的 Speaker 5…9／13，使用者要手動認出「Speaker 7 其實是 Speaker 3」。整場串接沒有這個問題。
- 逐段每段人數指定 4，但最後一段只有 3 人說話，工具回傳 3 個（它沒有硬切成 4 人）；所以「指定人數會把一個人切成兩個」的風險**這份資料沒有發生**。
- 耗時兩者相近（同一台 M1 的耗時會差 60%，只能看量級），逐段沒有比較慢。
- 限制：只有一份音檔、AMI 4 人每段都有人說話，是比較有利於逐段的情況；沒有測「某一段只有 2 人說話」的會議。配對門檻 0.5 是我隨手設的，沒有調過，調過標籤碎裂可能會改善。程式只是實驗腳本，不是可交付的實作。

**逐段辨識為什麼不建議放在第一版**：
1. **標籤碎裂**（上表）：配對產生多餘的說話者標籤，使用者看到 Speaker 1…9 而實際只有 4 人。
2. **跨段要另外寫「對人」邏輯**：算各段每位說話者的聲紋中心，再用相似度配對，並處理「新說話者」「這段沒出現的說話者」。這是新的程式，配對門檻要調，錯了會讓 Speaker 1 在不同段變成不同人；整場串接完全不需要。
3. **每段人數仍是問題**：某段可能只有 2 人說話但整場有 4 人。這份資料沒踩到（見上），但 auto 沒有可靠門檻（S1 §4.4：1.0 → 10 人、1.2 → 2 人），使用者選的「整場人數」也不一定適用於每一段。
4. 會議進行中處理會跟錄音、Groq 辨識搶 CPU（工具會用到約 3 個核心，310%）；**我沒有測過邊錄音邊辨識是否影響錄音品質或發熱**。

**逐段辨識的好處（這點很重要）**：可以在會議進行中就處理，會議結束時只剩最後一段，**使用者結束會議後等一兩分鐘，而不是約 13 分鐘**。如果老闆實測覺得 1 小時會議等十幾分鐘不能接受，這就是升級路線，而且這份實驗顯示準確率不是障礙，真正要解決的是標籤碎裂。

**串接的代價**：
- 全部在會議結束後才處理：**1 小時約 13 分鐘**（63.6 分鐘 AAC 44.1 kHz 64 kbps 音檔實測 765 秒，CPU 約 310%）。需要在背景跑並顯示進度（`meeting-diarizer --progress`）。
- 一次吃整場的記憶體：峰值約 252 MB（63.6 分鐘實測）。
- 段間缺口：M1 的 `chunk_gap` 是 0.3–0.5 秒，每段都要用 `offset` 補靜音，否則時間會漂移。補多少靜音由 `MeetingCoordinator` 的 `offset(of:)` 決定（它用 uptime 算，不是用音檔長度加總）。

**替代方案**：
- *逐段辨識＋聲紋對人*：見上，列為第二版，等整場版跑穩、而且老闆回報「等太久」再做。
- *會議中每 15 分鐘做一次整場辨識的增量版*：複雜度最高，不建議。

---

## 3. 人數選擇的 UI

**建議方案：會議結束時選。**

- 按「結束會議記錄」→ 逐字稿辨識完後彈出（選單列 App 用 `NSAlert` ＋ 下拉選單）：「這場會議有幾位說話者？」選項 **2 3 4 5 6 不確定**，預設是上一場選的值（第一次是 2）。
- 對話框不擋住主流程：逐字稿已經寫好、可以先看；選完才開始辨識。
- 沒回應也沒關係：`diarization: pending`，選單出現「辨識說話者…」，之後隨時能做（音檔還在，見 §1）。
- 選「不確定」→ `--num-speakers auto`，並在逐字稿 frontmatter 寫 `speakers_mode: auto`，正文頂端加一行「說話者數為自動估計，可能不準」。

**為什麼結束時選比開始時選好**：
1. 結束時才真的知道有幾個人發言（有人中途加入、旁聽的人也算一個）。
2. 辨識本來就在結束後才開始，所以不會增加等待。
3. 開始會議時要盡量少一個動作（M1 是一鍵開始）。

**開始時選的好處**：不用在結束時等使用者回應，流程自動走完。缺點是人數常常猜錯，而猜錯的後果很大（S1：不給人數就判成 55 人；給錯人數的影響**我沒有量**）。

**替代方案**：
- *開始時選，並記住上次*：實作最簡單，適合固定 2 人對談的使用者。可以和建議方案並存：「開始」時不問，「結束」時問，預設值取上次。
- *結束時自動試 2、3、4 人，挑最佳*：目前沒有可靠的指標知道哪個最好（沒有標準答案），不建議。

重跑成本：換人數就得整場重跑（S1：10 分鐘約 80–130 秒、1 小時約 13 分鐘（63.6 分鐘音檔實測 765 秒））。所以音檔要留到使用者滿意為止，這也是 §1 保留音檔的理由之一。

---

## 4. 對齊與逐字稿格式

**先講必要的前置：M1 現在存的東西不夠對齊。** `MeetingStore.appendChunk` 只寫 `[hh:mm:ss] 文字`，只有開始時間、沒有結束時間，也沒有字級時間；而且段檔辨識後就刪了。

**建議方案**：

1. M1 每段辨識成功時，另外 append 一行到 `segments.jsonl`（與 `transcript.md` 同一個資料夾）：
   ```json
   {"chunk":3,"start":612.4,"end":618.9,"text":"...","words":[{"w":"我們","s":612.4,"e":612.7}]}
   ```
   時間都是**整場相對秒數**（= 段 `offset` + Groq 的時間）。`words` 只在 Groq 真的回傳字級時間時才有（**Groq 是否回傳要等第一次實際呼叫才能確認**，見 S1 §6）；沒有就只存 segment。這個旁路檔是「純資料」，不含說話者。
2. 說話者辨識完成後，用 §S1 報告 §6.2 的演算法（字級最大重疊歸屬 → 平滑 → 合併）產生新的 `transcript.md`。沒有字級時間時，以 segment 為單位取重疊最長者；`end` 以該筆 `end` 為準。
3. **兩階段輸出**：
   - 階段 1（會議結束、Groq 辨識完）：M1 原樣的 `transcript.md`，馬上可看。frontmatter `diarization: pending`。
   - 階段 2（辨識完成）：先把階段 1 的檔案另存 `transcript.plain.md`，再原子寫入（寫暫存檔 → `rename`）新的 `transcript.md`。`diarization: done`。

格式（每行一個時間戳，與 M1 一致，只在時間戳後加說話者）：

```
[00:01:12] Speaker 1：好，我們先看下週的時程。
[00:01:18] Speaker 2：我覺得週五可以。
[00:01:21] Speaker 2：不過要等 QA。
```

- 同一個人連續多行：**每行都寫說話者**（不要合併成一段）。理由：M1 一行 = 一個 Whisper segment，且「每行一個時間戳」是 M1 已定的格式；每行都帶說話者，用 `grep "Speaker 2"` 就能抽出一個人的話，AGy 的摘要也不需要處理「上一行是誰」。
- 重疊說話、無法歸屬的行：`Speaker ?：`，不硬猜。
- frontmatter 新增：`diarization`、`speakers_mode: fixed|auto`、`speaker_count`、`speaker_names`（§5）。

**替代方案**：
- *只輸出一個檔，直接改寫 `transcript.md`，不留備份*：最簡單，但辨識有 bug 時使用者就失去原文。**不建議。**
- *另存 `transcript-speakers.md`，保留 `transcript.md` 不動*：最安全，但 `latestTranscriptURL()`、摘要、使用者都得知道「該讀哪一個」，兩份會逐漸分歧（使用者改了其中一份）。**不建議**，除非老闆想要一直保有「純文字版」。
- *合併同說話者的連續行成一段*：可讀性較好，但丟掉每行的時間戳，與 M1 格式不一致。

---

## 5. 改名（Speaker 1 → Tom）

**建議方案：對照表放 frontmatter，改名後由程式重新產生逐字稿。**

```yaml
speaker_names:
  Speaker 1: Tom
  Speaker 2: Emily
```

- 逐字稿正文由 `segments.jsonl`＋辨識結果＋這份對照表**產生**，不是對正文做文字取代。所以改名只是更新 frontmatter 後重新渲染，不會誤改內容裡剛好出現的 "Speaker 1"，也能再改回來。
- 渲染需要保留辨識結果：新增 `speakers.json`（`[{"start":…,"end":…,"speaker":1}]`，一場會議約數百筆）。
- 選單列 UI 最小做法：「改說話者名稱…」→ 列出 Speaker 1…N（附每個人的第一句話當提示，因為使用者不知道誰是誰）→ 輸入新名稱。

**限制**：重新渲染會覆蓋使用者手動編輯過的 `transcript.md`。對策：渲染前先備份為 `transcript.md.bak`，並在改名對話框說明。

**替代方案**：
- *完全不寫程式*：使用者用任何編輯器的「取代」功能把 "Speaker 1" 換成 "Tom"。零成本，但名字存不進 frontmatter，摘要不會知道，而且會誤改內文。可作為**第一版**。
- *只在正文行首做正規表示式取代，並更新 frontmatter*：比重新渲染簡單，但如果使用者已經手改過正文就會出現不一致；要處理「Tom」與其他人同名等情況。

---

## 6. CLI 的打包、簽章、模型下載

### 6.1 位置

```
AI語音輸入.app/Contents/
  Helpers/meeting-diarizer                ← CLI（arm64；universal 發布前再決定）
  Frameworks/SherpaOnnx/libsherpa-onnx-c-api.dylib
  Frameworks/SherpaOnnx/libonnxruntime.dylib
```

CLI 的 rpath 從原型的 `@executable_path/../lib` 改成 `@executable_path/../Frameworks/SherpaOnnx`。`build.sh` 在 `lipo` 之後多一段：編譯 CLI（同一份 `Tools/MeetingDiarizer/*.swift`）、複製兩個 dylib、簽章。大小約 +32 MB（arm64）／+68 MB（universal）。

App 以 `Process` 呼叫（**進度提醒**：63 分鐘那次，工具開始處理後我約 2 分鐘仍看不到任何 `progress` 行，之後才開始輸出，共 5609 行；所以進度條前段要顯示「準備中」，不能假設一開始就有進度）：`--input <音檔或段檔清單> --models <目錄> --num-speakers N|auto --progress`，讀 stdout 的 JSON、stderr 的 `progress 已完成/總數`。**主程式不載入 sherpa，當機不會連累聽寫。**

注意：原型 CLI 目前一次吃一個檔案。整場串接（§2）需要 CLI 能吃「一組段檔＋每段 offset」，或由 App 先把串好的 PCM 寫成暫存檔。**建議讓 CLI 新增 `--manifest`（JSON：`[{"path":…,"offset":…}]`）**，由 CLI 讀段檔並補靜音，避免 App 端寫一個 230 MB／小時的暫存檔。這是之後實作時的工作項目。

### 6.2 簽章與公證

預編譯的兩個 dylib 是 ad-hoc 簽章，**不能直接發布**。建議：

1. 由內而外簽：兩個 dylib → CLI → App，全部用同一個 Developer ID，`--options runtime`（hardened runtime）。
2. `release-macos.sh` 目前用 `codesign --verify --deep --strict` 驗證，**我沒有確認它會簽 `Frameworks` 與 `Helpers` 裡的第三方檔案**（S1 已列為待審）。要在實際的簽章＋公證建置上驗證，我這裡沒有簽章身分，**不能驗證**。
3. onnxruntime 是否需要 hardened runtime 的例外（例如 JIT）：CPU 推論一般不需要，但**我沒有在公證環境測過**，不能保證。
4. CLI 不需要任何權限（不碰麥克風、網路）；它只讀檔案與模型。

**替代方案**：
- *把 CLI 與 dylib 也改成第一次使用時下載*：App 少 32 MB，但下載來的可執行檔要處理 Gatekeeper／公證，失敗模式更多。**不建議。**
- *同進程連結 sherpa*：少一個進程，但 sherpa 當機會帶走 App，Emily 已否決。

### 6.3 模型第一次下載

位置：`~/Library/Application Support/<App>/Models/diarization-v1/`（`pyannote-segmentation/model.onnx` 與 `speaker-embedding.onnx`，約 35 MB）。

流程（原型的 `fetch-meeting-diarizer-assets.sh` 已示範其中的驗證邏輯）：

1. 第一次選「辨識說話者」且模型不存在 → 顯示「需要下載約 35 MB 的說話者辨識模型」，使用者同意才下載（**不在背景偷偷下載**）。
2. 下載到 `*.part`，邊下邊顯示進度。
3. 用**寫死在程式裡的 SHA256** 驗證，通過才 `rename` 成正式檔名。
4. 全部完成後才算安裝成功；缺任何一個都視為沒裝。

失敗處理：

| 情況 | 行為 |
|---|---|
| 沒網路／逾時 | `diarization: pending`，逐字稿維持純文字版，選單顯示「下載模型後辨識…」，音檔保留 |
| SHA256 不符 | 刪除 `.part`，顯示「檔案驗證失敗」，**不使用、不重試同一個網址超過 2 次**（可能是來源被改） |
| 磁碟不足 | 下載前檢查至少 100 MB 可用空間；不足就不下載、不報模糊錯誤 |
| 使用者按取消 | 刪 `.part`，維持 `pending` |
| 下載來源失效（GitHub release 被移除）| 見下 |

**來源**：目前是 sherpa-onnx 的 GitHub release（`speaker-segmentation-models`、`speaker-recongition-models` 兩個 tag）。這兩個是**別人的 repo、可變的 tag**，雜湊寫死可以擋掉被改，但擋不住被刪。**備案**：在我們自己的 repo release 放一份鏡像（切段模型是 MIT，可以；聲紋模型 CAM++ 授權已確認為 Apache License 2.0，鏡像時要一併附上授權文字，見 `docs/THIRD-PARTY-MODELS.md`）。

**授權已確認**：聲紋模型 CAM++ zh_en 為 Apache License 2.0（證據：ModelScope 官方 API `https://modelscope.cn/api/v1/models/iic/speech_campplus_sv_zh_en_16k-common_advanced` 的 License 欄位；S1 §3），切段模型為 MIT。第三方授權清單見 `docs/THIRD-PARTY-MODELS.md`。

---

## 7. 對 AGy 摘要（M3）的影響

**建議方案**：`summary.md` 等 `diarization` 進入終態（`done`／`skipped`／`failed`）才自動產生。

- 觸發條件：frontmatter `diarization ∈ {done, skipped, failed, off}`。`pending`／`running` 時，摘要選單顯示「等待說話者辨識…」。
- 摘要輸入：新的 `transcript.md`（含 `Speaker N` 或使用者改的名字）。
- 提示詞要告訴模型：
  - 說話者標籤是自動辨識的，可能把一個人切成兩個、或把兩個人併成一個，**不要把標籤當成已確認的事實**；`speakers_mode: auto` 時特別強調。
  - 不能因為 `Speaker 2` 的話就推測這個人是誰；有 `speaker_names` 才用名字。
  - 待辦的「負責人」只能取自逐字稿裡明確說出的名字，不能取自標籤。
- `diarization: failed` 或 `skipped` 時用純文字逐字稿摘要，並在 `summary.md` 加一行「未含說話者資訊」。
- **「先出摘要」選項**：1 小時會議的辨識約 13 分鐘（63.6 分鐘音檔實測 765 秒），使用者可能想先看摘要。提供「先出不含說話者的摘要」，辨識完成後可選擇「用說話者資訊重新產生」。這要 AGy 的 `MeetingSummarizer` 能重複執行且不覆蓋未備份的 `summary.md`。

**要和 AGy 對的事**：PR #48 的摘要找逐字稿是用 `MeetingStore.latestTranscriptURL()`，這個會抓「最近一場有逐字稿的會議」，**不看狀態**。辨識中途會讀到舊的純文字版。要改成先檢查 frontmatter 的 `diarization`。

**替代方案**：*不等說話者辨識，永遠用純文字逐字稿摘要*：流程最簡單，但摘要會失去「誰負責什麼」的資訊，這是老闆要說話者辨識的主因，不建議。

---

## 8. 狀態與資料流（一頁版）

```
開始會議 ──每 5 分鐘切段──▶ chunk-NNN.m4a ──Groq──▶ segments.jsonl + transcript.md（純文字）
   │                                  │（diarization≠off：保留段檔）
結束會議 ───────────────────────────────┴─▶ 問人數（§3） ─▶ pending
                                                      │ 模型不存在 → 下載（§6.3）
                                                      ▼
                                      running: meeting-diarizer --manifest … --progress
                                                      │
                          成功 ◀────────────────────────┴────────▶ 失敗
          transcript.plain.md 備份                       diarization: failed
          新 transcript.md（含 Speaker N）                audio: kept
          刪段檔；audio: deleted                         選單：重試／刪除音檔
          diarization: done
                          │
                          ▼
                  summary.md（§7）
```

## 9. 實作工作項目（粗估）

| 項目 | 內容 | 負責 | 估計 |
|---|---|---|---|
| M1 調整 | `segments.jsonl`、`diarization` 狀態、不刪段檔、啟動時掃描未完成會議 | Tom | 0.5–1 天 |
| CLI `--manifest` | 讀多個段檔＋offset、補靜音、測試 | Ben | **已完成**（#49）|
| 對齊器 | 字級／segment 對齊、平滑、合併；純函式＋離線測試 | Ben | **純函式與測試已完成**（#49，未接 App）；真實 Groq 輸出驗證待第一次呼叫 |
| `segments: incomplete` 對帳 | 階段 1 逐字稿行與 `segments.jsonl` 記錄的比對、對不上標 `Speaker ?`（純函式＋離線測試）| Ben | 0.5 天 |
| 逐字稿渲染與改名 | 從 `segments.jsonl`＋`speakers.json`＋`speaker_names` 產生 `transcript.md`，備份與原子寫入 | Ben | 0.5 天 |
| 模型下載器 | 同意提示、進度、SHA256、失敗處理 | Ben | 0.5–1 天 |
| 打包與簽章 | `build.sh`、重簽、公證驗證 | Senior dev 審查 | 無法估計（需簽章環境）|
| 選單列 UI | 結束時選人數、進度、重試、改名 | Tom／Ben | 0.5–1 天 |
| 摘要配合 | 等狀態、提示詞調整 | AGy | 0.5 天 |

**加總約 3–5 個工作天**，比 Emily 原先預估的 1–2 天長，主要多出來的是：M1 需要調整、模型下載器、簽章與公證。**我只能估計程式碼；公證能否通過我沒辦法驗證，是最大的未知。**

## 10. 沒有驗證的事

- 中英混用、中文會議語料的準確度。
- 真實會議（筆電麥克風、重疊說話、遠場）。
- Intel Mac。
- Groq 是否真的回傳字級時間（沒用 Key 呼叫）。
- 簽章、公證、hardened runtime 下 onnxruntime 能否正常載入。
- 對齊演算法只有設計，沒有實作也沒有測試。
- `segments.jsonl` 的大小是估計，沒有量。
- 使用者「選錯人數」的後果沒有量。

## 11. 給 Emily 要決定的事

1. **隱私**：音檔保留到辨識完成（失敗則一直保留、不自動刪）是否可接受？`PRIVACY.md` 要改。
2. **M1 要不要先合併再改**：#47 目前會刪段檔、不存結束時間；要在合併前就加 `segments.jsonl`，還是合併後另開 PR 改？
3. **逐字稿覆寫**：`transcript.md` 在辨識完成後被改寫（舊版備份為 `transcript.plain.md`）是否可接受？
4. **第一版改名**：先不做程式，讓使用者自己用編輯器取代（§5 替代方案），是否可接受？

---

## 附錄 A：JSON schema（給實作旁路檔的人用）

三份資料：`manifest.json`（App 給 CLI）、`segments.jsonl`（M1 寫、對齊器讀）、CLI 的輸出（對齊器讀）。程式裡的對應型別：`Tools/MeetingDiarizer/MeetingManifest.swift`、`SpeakerAligner.swift`（`TranscriptSegmentRecord`、`SpeakerTurn`）、`main.swift`（`Output`）。所有時間單位是**秒**（浮點數），所有檔案 UTF-8。

### 共同規則：時間軸

- **整場會議相對時間**：0 = 會議開始（`MeetingCoordinator` 的 `meetingStartUptime`），不是牆上時鐘，也不是各段檔自己的 0。
- 段檔的 `offset` 必須和 `MeetingCoordinator.offset(of:)` 給逐字稿用的 `chunk.offset` **同一個值**。M1 用 uptime 算，所以段間的 0.3–0.5 秒縫隙會自然反映在 offset 裡（這就是要補靜音的原因）。
- `segments.jsonl` 裡的 `start`／`end`／`words[].s／e` = 段 `offset` ＋ Groq 回傳的段內時間。

- **段編號從 1 開始**（與 M1 的檔名 `chunk-001.m4a` 一致，#52 的 `nextIndex` 也從 1 起算）。`segments.jsonl` 的 `chunk` ＝ 檔名裡的 NNN；第一段 `offset` 是 0。
- **CLI 的 `--manifest` 不依賴編號**：只看每個 entry 的 `path` 與 `offset`，檔名叫什麼都可以，順序也不用排好。唯一出現「第幾段」的地方是警告與錯誤文字裡的 `manifest entry N`，那是該 entry 在 manifest 裡的位置（從 1 起算），不是 `chunk` 編號（通常相同）。

### A.1 `manifest.json`（`meeting-diarizer --manifest`）

```json
{
  "version": 1,
  "chunks": [
    {"path": "chunk-001.m4a", "offset": 0.0},
    {"path": "chunk-002.m4a", "offset": 300.4},
    {"path": "chunk-003.m4a", "offset": 600.9}
  ]
}
```

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["version", "chunks"],
  "additionalProperties": false,
  "properties": {
    "version": {"const": 1},
    "chunks": {
      "type": "array", "minItems": 1,
      "items": {
        "type": "object", "required": ["path", "offset"], "additionalProperties": false,
        "properties": {
          "path": {"type": "string", "description": "絕對路徑，或相對於 manifest 所在資料夾"},
          "offset": {"type": "number", "minimum": 0, "description": "這段錄音在整場會議的開始時間（秒）"}
        }
      }
    }
  }
}
```

CLI 的行為（有測試）：
- 不要求 `chunks` 已排序，CLI 會依 `offset` 排序。
- 段與段之間依 offset **補 0（靜音）**；後一段與前一段**重疊**時保住後面音訊的時間位置、丟掉後一段開頭重疊的部分，並寫入輸出的 `warnings`。
- 某一段**解不開**（檔案不存在、損毀）：當成缺口，其他段照常處理，寫入 `warnings`；**全部**解不開才以非 0 結束。
- `offset` 為負數、非數值，或整場超過 12 小時：以非 0 結束，不處理。
- `version` 不是 1、`chunks` 為空、JSON 壞掉：以非 0 結束。
- 不能與 `--input` 同時使用。

### A.2 `segments.jsonl`（M1 在每段辨識成功時 append；Tom 實作）

**每個 Groq segment 一行**（與 M1 現在「一行逐字稿＝一個 segment」一致），UTF-8，以 `\n` 結尾，空行會被略過。

```json
{"v":1,"chunk":2,"start":312.4,"end":318.9,"text":"我們先看下週的時程。","words":[{"w":"我們","s":312.4,"e":312.9},{"w":"先","s":312.9,"e":313.1}]}
{"v":1,"chunk":2,"start":319.0,"end":322.4,"text":"Then let's confirm with QA."}
{"v":1,"chunk":3,"start":600.9,"end":900.9,"text":"","failed":"HTTP 429: rate limited"}
```

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["v", "chunk", "start", "end", "text"],
  "additionalProperties": false,
  "properties": {
    "v": {"const": 1},
    "chunk": {"type": "integer", "minimum": 1, "description": "與段檔名 chunk-NNN.m4a 的 NNN 相同；從 1 起算"},
    "start": {"type": "number", "minimum": 0},
    "end": {"type": "number", "minimum": 0, "description": ">= start"},
    "text": {"type": "string", "description": "Groq 原文（含標點）；失敗行為空字串"},
    "words": {
      "type": ["array", "null"],
      "description": "只在 Groq 真的回傳字級時間時才有；沒有就省略整個欄位",
      "items": {
        "type": "object", "required": ["w", "s", "e"], "additionalProperties": false,
        "properties": {
          "w": {"type": "string", "description": "原樣保留，包含 Whisper 常見的前導空白；不要 trim"},
          "s": {"type": "number", "minimum": 0},
          "e": {"type": "number", "minimum": 0}
        }
      }
    },
    "failed": {"type": "string", "description": "這一段辨識失敗的原因；有這個欄位時 text 為空、沒有 words"}
  }
}
```

寫入規則（Tom 實作時請遵守）：
0. **`chunk` 從 1 起算**，等於段檔名 `chunk-NNN.m4a` 的 NNN（第一段是 `chunk-001.m4a`、`"chunk":1`、offset 0）。讀取端（`SpeakerAligner`）**不檢查**這個編號，只看時間；編號只用來讓人對照檔案。
1. **只加不改**：整場期間只 append，不重寫。每行用單次 `write` 加上 `\n`，並在寫完後才刪段檔（開啟說話者辨識時不刪，見 §1）。
2. 順序：先 append `segments.jsonl`，再 append `transcript.md`。如果中途當機，`segments.jsonl` 多一行比少一行好（`transcript.md` 可以由它重新產生）。
3. 空白文字的 segment 不寫（M1 目前也略過）；整段沒有辨識到內容時**不寫任何行**。
4. 失敗的段寫一行 `failed`，`start` 為該段 `offset`、`end` 為 offset＋段長（不知道段長就等於 start）。重新產生逐字稿時它會以 `> ⚠️ [時間] 這段辨識失敗：原因` 保留在原位。
5. 一行出現解析錯誤時，對齊器會**整份失敗**（不默默丟資料），呼叫端退回純文字逐字稿並標 `diarization: failed`。
6. `v` 必須是 1；日後欄位增加時 `v` 才變，不要在 v1 偷加必填欄位。

### A.2.1 `transcript.md` frontmatter 的 `segments: complete | incomplete`，M2 怎麼處理

Tom 在 `transcript.md` frontmatter 加的欄位。我讀到的 #52（head 362b17e）還沒有這個欄位，只有 `sidecarFailureCount`（註解寫：旁路檔是盡力而為，寫入失敗不影響逐字稿與刪檔，但會留下計數，之後說話者辨識才知道旁路檔不完整），所以以下**假設**：`complete` ＝ 每個辨識成功或失敗的段都已寫進 `segments.jsonl`；`incomplete` ＝ 至少一次寫入 `segments.jsonl` 失敗（`sidecarFailureCount > 0`），也就是 `transcript.md` 有些行在 `segments.jsonl` 裡沒有對應記錄。若實際定義不同，以 Tom 的為準，請告訴我改這一節。

| `segments` | `segments.jsonl` | M2 的處理 |
|---|---|---|
| `complete` | 存在 | 正常辨識與對齊 |
| `incomplete` | 存在、至少 1 筆記錄 | **照常辨識**；對不上的逐字稿行標 `Speaker ?`（見下）；frontmatter 加 `speakers_note: 部分逐字稿行沒有時間資料，已標 Speaker ?`，逐字稿頂端也加一行同樣的說明 |
| 沒有這個欄位 | 存在 | 當作 `incomplete`（舊版或不是 M1 寫的會議，無法確定完整）|
| 任何值 | 不存在或 0 筆 | **不跑說話者辨識**：沒有可對齊的時間資料，辨識只會白花約 13 分鐘（1 小時會議）。`diarization: skipped`、`diarization_reason: no-segments`，並依 §1 的 `skipped` 規則處理音檔 |
| 任何值 | 有壞行（A.2 規則 5）| `diarization: failed`，退回純文字逐字稿。這與 `incomplete` 不同：`incomplete` 是 M1 **宣告**的缺漏，壞行是檔案本身損毀 |

「對不上的行」的判定（`incomplete` 時才需要；**這一段規則還沒有實作**，`SpeakerAligner` 目前只處理 `segments.jsonl` 這一側，是 §9 的後續工作項目）：

1. 以階段 1 的 `transcript.plain.md`（辨識前的原版）為準，逐行解析 `[hh:mm:ss] 文字`。
2. 一行與某筆記錄「對得上」＝ 時間戳等於 `floor(record.start)` 的 `hh:mm:ss`，且文字（折成單行、去掉頭尾空白後）相同。
3. 對不上的逐字稿行 → 依時間戳插入結果，顯示為 `[hh:mm:ss] Speaker ?：文字`，不硬猜；`> ⚠️` 開頭的失敗／無內容標記行原樣保留在原位。
4. 有記錄但逐字稿裡沒有對應行（例如 `transcript.md` 寫入失敗）→ 照樣輸出（`segments.jsonl` 是資料來源，排序依時間）。
5. 同一秒內多行：維持原有順序。

為什麼不乾脆整場放棄：`incomplete` 通常只缺一兩段（旁路檔寫入失敗是少見的），其餘行仍能標出說話者；整場放棄等於為了一點缺漏浪費使用者等的 13 分鐘。代價：缺的那幾行是 `Speaker ?`，使用者看得到、也不會被誤導。

### A.3 CLI 輸出（`meeting-diarizer` 的 stdout）

```json
{
  "durationSeconds": 900.1,
  "numSpeakers": 2,
  "numSpeakersMode": "fixed",
  "processingSeconds": 83.2,
  "warnings": [],
  "segments": [
    {"start": 0.031, "end": 7.186, "speaker": 0, "label": "Speaker 1"},
    {"start": 8.215, "end": 14.577, "speaker": 1, "label": "Speaker 2"}
  ]
}
```

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["durationSeconds", "numSpeakers", "numSpeakersMode", "processingSeconds", "warnings", "segments"],
  "properties": {
    "durationSeconds": {"type": "number"},
    "numSpeakers": {"type": "integer", "description": "輸出中實際出現的說話者數，不一定等於要求的人數"},
    "numSpeakersMode": {"enum": ["fixed", "auto"], "description": "auto = 人數是估計值，逐字稿要註明可能不準"},
    "processingSeconds": {"type": "number"},
    "warnings": {"type": "array", "items": {"type": "string"}},
    "segments": {
      "type": "array", "description": "依 start 排序；不同說話者的段落可以重疊",
      "items": {
        "type": "object", "required": ["start", "end", "speaker", "label"],
        "properties": {
          "start": {"type": "number"}, "end": {"type": "number"},
          "speaker": {"type": "integer", "minimum": 0, "description": "sherpa 的 id，0 起算，整場一致"},
          "label": {"type": "string", "description": "Speaker N（N = speaker + 1）；顯示名稱由 frontmatter 的 speaker_names 決定，不看這個欄位"}
        }
      }
    }
  }
}
```

退出碼：0 成功；2 參數錯誤；3 檔案／模型／manifest 不存在或無效；4 音訊解不開；5 辨識器建立失敗。進度在 stderr（加 `--progress`）：`progress 已完成/總數`。

App 存成 `speakers.json` 時，**原樣存這份輸出**即可（改名時重新產生逐字稿需要它，見 §5）。

### A.4 已驗證的行為（測試）

| 測試 | 內容 | 結果（M1 MacBook，2026-11-12）|
|---|---|---|
| `scripts/test-meeting-diarization-core.sh`（無下載、秒級）| 18 項純函式：時間軸補靜音（3 段、0.4 秒縫隙，後面的段位置精確）、排序、小數 offset（300.4 秒 → 第 4,806,400 個樣本）、重疊、被包含的段、壞 offset；manifest 驗證與路徑；`segments.jsonl` 解析（壞行整份失敗、行號）；對齊規則（見下）；失敗段保留；渲染 | 通過 |
| `scripts/spike-meeting-diarizer-test.sh` 的 manifest 區段 | 3 個 AAC 44.1 kHz／64 kbps 段檔＋manifest，中間 0.4 秒縫隙，與「整場一個 WAV」比對每段的最佳時間位移 | 第 1／2／3 段位移 **0／30／30 毫秒**（標準 ≤ 50 毫秒，解析度 10 毫秒）；負對照（offset 不含縫隙）最後一段偏 **-760 毫秒**，證明測試抓得到漂移。30 毫秒的後續查證見 A.4.1：12 段實測不累積 |
| `scripts/spike-meeting-timeline-drift.sh`（12 段、不需 sherpa）| 見 A.4.1 | 12 段全部 0.00 毫秒，負對照量到 50.0 毫秒 |
| 同上（manifest 區段），失敗情境 | 缺一段 → 警告並照常處理；全部缺 → 非 0；壞 manifest → 非 0；`--input` 與 `--manifest` 並用 → 非 0 | 通過 |

### A.4.1 12 段（模擬 1 小時）時間軸漂移實測

起因：上面 3 段合成音檔量到 30 毫秒位移，離 50 毫秒標準只剩 20 毫秒，要確認會不會隨段數累積。

做法：從 AMI ES2002a（CC BY 4.0）每段取不同位置、各 300 秒，共 12 段；每段轉成 AAC 44.1 kHz／64 kbps 的 m4a；段間 0.4 秒縫隙（offset = (第 n 段 − 1) × 300.4 秒，n 從 1 起），整場 3604.4 秒。對照組是同樣內容、依相同 offset 放好的「整場 WAV」。

**(a) 信號層級**（`scripts/spike-meeting-timeline-drift.sh`，不需要 sherpa）：用 `--manifest` 同一套程式碼解碼並串回整場，與整場 WAV 逐段做互相關，每段量開頭／中間／結尾三處（5 秒窗口、搜尋 ±100 毫秒，解析度 1/16 毫秒）。

| 段（檔名 chunk-001…chunk-012）| offset（秒）| 開頭 | 中間 | 結尾 |
|---|---|---|---|---|
| 1–12（12 段全部）| 0.0、300.4、…、3304.4 | 0.00 ms | 0.00 ms | 0.00 ms |

- 每段解碼後樣本數都剛好是 4,800,000（= 300 秒 × 16 kHz），AAC 的 2112 個編碼前置樣本（約 48 毫秒）已被 AVAudioFile 正確去除。
- 負對照：把第 2 段（`chunk-002`）的 offset 加 50 毫秒，檢查器量到 50.0／50.0／50.0 毫秒，所以這個檢查看得到 50 毫秒的錯。
- 通過標準：每處 |位移| ≤ 5 毫秒。**實測最大 0.00 毫秒。**

**(b) 端到端**（`meeting-diarizer`，人數 = 4，3604.4 秒）：`--manifest`（12 個 AAC 段檔）對 `--input`（整場 WAV）。每段取 30 秒的說話活動遮罩（10 毫秒一格），找最佳位移：

| 段 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 最佳位移（ms）| 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 位移 0 時不一致的格數（共 30000）| 626 | 355 | 402 | 398 | 387 | 535 | 328 | 320 | 382 | 538 | 612 | 362 |

- 12 段最佳位移全為 0，**斜率 0.0 毫秒／段，不累積**。兩邊的說話者數都是 4，整場長度都是 3604.4 秒，`warnings` 為空。
- 不一致的格數是 1.1%–2.1%（每 30 秒窗口 320–626 格，即 3–6 秒），來源是 AAC 壓縮讓切段模型的段落邊界抖動幾格；位移取最佳值仍然不變，所以不是時間偏移。

**結論：不會累積，不需要補償。** 先前 3 段合成音檔的 30 毫秒，我的判斷是 10 毫秒取樣的遮罩在只有 35 秒的合成音檔上，因為邊界抖動造成的挑選結果；信號層級量不到任何位移。這是推測，沒有另外驗證。

**要補償的情況（目前不需要，記錄做法）**：若日後錄音器改成會讓段檔的實際長度與 `offset` 的差距累積（例如改編碼器、或 `offset` 不再是 uptime 而是各段長度加總），要用**實際解碼後的樣本數**修正：下一段的位置 = max(其 `offset`, 上一段位置 + 上一段解碼樣本數)。這與目前 `ChunkTimeline` 對「重疊」的處理一致（保住後面音訊的位置，丟掉重疊的開頭）。`scripts/spike-meeting-timeline-drift.sh` 會在這種變動時抓到。

沒有測到的：真實麥克風錄音（可能有取樣率時脈誤差，段內累積）；段內長度與 `offset` 的差距是否在 M1 的錄音器真的為 0（M1 還沒合併，我只能假設每段實際長度 ≈ 5 分鐘）。這兩點要在 M1 合併後用真實錄音量一次。

### A.5 對齊演算法的規則（`SpeakerAligner.align`，純函式）

輸入：`segments.jsonl` 解析結果＋CLI 輸出的 `segments`。輸出：每行 `AlignedLine(start, end, speaker?, text)`，`speaker == nil` 顯示為 `Speaker ?`。

1. **詞級（有 `words`）**：每個詞取與它時間重疊**最久**的說話者；重疊一樣久取較早開始的 turn。完全沒重疊時，取 1.0 秒內最近的 turn；還是沒有就沿用前一個詞（開頭的詞沿用後一個詞）。
2. **邊界抖動**：A B A 且中間那個詞短於 0.3 秒 → 改成 A A A。
3. **併短 run**：同一個 segment 內，某位說話者連續說話短於 1.0 秒，就併回相鄰較長的那位（避免為了很短的插話切行）。
4. **只剩一位說話者**（最常見）：用 Groq 原本的 `text`（含標點），一個 segment 一行，與 M1 格式相同。
5. **有兩位以上**：依字級時間切成多行，文字由詞串接（英文保留詞的前導空白、中文直接相連），**標點可能比原文少**。
6. **沒有 `words`**：整個 segment 取重疊最久的說話者，不切行（沒有字級時間就切不了文字）。
7. 空白文字的 segment 略過；`failed` 行原位保留。
8. 輸出格式：`[hh:mm:ss] Speaker N：文字`（N = speaker id + 1）；`names` 對照表（id → 名字）有值就用名字；文字中的換行折成一個空白。

**沒有用真實 Groq 輸出測過**；上面的測試用手寫的 segments／words。字級時間是否存在、詞是否帶標點、中文是逐字還是逐詞，要等第一次實際呼叫才知道，規則 5 的「標點可能比原文少」就是依這個不確定性寫的。
