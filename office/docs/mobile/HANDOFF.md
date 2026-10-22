---
title: 貓咪辦公室手機直連：交接板
date: 2026-10-22
status: 已拍板 N2＋WSS＋CLI 配對；後端實作中；未部署
---

# 交接板

需求與契約以 [PRD.md](PRD.md) 為準。這份只管分工與進度。

## 分工（2026-10-22 確認）

| ID | 任務 | 負責 | 擁有的檔案 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| M0 | PRD 與交接板 | Claude | `office/docs/mobile/PRD.md`、`HANDOFF.md` | — | 完成 |
| M1 | `/api/sync`、`_office` 事件、Host/Origin 設定化 | Claude | `office/office.py`、`office/tests/test_mobile.py` | — | 完成（本機） |
| M2 | WebSocket 端點（D2＝W） | Claude | 同 M1 | M1 | 完成（本機） |
| M3 | 配對（VPS CLI）、devices、session、撤銷 | Claude | 同 M1 | M1 | 完成（本機） |
| M4 | 手機版面、配對頁、補狀態、WebSocket、重連、退回輪詢 | Codex | `office/static/*` | PRD 第 13 節（已定稿） | 進行中 |
| M5 | 網路前置：SSH 收緊，加上 Caddy、DNS（office.nekonode.cloud）、ufw 80/443 | YUI（root、hPanel） | VPS 設定 | — | 未開始，此輪不做 |
| M6 | 部署與 iPhone 實機驗收 | Claude＋YUI | 驗證紀錄 `reports/office-mobile/` | M1–M5，另取 YUI 部署同意 | 未開始 |

M1 的回應格式（PRD 第 5、6 節）一旦定稿，M4 就可以和 M2、M3 同時進行。

## 規則

- 一個檔案只有一個負責人。要改別人的檔案，先在下方留言。
- 只在本機分支 `codex/neighbor-office-v1` 上 commit，不 push、不部署，不改 8421 的監聽位址。
- office-v1 裡未提交的 `.impeccable/`、`design/` 來源不明，任何人都先不要加入 commit。
- 不讀取、不輸入、不保存密碼、配對碼或 cookie 值，也不把它們寫進報告。

## 進度紀錄

- 2026-10-22｜Claude｜M0｜草案｜新增 PRD.md、HANDOFF.md｜唯讀核對：VPS 上的 office 等於 75bc990；8421 只聽 loopback；只開 22；root 仍可用密碼登入｜待 YUI 拍板 D1–D4，並確認分工
- 2026-10-22｜Claude｜M0｜完成｜PRD 加入決策（D1=N2、D2=W、D3=CLI、D4=不做）與第 13 節 API 契約 v1｜—｜前端依第 13 節實作；後端開始寫 office.py、tests/test_mobile.py
- 2026-10-22｜Claude｜M1–M3｜完成（本機）｜office.py：
  - local/public 模式判定，帶 `X-Forwarded-*` 的 loopback Host 一律回 421。
  - 配對：CLI `pair/devices/revoke`、`/api/pair`、`/api/session`、`/api/session/forget`。
  - 配對碼只存雜湊、一次性、10 分鐘到期、新碼使舊碼失效、累計失敗 10 次作廢；每個 IP 失敗 5 次鎖 10 分鐘。
  - cookie `__Host-office`；token 綁定裝置；public 模式的 POST 與 WebSocket 一律要求 Origin。
  - `/api/sync`、`_office` 事件；`/api/tasks` 加 `latest_seq`，`snapshot()` 在同一個 read transaction 取得。
  - stdlib 實作 RFC 6455 WebSocket：hello、補送積壓、resync、即時事件、ping/ack、4401／4008／4000／1002／1009。
  - local 模式可撤銷裝置；public 模式的 CSP 加 `connect-src wss`、HSTS；VERSION 0.3.0。
  
  ｜驗證：新增 tests/test_mobile.py 24 項，全部 62 項通過。6 組 mutation 都被抓到：重複送 frame、Origin 變成選填、拿掉限速、配對碼可重用、WebSocket 忽略撤銷、public 可呼叫 bootstrap。
  
  ｜Codex 提出的兩點：`ws_send` 在磁碟上只有一次 sendall，重連測試的 seq 1–5 也沒有重複；`snapshot()` 已照建議改成單一 transaction。
  
  ｜未做：部署、DNS、Caddy、iPhone 實機（M5、M6）。Codex 的 static/README/DEPLOY/services 由 Codex 自行 commit。
