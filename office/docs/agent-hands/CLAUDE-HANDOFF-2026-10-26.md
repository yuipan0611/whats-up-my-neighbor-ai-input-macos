---
title: 給 Claude：瀏覽器動作控管、紀錄與接手增補
date: 2026-10-26
status: 文件已整合；實作未開始；尚未傳送至其他聊天
---

# 給 Claude：接著做什麼

## 1. 任務與入口

YUI 要求把 OpenBot 值得借用的設計整合進既有貓咪辦公室，優先處理瀏覽器動作控管、操作紀錄與接手。請在桌面工作區 `worktrees/neko-agent-hands` 接續，沿用 `claude/agent-hands-prd`；先查當前 HEAD／工作樹，保留其他人的未提交修改。

閱讀順序：

1. 工作區根 `AGENTS.md`、`README.md`。
2. [PRD.md](PRD.md) 的 5.11、6、9.2、13.3。
3. [ADR-002](ADR-002-browser-actions-audit-handover.md)：本次新增契約的唯一詳細規格。
4. [HANDOFF.md](HANDOFF.md)：H／G 任務與當前狀態。
5. [ADR-001](ADR-001-office-sqlite-vs-vps-mvp-prd.md)：SQLite 決策及 D12–D14。

這份是施工入口，不是另一套規格。驗收方式與詳細 API 以 ADR-002 為準；若發現衝突，先記錄具體差異並修一致，不自行擴張權限。

## 2. 已知基準與限制

- 本次文件編輯前：分支 `claude/agent-hands-prd`，HEAD `48cdcdc`，工作樹乾淨；本次只修改／新增規劃文件，未 commit、push、部署或改程式。
- 本機 H3 紀錄：2026-10-24 完成真 Codex＋真 Chrome 的 Example Domain 任務；仍有惡意內容、資源、重啟等 NOT RUN。請重查目前狀態，不要照舊表又要求 YUI 重登已登入的帳號。
- 現有 `worker.py` 直接提供 browser MCP、自動核准、同 UID、網路開啟。這是 D13 的低權限帳號取捨，不能寫成所有網站動作已強制分級。
- 現有每 30 秒 heartbeat 和 SIGSTOP 都不足以單獨證明已可安全接手：還有在途請求、子程序、舊工具佇列與恢復後重播問題。
- 沒有在本次重驗 VPS、公網、Mac／iPhone 或目前登入狀態。歷史部署證據按日期引用。

## 3. 施工單

| 順序 | 任務 | 建議改動範圍 | 驗收與交付 |
|---|---|---|---|
| G0 | 能力路徑與基準盤點 | 唯讀檢查 worker／Chrome 啟動與權限；新增 `reports/agent-hands/BROWSER-CAPABILITY-BASELINE.md` | 明列 broker、CDP、profile、shell、GUI／程序、網路、worker API 各入口；哪些可擋、哪些待隔離 |
| G1 | broker 核心 | 新 `office/browser_actions.py`、worker socket route、聚焦測試 | action_id、lease、epoch、目標版本、固定分類、先記錄後 dispatch；先用 fake browser 做決策與競態測試 |
| G2 | 可信任紀錄 | 新 `office/browser_audit.py`、新增 SQLite 遷移與 owner 讀取 API | decision／outcome 分列、錯誤不假成功、敏感值不落盤、歷史資料與 API 相容 |
| G3 | 受限瀏覽器工具 | 新 `office/hands/browser_adapter.py`、`worker.py` 的 broker mode 接合、H5 卡片 | 接真 Chrome 完成讀取；未知／L3 不執行而交人；L4 拒絕；不能回 raw MCP；區分 mock 與真 Chrome |
| G4 | 接手屏障與 viewer | `office.py`、`office/hands/*`、`office/static/viewer*`、viewer 測試 | take 先 hold 再確認停手才開輸入；epoch 拒舊裝置；斷線／重啟持續 hold；交還先觀察、無舊操作重播 |
| G5 | 整合與撤銷 | H9 文件、聚焦整合測試與驗收紀錄 | 重試／取消／撤銷／DB 故障／回退；Mac、iPhone、VPS 分列；未測不得寫通過 |

G1/G2 的模組可在同一組本機改動協作完成，不必為了先後順序造出不寫紀錄的 dispatch。G3／G4 之前先補 H3 相關缺項；H4／H5 沿用原任務，可共用這次的紀錄與卡片，沒有被取代。

每個任務完成就更新 HANDOFF 與實測證據，再開始下一個。先在現有交接板記下檔案接手；不要求開多個 Agent，也不改官網 repo 或正式 Mac App。

## 4. 不可省略的實作條件

- broker 壞掉、沒有匹配規則、未知工具、舊 lease／epoch／snapshot，都不能 dispatch。判斷採伺服器解析的目標與固定規則，不相信 Agent 自稱只是讀取。
- click、type、Enter、navigation、upload 都可能造成外部效果。任意 script 不直接開放；安全讀取改成固定實作。不以按鈕標籤關鍵字或 prompt 當唯一保障。
- 同 action_id 同內容回原結果；不同內容 409。外部結果不明先核對，不因自動重試多寄一次、多開一個 PR。
- 操作紀錄由辦公室／broker 產生，worker 自述另標來源。紀錄不存輸入值、cookie、headers、lease、query／fragment、raw payload 或鍵盤；不為紀錄讀出真秘密。
- 控制狀態存 browser session，擋住下一件任務；take／return 具 operation_id 與 epoch。收到 202 不代表已接手。
- 接手時必須先關 Agent 動作與截圖，再確認程序樹和在途工具都已處理；超時維持 held，人工輸入不開放。
- 人工輸入在伺服器檢查控制者與 epoch；viewOnly 僅做 UI。撤銷或切裝置後，舊連線的輸入立刻失效。
- 交還先關人類輸入、清舊工具與快照，再取新觀察。不能把凍結在舊工具裡的程序直接恢復；可重啟同一 task 下的新 turn，保留有效 lease 與上下文。
- hold 持續 heartbeat，不重領、不計 30 分鐘；但取消／收回仍要生效，return 不能復活已取消任務。
- D7 維持人親手做；D13 同 UID 與 D14 不做網站白名單不暗改。要宣稱完整強制隔離時，另提隔離設計與資源證據。

## 5. 測試與交付方式

先跑受影響的 office／worker／viewer 測試；集成後跑既有 office suite，保留 SQLite 舊資料遷移與回退的測試。這些是後續實作要求，本次文件工作沒有跑產品測試。

回報至少包含：

- 本機分支／commit、實際改動、G0–G5 與 H 任務狀態。
- 假瀏覽器測試、真 Chrome、VPS、Mac、iPhone 各自的結果與 NOT RUN。
- 攔住的工具路徑、尚未封住的旁路、敏感資料遮蔽與故障處理證據。
- broker mode 如何關閉、回退時如何保留 hold／紀錄，不把控制中的 session 交給舊 worker。

預設沿用 legacy 部署狀態，broker mode 只在隔離測試環境開啟；啟用後出錯不得 fallback。正式 VPS 部署、push、合併、安裝或發布仍需另外授權。既有個人登入、金鑰設定與生產資料不得作測試素材。

## 6. 可直接貼給 Claude 的啟動文字

> 請接續桌面工作區 `worktrees/neko-agent-hands` 的 `claude/agent-hands-prd`。先讀根 AGENTS.md／README.md，再讀 `office/docs/agent-hands/CLAUDE-HANDOFF-2026-10-26.md`、PRD、ADR-002 與 HANDOFF。這次做現有辦公室的瀏覽器動作控管、操作紀錄與接手增補，沿用 office.py＋SQLite，不另建服務。先做 G0 的能力路徑盤點，再以本機合成環境做 G1／G2；逐步接 G3／G4／G5，保留原 H4／H5 工作。D7 人親手做、D12 接手斷線持續暫停、D13 同 UID 與 D14 不做網站白名單都不暗改。不要把 broker 路徑的控管說成全面隔離；不得以 prompt、隱藏 CDP 或自動核准冒充權限強制。完成每段後補驗證與 NOT RUN。這份啟動範圍是本機實作與測試，不授權 push、部署、合併、正式安裝或發布。
