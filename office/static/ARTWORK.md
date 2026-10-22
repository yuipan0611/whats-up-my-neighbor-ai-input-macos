`cat.svg` is a byte-for-byte copy of the approved `Resources/DesktopPet/sit.svg`
from source baseline cb60121c6319ee6806f650b6438c0ea663c77bef.
See `Resources/DesktopPet/README.md` for the existing artwork provenance.
No new mascot design, recoloring, or animation was introduced for that asset.

# 手機聊天版素材

- `neko-openai.png`、`neko-gemma.png`、`neko-claude.png`：依使用者核准的圓臉黑貓、肩膀比例、細項圈與模型吊牌方向產生的透明頭像。原始生成檔保存在此工作階段的 generated_images 目錄。
- Claude 吊牌使用 Claude 網站提供的 [`favicon.svg`](https://claude.ai/favicon.svg) 原始路徑，來源複本為 `claude-mark.svg`；`neko-claude-source.svg` 保存合成來源，產出 `neko-claude.png`。
- `icon-*.svg`：Lucide Static 1.61.0 圖示。授權條款見 `LUCIDE-LICENSE.txt`。
- `pdf-main.mjs`、`pdf-worker.mjs`：PDF.js (`pdfjs-dist` 5.4.296) legacy build，用於在手機瀏覽器把 PDF 頁面轉成圖片。授權條款見 `PDFJS-LICENSE.txt`。

此處的模型吊牌是介面識別圖，不代表第三方模型已接通或獲得官方認證。選單內的實際可用狀態以後端為準。
