---
title: 貓咪的手：交接板
date: 2026-10-23
status: D1–D11 已拍板（2026-10-23，全部照推薦）；v1a 進行中，H2 loopback 修補先做
---

# 交接板

需求、決策、權限與體驗規則以 [PRD.md](PRD.md) 為準。本檔只記錄分工與進度。

## 分工

| ID | 任務 | 負責 | 擁有的檔案／範圍 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| H0 | PRD 與交接板 | Claude | `office/docs/agent-hands/*` | — | 完成（D1–D11 已拍板） |
| H1 | VPS 基礎：swap、`neko-hands`、Chrome、VNC 改歸 neko-hands、`/srv/neko-handoff` | YUI（root）；Claude 提供指令並唯讀驗證 | VPS 系統設定 | D1、D2、D8 | 未開始 |
| H2 | 辦公室安全底座：loopback 修補、worker API、「手」執行者、先停一下與收回開關 | Claude | `office/office.py`、`office/tests/test_local_entry.py`、`office/tests/test_hands.py` | D1 | loopback 修補完成並已部署（0.4.0，2026-10-23）；worker API／執行者／收回開關進行中 |
| H3 | worker＋Codex 登入＋瀏覽器 MCP；合成任務 | Claude＋YUI（登入） | `office/hands/*`（新增） | H1、H2、D9 | 未開始 |
| H4 | GitHub App（營運者建立）、辦公室代為 clone／push／開 Draft PR、鑰匙收回、越權測試 | Claude＋YUI | `office/github_app.py`（新增）、`office/tests/test_github_push.py`、驗證紀錄 `reports/agent-hands/` | H2、H3、D4 | 未開始 |
| H5 | 體驗層：自動轉交、三種卡片、鑰匙清單、文案清理、禁用詞掃描 | Claude | `office/static/*`（先在下方留言，與手機版協調）、`office/tests/test_copy.py` | H3、D10 | 未開始 |
| — | **v1a 完成點** | — | — | H1–H5 | — |
| H6 | 看看貓咪（noVNC＋WebSocket 轉接）、接手時自動停手 | Claude＋YUI | `office/static/viewer*`、`office.py` 的 viewer 端點 | H5、D6 | 未開始 |
| H7 | 貓咪資料夾：Mac LaunchAgent＋rsync | Claude | `office/handoff-sync/*`（新增） | H1、D5 | 未開始 |
| H8 | 通知 | Claude＋YUI | `office/notify*`（新增） | H5、D11 | 未開始 |
| H9 | REVOKE.md、撤銷演練 | Claude＋YUI | `office/docs/agent-hands/REVOKE.md` | H4–H8 | 未開始 |

## 規則

- **H2 的 loopback 修補完成並部署之前，不建立 neko-hands。**
- **GitHub App 私鑰只放 neighbor。** neko-hands 的環境裡不能出現任何 GitHub 鑰匙；push 一律經過 `/api/worker/push`，而且只推 `neko/*`。
- 在 `claude/agent-hands-prd` 分支上 commit。合併到 main、push、部署到 VPS，都要另外取得 YUI 同意。
- 一個檔案只有一個負責人。要改別人的檔案，先在下方留言。
- 新介面文案要通過 PRD 3.8 的禁用詞掃描。
- 不讀取、不輸入、不保存密碼、token、cookie、配對碼或私鑰，也不寫進報告或聊天。
- 需要 YUI 動手的步驟（root 指令、登入、建立 App），先用確認問題講清楚要輸入什麼、什麼時候輸入，再開始。
- 不要把 `.impeccable/`、`design/` 或 `worktrees/neighbor-remote-agent` 的實驗混進來。

## 進度紀錄

- 2026-10-23｜Claude｜H0｜v0.1 草案
  - 新增 PRD.md、HANDOFF.md。
  - 唯讀實測：Mac swap 7.07/8 GB、70 個 node 程序；VPS 2 vCPU、7.9 GB、沒有 swap、x86_64、只有 `neighbor` 使用者、沒有 Chrome／gh。
  - 確認辦公室 local 模式信任 loopback（PRD 5.8）。
- 2026-10-23｜Claude｜H0｜v0.2 草案
  - YUI 要求「工程做，使用者無感」，PRD 新增第 3 節體驗層：六樣可見元素、工程吸收清單、不能藏的四件事、互動預算、用到才設定、文案、禁用詞。
  - 唯讀實測 GitHub：macOS repo 公開；`main` 沒有保護；`macos-release` 沒有審核規則；`build.yml` 的 `free-release-check` 在 push 到 `main` 或 `codex/neko-cicd-updates` 時，會拿到簽章憑證和 Sparkle 私鑰。因此改成 GitHub App，由辦公室代為 push，而且只推 `neko/*`。
  - 撤回 v0.1 的「Chrome 登入 GitHub 網頁」。
  - 範圍拆成 v1a（H1–H5）和 v1b（H6–H9）。
  - 待 YUI 拍板 D1–D11。
- 2026-10-23｜YUI｜H0｜拍板｜D1–D11 全部照 PRD 推薦；指示開始 v1a，先做 H2 的 loopback 修補｜手機 PRD 的 D4（暫不通知）由本 PRD 的 D11 取代，已在手機 PRD 註記
- 2026-10-23｜Claude｜H2 loopback 修補｜完成（本機，未部署）
  - office 0.4.0：本機模式只開在私有 Unix socket `~/neighbor-office/run/office.sock`（600／700）；TCP 只認公網模式；新增 `--local-socket`、`--dev-tcp-local`（只限開發機）。
  - `open-office.command` 改成轉送到 socket；VPS 還是 0.3.0 時自動沿用 8421。`verify_live.py` 改走 socket。
  - 測試：新增 `tests/test_local_entry.py` 14 項；共用測試的本機請求改走 socket（`test_office.py`、`test_mobile.py` 的 helper）。全部 83 項通過；9 組 mutation 全部被抓到（含連接埠被占用時要回報原本的錯誤）。
  - VPS 唯讀確認：sshd 允許轉送到 Unix socket；`/home/neighbor` 750、`~/neighbor-office` 700，沒有額外 ACL。
  - 在 `/tmp` 隔離的暫時實例實測：TCP 本機 Host 回 421、Mac 經 SSH 轉送到 socket 回 200、socket 權限 `srw------- neighbor`、停止後自動移除。暫時資料夾已刪除，正式服務沒有動。
  - 下一步：部署 0.4.0（需 YUI 同意，照 `docs/mobile/DEPLOY.md` 第 7 點）；接著做 worker API。
  - 注意：VPS 桌面的 `neighbor-office.desktop` 捷徑部署後會失效，這是刻意的。
- 2026-10-23｜Claude｜H2 部署 0.4.0｜完成（YUI 同意）
  - `current` → `releases/public-20261023-52108bd`；備份 `backups/pre-52108bd-20261023T074835Z`（SQLite integrity ok）。
  - VPS 上 83 項測試通過；新增 `office/verify_public.py`，27 項全過。
  - 紀錄見 `reports/agent-hands/DEPLOY-0.4.0-2026-10-23.md`。
  - Mac 在合併 main 之前，要用這個分支的 `open-office.command`。
