---
title: 給 Claude Code：沙盒整合施工單的接續
date: 2026-10-28
status: 已由 Claude Code 在 Mac 本機跑完測試並分三個 commit（見 HANDOFF 進度紀錄）；未安裝、未部署、未推送、未啟用真實 provider
---

# 給 Claude Code：接著做什麼

## 1. 現況

- 工作樹 `worktrees/neko-agent-hands`，分支 `claude/agent-hands-prd`，HEAD `b8599c6`。
- 上一手（雲端 Claude 經 Mac 的 Linux VM）完成了施工單第三～六節的本機部分，**全部只在工作樹，沒有 commit**。原因：那個 VM 的 git 2.34 不認得這個 repo 的 `relativeWorktrees` 設定，而且不能刪 lock 檔，所以 commit 一律交給 Mac 本機的 git。
- 詳細紀錄、NOT RUN、回退方式見 [HANDOFF.md](HANDOFF.md) 進度紀錄的「沙盒整合施工單」一則。

改動清單：

| 類型 | 檔案 |
|---|---|
| 修改 | `office/browser_actions.py`、`office/browser_audit.py`、`office/browser_control.py`、`office/office.py`（只多一條 `/api/viewer/reconcile` 路由）、`office/tests/test_browser_actions.py`、`office/tests/test_browser_control.py`、`office/docs/agent-hands/HANDOFF.md` |
| 新增 | `office/runner.py`、`office/uploads.py`、`office/github_app.py`、`office/tests/test_runner.py`、`office/tests/test_uploads.py`、`office/tests/test_github_push.py`、本檔 |

## 2. 依序要做的事

1. **先查狀態，不覆蓋。** `git status`、`git log -1`。若 HEAD 已不是 `b8599c6`，或有上表以外的改動，先停下來回報，不 reset、不 stash 別人的東西。
2. **讀 diff。** 重點看 `browser_control.py` 的 `ret()`、`reconcile()`、`settle_one()`，以及 `browser_audit.py` 的遷移。這是刻意的行為改變：交還不再等於核對。看到問題就記下來修，不要整段重寫。
3. **在 Mac 本機 Python 跑完整測試：** `python3 -I -m unittest discover -s office/tests -v`。上一手在 VM 上分批跑的結果是 281 通過、7 略過。Mac 上 `test_browser_chrome` 應該會實跑，把結果分開記。
4. **分三個 commit**，在 `claude/agent-hands-prd` 上，不 push：
   - 未知結果核對：`browser_*`、`office.py`、兩個 browser 測試。
   - runner 骨架＋上傳後端：`runner.py`、`uploads.py`、兩個測試。
   - H4 離線流程：`github_app.py`、`test_github_push.py`。
   - 最後一個 commit 一併帶上 HANDOFF 的更新與本檔。
5. **更新 HANDOFF：** commit 雜湊、Mac 本機測試結果。
6. **停下來回報。** 接線（見第 3 節）要等 YUI 決定先接哪一個。

## 3. 等 YUI 決定後才做

- 三個新模組都還沒接進 `office.py` 與 worker。接 runner 時，啟動流程要呼叫 `RunService.recover()`；接 H4 時，在原本 PRD 9 的 `/api/worker/push` 上做。
- 核對卡片與上傳介面：先做預覽，照既有視覺驗收流程，再整合到 `office/static/*`。
- 真 provider（E2B Python SDK，只用合成資料、不帶密鑰）、GitHub App 建立：都需要另外授權。

## 4. 不可越過的線

- 不 push、不合併、不部署、不安裝、不碰 VPS、不建真沙盒、不開真 PR、不讀憑證。
- 不改 D13／D14／D15–D17。同 UID 旁路要照實標示，不能說成已隔離。
- 任何失敗都不能自動退回主機裸跑。
- 未執行的項目一律寫 NOT RUN；mock、本機真 Chrome、VPS、Mac App、Windows、iPhone 分開標示。
