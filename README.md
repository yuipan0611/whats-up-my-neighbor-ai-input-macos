<p align="center">
  <a href="https://nekonode.cloud">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/media/brand/app-icon.svg">
      <img src="docs/media/brand/neko-round-face.svg" alt="What's up my neighbor 小黑貓 Logo" width="150">
    </picture>
  </a>
</p>

<h1 align="center">What's up my neighbor</h1>

<p align="center">
  <b>想到什麼，就說出來。</b><br>
  住在 Mac 選單列的小黑貓語音輸入：按快捷鍵說話，文字貼回你正在打字的地方。
</p>

<p align="center">
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml"><img src="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest"><img src="https://img.shields.io/github/v/release/yuipan0611/whats-up-my-neighbor-ai-input-macos" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-101114?logo=apple" alt="macOS 13+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
  <a href="https://nekonode.cloud"><img src="https://img.shields.io/badge/website-nekonode.cloud-101114" alt="官方網站 nekonode.cloud"></a>
</p>

<p align="center">
  <a href="https://nekonode.cloud"><b>官方網站</b></a> ·
  <a href="https://nekonode.cloud/#download">下載</a> ·
  <a href="https://nekonode.cloud/guide">使用教學</a> ·
  <a href="docs/GUIDE.md">完整指南</a> ·
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-windows">Windows 版</a>
</p>

<p align="center">
  語言：
  <a href="README.md"><kbd>繁體中文 ✓</kbd></a>
  <a href="README.en.md"><kbd>English</kbd></a>
  <a href="README.ja.md"><kbd>日本語</kbd></a>
</p>

---

What's up my neighbor 是輕量的原生 macOS 選單列語音輸入 App。在任何文字欄位按 `⌥↑` 開始錄音，再按一次停止；音訊送到 Groq `whisper-large-v3` 轉成文字，自動貼回原本的游標位置。錄音時，一隻小黑貓會出現在螢幕上陪你說話。

<p align="center">
  <img src="docs/media/screenshots/recording-hud-card.png" alt="錄音中的小黑貓浮窗：兩耳之間的音量條跟著聲音跳動，左眼叉叉是取消、右眼勾勾是完成" width="420">
</p>

## 特色

- **一鍵錄音、貼回原位**：預設快捷鍵 `⌥↑`，可自訂；辨識完自動貼到原本的輸入框。
- **黑貓錄音浮窗**：音量條跟著聲音跳動；左眼取消、右眼完成，不會搶走輸入框的焦點。
- **三種文字輸出模式**：純逐字（預設）、標準、簡潔。全部是本機固定規則，不用改寫模型；法律用語與「第159條」不會被改動。
- **語言保護**：一個主要語言加最多兩個混用語言。出現未允許的文字時，會攔下來並自動重試一次，不直接貼出。
- **剪貼簿歷史**：最近 10 筆，按 `⌃⌥V` 叫出；Enter 只貼上，不會送出訊息。
- **桌面小黑貓**：散步、舔掌、打哈欠、趴著睡；點她會「呼嚕～」，按住拖曳可以拎起來。
- **隱私優先**：API Key 只存在 macOS 鑰匙圈；沒有分析、廣告或自有後端。
- **你決定何時更新**：Sparkle 每天檢查新版並通知，由你選擇是否安裝；不覆寫個人設定。

### QA 測試功能（尚未正式發布）

- **Command＋V 歷史手勢**：一般短按 `⌘V` 照常貼上；按住 `⌘V`，再按 `↑`／`↓` 叫出歷史清單，Enter 確認，Esc 關閉。`⌃⌥V` 與選單入口也保留。
- **九種毛色直接換**：從選單列的「選擇貓咪花色」選擇，桌面貓立即換色；收起時會直接放出，不需要重開 App。預設原版黑貓，會記住上次選擇。
- **客製貓咪外觀包**：獨立設定左右眼、鼻子、項圈與蝴蝶結，匯入／匯出 `.nekocat`；客製交付包可在首次安裝時帶入指定貓咪。[格式、交付與驗收](docs/CAT-PACKS.md)。

正式版 1.4.5 尚未包含這些功能。QA 安裝包的選單會另外顯示「QA 測試版」與來源編號；[安裝與桌面驗收步驟](docs/QA_CLIPBOARD_CAT.md)。

## 操作畫面

<p align="center">
  <img src="docs/media/screenshots/greeting-card.gif" alt="對小黑貓說 what's up，她用右上方的氣泡回覆 what's up!" width="400">
  &nbsp;&nbsp;
  <img src="docs/media/screenshots/desktop-pet-walking-card.gif" alt="桌面小黑貓散步的動畫" width="250"><br>
  <sub>整句只說 <code>what's up</code>，小黑貓會回你一句（這句不會貼進輸入框）；放出小黑貓後，她會在桌面邊緣散步、休息</sub>
</p>

<p align="center">
  <img src="docs/media/screenshots/desktop-pet-poses.png" alt="桌面小黑貓的七種姿勢：安靜坐著、站起來看看、散步中、有點好奇、舔舔前掌、打哈欠、趴著休息" width="820"><br>
  <sub>約 12 秒沒操作電腦，她會自己換姿勢；錄音、全螢幕或鎖定時會暫停</sub>
</p>

<p align="center">
  <img src="docs/media/screenshots/desktop-pet-interaction.png" alt="左邊是點了小黑貓後，她閉上眼睛說呼嚕～；右邊是按住拖曳時，她被拎起來" width="820"><br>
  <sub>點她一下會「呼嚕～」；按住拖曳可以拎起來，放手就坐回去</sub>
</p>

## 安裝

**系統需求**：macOS 13 Ventura 以上、自己的 Groq API Key、網路，以及「麥克風」與「輔助使用」權限。

### 下載 ZIP

1. 到 [Releases](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest) 下載 `Groq-AI-Voice-Input-macOS-v<版本>.zip` 並解壓縮。同一頁的 `Neighbor-macOS-<版本>.zip` 是 App 內更新用的，不用下載。
2. 第一次請對 `安裝.command` 按右鍵選「打開」（免費版沒有 Apple 公證）。仍被阻擋時，到「系統設定 → 隱私權與安全性」按「仍要打開」。
3. 依首次啟動畫面貼上自己的 Groq API Key，並允許「麥克風」與「輔助使用」權限。
4. 在任何文字欄位按 `⌥↑` 開始錄音，再按一次停止。

目前最新正式版尚未附帶一行安裝腳本；請使用上述 ZIP 安裝方式。未來版本若附帶腳本，再依[完整指南](docs/GUIDE.md#一行指令安裝熟悉終端機)操作。

已經裝過的話，安裝工具會沿用原本的位置與設定。找不到 App，或想確認安裝結果，見[安裝位置、名稱對照與驗證](docs/GUIDE.md#安裝位置名稱對照與驗證)。

也可以交給 Claude Code、Codex 這類 AI 代為安裝：整段貼上[直接交給 AI 安裝](docs/GUIDE.md#直接交給-ai-安裝)裡的提示詞。

### Groq API Key

到 [Groq Console](https://console.groq.com/keys) 建立以 `gsk_` 開頭的金鑰，只貼進 App 自己的輸入視窗。請勿使用別人的 Key。一般語音輸入很難碰到 Groq 免費方案上限，詳見[免費方案限制](docs/GUIDE.md#groq-免費方案限制--groq-free-tier-limits)。

## 隱私

- 錄音只為轉錄而傳到 Groq Speech-to-Text API；App 不包含分析、廣告或自有後端。
- Groq API Key 只存在這台 Mac 的鑰匙圈，不寫入設定檔、repo 或日誌。
- 剪貼簿歷史只存在本機，可隨時暫停或清除；不建立錄音檔歷史。

完整說明見 [PRIVACY.md](PRIVACY.md)。

## 文件

| 想做什麼 | 看這裡 |
|---|---|
| 了解每個功能與設定 | [完整使用指南](docs/GUIDE.md)、[官網教學](https://nekonode.cloud/guide) |
| 自訂小黑貓圖片與招呼 | [CAT-CONFIG.md](CAT-CONFIG.md) |
| 客製、分享與交付貓咪外觀包 | [docs/CAT-PACKS.md](docs/CAT-PACKS.md) |
| 看版本更新內容 | [CHANGELOG.md](CHANGELOG.md)、[官網更新紀錄](https://nekonode.cloud/changelog) |
| 了解架構與資料流 | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| 從原始碼建置、跑測試 | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)、[docs/TESTING.md](docs/TESTING.md) |
| 發佈與更新流程 | [docs/UPDATES.md](docs/UPDATES.md) |
| 參與開發、回報問題 | [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) |

配套的 iPhone App 仍在開發中，尚未發布。

## 授權

[MIT License](LICENSE)
