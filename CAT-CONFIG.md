# 自訂你的貓咪 / Customize your cat

要分享整隻貓，或製作安裝後就帶客製貓的交付檔，請看[貓咪外觀包與客製交付](docs/CAT-PACKS.md)。包含此功能的 QA 版也支援異瞳、鼻子、項圈與蝴蝶結；正式版 1.4.5 尚未支援。

macOS 現在支援 **version 2**：問候、圖片設定之外，也能選自然毛色並逐一調整身體部位。舊 **version 1** 仍可原樣讀取，不會自動改寫。Windows 的 version 2 尚未實作或驗證；跨平台分享請繼續使用 version 1。設定不包含 API key。

## macOS 開始使用

### 從選單切換毛色

在選單列點選 App →「選擇貓咪花色」，直接選擇原版黑貓、黑貓、白貓、灰貓、橘虎斑、賓士貓、三花貓、玳瑁貓或重點色貓。這九款已內建，**不必準備圖片或編輯 JSON**。

選擇後立即替換桌面貓、錄音浮窗與問候的毛色，不需要重新啟動。若桌面貓已收回，這次選擇會把牠放出來；已在桌面上的貓保持位置與動作。選擇會保存在這台 Mac，下次開啟仍沿用；未設定時使用原版黑貓。錄音或辨識期間需先完成該次工作再切換。

自訂 `image` 仍優先於錄音／問候毛色。選單保留問候與其他設定；若曾手動修改部位或種子，會保留原檔並提示從設定資料夾調整。直接使用專案附的完整毛色範例仍可切換，只要其內容尚未自訂。

這是開發版的操作方式；正式版 1.4.5 尚未包含此選單，需安裝包含這項改動的 QA 版或後續新版。[QA 安裝與桌面驗收](docs/QA_CLIPBOARD_CAT.md)。

### 手動編輯其他設定

1. 在選單列點選 App，選擇「開啟貓咪設定資料夾…」。這會建立設定資料夾，並在尚無設定檔時複製隨附範本；不會覆蓋既有檔案。
2. 結束 App，編輯 `cat.config.json`，儲存為 **UTF-8 JSON**。
3. 重新啟動 App。手動修改的檔案只在啟動時讀取；選單切換毛色會即時套用。

資料夾位在 `~/Library/Application Support/` 底下、以 App 的 Bundle ID 命名；從選單打開是最簡單的方式。

若沒有設定檔，直接使用以下預設值。Windows 使用 `%LOCALAPPDATA%\WhatsUpMyNeighbor`；兩個平台的設定資料夾各自獨立，不會自動同步。

桌面模式的「放出／收回小黑貓」獨立儲存在本機偏好設定。version 2 的 `appearance` 同時用於桌面貓、錄音浮窗與問候；自訂 `image` 只用於錄音浮窗與問候，優先於毛色，且不會被重新著色；觸發句、回覆文字、字型、氣泡與嘴型設定只用於問候。

## 完整預設範本

```json
{
  "version": 2,
  "image": null,
  "triggers": ["what's up", "whats up", "what is up"],
  "reply": "what's up!",
  "fontFamily": "Comic Sans MS",
  "fontSize": 18,
  "bold": true,
  "bubblePosition": "upperRight",
  "tiltDegrees": -10,
  "cooldownSeconds": 5,
  "displaySeconds": 3,
  "animateMouth": true,
  "appearance": { "preset": "original", "seed": 1, "parts": {} }
}
```

這是 `main` 的範本。正式版 1.4.5 請把 `"version"` 改成 `1`，並刪掉 `"appearance"` 那一行（記得一併刪掉上一行結尾的逗號）；1.4.5 的完整說明見 [v1.4.5 的 CAT-CONFIG.md](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/blob/v1.4.5/CAT-CONFIG.md)。

| 欄位 | 說明 |
| --- | --- |
| `version` | 整數 `1` 或 `2`；`appearance` 必須使用 `2`。目前正式版 1.4.5 只接受 `1`，見下方「自然毛色」的提醒。 |
| `appearance` | version 2 的整套毛色與部位覆蓋，詳見下方。 |
| `image` | `null` 使用內建貓咪；自訂圖片填同資料夾內 PNG 檔名，例如 `"my-cat.png"`。 |
| `triggers` | 1–32 個完整觸發句，每句 1–80 個 Unicode 字元。設定後取代整組預設觸發句。 |
| `reply` | 氣泡回覆，1–80 個 Unicode 字元，不可換行。建議 24 字內；較長文字可能換行、縮小或省略。 |
| `fontFamily` | 已安裝字型名稱，1–80 個 Unicode 字元。未安裝時使用系統後備字型；分享設定不會安裝字型。 |
| `fontSize` | 12–28，可用小數。macOS 使用螢幕點數，配合 Retina 縮放；實際大小也會配合文字長度調整。 |
| `bold` | `true` 粗體、`false` 一般字重。 |
| `bubblePosition` | `"upperRight"` 貓咪右上方、`"upperLeft"` 左上方。 |
| `tiltDegrees` | -15 至 15 度，可用小數。負數逆時針、正數順時針。 |
| `cooldownSeconds` | 兩次問候間隔，1–60 秒，可用小數。冷卻期間完整觸發句仍不輸入其他 App，也不會延長冷卻。 |
| `displaySeconds` | 氣泡顯示時間，1–10 秒，可用小數。開始新錄音會立即收起氣泡。 |
| `animateMouth` | 預設 `true`，內建貓咪只在氣泡顯示時有無聲小嘴動畫；`false` 保留靜止嘴型。 |

省略的欄位採用預設值。欄位名稱區分大小寫；不接受未列出的欄位。數字及布林值不要加引號。文字長度以 Unicode scalar 計算，例如 `🐱` 為一個字元，組合附加符號各自計算。

## 觸發句比對

- 只比對完整句子；`what's up` 會觸發，`translate what's up` 和 `what's up my neighbor` 仍為一般聽寫。
- 忽略大小寫、前後空白與句首句尾標點，合併連續空白。
- `'`、`’`、`‘`、`ʼ`、`＇` 視為相同的英文撇號。
- 不刪除詞語內部標點：`what-s up` 不等於 `what's up`。
- 設定的觸發句不能包含換行、控制字元、純空白、純標點，或正規化後重複的句子。
- 問候在語言處理與文字輸出前比對；命中的完整觸發句不會輸入或傳送到其他 App。

## 圖片與嘴型動畫

將 `my-cat.png` 放入同一設定資料夾，改為 `"image": "my-cat.png"`：

- 僅接受本機同資料夾的 PNG，最大 **4 MiB**，寬高各最多 **2048 像素**。建議透明背景、約 **2:1** 寬高比。
- 不接受網址、絕對路徑、子資料夾、`..`、符號連結、非 PNG 或 Windows 保留檔名。設定不下載圖片，也不執行指令。
- 圖片在啟動時讀成有上限的快照，檢查格式、尺寸並解碼。變更圖片後也需要重啟。
- 貓咪的左眼取消與右眼完成按鈕位置固定。自訂圖請保留原有眼睛位置；本格式不支援改動點擊區域。
- 嘴型只在內建貓咪問候期間播放，沒有聲音。`"animateMouth": false` 可關閉；舊設定省略此欄位仍預設開啟。
- 只要指定自訂 `image` 就不加上嘴型；即使圖片無法載入而退回內建貓咪，也保持關閉。這可避免將預設嘴巴疊在別人的圖上。

## 格式錯誤時

設定檔最多 **16 KiB**，只接受有效 UTF-8（可含 UTF-8 BOM）。JSON 語法、欄位型別、版本、數值範圍或圖片路徑無效，會讓**整份設定回到預設值**；原檔會保留，不會覆寫。設定檔本身必須是一般檔案，不能使用符號連結或命名管道。

圖片不存在、過大、尺寸不符或無法解碼時，只改用內建圖片；其他有效設定仍保留。修正檔案並重啟即可，也可移走 `cat.config.json` 恢復預設。

## English quick start

In a development build containing live coat selection, choose “選擇貓咪花色” from the menu bar to switch among nine bundled coats immediately. Selecting a coat also releases a recalled desktop pet; an already-visible pet keeps its position and pose. The selection persists across launches. Original black is the default. Explicit custom images and genuinely customized parts or seeds are preserved. The released 1.4.5 build does not include this menu.

For other settings, choose “開啟貓咪設定資料夾…”. This creates the app's folder under `~/Library/Application Support/` (named after its bundle ID) and copies the bundled template only if no configuration exists. Quit the app, edit `cat.config.json` as UTF-8 JSON, then restart. Manual file edits and images are loaded only at startup; menu coat choices apply live.

Version one remains readable. Version two adds macOS-only anatomical appearance; Windows v2 support is not implemented or verified. Omitted fields use defaults; unknown fields, invalid types, unsupported versions, unsafe image paths and out-of-range values invalidate the whole configuration without overwriting it. The config limit remains 16 KiB. Triggers match whole utterances only, and a match is consumed even during cooldown.

Use a same-folder PNG filename for `image`, or `null` for the built-in cat. PNGs are limited to 4 MiB and 2048 × 2048 pixels. Keep the original cat's eye positions because click targets are fixed. Missing or undecodable artwork falls back to the built-in image while retaining other valid settings. Any explicit custom image disables mouth overlays, even when the image cannot load. Set `animateMouth` to `false` to disable the silent mouth animation while retaining greetings. Fonts are resolved locally, with a system fallback when absent.


## 自然毛色與部位設定（macOS version 2）

> [!IMPORTANT]
> version 2 與 `appearance` 已提供於開發／QA 版，尚未隨正式版發布。1.4.5（含）以前的 App 只接受 `"version": 1`，也不認得 `appearance` 欄位；讀到 version 2 的設定會讓**整份設定回到預設**（原檔保留）。仍使用正式版時，請維持 version 1。

[完整部位說明與驗收方式](docs/appearance/README.md)。[可直接修改的範例](Examples/CatAppearance/)已將每隻貓的全部 16 個部位填好；手動修改後請重新啟動 App 載入，或在獨立預覽按「載入 JSON…」。直接從 App 選單選毛色會立即套用並儲存該選擇，不改動其他設定。

`appearance.preset` 可選 `original`（原版黑貓）、`black`、`white`、`blue`（灰貓）、`orange-tabby`、`tuxedo`、`calico`、`tortoiseshell`、`colorpoint`。未提供 `appearance` 使用原版黑貓。

`appearance.parts` 先繼承預設，再逐欄覆蓋。預設範本以空物件列出部位，表示繼承；完整毛色範例則已填入每個部位的值。若只想切換 `preset`，請將既有 `parts` 清空，避免舊覆蓋值蓋住新的毛色。例如將賓士貓的尾巴改灰：

```json
{
  "version": 2,
  "appearance": {
    "preset": "tuxedo",
    "seed": 1,
    "parts": { "tail": { "color": "#8D9295", "pattern": "none" } }
  }
}
```

| 部位鍵 | 位置 |
| --- | --- |
| `head` | 頭臉底色與臉部花紋 |
| `leftEar`, `rightEar` | 正面觀看的左／右耳 |
| `muzzle` | 口鼻及向上的尖形白斑 |
| `chest`, `belly`, `body` | 胸前、腹部、軀幹兩側與背身 |
| `frontLeftLeg`, `frontRightLeg` | 正面觀看的左／右前肢 |
| `rearLeftLeg`, `rearRightLeg` | 正面觀看的左／右後肢 |
| `frontLeftPaw`, `frontRightPaw` | 左／右前腳掌（白襪） |
| `rearLeftPaw`, `rearRightPaw` | 左／右後腳掌（白襪） |
| `tail` | 尾巴 |

每個部位接受 `color`（底色）、`pattern`（花紋）及 `patternColor`（花紋色）。顏色為 `#RRGGBB`，不支援透明色；省略欄位沿用該部位預設。花紋有 `none`、`tabby`（虎斑）、`patches`（玳瑁式拼色）、`calico`（三花）、`whiteSpots`（斑塊，白斑請搭配白色 `patternColor`）、`point`（深色區，顏色由 `patternColor` 決定）。`seed` 是 0–4294967295 的整數，固定種子保持同一隻貓的斑紋；省略為 1。換姿勢時部位跟隨原動作，不重新抽樣。

錄音／問候只顯示頭部，因此只有可見部位會出現；不把桌面圓臉替換成錄音長臉。眼睛的取消／完成位置不變，嘴型顏色配合口鼻對比。自訂 PNG（即使讀取失敗）維持既有圖片優先和停用嘴型的規則。

未知部位、花紋、欄位、無效顏色、種子或版本會使整份設定回到預設並提示錯誤，原檔保留。設定不下載素材、不讀取官網帳號，不代表收藏或付費權益；官網抽取、收藏與同步不在本機預覽範圍。

## 異瞳、鼻子與配件（包含角色包功能的 QA 版）

`appearance.features` 描述固定造型模板上的個別特徵。省略整個物件時維持原有圖像；舊設定不需要遷移。此欄位只在包含角色包功能的版本中有效，先前只支援換色的 QA build 也可能尚不認得它。

一般使用請從選單列選「自訂貓咪…」，調整後按「儲存並套用」；不需要手動編輯 JSON。已保存的角色放在「我的貓咪」選單，也可以用「匯出目前貓咪…」分享。

```json
{
  "version": 2,
  "appearance": {
    "preset": "tuxedo",
    "seed": 1,
    "parts": {},
    "features": {
      "eyes": { "left": "#70A7B8", "right": "#D5A85C" },
      "nose": { "shape": "triangle", "color": "#C98784", "freckles": true },
      "collar": { "enabled": true, "color": "#A45E58" },
      "bow": { "enabled": true, "color": "#C98784", "knotColor": "#9F5B60", "position": "neck" }
    }
  }
}
```

| 欄位 | 說明與預設 |
| --- | --- |
| `eyes.left`、`eyes.right` | 正面觀看的左／右眼顏色，格式 `#RRGGBB`。省略任一側即沿用那一側的原圖／自動對比色。保留叉叉和勾勾的形狀，睡眠與閉眼時維持對應表情。 |
| `nose.shape` | `none`（預設，不新增鼻形）、`triangle`、`round`、`heart`。 |
| `nose.color` | 鼻子顏色，預設 `#C98784`。 |
| `nose.freckles` | 是否加上鼻旁小斑點，預設 `false`。 |
| `collar.enabled` | 是否顯示頸部項圈，預設 `false`。 |
| `collar.color` | 項圈顏色，預設 `#A45E58`。 |
| `bow.enabled` | 是否顯示蝴蝶結，預設 `false`。 |
| `bow.color`、`bow.knotColor` | 蝴蝶結兩翼與中央結的顏色，預設分別為 `#C98784`、`#9F5B60`。 |
| `bow.position` | `neck`（預設）、`leftEar`、`rightEar`；左右依正面觀看命名。 |

項圈與蝴蝶結可以同時顯示。配件使用模板提供的附著位置，與部位一起繪製；本版不接受任意座標、外部配件圖片或更換身體輪廓。這些外觀設定不改動錄音取消／完成的點擊區域。

角色包的 `appearance.json` 使用上例中 `appearance` 裡面的物件，不包含最外層的 `version` 與 `appearance`。包格式版本與角色版本另外放在 `manifest.json`，詳見[包格式 v1](docs/CAT-PACKS.md#外觀包格式-v1)。
