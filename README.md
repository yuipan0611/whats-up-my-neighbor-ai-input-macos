# What's up my neighbor AI Input — macOS

[![Build](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml/badge.svg)](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml) [![Latest release](https://img.shields.io/github/v/release/yuipan0611/whats-up-my-neighbor-ai-input-macos)](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

官方網站：[nekonode.cloud](https://nekonode.cloud)。使用教學、開發者文件、Roadmap 與更新紀錄都在這裡。

Windows 測試版已獨立至 [Windows repo](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-windows)，功能、測試與發佈各自維護。拆分與舊網址相容說明見 [repo 搬遷紀錄](docs/REPOSITORY_MIGRATION.md)。

一個輕量的原生 macOS 選單列語音輸入 App。按下自訂全域快捷鍵開始錄音，再按一次停止；音訊會送到 Groq `whisper-large-v3`，轉成繁體中文後貼到原本游標位置。也可與配套 iPhone App 在附近直接連線，從手機修改轉錄文字並明確選擇「只貼上」或「貼到 Mac 並送出」（iPhone App 仍在開發中，尚未發布）。

## 更新與自動發佈

目前版本：**1.4.5（build 1012）**。黑貓選單會顯示實際安裝版本；完整紀錄見 [CHANGELOG.md](CHANGELOG.md)。版本與 build 統一以 `Resources/Info.plist` 為準；提高編號的新版本合併 main 後，由 GitHub Actions 自動測試、簽章、發佈安裝包與更新清單。

macOS 版加入 Sparkle：每日偵測新版並通知，由使用者自行選擇是否下載安裝。錄音、辨識或等待重試時延後提示與重新啟動；選單提供「檢查更新…」與「自動偵測新版本」。既有 API Key、快捷鍵及使用者資料夾的 `cat.config.json`／圖片不覆寫。

舊版需先手動安裝一次包含更新器的版本。發佈採用免費方案：固定的既有程式碼簽章憑證，加上 Sparkle 更新驗證金鑰，不需要付費 Apple Developer、Developer ID 或 Apple 公證。安裝工具沿用既有安裝位置，保留個人設定；macOS 首次開啟仍可能要求安全確認。首次發佈成功前，不代表更新服務已上線。[完整發佈設定與驗證範圍](docs/UPDATES.md)。

## 已保留的桌面功能

- 固定黑貓選單圖示、錄音浮窗、左眼取消／右眼完成及首次使用說明。
- 最近十筆本機文字剪貼簿，`⌃⌥V` 開啟快捷視窗；保留既有自訂快捷鍵。

- 詞典管理、修正觀察與六秒可取消的詞彙學習提示。
- 輸入目標驗證、原游標貼上、語言與輸出模式、錄音重試及選用 iPhone 接力。
- `cat.config.json` 自訂圖片與問候設定，整句招呼指令不輸入其他 App。

## 桌面小黑貓

<img src="docs/media/desktop-pet-walking.gif" alt="桌面小黑貓散步的動畫" width="128">

從選單點「放出小黑貓」，就能讓牠待在桌面；想專心時點「收回小黑貓」。App 會記住這個選擇，第一次使用預設收回。

你操作電腦時牠會安靜坐在螢幕邊緣；約 12 秒沒操作後，牠會散步、站起來、偶爾冒問號、舔舔前掌、打哈欠，再趴下睡覺。桌面資料夾的圖示可見且位置可讀時，也會走去趴在上面；否則就在邊緣休息。牠旁邊的透明處滑鼠可直接點穿；1.4.5 起點牠一下會回「呼嚕～」，按住拖曳可以抓起、放手坐回。錄音、選取剪貼簿、全螢幕工作、鎖定或休眠時會暫停。牠不會讓電腦保持喚醒。

配合 macOS「減少動態效果」時保持靜止。此模式不開啟麥克風、不連網，也不啟用手機接力；詳見 [桌面夥伴說明](docs/DESKTOP_PET.md)。

## 剪貼簿歷史

錄音結束後照常自動貼上，語音結果與一般複製文字共用最近 10 筆紀錄。`⌘V` 直接貼上目前剪貼簿內容；需要舊文字時，按 `⌃⌥V` 或點小黑貓選單的「剪貼簿歷史」，再點選一筆，或用上下方向鍵選擇後按 Enter。Enter 只確認選取並貼上，不會送出訊息；Esc 關閉清單。

清單依最近使用排序，相同文字合併，選回舊文字後會移到最上方；超過 10 筆移除最舊內容。原始換行與空白會保留。若輸入位置無法驗證，文字仍會複製到剪貼簿，回到需要的位置按 `⌘V` 即可。「剪貼簿設定」可暫停或清除紀錄；暫停時仍能正常語音輸入。紀錄只存在這台 Mac，重開 App 後仍保留，不建立錄音檔歷史。

## 非工程師技術教學

想了解錄音、辨識、文字處理與貼上之間怎麼串起來，以及為什麼不會隨便按 Enter，請閱讀 [架構與資料流](docs/ARCHITECTURE.md)。想參與開發，從 [開發者文件](#開發者文件) 開始。

## 貓咪錄音與招呼彩蛋

<img src="docs/media/greeting.gif" alt="對小黑貓說 what's up，她回覆 what's up! 的動畫" width="330">

錄音時在螢幕上方中央（可改到下方中央）顯示原生黑貓浮窗，兩耳之間的音量條跟著聲音跳動；左眼取消、右眼完成，不搶走原本輸入框的焦點。結束一段錄音後，辨識結果若整句是 `what’s up`、`whats up` 或 `what is up`，貓咪會出現在滑鼠所在螢幕的下方中間，用她右上方的微斜氣泡回覆 `what’s up!` 約三秒，並無聲地動一下小貓嘴。這句口令不會貼入輸入框；五秒冷卻期間也會被消費。包含口令的長句仍照常輸入。

彩蛋使用既有錄音的辨識結果，不會常駐監聽或額外呼叫 AI。可從「開啟貓咪設定資料夾…」取得 `cat.config.json`，調整圖片、文字、字型與時間，重啟後載入。[設定格式與安全限制](CAT-CONFIG.md)。

## 文字輸出模式

從選單列的「文字輸出模式」可以切換三種模式，預設是純逐字：

| 模式 | 會做什麼 | 適合 |
|---|---|---|
| 純逐字（預設） | 只修格式：簡體轉繁體、標點正規化、中英文之間補空格 | 逐字紀錄、訪談、會議、法律內容 |
| 標準 | 純逐字的全部，再移除句首「呃、嗯」與明顯重複詞 | 一般筆記 |
| 簡潔 | 標準的全部，再移除句尾語氣詞（啊、啦、喔） | 傳訊息 |

同一句話的差別：

```text
輸入：嗯，好啊，那個報告我明天再給你喔
純逐字：嗯，好啊，那個報告我明天再給你喔
標準：  好啊，那個報告我明天再給你喔
簡潔：  好，那個報告我明天再給你
```

> 簡潔模式會改變語氣（「好啊」→「好」），傳訊息時可能顯得比較冷淡，所以它不是預設，要自己開。

三種模式都**不會**摘要、不會改寫成 Email、不會自動條列、不會重組句子。所有處理都是本機的固定規則，不使用任何聊天或改寫模型，也不額外連網。

法律用語（假扣押、證據能力、不起訴處分、強制執行法等）在三種模式下都不會被改寫；「第159條」「新台幣50萬元」也不會被拆開加空格。詞彙保護表確保「我們去酒吧」不會被切成「我們去酒」。

## 語言設定與保護

從選單列的「語言設定…」可以設定最多三種語言：一個主要語言，加上最多兩個允許混用的語言。預設是繁體中文＋英文。

主要語言會同時決定辨識語言、提示字串，以及是否套用中文專屬的後處理——選日文時不會做簡繁轉換，避免破壞日文漢字。

> 語言檢查看的是文字系統，不是語言本身。英文、西班牙文、越南文都寫成拉丁字母，無法互相區分。

轉錄結果如果大量出現允許範圍以外的文字——例如音訊過短或沒有出聲時模型憑空產生的泰文——App 不會直接貼出來，而是保留錄音、指定主要語言自動重試一次；仍然失敗才顯示錯誤並讓你選擇重新辨識或捨棄。單次誤判不會改變任何設定。

錄音在文字成功放進剪貼簿前不會被刪除，所以辨識失敗或網路中斷時不需要重講；文字放進剪貼簿後就會刪除錄音，即使這次沒有自動貼上。

## 其他設定

從選單列的「文字與錄音設定…」可以調整：

- **中文數字轉阿拉伯數字**（預設關閉）：只轉法條、金額與百分比，「第一百五十九條」→「第159條」。成語裡的數字不會被動到，「我一直在等」不會變成「我1直在等」。
- **第二快捷鍵**：設定後可以一鍵用另一種模式錄音，只影響當次，不改變預設。例如平常用純逐字，傳訊息時按第二快捷鍵用簡潔。
- **靜音自動停止**（預設關閉，可選 3／5／10 秒）：講完停頓後自動結束錄音。
- 錄音最長 5 分鐘的保護一律啟用，避免忘記按第二次快捷鍵。

## 產品規劃

以下功能仍在規劃階段，**目前版本尚未具備**：

- 多次偵測到新語言後詢問是否加入允許清單（目前只能在語言設定裡手動加）。
- 擴充預載的台灣法律／科技詞庫（本機詞典管理已提供）。
- 智慧常用詞典（iPhone 端）與主要／備用 API 金鑰備援。

詳細規劃文件（文字輸出模式、智慧常用詞典、金鑰備援與產品 Roadmap）目前存放在維護者的私人工作區，尚未公開。公開版 Roadmap 整理好後會另行連結。

## 直接交給 AI 安裝

只要把這個 Repo 連結交給能操作 Mac 終端機的 AI，例如 Codex 或 Claude Code：

```text
https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos
```

再貼上以下指令：

```text
請幫我安裝這個 GitHub Repo 的最新版 macOS App：
https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos

請先閱讀 README、PRIVACY.md 與 Release 說明，再下載最新 Release 的 ZIP 和 .sha256，核對 SHA-256 後解壓縮並執行安裝工具。不要從原始碼或不明分支直接執行檔案，也不要移除或繞過 macOS quarantine；若 Gatekeeper 阻擋，請引導我使用右鍵「打開」或「系統設定 → 隱私權與安全性 → 仍要打開」。

安裝後請確認 What's up my neighbor 正在執行、登入啟動項目存在，並告訴我如何允許麥克風與輔助使用權限。保留預設快捷鍵 Option + ↑，並告訴我可以從選單列的「設定快捷鍵…」自行更改。

絕對不要要求我把 Groq API Key 貼進聊天、終端機、程式碼或設定檔。請啟動 App，讓我只在 App 自己的安全輸入視窗中建立並儲存 Groq API Key。
```

AI 應該完成下載、校驗、解壓縮與安裝；使用者只需要親自處理 macOS 安全確認、麥克風／輔助使用權限，以及在 App 內輸入自己的 Groq API Key。熟悉終端機時，也可以直接執行「下載與安裝」裡的一行指令。

## 特色

- Swift、AppKit、AVFoundation 原生實作，不在本機常駐 Whisper 模型。
- 預設快捷鍵 `⌥↑`，可從選單列的「設定快捷鍵…」錄製任何包含修飾鍵的組合。
- 16 kHz、單聲道 AAC 錄音。
- 固定使用 Groq `whisper-large-v3`，以繁體中文、台灣字形與自然標點為提示。
- Groq API Key 只儲存在 macOS 鑰匙圈。
- 轉錄文字先進入剪貼簿；有輔助使用權限時自動模擬 `⌘V`。
- 沒有輔助使用權限時仍保留剪貼簿文字，不會遺失。
- 純逐字／標準／簡潔三種輸出模式，本機固定規則處理，不使用改寫模型。
- 未允許語言的轉錄結果會被攔截並自動重試一次，不會直接貼出。
- 暫存錄音在文字成功放進剪貼簿後刪除（即使沒有自動貼上）；辨識失敗時暫時保留，可直接重新辨識。
- 登入後自動啟動，並提供移除工具（會保留剪貼簿歷史與貓咪設定資料夾，見「移除」）。
- 錄音一律指定 Mac 端的麥克風，不會被 macOS 的 iPhone 連續互通麥克風搶走。
- iPhone 接力模式預設關閉，必須按快捷鍵或從選單列明確開啟。
- 可與 iPhone 經加密的 Multipeer Connectivity 直接通訊，不需要 VPS 或開發者後端。
- Mac 本機快捷鍵永遠只貼上；只有已配對 iPhone 上實際按下「貼到 Mac 並送出」才會模擬 Enter。
- 不使用 ChatGPT、OpenAI API 或其他聊天模型。

## 系統需求

- macOS 13 Ventura 或更新版本。
- Groq 帳號與自己的 API Key。
- 網路連線、麥克風權限及輔助使用權限。
- 選用 iPhone 遠端功能時，兩台裝置需在附近並允許區域網路。

## 下載與安裝

### 一行指令安裝（熟悉終端機）

打開「終端機」，貼上後按 Enter：

```bash
curl -fsSL https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest/download/install.sh | zsh
```

這行指令會下載最新版安裝包，用腳本裡寫死的 SHA-256 核對，再執行安裝包裡同一支 `安裝.command`：沿用原本的安裝位置、檢查簽章身分、保留舊版備份，裝完自動開啟 App。不需要輸入 Mac 密碼，不重簽 App，也不改系統安全設定。用 `curl` 下載的檔案本來就不帶 macOS 隔離標記（quarantine），所以這條路線不會出現「仍要打開」的安全確認。

想先看內容再執行，可以分三步：

```bash
curl -fsSLO https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest/download/install.sh
```

```bash
less install.sh
```

```bash
zsh install.sh
```

> 這行指令從第一個附帶 `install.sh` 的正式版開始可用；在那之前請用下方 ZIP 方式。

### 從瀏覽器下載 ZIP

1. 到 GitHub 的 **Releases** 下載最新 ZIP，解壓縮。
2. 因為免費版沒有 Apple Developer ID 公證，第一次請對 `安裝.command` 按右鍵並選「打開」。
3. 若 macOS 仍阻擋，前往「系統設定 → 隱私權與安全性」，找到提示並按「仍要打開」。
4. 安裝完成後，App 會出現在選單列。
5. 依首次啟動畫面取得並貼上自己的 Groq API Key。
6. 允許「麥克風」與「輔助使用」權限。
7. 在任何文字欄位按 `⌥↑` 開始錄音，再按一次停止。

> 請勿使用別人的 Groq API Key。每位使用者應建立自己的 Key，額度與帳務也各自分開。

## 建立 Groq API Key

首次啟動畫面可直接開啟 [Groq API Keys](https://console.groq.com/keys)：

1. 登入或建立 Groq 帳號。
2. 按 `Create API Key`。
3. 複製以 `gsk_` 開頭的金鑰。
4. 回到 App 貼上並按「安全儲存」。

App 不會把 Key 寫入設定檔、Repo 或日誌，只會保存在這台 Mac 的鑰匙圈。之後可從選單列選「設定／更換 Groq API 金鑰…」。

## Groq 免費方案限制 / Groq Free Tier Limits

本專案固定使用 Groq `whisper-large-v3` 進行語音轉文字。以下是截至 **2026-07-15**，[Groq 官方 Rate Limits](https://console.groq.com/docs/rate-limits) 公開的 Free Plan 限制：

| 限制 | 數值 |
|---|---:|
| 每分鐘請求數（RPM） | 20 |
| 每日請求數（RPD） | 2,000 |
| 每小時音訊秒數（ASH） | 7,200 秒（2 小時） |
| 每日音訊秒數（ASD） | 28,800 秒（8 小時） |

### 這對日常使用代表什麼？

一般語音輸入通常每段只有 5–30 秒，因此很難碰到上述限制。例如每天使用 200 次、每次錄音 10 秒：

- 總音訊量為 2,000 秒，約 33 分鐘。
- 只使用約 **7%** 的每日免費音訊額度。
- 200 次請求也只使用每日 2,000 次請求上限的 10%。

非常適合語音打字、程式開發口述、ChatGPT 提示詞輸入、短篇會議筆記及一般生產力工作。較可能超過限制的情境包括：轉錄數小時的會議、處理長篇影片、批次轉錄大量音訊檔，或持續不中斷地錄音。

> [!NOTE]
> Groq 目前公開的是 RPM、RPD、ASH、ASD 等速率限制，官方並未另外公布固定的「每月免費 X 小時」轉錄配額。這不代表免費方案永久無限量；Groq 可能調整限制，而且不同帳號可能有例外。請以 [Groq Console](https://console.groq.com/) 中自己帳號顯示的最新 Limits 為準。

> [!WARNING]
> 到達任何一項限制後，Groq API 會回傳 `429 Too Many Requests`，App 在限制重置前將無法完成轉錄。請勿透過多帳號或其他方式規避免費方案限制。

### English

This project uses Groq `whisper-large-v3` for speech-to-text. As of **2026-07-15**, the public [Groq Rate Limits](https://console.groq.com/docs/rate-limits) list the following Free Plan limits:

| Limit | Value |
|---|---:|
| Requests per minute (RPM) | 20 |
| Requests per day (RPD) | 2,000 |
| Audio seconds per hour (ASH) | 7,200 seconds (2 hours) |
| Audio seconds per day (ASD) | 28,800 seconds (8 hours) |

For normal voice dictation, recordings are usually only 5–30 seconds long, so these limits are unlikely to be reached. For example, 200 ten-second recordings per day use 2,000 audio seconds (about 33 minutes), approximately **7%** of the daily audio allowance and 10% of the daily request allowance.

This is well suited to voice typing, coding dictation, ChatGPT prompt input, short meeting notes, and everyday productivity. You are more likely to exceed the limits when transcribing multi-hour meetings, long videos, large batches of audio files, or continuous recordings.

> [!NOTE]
> Groq currently publishes rate limits such as RPM, RPD, ASH, and ASD; it does not separately publish a fixed “X free transcription hours per month” quota. This does not mean the Free Plan is permanently unlimited. Limits may change, and exceptions may apply to individual accounts. Always check the latest Limits shown for your account in the [Groq Console](https://console.groq.com/).

> [!WARNING]
> When any applicable limit is reached, the Groq API returns `429 Too Many Requests`, and the app cannot complete transcription until the limit resets. Do not use multiple accounts or other methods to circumvent Free Plan limits.

## 自訂快捷鍵

1. 點選單列的小黑貓圖示。
2. 選「設定快捷鍵…」。
3. 在錄製區按下想要的組合，例如 `⌃⌥R`。
4. 按「儲存」。

快捷鍵至少要包含一個修飾鍵。若組合已被其他 App 註冊，App 會提示無法使用並保留原本設定。

macOS 自己的快捷鍵不一定偵測得到衝突，挑組合時請避開：

- `⌃Space`（切換輸入法）、`⌘Space`（Spotlight）這類系統快捷鍵；設成 `⌃Space` 可能讓注音等輸入法無法切換。
- 常用 App 的快捷鍵，例如 `⇧⌘D`，全域快捷鍵會把它搶走。
- App 自己的預設：`⌥↑`（錄音）、`⌃⌥↑`（iPhone 接力）、`⌃⌥V`（剪貼簿歷史）。

## 錄音麥克風與 iPhone 接力模式

這兩件事看起來都像「它自己連到手機」，但其實是兩個各自獨立的機制，設定也分開。

### 錄音麥克風：一律排除 iPhone

macOS 的「連續互通麥克風」會把 iPhone 註冊成這台 Mac 的輸入裝置。它是系統層級的功能，
**手機 App 沒開、手機鎖屏、手機放在別的房間都會出現在裝置清單裡**。一旦 macOS 把系統
預設輸入切到它，按下快捷鍵就只會錄到一段靜音，而且遠處的手機還會被隔空叫醒。

What's up my neighbor 錄音時會明確指定裝置，不跟著系統預設走：

- 沿用系統目前的輸入裝置，但**排除 iPhone 連續互通麥克風**。
- AirPods、USB 麥克風、虛擬音訊裝置都不受影響，行為與以前相同。
- 系統預設被切到 iPhone 時，自動改用內建麥克風。
- 不會去修改系統設定，因此 Zoom、Teams 等其他 App 的輸入裝置不受影響。

可在選單列 →「iPhone 接力與麥克風設定…」固定使用電腦或外接麥克風。
電腦錄音不提供 iPhone 輸入選項；舊版固定選過 iPhone 或允許連續互通的設定也不會啟動手機。
沒有電腦端麥克風時會提示，不會自動開啟手機模式。

### iPhone 接力模式：預設關閉

接力模式管的是「iPhone 能不能連上來貼字」，預設是關的：

| 狀態 | 行為 |
|---|---|
| 關閉（預設） | Mac 不廣播、不接受任何 iPhone 連線，已連線的 iPhone 會被斷開 |
| 開啟 | 接受已配對 iPhone 連線，可從手機貼上與送出 |

用預設快捷鍵 `⌃⌥↑`，或從選單列的「iPhone 接力模式」切換。快捷鍵可在
「iPhone 接力與麥克風設定…」中自訂或清除。

**App 每次啟動一律是關閉狀態**，不會記住上次開著的設定。

只有電腦放得較遠、身邊沒有麥克風時，才手動開啟接力並從手機 App 錄音。
一般使用電腦錄音不需要開啟接力，也不會更改手機設定。關閉接力後，舊連線排隊中的訊息也會被忽略。

## 從 iPhone 修改、貼上並送出

> [!NOTE]
> 配套的 iPhone App 仍在開發中，尚未發布；以下步驟給測試開發版的人參考。

第一次使用：

1. 先安裝配套的 iPhone App，並讓 iPhone 與 Mac 開啟 Wi-Fi、藍牙及區域網路權限。
2. 確認 Mac 選單列的 What's up my neighbor（小黑貓圖示）正在執行。
3. 點 Mac 選單列小黑貓圖示 →「配對 iPhone…」，保持畫面開啟並記下新的六位數配對碼。
   配對期間會暫時開啟接力模式，關閉視窗後恢復原狀。
4. 在 iPhone App 點右上角齒輪 →「Mac 連線／配對」，輸入配對碼後再點找到的 Mac。
5. 配對完成後，之後只要開啟接力模式且兩端在附近，就會自動重新連線。

配對碼有效五分鐘，成功使用後立即失效。若第一次沒有成功，請從 Mac 重新產生新碼，不要繼續使用舊碼。

日常使用：

1. 在 Mac 按 `⌃⌥↑` 開啟接力模式（選單列圖示會改變）。
2. 讓 Mac 停在準備輸入的聊天文字框。
3. 從 iPhone 背面點三下或 App Shortcut 開始錄音。Mac 會鎖定當下的 App、視窗與文字框五分鐘。
4. 停止並完成 Groq 辨識後，在 iPhone 的可編輯文字框修正內容。
5. 確認 iPhone 顯示的目標，例如 `Google Chrome — ChatGPT`。
6. 選「只貼上」、「貼到 Mac 並送出」或「取消」。

Mac 在執行前與貼上後都會重新確認焦點。若 App、視窗或輸入框已改變，操作會被拒絕；文字仍保存在剪貼簿，iPhone 會顯示失敗原因。Mac 本機 `⌥↑` 錄音不會自動按 Enter。

### iPhone 配對故障排除

1. **iPhone 沒看到 Mac：**先確認 **Mac 的接力模式已開啟**（選單列「iPhone 接力模式」有勾選，或按 `⌃⌥↑`）。接力模式關閉時 Mac 不會廣播，iPhone 一定掃不到。接著確認 App 正在執行、兩台裝置的 Wi-Fi 與藍牙都已開啟，等待 5–10 秒重新探索。
2. **iPhone 曾拒絕區域網路：**前往 iPhone `設定 → 隱私權與安全性 → 區域網路 → what's up my neighbor` 開啟權限。
3. **六位數配對碼失敗：**在 Mac 關閉舊配對畫面，再選一次「配對 iPhone…」取得新碼，並在五分鐘內完成。
4. **配對後無法自動重連：**喚醒並解鎖兩端。仍失敗時，兩端各自忘記舊配對，再用新碼重新配對。
5. **顯示版本不相容：**更新 Mac 與 iPhone App，確保兩端採用相同遠端協定。

附近連線使用加密的 Apple Multipeer Connectivity；它不是 AirDrop，不需要 Tailscale、VPS、固定 IP 或額外帳號。

## 隱私與資料

- 錄音只為轉錄而傳到 Groq Speech-to-Text API。
- App 不包含分析、廣告或自有後端。
- iPhone 遠端文字與明確動作只在已配對裝置間加密傳送，不經過開發者伺服器。
- Groq API Key 儲存在 Keychain。
- 啟用剪貼簿記錄時，語音結果與一般複製文字會保留在本機最近 10 筆歷史；重開 App 後仍保留，可暫停或清除。歷史不另外傳到雲端，也不建立錄音檔歷史。
- 詳細內容見 [PRIVACY.md](PRIVACY.md)。

## 從原始碼建置

需要安裝 Xcode Command Line Tools：

```bash
./scripts/build.sh
```

輸出位於 `build/AI語音輸入.app`。建立可分享 ZIP：

```bash
./scripts/package-release.sh
```

## 免費簽章限制

發佈版本沿用固定程式碼簽章憑證、Bundle ID 與既有 designated requirement；更新清單與 ZIP 另外使用 Sparkle Ed25519 驗證，不使用變動的 ad-hoc 身分發佈。一般 CI 開發包仍採 ad-hoc 簽章，不會自動送入更新清單。免費方案沒有 Apple 公證，從瀏覽器下載時首次開啟可能出現 macOS 安全確認；安裝工具不會清除 quarantine、停用 Gatekeeper 或重設權限。一行指令安裝以 `curl` 下載，檔案本來就沒有 quarantine 標記，所以首次開啟不經 Gatekeeper 確認；完整性改由腳本內固定的 SHA-256 與安裝工具的簽章身分檢查保障。

## 移除

執行 Release 裡的 `移除.command`，會停止 App，移除登入啟動設定、`~/Applications/AI語音輸入.app`、偏好設定（含快捷鍵）與 Keychain 裡的 API Key。

目前的移除工具**不會**刪除以下資料夾，想完全清除請手動刪除：

- `~/Library/Application Support/AI語音輸入/`（剪貼簿歷史）
- 貓咪設定資料夾（`cat.config.json` 與自訂圖片）：移除前從小黑貓選單「開啟貓咪設定資料夾…」打開，整個丟到垃圾桶

很早期的版本可能裝在 `/Applications` 等其他位置，之後升級會沿用原位置；移除工具只刪 `~/Applications` 裡的那一份，其他位置請手動移到垃圾桶。

## 開發者文件

- [參與方式](CONTRIBUTING.md)：回報問題、修正文件、送程式修正。
- [開發環境與本機建置](docs/DEVELOPMENT.md)：取得原始碼、跑離線測試、建置與打包。
- [架構與資料流](docs/ARCHITECTURE.md)：從快捷鍵到貼上，每個模組負責什麼。
- [測試方式與驗證範圍](docs/TESTING.md)：每組測試保護什麼、哪些只能實機確認。
- [發布與使用者選擇更新](docs/UPDATES.md)：版本、簽章、Sparkle 更新流程。
- [安全政策](SECURITY.md)：安全性問題請用私密管道回報。

## 授權

[MIT License](LICENSE)
