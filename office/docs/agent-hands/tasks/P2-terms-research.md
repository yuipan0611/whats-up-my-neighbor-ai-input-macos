# 任務：查 Claude 訂閱與 Gemini 個人帳號用在自己伺服器的條款（ADR-003 P2 前置）

背景：貓咪辦公室是 YUI 一個人用的私人服務，跑在 YUI 自己的 VPS 上。辦公室會在 VPS 上無人值守地呼叫官方 CLI：
- **Claude Code**（`claude -p`），用 YUI 自己的 Claude 訂閱登入（Pro／Max，`claude auth login --claudeai`）。不用 API 金鑰。
- **Gemini CLI**（`gemini -p`），用 YUI 自己的 Google 帳號登入（「Login with Google」／oauth-personal）。不用 API 金鑰。

只有 YUI 本人會交辦任務，不提供給其他人使用，也不轉售。

## 要回答的問題

每一題都要附**官方來源網址**（anthropic.com、claude.ai、support.claude.com、docs.claude.com、google.com、ai.google.dev、developers.google.com、github.com/google-gemini）與原文重點（短引用）。找不到官方說法就寫「沒有找到官方說法」，不要猜。

1. Claude 訂閱（Pro／Max）登入 Claude Code，在自己的伺服器上以 `claude -p` 無人值守執行，官方是否允許？有沒有「只限個人使用」「不得自動化」或用量上限的說明？`claude setup-token` 的官方用途是什麼？
2. Claude 訂閱的用量限制：Claude Code 和 claude.ai 是否共用同一份額度？官方怎麼描述（例如每 5 小時的限制）？
3. Gemini CLI 用個人 Google 帳號登入時，用的是哪個方案（例如 Gemini Code Assist for individuals）？免費額度是多少（每分鐘、每天的請求數）？
4. 這種登入方式，Google 會不會用提示內容與回覆來改善產品或訓練模型？能不能關掉？付費方案（Google AI Pro 等）有沒有不同？
5. Gemini CLI 用個人帳號在自己的伺服器上無人值守執行，條款有沒有限制？

## 交付

寫成 `reports/agent-hands/TERMS-CLAUDE-GEMINI-2026-10-28.md`（相對於 worktree 根目錄），繁體中文：
- 每題一節：結論（一句）＋官方來源網址＋原文短引用＋確定程度（確定／大致確定／不確定）。
- 最後一節「對 P2 的影響」：可以照 D15 做、要注意什麼、哪些需要 YUI 決定。

只建立這一個檔案。不要改其他檔案，不要執行終端機指令。
