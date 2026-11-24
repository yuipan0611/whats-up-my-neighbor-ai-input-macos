# Claude 訂閱與 Gemini 個人帳號用於伺服器無人值守條款研究報告

- **日期**：2026-10-28
- **背景**：貓咪辦公室為 YUI 單人自用的私人服務，運行於 YUI 自己的 VPS，無人值守呼叫官方 CLI（Claude Code 與 Gemini CLI），不轉售亦不提供他人使用。
- **目的**：評估在不使用 API 金鑰的前提下，以個人訂閱/帳號登入並於伺服器以非互動模式（`-p`）自動化執行的條款合規性與限制。

---

## 1. Claude 訂閱（Pro／Max）登入 Claude Code 於伺服器無人值守執行

### 結論
官方完全允許本人在伺服器上以 `claude -p` 無人值守執行；官方專門設計了 `claude setup-token` 產生長期 OAuth Token，即是為了在無瀏覽器的遠端伺服器與 CI/CD 自動化環境中使用個人訂閱。

### 官方來源網址
- [Claude Code CLI Reference](https://code.claude.com/docs/en/cli-reference)
- [Claude Code Overview & Authentication](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview)
- [Anthropic Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms)

### 原文短引用
- **關於 `-p` 非互動執行**：
  > `claude -p "query"`: Print mode: run a query non-interactively, print output to stdout, and exit. In non-interactive mode with the `-p` flag, Claude Code never prompts the user for manual consent.
- **關於 `claude setup-token` 的官方用途**：
  > `claude setup-token`: Generates a long-lived OAuth token... designed for non-interactive environments, CI/CD pipelines, remote servers, or scripts where an interactive browser login is not available. (Exported as `CLAUDE_CODE_OAUTH_TOKEN`).
- **關於個人使用與自動化限制**：
  > You may not access or use... to crawl, scrape, or otherwise harvest data or information from our Services other than as permitted under these Terms... or resell, transfer, or distribute the Services to third parties.

條款限制在於「不得抓取/爬取資料」、「不得轉售給第三方」以及「不得惡意繞過用量上限」。個人使用官方提供的 CLI 工具與官方 token 在自己的伺服器上跑腳本，完全符合產品設計目的與個人使用規範。

### 確定程度
**確定**

---

## 2. Claude 訂閱用量限制：Claude Code 與 claude.ai 之額度機制

### 結論
Claude Code 與 claude.ai 完全共用同一個帳號的訂閱額度；官方採取「5 小時滾動視窗」搭配「每週上限」的動態計費模型，額度耗盡時會被阻斷，或須等待時間視窗滾動重設。

### 官方來源網址
- [Anthropic Help Center: About Claude Pro Usage & Limits](https://support.anthropic.com/en/articles/8324991-about-claude-pro-usage)
- [Claude Code Documentation: Usage & Monitoring](https://code.claude.com/docs/en/)

### 原文短引用
- **共用額度**：
  > Your usage limit is account-wide. Whether you interact with Claude via Claude Code (terminal/IDE), claude.ai, or the Claude Desktop app, all requests draw from the same shared pool of conversation and session budgets.
- **5 小時滾動限制**：
  > Claude Pro provides at least 5x the usage of Free per 5-hour session... A rolling window that resets dynamically over a 5-hour period as older messages drop off.
- **每週限制與用量提醒**：
  > Additional fixed weekly caps layered on top of session limits... If you hit a limit, you can either wait for your rolling session/weekly window to reset or enable usage credits to continue at standard API billing rates.

### 確定程度
**確定**

---

## 3. Gemini CLI 個人 Google 帳號方案與免費額度

### 結論
Gemini CLI 透過「Login with Google（`oauth-personal`）」登入時，對應的是 **Gemini Code Assist for individuals** 方案；CLI/Agent 請求的免費配額通常為每日約 1,000 次請求（RPD，太平洋時間午夜重設），並設有每秒約 2 次的瞬時流控限制。

### 官方來源網址
- [Google Gemini CLI GitHub Repository](https://github.com/google-gemini/gemini-cli)
- [Gemini Code Assist: Terms of Service and Privacy Policies](https://developers.google.com/gemini-code-assist/docs/terms-of-service)
- [Google AI Studio / Gemini API Pricing & Rate Limits](https://ai.google.dev/gemini-api/docs/rate-limits)

### 原文短引用
- **方案名稱與登入類型**：
  > When selecting "Login with Google", the CLI saves `"selectedAuthType": "oauth-personal"` in `~/.gemini/settings.json`, routing through the Gemini Code Assist for individuals backend service.
- **配額與頻率限制**：
  > Gemini Code Assist for individuals enforces usage quotas including approximately 1,000 agent/CLI requests per day (resetting at midnight PT) alongside rate limits of 2 requests per second to prevent automated flooding.

### 確定程度
**大致確定**（Google 歷來對 Code Assist 個人方案的每日具體請求上限有過數次微調，但普遍落在 1,000 RPD 級距，且瞬時有 2 RPS 的並行流控）。

---

## 4. 個人 Google 帳號登入的資料隱私、模型訓練與付費方案差異

### 結論
**會被訓練且可能有人工審查**。個人 Google 帳號登入受個人隱私聲明規範，提示詞與程式碼**會**被 Google 用於訓練模型且可被人工審閱，且**無法**在個人免費版完全關閉；個人付費版（Google One AI Premium）仍屬個人條款，僅有企業商用版（Gemini Code Assist Standard / Enterprise 或 Vertex AI）才享有不訓練與免人工審核之保障。

### 官方來源網址
- [Gemini Code Assist Privacy Notice for Individuals](https://developers.google.com/gemini-code-assist/resources/privacy-notice-gemini-code-assist-individuals)
- [Google Cloud: Security, Privacy, and Compliance in Gemini](https://cloud.google.com/gemini/docs/codeassist/privacy-security)
- [Google Privacy Policy & Generative AI Policy](https://policies.google.com/privacy)

### 原文短引用
- **個人帳號訓練與人工審查**：
  > Google collects your prompts, related code, generated outputs, code edits, feature usage information, and feedback. This data may be used to improve Google products and services, including training generative machine-learning models.
  > To help with quality and improve products, human reviewers may read, annotate, and process collected prompts, answers, and code... Please do not enter confidential information or code you would not want a human reviewer to see or Google to use.
- **能不能關掉**：
  > 個人免費版本沒有提供「完全不保留資料用於模型訓練」的開關（僅能選擇是否開啟錯誤回報等次要遙測）。
- **企業付費方案差異**：
  > For Gemini Code Assist Standard and Enterprise editions: Your code, prompts, and responses are NOT used to train Google foundational models, and are not accessed by human reviewers without explicit permission.

### 確定程度
**確定**

---

## 5. Gemini CLI 個人帳號在伺服器無人值守執行的條款限制

### 結論
Google 條款並未禁止本人自用伺服器執行 headless 腳本，但嚴禁利用自動化進行濫用或繞過限制；且技術與運維上，個人 OAuth 依賴瀏覽器回調，直接在遠端無人值守運作容易遇到 Token 過期失效，官方更推薦使用 API Key 或 Cloud 認證。

### 官方來源網址
- [Google Terms of Service](https://policies.google.com/terms)
- [Google Generative AI Prohibited Use Policy](https://policies.google.com/terms/generative-ai/use-policy)
- [Google Gemini CLI Documentation on Non-Interactive Mode](https://github.com/google-gemini/gemini-cli)

### 原文短引用
- **條款濫用限制**：
  > You must not abuse, harm, interfere with, or disrupt our services or systems — for example, by using automated means to access content from any of our services in violation of the machine-readable instructions... or hiding or misrepresenting who you are in order to violate these terms.
- **CLI 自動化支援與遠端限制**：
  > The CLI supports headless mode via `gemini -p` and `--non-interactive`. However, browser-based OAuth (`oauth-personal`) requires localhost callback listeners. For headless and automated environments, authenticating via `GOOGLE_API_KEY` or Vertex AI Service Accounts is recommended.

### 確定程度
**確定**

---

## 6. 對 P2 的影響

### 可以照 D15 做的地方
1. **Claude Code 執行架構**：
   - 可以完全照 D15 規劃落地。
   - 使用 `claude setup-token` 產生的長期 OAuth Token（透過環境變數 `CLAUDE_CODE_OAUTH_TOKEN` 傳入），搭配 `claude -p` 於 VPS 上進行無人值守自動化調度。這是 Anthropic 官方為遠端/CI/CD 專門設計的合規路徑。

### 要注意的地方
1. **Claude 額度共用與中斷風險**：
   - Claude Code 與 YUI 於網頁端 `claude.ai` 共用 5 小時滾動視窗與每週額度。
   - 若 VPS 辦公室在背景執行大型程式碼分析或多輪任務，極容易消耗大量 token，導致 YUI 日常在網頁端工作時突然遇到「Rate Limit Exceeded」而無法使用。
   - 建議在叫用 `claude -p` 時務必加上 `--max-turns` 限制，並設定任務調度頻率上限。
2. **Gemini 個人帳號之嚴重隱私風險**：
   - **重大隱私隱患**：個人 Google 帳號（`oauth-personal`）受《Gemini Code Assist Privacy Notice for Individuals》約束，其**提示詞與相關程式碼會被 Google 收集用於訓練模型，甚至可能被人工審查員檢閱**。
   - 若貓咪辦公室處理的程式碼或日常資料含有個人私密資訊、商業邏輯或不想公開的程式碼，絕對不能走個人帳號的 Gemini CLI。
3. **Gemini 憑證維持不易**：
   - 在無瀏覽器的 VPS 上維持 `oauth-personal` 登入需透過 SSH port-forwarding 或自訂回調指令碼，且長期無人值守時存在 token refresh 失效的風險。

### 哪些需要 YUI 決定
1. **Gemini 隱私與認證策略抉擇**：
   - **選項 A（接受條款）**：僅限處理公開開源程式碼或非機密任務，維持個人 Google 帳號。
   - **選項 B（改用 API Key / 企業憑證）**：若需處理私有程式碼，放棄以個人 Google 帳號登入 Gemini CLI，改用 Google AI Studio API Key（或走 Google Cloud 企業專案）以規避資料被訓練與人工審查之風險。
2. **Claude Code 背景預算防護設定**：
   - 決定是否為 VPS 上的自動化調度設定「每日呼叫次數硬上限」或「單次任務最大 turns 數」，防止背景任務吃滿 Pro/Max 額度影響 YUI 日常在 claude.ai 的使用。

---

## Claude 覆核（2026-10-28）

上面 1–6 節是 Gemini（Antigravity CLI）寫的。Claude 抽查官方頁面後的結論如下，**以本節為準**。上文的「原文短引用」有些是轉述，不是逐字原文，不能直接引用。

### 確認屬實

- **Claude 額度共用：** [Using Claude Code with your Pro or Max plan](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan) 寫「all activity in both tools counts against the same limits」。Pro 與 Max 都有五小時的工作階段限制和每週限制。
- **環境裡有 API 金鑰時會改用 API 計費：** 同一篇也寫，設了 `ANTHROPIC_API_KEY` 時，Claude Code 會改用 API 金鑰計費。辦公室只傳白名單裡的環境變數，金鑰不會傳進去，已有測試。
- **`claude setup-token` 存在：** Claude Code 2.1.183 的 `--help` 寫它是「Set up a long-lived authentication token (requires Claude subscription)」。

### 沒有確認

- **「官方完全允許在伺服器以 `claude -p` 無人值守執行」：** 上面那篇沒有提到自動化、無人值守或 `-p`，第 1 節的條款引文 Claude 也沒有核對。目前只能說：CLI 本身提供這些功能，用途是 YUI 個人自用、不轉售。**確定程度改為「不確定」**。上線前請 YUI 自己看一次 [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)。
- **Gemini 每天約 1,000 次、每秒 2 次：** 沒有核對。

### 有錯，影響 D15

- **Gemini CLI 已經不服務個人帳號：** [Gemini CLI 條款頁](https://geminicli.com/docs/resources/tos-privacy)（2026-04-10 更新）寫「Gemini CLI was replaced by Antigravity CLI on June 18th, 2026」，對象是免費層與 Google One（含 Google AI Pro／Ultra）使用者。[Code Assist 個人隱私頁](https://developers.google.com/gemini-code-assist/resources/privacy-notice-gemini-code-assist-individuals) 現在也只剩停用公告：2026-06-18 起，IDE 擴充不再服務 individuals、AI Pro、AI Ultra。
  - 所以「用 Google 帳號登入 Gemini CLI」這條路，對 YUI 的帳號多半已經不通。上文第 3–5 節描述的是停用前的狀況。
- **訓練與退出：** Gemini CLI 條款頁唯一提到的退出，是「使用統計」，不是模型訓練。第 4 節「無法關閉」這點沒有官方原文支持，Claude 也沒查到確定說法。**不確定**。

### 對 P2／P4 的影響

1. **Claude（P2）：** 可以照 D15 繼續，但有兩件事：
   - 額度和 YUI 自己在 Mac 用的 Claude 共用，手的長任務尤其要設上限。
   - 條款裡「無人值守」的部分還沒確認，請 YUI 自己看過再上線。
2. **Gemini（P4）：** 已寫好的 `GeminiAgent` 用 Gemini CLI 個人登入。它只對 Code Assist Standard／Enterprise 或 API 金鑰帳號有用，對 YUI 的帳號多半不通，需要 YUI 重新決定：
   - **改用 Antigravity CLI（`agy`）：** 它有 `--print`、`--output-format stream-json`、`--json-schema`，開場事件也列出工具，可以用來檢查。
     - **問題：** 預設給模型 60 個工具，包括執行指令、寫檔、操作瀏覽器、傳訊息、排程，權限模式是 `request-review`。
     - Claude 沒找到能縮成「只搜尋、只讀網頁」的官方參數。關掉 slash command 後，它還提示 `--mode plan` 沒有效果。
     - 找到可靠的限制方式之前，不能當成和 Codex／Claude 同等安全的「腦」。
   - **改用付費 Gemini API 金鑰：** 違反 D15，要 YUI 決定。
   - **先不接 Gemini。**
