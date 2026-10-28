# 原 App 貓咪進出 VPS：修正檢查點

更新：2026-10-27。

## 使用者要的互動

使用現有 Mac App 的同一隻桌面貓，以及選單中的現有「VPS 遠端桌面」視窗。從本機拖進已連線的 VPS 畫面後，原桌面貓暫時隱藏並在視窗裡顯示；從視窗拖到外面則回到本機。「叫牠回家」直接返回原本位置，沿用既有拎起與 400ms 放下影格。鑽貓門的軟 Q 過場仍在 Roadmap，這次不做。

## 修正範圍

- `DesktopPetController` 保持唯一一個貓咪模型與桌面面板，記住出發位置並負責進出狀態。
- `VPSDesktopWindowController` 接上既有桌面貓；不建立第二個 VNC 視窗。
- `VPSCatHostView` 是放在原 VPS 視窗裡的繪圖與點擊層，沿用同一個模型及素材；VNC 其他區域仍可操作。
- 未連線、收合或隱藏的 VPS 視窗不能接受拖入。
- 先前 `native-vps-cat-journey` 是獨立預覽，因為多開了 VNC 與貓咪，已停用並僅供追溯。

## 視窗與連線生命週期

收合、關閉、縮小視窗或斷線時，貓咪自動回到本機出發位置；視窗重新開啟後可以再次拖入。關閉與收合仍保留既有 VNC 連線。尚未連線、等待密碼、隱藏、收合與縮小時不接受拖入；拖到有效 VPS 畫面內才會進入。

## 驗證

- `./scripts/test-vps-cat-transfer.sh`：落點及不可用狀態。
- `./scripts/test-vps-cat-window-lifecycle.sh`：原生控制器的收合、關閉／重開、縮小通知、斷線及重複結束。連線事件為合成，不開啟 SSH／VNC。
- `./scripts/test-desktop-pet-interaction.sh`：同一模型的進出、取消及原抓起／放下影格。
- `./scripts/test-vps-desktop-viewer.sh`：既有 VNC 登入與斷線。

真實 VNC 畫面及跨視窗拖放仍需另行實測，離線測試不能替代。整合源自 `80fb9f3`，保留原提交作者；最新主線的音訊修正與花色素材沿用。沒有修改 VPS 服務，也沒有新增第二隻貓或第二個 VPS 視窗。

## 感應線來源與效果

使用者最終澄清：不要已放棄的貓門／隧道動畫，也不要大面積色塊；保留靠近框邊時亮起的紅色感應線。三份封存的 DirectDrop 原始碼都保存 `x=501、y=150…506、lineWidth=4` 的 systemPink 側邊線。`VPSCatDropHint` 沿用這段繪圖，只把原座標映射到真實 VPS 視窗；原 entry／home 矩形只用於不可見的命中判斷，不畫成大區塊。靠近時只做 120ms 淡入，減少動態設定下直接顯示；不增加鑽門、側身或過場動畫。

提示層不搶焦點且滑鼠可穿透，沒有第二隻貓或第二個 VNC viewer。開發包可用 `NEKO_QA_OPEN_VPS=1` 打開同一個原 App 視窗，公開包忽略此驗收開關。

## 拖入後的顯示回歸

原先把 `VPSCatHostView` 直接加進 SwiftUI `NSHostingView` 的子視圖；實際拖入後，AX 項目和回家按鈕都存在，但合成畫面沒有貓。新增使用真實花色素材的像素檢查後，修正前可重現失敗。

改由 `VPSDesktopContentView` 明確管理背景 viewer 與上層貓咪，避免 SwiftUI／WKWebView 管理的視圖蓋住貓咪。測試同時檢查合成畫面中的貓咪像素、可拖曳命中、透明區穿透及視窗縮放後仍在桌面區域內。`build/cat-render/vps-hosted-cat.png` 是合成的原生測試畫面；真實已連線 VNC 畫面仍需另行驗收。
