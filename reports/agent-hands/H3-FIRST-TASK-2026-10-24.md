# H3 第一件真任務（2026-10-24）

證據分類照 ADR-001 第 8 節：本文件全部是**實機**，在真的 VPS 上、用真的 Codex 和真的 Chrome 跑，不是模擬。

## 登入

- 貓咪的 Codex 用 YUI 的 ChatGPT 帳號登入，`login status` 回「Logged in using ChatGPT」（17:03:45 UTC）。
- 登入檔 `~neko-hands/.codex/auth.json` 權限 600，只有 neko-hands 讀得到。
- **過程：**
  - 裝置碼登入兩次都在 15 分鐘內沒完成，逾時（YUI 當時不在電腦前，或來不及）。
  - 改用瀏覽器登入：VPS 上的 `codex login` 在 127.0.0.1:1455 等待；Mac 以 SSH 把 1455 轉送過去；登入頁在 app 內建的瀏覽器打開，由 YUI 本人按「Yui PAN」。
  - 登入完成後，Claude 關掉通道，確認 Mac 和 VPS 的 1455 都已釋放。

## 任務

> （第一件真任務）用瀏覽器打開 https://example.com ，告訴我頁面標題和第一段文字，並把整頁截圖存到交回資料夾，檔名 example.png。

### 第一次（`b288ca12`）：未完成，但回報誠實

整條路都走到了：交辦 → worker 領取 → Codex 規劃 → 呼叫瀏覽器工具 `new_page`。

瀏覽器工具的呼叫需要核准，worker 卻用「永遠不問人」（`-a never`），所以被拒絕。貓咪回報 `incomplete` 並寫明原因，沒有假裝完成。

**修正：**
- 先用一個錯誤的值讓 Codex 0.163.0 列出合法值（`auto`／`prompt`／`writes`／`approve`），確認後設成 `mcp_servers.browser.default_tools_approval_mode="approve"`。
- 移除會產生假「出錯」訊息的 `--enable skip_host_skill_discovery`。

### 第二次（`4fddcb8f`）：完成，42 秒

- **步驟：** `new_page https://example.com` → `evaluate_script` → `take_screenshot` → 用 shell 把圖寫進 `/srv/neko-handoff/from-cat/example.png`。
- **成果：** 標題「Example Domain」，第一段文字正確，附上截圖連結。
- **Claude 獨立確認：**
  - 檔案存在，116,644 bytes，是 PNG。
  - Chrome 的分頁列表裡有 `https://example.com/`。
  - 截圖拿回 Mac 檢視過（`first-task-example.png`），中文字型正常顯示。

### 獨立確認時發現的問題（已修）

- **問題：** 截圖權限是 `-rw------- neko-hands:neko`，辦公室（neighbor）讀不到，Mac 也就拉不回來。原因是 worker 把遮罩設成 077。
- **修正：** 改成 027，同群組可讀。貓咪的家目錄是 750、群組是 neko-hands，其他檔案不會因此外露。worker 重新安裝（sha256 `9bc1bb9d…`）。既有的截圖已由 root 補正為 640。

## 還要處理的觀察

- **截圖的傳法很繞：** 瀏覽器工具把圖以 base64 回給 agent，agent 再用好幾次 `printf` 分段寫檔。之後可以在 worker 的說明裡請它直接存檔（`take_screenshot` 的檔案路徑參數），再複製過去。
- **思考摘要是英文：** 工作過程裡的思考摘要是英文。介面要以繁體中文為主，H5 處理。

## NOT RUN（ADR 第 7 節的 H3 驗收，還沒做）

- 惡意網頁與惡意 README 的合成任務。
- 連續 100 件的資源紀錄。
- 2 GB 磁碟上限的實機觸發。
- Mac 闔蓋時跑完一件任務（A01）。
- 重開機後 Chrome profile 與服務是否還在（A03）。
- 在驗收紀錄寫明「安裝腳本讀得到貓咪 Chrome 的 profile」（D13）。
