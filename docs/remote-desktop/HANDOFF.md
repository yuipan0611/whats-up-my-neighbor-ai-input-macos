---
title: 接手控制（VNC）多 agent 交接板
date: 2026-10-20
owner: Claude（協調）
branch: codex/neighbor-remote-agent
status: 進行中，只在本機分支；不 push、不 merge、不發布
---

# 接手控制：Agent 交接板

## 一句話

在遠端分身預覽加一顆「接手控制」按鈕，用 macOS 螢幕共享開啟 Linux VPS 或本機第二使用者的桌面。需求與規格以 [PRD.md](PRD.md) 為準，這份文件只管分工與進度。

## 接手前必讀（依序）

1. 工作區 `README.md` 與 `AGENTS.md`：工作區規則，例如不 push、不碰 `history/`。
2. [PRD.md](PRD.md)：需求、不做的範圍、介面契約、驗收標準。
3. 本文件的「分工」與「規則」兩節；派給你的任務說明放在 `tasks/`。
4. 既有脈絡：[../REMOTE_AGENT_PREVIEW.md](../REMOTE_AGENT_PREVIEW.md)、`Sources/NeighborAgentCore/SSHTunnel.swift`。

## 分工與檔案所有權

一個檔案只能有一個負責的 agent。要改不屬於自己的檔案，先在下方「進度紀錄」留言，由協調者分配。

| ID | 任務 | 負責 | 擁有的檔案 | 依賴 | 狀態 |
|---|---|---|---|---|---|
| T0 | PRD 與交接板 | Claude | `docs/remote-desktop/PRD.md`、`HANDOFF.md` | — | 完成 |
| T1 | 遠端設定文件，以官方來源查證；任務說明見 [tasks/T1-setup-doc.md](tasks/T1-setup-doc.md) | **Antigravity**（Gemini，`agy` CLI） | `docs/remote-desktop/SETUP.md`（只新增這一個） | T0 | 完成，Claude 審閱並修正 |
| T2 | 核心狀態機、探測、啟動器與離線測試 | Claude | `Sources/NeighborAgentCore/RemoteDesktopHandoff.swift`、`Tests/RemoteDesktopHandoffTests.swift`、`scripts/test-remote-desktop.sh` | T0 | 完成 |
| T3 | 面板 UI 與預覽圖 | Claude | `Previews/RemoteAgent/RemoteDesktopHandoffModel.swift`、`RemoteAgentView.swift`、`PreviewMain.swift`、`PreviewRenderer.swift`、`build-preview.sh` | T2 | 完成 |
| T4 | 審閱 T1、同步既有文件、完整回歸、commit | Claude | `docs/REMOTE_AGENT_PREVIEW.md`、`Previews/RemoteAgent/README.md`、工作區 `README.md` 該列 | T1、T2、T3 | 完成 |
| R1 | 依獨立審閱修正：15901 佔用檢查、探測期限上限、開啟中停用結束、測試缺口；任務說明見 [tasks/R1-review-fixes.md](tasks/R1-review-fixes.md) | **Antigravity**（Gemini，`agy` CLI） | 核心、面板 model／View／Renderer、測試檔 | T2、T3 | 完成，Claude 審閱並通過 mutation 測試 |
| T5a | 本機假 VNC 伺服器與螢幕共享 loopback 檢查工具；任務說明見 [tasks/T5a-loopback-check.md](tasks/T5a-loopback-check.md) | **Antigravity**（Gemini，`agy` CLI） | `scripts/fake-rfb-server.py`、`Tests/RemoteDesktopLiveCheck.swift`、`scripts/check-screen-sharing-loopback.sh` | R1 | 完成；R2 補 RFB 3.3 握手，Claude 修腳本並實測 |
| T5b | VPS 路徑本機 sshd 端到端檢查；任務說明見 [tasks/T5b-vps-path-loopback.md](tasks/T5b-vps-path-loopback.md) | **Antigravity**（Gemini，`agy` CLI） | `scripts/check-vps-path-loopback.sh`、`Tests/RemoteDesktopVPSLiveCheck.swift` | R2 | 完成，實測結束碼 0 |
| T5c | Docker（Debian 12）版 Linux VPS 端到端，加上假伺服器持續監聽；任務說明見 [tasks/T5c-docker-vps.md](tasks/T5c-docker-vps.md) | **Antigravity**（Gemini，`agy` CLI） | `scripts/docker-vps/`、`scripts/check-docker-vps.sh`、`scripts/fake-rfb-server.py` | T5b | 完成（2026-10-21）：使用者經由螢幕共享登入 xfce 桌面；找到 macOS 螢幕共享的 VNC 密碼 8 字元限制 |
| R3 | 15901 佔用檢查改成判斷有沒有程式在監聽，避免 TIME_WAIT 誤報；任務說明見 [tasks/R3-port-check-time-wait.md](tasks/R3-port-check-time-wait.md) | **Antigravity**（Gemini，`agy` CLI） | 核心、測試檔 | T5b | 完成，重現測試在舊實作下會失敗 |
| T5 | 真機驗證（第二使用者先，VPS 等資料） | 使用者＋Claude | 驗證紀錄 `reports/REMOTE_DESKTOP_HANDOFF_<日期>.md` | T4、遠端設定完成 | **VPS 完成（2026-10-21）**：真實 Hostinger VPS 端到端與預覽 App 都通過，見 `reports/REMOTE_DESKTOP_VPS_2026-10-21.md`。第二使用者仍待決定要用哪個伺服器 |

## 規則（所有 agent）

- 只改自己擁有的檔案。**只有協調者（Claude）可以 commit**；其他 agent 不 commit、不切分支、不 stash、不 reset。
- 不 push、不 merge、不發布，也不安裝或替換正式 App。
- 不在任何機器上安裝或啟動 VNC 伺服器、不建立 macOS 使用者、不連任何 VPS。這些由使用者照 SETUP.md 自己做。
- 不碰正式 App 的 `Sources/GroqVoiceInput/`、`Resources/`、`scripts/build.sh`，也不改 `SSHTunnel.swift`。
- 不讀取、不輸入、不保存任何密碼、API Key 或 VNC 密碼。
- 查不到官方或上游依據的內容，標註「未確認」，不要寫成已驗證。
- PRD 和這份交接板若有衝突，以 PRD 為準；要改 PRD，先跟協調者確認。

## 回報格式

完成或卡住時，在「進度紀錄」加一行：

```text
- YYYY-MM-DD HH:MM｜<agent>｜<任務 ID>｜<完成／卡住／需決定>｜<改了哪些檔案>｜<驗證做了什麼、結果>｜<還沒做或不確定的事>
```

## 進度紀錄

- 2026-10-20｜Claude｜T0｜完成｜新增 PRD.md、HANDOFF.md｜—｜T1 派給 Antigravity，提示詞存於工作區 `reports/ANTIGRAVITY_TASK_2026-10-20_vnc-docs.md`
- 2026-10-20｜Claude｜T2｜完成｜新增 RemoteDesktopHandoff.swift、RemoteDesktopHandoffTests.swift、test-remote-desktop.sh；PRD 第 5、6 節補 `openingViewer` 狀態與 SSH 兩種失敗文案｜`test-remote-desktop.sh` 18 情境通過（含真實 loopback 探測 4 種）；`test-agent-ssh.sh` 不變、通過｜UI 尚未接上（T3）
- 2026-10-20｜Claude｜T3｜完成｜新增 RemoteDesktopHandoffModel.swift；修改 RemoteAgentView（側欄接手控制區、側欄可捲動、獨立預覽說明改寫）、PreviewMain、PreviewRenderer（8 張）、build-preview.sh；核心逾時文案依目標區分（第二使用者不再提 SSH）｜`test-remote-desktop.sh` 22 情境（含面板 4 種）、`test-agent-preview.sh`、`test-agent-core.sh` 通過；8 張預覽圖人工檢查｜窄版錯誤狀態底部說明需捲動才看得到（預期）；T1 SETUP.md 尚未收到
- 2026-10-20｜Claude｜T4｜部分完成｜同步 REMOTE_AGENT_PREVIEW.md、Previews README、工作區 README；新增 tasks/T1-setup-doc.md（派工說明移入 worktree，不再依賴剪貼簿）｜`test-all.sh` 27 組全過；`build.sh` 通過（x86_64＋arm64，codesign 驗證）；正式 App 原始碼對 3101f03 差異 0 行；真實探測對無伺服器的 5901 實測 9.9 秒失敗、檢視器 0 次｜等 Antigravity 交 SETUP.md 後審閱並 commit；預覽 App UI 點擊未獲授權，未做
- 2026-10-20 15:38｜Antigravity｜T1｜完成｜新增 docs/remote-desktop/SETUP.md｜以 Debian/TigerVNC 官方 manpage、Eggplant 論壇與 Homebrew formulae 查證參數與套件名稱；內容涵蓋目標說明、VPS 與 Mac 第二使用者設定、排錯對照與官方連結｜macOS 螢幕共享連本機 loopback 是否被擋、RFB 探測中斷是否計為失敗連線（依 PRD 第 10 節標註為未確認，待 T5 真機驗證）
- 2026-10-20｜Claude｜T1 審閱｜完成｜修正 SETUP.md｜用 Homebrew API 查證：`vine-server` 自 2026-09-01 停用（fails_gatekeeper_check），原文的 `brew install` 會失敗，改寫為待決定選項；`tigervnc-viewer` 已查無，改為 `tigervnc`；依 Debian tigervncserver(1)，加上 `-localhost` 時預設已是 VncAuth，所以刪掉「不指定就一定失敗」的說法；Vine Server 改引上游 OSXvnc.html，GUI 勾選名稱標為未確認；排錯表加入 15901 被佔用一列｜第二使用者要用哪一個 VNC 伺服器，記入 PRD 第 10 節，待使用者決定
- 2026-10-20｜Claude｜R1 審閱｜完成｜Gemini 修改 5 個檔案；Claude 補回 Comment Sicko 保留的 `.waiting` 註解，PRD 第 5～7、9 節同步｜`test-remote-desktop.sh` 32 情境通過；mutation 測試三組（拿掉埠號檢查、拿掉期限上限、拿掉 `.waiting`）都被抓到；8 張預覽圖重新產生｜—
- 2026-10-20｜Gemini｜T5a｜完成｜新增 fake-rfb-server.py、RemoteDesktopLiveCheck.swift、check-screen-sharing-loopback.sh｜由 Claude 執行｜Gemini 指出：探測連線本身會讓「第一個連線後退出」的規格失效，所以把沒送客戶端版本的連線當成探測
- 2026-10-20｜Gemini｜R2｜完成｜fake-rfb-server.py 支援 RFB 3.3 與 3.7 握手｜實測：螢幕共享回覆 RFB 003.003，3.3 協商成功｜—
- 2026-10-20｜Claude｜T5（部分）｜完成｜刪掉檢查腳本與 Python 中逐步敘述的註解；修正畫面張數的計算、3.3 摘要；加入 CHECK_WAIT 與停在登入步驟的提示；新增 reports/REMOTE_DESKTOP_HANDOFF_2026-10-20.md｜真實螢幕共享會連進 127.0.0.1:5901，走到密碼對話框，所以 loopback 沒有被擋；Claude 依安全規則不在系統密碼框輸入，按取消後清理｜待使用者：用 CHECK_WAIT=90 重跑並輸入任意字元，以驗證畫面；決定第二使用者的 VNC 伺服器；提供 VPS 資料；預覽 App 的 UI 點擊
- 2026-10-20｜Claude｜T5 UI｜完成｜—｜使用者第二次授權預覽 App。選「本機第二使用者」→ 按接手控制 → 面板顯示成功文案，真實螢幕共享跳出 127.0.0.1:5901 密碼框 → 按結束接手 → 顯示結束文案；server.log 記到探測與 RFB 3.3 連入｜密碼框依安全規則未輸入，按了取消
- 2026-10-20｜Gemini｜T5b｜完成｜新增 check-vps-path-loopback.sh、RemoteDesktopVPSLiveCheck.swift｜Claude 先用原型證實一般使用者權限可跑 sshd；第一次執行抓到 TIME_WAIT 誤報｜—
- 2026-10-20｜Gemini｜R3、R3b｜完成｜SystemLocalPort.isFree 改用 connect；TIME_WAIT 重現測試照 Claude 原型的順序改寫｜33 情境通過；舊的 bind 實作在新測試下失敗；VPS 路徑模擬重跑結束碼 0，結束後 15901 立刻空出｜—
- 2026-10-21｜Claude｜T5 VPS｜完成｜Tests/RemoteDesktopVPSLiveCheck.swift 加 `--alias`（預設不變）；新增 scripts/check-real-vps.sh、scripts/vps-bootstrap-ubuntu.sh；SETUP.md 補 2.8／2.9 與 tigervnc-tools 說明；PRD 第 9、10 節｜真實 Hostinger VPS：check-real-vps.sh 結束碼 0，使用者確認桌面、滑鼠、鍵盤；TigerVNC log 記探測為 Clean disconnection；預覽 App Linux VPS 接手／結束，15901 釋放｜SSH 收緊與 VNC 開機自動啟動待使用者以 root 執行（SETUP 2.9）；第二使用者伺服器仍待決定
- 2026-10-21｜Claude｜T5c｜暫停｜—｜已由真實 VPS 取代。Gemini 的 `fake-rfb-server.py`、`check-screen-sharing-loopback.sh` 修改與 docker-vps 檔案保留在工作目錄，未提交｜要不要繼續做 Docker 版（例如當 CI 用的重現環境），之後再決定
- 2026-10-21｜Claude｜T5c｜完成（取代上一行的「暫停」）｜Gemini 寫的 docker-vps 與 check-docker-vps.sh；Claude 補上 `tigervnc-tools`、`VNC_TEST_PASSWORD`、保存 TigerVNC log；fake-rfb-server 改為持續監聽｜Docker 中照 SETUP.md 設定的 TigerVNC 1.12：密碼 `neighbor1`（9 字元）時，螢幕共享被判定認證失敗 4 次，但同一組密碼的標準 VncAuth 客戶端能登入；改成 8 字元後，使用者經由 SSH 通道一次登入成功，看到 xfce 桌面（截圖在 build/docker-vps-evidence/）；伺服器存的密碼解出來是前 8 個字｜測試容器與映像檔已刪除，Docker Desktop 已關閉
