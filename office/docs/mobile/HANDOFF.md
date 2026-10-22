---
title: 貓咪辦公室手機直連：交接板
date: 2026-10-22
status: 對齊設計中；未實作、未部署
---

# 交接板

需求與契約以 [PRD.md](PRD.md) 為準。這份只管分工與進度。

## 分工（提案，待 YUI 確認）

| ID | 任務 | 負責 | 擁有的檔案 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| M0 | PRD 與交接板 | Claude | `office/docs/mobile/PRD.md`、`HANDOFF.md` | — | 草案 |
| M1 | `/api/sync`、`_office` 事件、Host/Origin 設定化 | Claude | `office/office.py`、`office/tests/test_mobile.py` | YUI 拍板 D1、D2 | 未開始 |
| M2 | W：WebSocket 端點；或 S：SSE 端點 | Claude | 同 M1 | M1、D2 | 未開始 |
| M3 | 配對、devices、session、撤銷 | Claude | 同 M1 | M1、D3 | 未開始 |
| M4 | 手機版面、配對頁、補狀態、長連線、重連、退回輪詢 | Codex | `office/static/*` | M1 的回應格式定稿 | 未開始 |
| M5 | 網路前置：SSH 收緊，加上 tailscale 或 Caddy、DNS、ufw | YUI（root、hPanel） | VPS 設定 | D1 | 未開始 |
| M6 | 部署與 iPhone 實機驗收 | Claude＋YUI | 驗證紀錄 `reports/office-mobile/` | M1–M5，另取 YUI 部署同意 | 未開始 |

M1 的回應格式（PRD 第 5、6 節）一旦定稿，M4 就可以和 M2、M3 同時進行。

## 規則

- 一個檔案只有一個負責人。要改別人的檔案，先在下方留言。
- 只在本機分支 `codex/neighbor-office-v1` 上 commit，不 push、不部署，不改 8421 的監聽位址。
- office-v1 裡未提交的 `.impeccable/`、`design/` 來源不明，任何人都先不要加入 commit。
- 不讀取、不輸入、不保存密碼、配對碼或 cookie 值，也不把它們寫進報告。

## 進度紀錄

- 2026-10-22｜Claude｜M0｜草案｜新增 PRD.md、HANDOFF.md｜唯讀核對：VPS 上的 office 等於 75bc990；8421 只聽 loopback；只開 22；root 仍可用密碼登入｜待 YUI 拍板 D1–D4，並確認分工
