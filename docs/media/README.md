# docs/media

README 與 [完整使用指南](../GUIDE.md) 用的圖片。

## 示範動畫

兩張都是 1.4.4 原始碼在離線測試中輸出的實際繪圖（`./scripts/test-cat.sh`、`./scripts/test-desktop-pet.sh` 產生於 `build/cat-render/`），用 ffmpeg 轉成 GIF，不是螢幕錄影。

| 檔案 | 來源 |
|---|---|
| `greeting.gif` | `build/cat-render/greeting-frame-00…29.png`，10 fps，寬 440px |
| `desktop-pet-walking.gif` | `build/cat-render/desktop-pet/walking-cycle/right-0…15.png`，12 fps，放大到 256px |

貓咪造型改版時，重跑上述測試並重新產生 GIF。

## 品牌標誌（`brand/`）

從官方網站 repo `yuipan0611/nekonode-site` 的 `55653c822c52d2c7b04364eb72ff3ec42ab020e8` 原檔複製，未修改。

| 檔案 | 網站原路徑 | 用途 | SHA-256 |
|---|---|---|---|
| `neko-round-face.svg` | `public/images/neko-round-face.svg` | 官網頁首的品牌標誌，README 淺色模式 Logo | `849015a6e378c31337abf5b235d94b3e915ea18137d88d4052e8bc173120abfd` |
| `app-icon.svg` | `public/favicon.svg` | 核准的白底 App 圖示，README 深色模式 Logo（黑貓臉在深色背景看不見） | `c47124e3f4fccea1a0b81f83490946c31b826c5201327902c5036b97150d1b4e` |

兩者都來自 macOS 圖示分支 `dd434cc` 的 `Resources/AppIcon.svg`，詳見網站 repo 的 `public/images/brands/README.md`。不要修改圖形；官網換標誌時一起更新。

## 操作畫面（`screenshots/`）

原檔複製（網站同一 commit，未修改）：

| 檔案 | 來源 | SHA-256 |
|---|---|---|
| `desktop-pet-poses.png` | 網站 `public/images/guide/desktop-pet-poses.png` | `fead2039a29328304523abf94ec07fed1d3b78e0a3d9889a0c8385a9524973bd` |
| `desktop-pet-interaction.png` | 網站 `public/images/guide/desktop-pet-interaction.png` | `fd2637eaf444ce19eaec367f8e6bade404ec793a8aed48c1036dc0f7bfe2278b` |

加底卡版本：原圖是透明背景，黑貓在 GitHub 深色模式幾乎看不見，所以把原圖置中疊在網站插圖的底色 `#E6E8E3` 上。貓的圖形、影格與時間都不變，只加底色與留白。

| 檔案 | 來源 | 尺寸 |
|---|---|---|
| `recording-hud-card.png` | 網站 `public/images/guide/recording-hud.png`（SHA-256 `929c7d89…a698`） | 736×384，原尺寸 |
| `greeting-card.gif` | 本資料夾的 `../greeting.gif` | 480×300，四邊各留 20px |
| `desktop-pet-walking-card.gif` | 本資料夾的 `../desktop-pet-walking.gif` | 300×300，四邊各留 22px |

App 改版讓畫面不同時，網站與這裡一起更新；原圖更新後，重新產生加底卡版本。

## README 九色展示（2026-11-11）

以本 repo `9126c02` 執行 `scripts/test-cat-appearance.sh`，1,074 項檢查通過；以下兩圖由產品原生 renderer 直接輸出，原檔複製，並未以生成模型改畫貓咪。桌面圖也複製至 Windows README 以展示同源花色。

| 檔案 | 原生輸出 | SHA-256 |
|---|---|---|
| `screenshots/desktop-cat-coats.png` | `build/appearance/natural-coats.png` | `cfb6113ec4c25f47ada97148b93d53fb29439f624a0fb97a65540498109791ff` |
| `screenshots/recording-cat-coats.png` | `build/appearance/recording-coats.png` | `01e812c23c95409b85397b7f01badfa464673da6393f4bb7da394e74f9a476b7` |
