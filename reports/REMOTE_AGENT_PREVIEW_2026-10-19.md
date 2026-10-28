# 遠端分身第一階段驗證紀錄

日期：2026-10-19（台北）。此交付是本機獨立原型，非正式 App 更新，未 push、合併或發布。

## 版控與產物

- 基準：`3101f03a06c027b75cc9058fbf5abad68a05fb29`。
- 分支：`codex/neighbor-remote-agent`，工作目錄為桌面工作區的 `worktrees/neighbor-remote-agent/`。
- 任務核心：`a2013ca`；面板預覽：`e294686`；SSH 與本驗證紀錄隨第三個階段提交，可用 `git log 3101f03..HEAD` 查看。
- 預覽：`build/remote-agent-preview/遠端分身預覽.app`，身分 `tw.panh.NeighborRemoteAgentPreview`。已在本機開啟。
- 正式 App 的所有來源、資源、版本與 `scripts/build.sh` 對基準沒有差異；本機 `main` 保持在基準且乾淨。

## 驗證結果

| 項目 | 結果與實際範圍 |
| --- | --- |
| 任務核心 | 16 情境通過：重複送出、取消後延遲事件、舊任務污染、事件順序、空結果、無效進度、格式版本、啟動失敗、斷線與真實執行閘門。 |
| 面板模型 | 輸入驗證、忙碌狀態、取消、provider 選擇、設定損壞恢復、只保存 provider 及獨立目錄通過。 |
| SSH | 11 情境通過：參數／注入拒絕、生命週期、啟動失敗、退出、重複啟動與延遲回呼；假的 runner 沒有連線。 |
| 系統 SSH | 真實 `/usr/bin/ssh -G -F /dev/null` 的參數解析與 exit callback 通過；沒有連線、沒有讀取使用者 SSH 設定。 |
| 完整回歸 | `./scripts/test-all.sh`：全部 26 組通過，包含既有語音、貼上、手機協定、黑貓、詞典與更新驗證。 |
| 正式 App 建置 | `./scripts/build.sh` 通過；產物同時包含 arm64 與 x86_64；嚴格簽章檢查通過。產物僅留在 worktree 的 build/。 |
| 預覽建置 | `./Previews/RemoteAgent/build-preview.sh` 通過；本機 arm64，部署目標 macOS 13.0；獨立 ad-hoc 簽章通過。未在 macOS 13 或 Intel 真機操作驗證。 |
| 原生畫面 | 六種 view-tree 圖：ready、running、cancelled、failed、completed、compact-dark。只繪製本 App，沒有擷取使用者桌面。 |
| 獨立畫面審查 | 對比問題修正後，最終 disposition `ship`；原項目 resolved，remaining clear。審查測得淺色說明 5.02:1、錯誤 5.62:1、深色說明 10.07:1。 |
| 實際 UI 操作 | 透過原生介面驗證範例輸入、三家選項、切換 Gemini 標籤、啟動、忙碌時禁用、取消、再次執行及完成結果；最後回到 Codex 待命。 |
| 已安裝 App 保留 | 既有 App 的 Info.plist、主程式與 CodeResources 前後 SHA-256 一致。沒有安裝、重簽或替換既有 App。 |

首次完整回歸因新 worktree 尚缺 Sparkle 解壓工具而中止。使用原工作區的固定 2.10.0 archive，沿用原腳本 SHA-256 驗證與解壓流程補齊，完成正式建置後重跑全套通過；沒有放寬更新或簽章測試。

## 資料與權限

示範使用固定事件，不呼叫 AI、不查網站、不控制桌面、不寫備忘錄。任務與結果只在記憶體；僅將 AI 選項保存於預覽自己的 Application Support 目錄。新增碼沒有正式 App 的 Keychain、偏好、剪貼簿歷史或權限存取路徑；沒有匯出私人資料或要求新的麥克風、螢幕錄製與輔助使用權限。

沒有讀取 API Key 值或對 TCC 資料庫做逐項前後比對；不可把原型驗證描述成私人設定或系統權限的全面驗收。

## 尚未驗證

- VPS 真實連線、Linux 系統／資源、虛擬桌面、瀏覽器與畫面串流。
- Gemini、Codex、Claude 官方訂閱登入、額度、MCP 及真實任務；三家名稱目前僅為示範標籤。
- 寫入 Apple 備忘錄、語音入口與正式黑貓選單整合。
- VoiceOver 實際朗讀與使用者主觀操作驗收。

SSH `processRunning` 不能證明通道或遠端服務可用。取得連線目標後，應先做唯讀主機檢查，再另行驗證遠端原型。

## 證據位置

本機完整測試與建置輸出、六種 PNG 及安裝檔比對保存在 `build/remote-agent-preview/`，不提交生成的二進位與測試暫存。操作與重現指令見 [預覽說明](../Previews/RemoteAgent/README.md)，設計與對比修正見 [DESIGN.md](../Previews/RemoteAgent/DESIGN.md)。
