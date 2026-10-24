# 開發環境與本機建置

這份文件帶你從取得原始碼，到在自己的 Mac 建出一份可以執行的 App。不需要 Xcode 專案，也不需要付費 Apple Developer 帳號。

對照版本：1.4.5（build 1012）。

## 需要準備

| 項目 | 說明 |
|---|---|
| macOS 13 以上 | 建置與執行都需要；Apple 晶片或 Intel 都可以 |
| Xcode Command Line Tools | 提供 `swiftc`、`codesign`、`lipo`。安裝：`xcode-select --install` |
| Python 3 | 跑發布與貓咪設定相關的測試；macOS 內建的 `python3` 就夠 |
| 網路 | 第一次建置會從 Sparkle 官方 GitHub Release 下載 2.10.0，並核對固定的 SHA-256 |
| Groq API Key（選用） | 只有實際錄音辨識時需要；建置與離線測試都不需要 |

確認工具都在：

```bash
swiftc --version
python3 --version
```

## 取得原始碼

```bash
git clone https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos.git
cd whats-up-my-neighbor-ai-input-macos
```

Windows 版在另一個 repo：<https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-windows>。

## 跑離線測試

更新相關的測試會用 Sparkle 附的工具驗證簽章，所以第一次跑之前要先下載 Sparkle。先建置一次（見下一節）也會順便下載；只想下載的話：

```bash
./scripts/fetch-sparkle.sh
```

之後就可以跑全部測試：

```bash
./scripts/test-all.sh
```

這會依序執行 `scripts/` 裡所有 `test-*.sh`，全部通過時最後一行是：

```text
All 24 offline test suites passed.
```

下載好 Sparkle 之後，測試不需要網路、不讀你的 Groq Key、不碰系統剪貼簿與鑰匙圈。有幾組會開出不搶焦點的原生視窗來檢查畫面，**請在螢幕解鎖、沒有休眠的狀態下執行**。每組測試涵蓋什麼，見 [TESTING.md](TESTING.md)。

只想跑其中一組，例如文字處理：

```bash
./scripts/test-text-pipeline.sh
```

## 建置 App

```bash
./scripts/build.sh
```

完成後產物在：

```text
build/AI語音輸入.app
```

`build.sh` 會：

1. 下載並驗證 Sparkle 2.10.0（之後會使用 `build/` 裡的快取）。
2. 用 `swiftc` 分別編譯 arm64 與 x86_64，再合成 Universal 2 執行檔。
3. 複製 `Resources/` 裡的 `Info.plist`、圖示、黑貓素材與預設 `cat.config.json`。
4. 簽好整個 App：沒有設定 `MAC_CODESIGN_IDENTITY` 時用 ad-hoc 簽章，並指定和正式版相同的 designated requirement（只認 App 的 Bundle ID）。正式發布才使用固定憑證，見 [UPDATES.md](UPDATES.md)。

## 執行你建出來的版本

建置**不會**安裝或取代你電腦上正在用的 App。想試跑的話：

```bash
open build/AI語音輸入.app
```

幾件要注意的事：

- 如果你同時裝著正式版，請先從選單列結束正式版，避免兩個程式搶同一組快捷鍵。
- 開發版是 ad-hoc 簽章，但 designated requirement 和正式版一樣只認 Bundle ID，所以通常會沿用你已經給過的麥克風、輔助使用權限與鑰匙圈授權；macOS 仍可能在少數情況再問一次，照提示允許即可。也因為身分要求相同，用 `package-release.sh` 打出的開發包執行 `安裝.command` 時，會被當成正式版的更新直接覆蓋上去；測試完記得重新安裝正式版。
- 開發版和正式版共用同一個 Bundle ID、鑰匙圈項目與偏好設定，所以會讀到你正式版的設定。想完全隔離，可以在另一個 macOS 使用者帳號測試。
- 不要用 `tccutil reset` 重設權限來「解決」授權問題，那會影響所有 App。

## 打包成安裝包

```bash
./scripts/package-release.sh
```

會在 `dist/` 產生和正式發布相同結構的 ZIP 與 `.sha256`，裡面有 `安裝.command` 與 `移除.command`。這個開發包是 ad-hoc 簽章，只適合自己測試；正式發布由 GitHub Actions 用固定憑證簽署，流程在 [UPDATES.md](UPDATES.md)。

`安裝.command` 有兩個環境變數：

- `NEKO_INSTALL_NO_DIALOG=1`：照常安裝並開啟 App，但不跳「安裝完成」與「安裝未完成」視窗，給 AI 或腳本無人值守安裝用。不設定時，視窗也會在 2 分鐘後自動關閉。
- `NEKO_INSTALL_TEST_PROFILE=<拋棄式資料夾>`：只給離線測試用。把整個安裝裝進這個資料夾，不停止 App、不動登入啟動、不跳視窗，也不碰真實使用者資料，用法見 `Tests/test_release_contract.py`。

## 專案結構

```text
Sources/GroqVoiceInput/   App 原始碼（53 個 Swift 檔，含 3 個尚未發布的毛色外觀）
Tests/                    Swift 測試執行檔與 Python 測試
scripts/                  建置、測試、打包、發布腳本
Resources/                Info.plist（版本唯一來源）、圖示、黑貓素材
Packaging/                安裝包內的安裝／移除工具與使用說明
Previews/                 獨立的動畫預覽，不會打包進 App
docs/                     開發者文件
.github/workflows/        CI：建置與離線測試、正式發布
```

各模組的分工見 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 常見問題

**`xcrun: error: invalid active developer path`**：還沒裝 Command Line Tools，執行 `xcode-select --install`。

**`Build/fetch Sparkle before the offline suite`**：`test-updates.sh` 找不到 Sparkle 的工具。先跑 `./scripts/fetch-sparkle.sh` 或 `./scripts/build.sh`，再重跑測試。

**`Sparkle checksum mismatch`**：下載到的檔案和固定的 SHA-256 不符，腳本會停下來而不是繼續用不明檔案。刪掉 `build/Sparkle-2.10.0.tar.xz` 後重試；仍失敗的話，檢查網路是否被代理改寫。

**某個畫面相關的測試在 CI 過、在你這裡失敗**：確認螢幕沒有鎖定或休眠。動畫與視窗測試需要可用的桌面工作階段。

**專案路徑裡有空白或特殊字元**：腳本都有加引號，可以正常使用。若遇到其他工具出錯，可以先移到單純的路徑（例如 `~/dev/neighbor-macos`）排除變數。
