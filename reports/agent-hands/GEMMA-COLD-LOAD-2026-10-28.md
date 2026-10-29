# Gemma 冷載入逾時修正（2026-10-28）

**狀態：只在分支，未部署。** 修正在分支 `claude/agent-hands-prd` 的 `82f70d5`（本機，未推送，未合併 main）。VPS 仍是 office 0.5.1（`releases/public-20261023-f74a50a`），Gemma 任務在冷載入超過 60 秒時仍會失敗。YUI 表示 Gemma 本地模型不是重點，主力是 Claude、OpenAI、Gemini 接進 VPS，所以這次沒有部署。

## 問題

2026-10-27 的兩件 gemma 任務（`644c239b`、`43e9789b`）都失敗。`Ollama.generate()` 串流 `/api/chat` 的讀取逾時是 60 秒，但 VPS CPU 上 gemma3:4b 的冷載入（load_tensors + CPU_REPACK）超過 60 秒。辦公室斷線後，Ollama 也跟著中止載入（`client connection closed before llama-server finished loading, aborting load`，HTTP 499），所以重試也一樣會失敗。

## 修正

- `Ollama.load()` 先送一個沒有訊息的 `/api/chat`，這個請求只會載入模型。它在背景執行緒等待，最多 5 分鐘；主執行緒每 0.5 秒呼叫一次 `check()`，所以取消仍然有效。
- 載入請求和真正的對話使用相同的 `num_ctx`、`num_thread`，Ollama 就不會重新載入。
- 原本的 60 秒讀取逾時不變；4 分鐘的生成上限改從載入完成後開始計算。
- metrics 多一個 `load_seconds`。

## 驗證

- **自動測試：** 新增 4 項（`OllamaLoadTests`）：冷載入超過讀取逾時仍能完成、熱模型立即通過、載入中取消、載入超過上限時給出明確錯誤。整套 174 項在 Mac 上通過。同一個冷載入測試套在舊版 `f74a50a` 的程式碼上會 `TimeoutError`，證明它能重現原本的問題。
- **VPS 實機（未部署，沒有碰辦公室服務）：** 把「`f74a50a` 加上這次修正」的 office.py 放在 `/tmp` 暫存資料夾，用真的 Ollama 0.40.7 測試。`neighbor-ollama` 從 inactive 開始：
  - 載入請求 200，花了 21.0 秒。
  - 接著的生成 2.0 秒，`load_duration` 2 ms，表示沒有重新載入。
  - 測完已停回 inactive，暫存資料夾也已刪除。
  - 這次只花 21 秒，是因為模型檔還在系統檔案快取裡。超過 60 秒的情況只由自動測試涵蓋。

## 若之後要部署

用最小修補：從 `f74a50a` 另開分支，只帶這次的修正，版本改為 0.5.2；G0–G4 不能一起上線。流程照 `office/docs/mobile/DEPLOY.md`：備份資料庫、建新 release、在 VPS 跑測試、切換 `current`、重啟，再跑 `verify_public.py --expect-version 0.5.2`。YUI 同意冷啟動驗證前用 root 清檔案快取，以重現超過 60 秒的載入。

## 尚未處理

- 輸入接近 7000 位元組時，CPU 上的 prompt eval 可能超過 60 秒才吐出第一個字，同樣會撞到讀取逾時。以往的任務 prompt eval 約 10 秒，所以這次沒有處理。
