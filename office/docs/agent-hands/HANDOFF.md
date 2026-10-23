---
title: 貓咪的手：交接板
date: 2026-10-23
status: H0 草案完成；等 YUI 拍板 D1–D9，之後才開始 H1
---

# 交接板

需求、決策與權限以 [PRD.md](PRD.md) 為準。本檔只記錄分工與進度。

## 分工

| ID | 任務 | 負責 | 擁有的檔案／範圍 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| H0 | PRD 與交接板 | Claude | `office/docs/agent-hands/*` | — | 草案完成，待拍板 |
| H1 | VPS 基礎：swap、`neko-hands`、Chrome、VNC 改歸 neko-hands、`/srv/neko-handoff` | YUI（root）；Claude 提供指令並唯讀驗證 | VPS 系統設定 | D1、D2、D8 | 未開始 |
| H2 | 辦公室：loopback 修補、worker API、`hands` 執行者、測試 | Claude | `office/office.py`、`office/tests/test_hands.py` | D1 | 未開始 |
| H3 | worker＋Codex 登入＋瀏覽器 MCP；合成任務 | Claude＋YUI（登入） | `office/hands/*`（新增） | H1、H2、D9 | 未開始 |
| H4 | GitHub token＋測試 repo 端到端與越權測試 | Claude＋YUI（建立 token） | 驗證紀錄 `reports/agent-hands/` | H3、D4 | 未開始 |
| H5 | 交接資料夾同步（Mac launchd＋rsync） | Claude | `office/handoff-sync/*`（新增） | H1、D5 | 未開始 |
| H6 | 只看模式、步驟截圖、手機驗收 | Claude＋YUI | `office/static/*`（與手機版協調）、VNC 設定 | H3、D6 | 未開始 |
| H7 | 收回權限腳本、REVOKE.md、撤銷演練 | Claude＋YUI | `office/hands/lockdown*`、`docs/agent-hands/REVOKE.md` | H3–H6 | 未開始 |

## 規則

- **H2 的 loopback 修補完成並部署之前，不建立 neko-hands。**
- 在 `claude/agent-hands-prd` 分支上 commit；合併到 main、push、部署 VPS 都要另外取得 YUI 同意。
- 一個檔案只有一個負責人。要改別人的檔案，先在下方留言。
- 不讀取、不輸入、不保存密碼、token、cookie 或配對碼，也不寫進報告或聊天。token 由 YUI 本人在 GitHub 建立，並貼進 VPS 上的檔案。
- 需要 YUI 動手的步驟（root 指令、登入、VNC 密碼），先用確認問題講清楚要輸入什麼、什麼時候輸入，再開始。
- 不把 `.impeccable/`、`design/` 或 `worktrees/neighbor-remote-agent` 的實驗混進來。

## 進度紀錄

- 2026-10-23｜Claude｜H0｜草案｜新增 PRD.md、HANDOFF.md｜唯讀實測：Mac swap 7.07/8 GB、70 個 node 程序；VPS 2 vCPU、7.9 GB、無 swap、x86_64、只有 `neighbor` 使用者、沒有 Chrome／gh；確認辦公室的 local 模式信任 loopback（PRD 5.7）｜待 YUI 拍板 D1–D9
