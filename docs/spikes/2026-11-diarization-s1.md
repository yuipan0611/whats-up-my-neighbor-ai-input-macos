---
title: S1 說話者辨識可行性（Mac 版）
date: 2026-11-11
owner: Ben
status: 報告完成，原型另見 spike/diarization
tags: [spike, diarization, meeting-notes, sherpa-onnx]
---

# S1 說話者辨識可行性（Mac 版）

## 1. 結論

**可行，但有一個必須處理的條件。**

| 通過標準 | 結果 | 說明 |
|---|---|---|
| 能接進 Swift App | 通過 | sherpa-onnx 有 C API 和官方 Swift 包裝檔，現有 `swiftc` 建置只要加幾個參數 |
| 10 分鐘音檔 ≤ 3 分鐘 | **通過，但餘裕只有約 30%** | M1：實測 125–130 秒（另有一次 56 秒，見 §4.3）。Intel Mac 沒測 |
| 授權允許使用 | 大致通過，**有 1 項發布前必須確認** | 切段模型 MIT、sherpa-onnx Apache-2.0；目前選用的聲紋模型 CAM++ 授權沒查到，備案（TitaNet CC-BY-4.0、WeSpeaker Apache-2.0）見 §3 |
| 說話者數正確 | **只有「事先告訴它人數」才正確** | 讓它自己判斷人數會嚴重切太多（4 人會議判成 55 人）|

**必須處理的兩個條件**：

(1) 錄音格式：現行聽寫的 AAC 16 kHz 32 kbps 會讓準確率從 94.3% 掉到 72.4%，會議錄音要改用 ALAC 或 AAC 44.1 kHz 64 kbps（§4.6）。

(2) 人數：App 要在會議開始時讓使用者選「幾個人」（建議預設 2，可選 2–6）。不給人數時，4 人會議在預設參數下被判成 55 人，調高門檻到 0.9 仍判成 17 人，結果不能用。給了正確人數、且錄音格式夠好（WAV 或無損）時，10 分鐘 AMI 會議的說話者歸屬正確率是 94.3%（M1，簡化指標，見 §4.2）；用現行的 32 kbps AAC 只有 72.4%（§4.6）。

**沒測的事（不要當成已通過）**：
- 中英混用。測試音檔是英文（AMI）。中文只用了一段 57 秒的 4 人樣本，來源授權不明（§4.1）。
- 真實會議（遠場、重疊、咳嗽、背景音）。老闆的真實錄音還沒有。
- Intel Mac、8 GB 以下的記憶體壓力。
- Groq 是否真的回傳 segments／words，要等第一次實際呼叫才能確認（§6）。

## 2. 怎麼接進這個 Swift App

**sherpa-onnx 有什麼**：C API（`libsherpa-onnx-c-api.dylib`）、官方 Swift 包裝檔 `swift-api-examples/SherpaOnnx.swift`（含 `SherpaOnnxOfflineSpeakerDiarizationWrapper`）、一支 `speaker-diarization.swift` 範例。

**macOS 預編譯庫**：release v2.0.1 的 `sherpa-onnx-v2.0.1-osx-universal2-shared-no-tts-lib.tar.bz2`（17.9 MB 壓縮）。我下載後逐一檢查：

| 檔案 | 大小（fat） | arm64 | x86_64 | 最低系統 |
|---|---|---|---|---|
| `libonnxruntime.dylib` | 61.1 MB | 28.8 MB | 32.3 MB | arm64 11.0／x86_64 10.15 |
| `libsherpa-onnx-c-api.dylib` | 7.2 MB | 3.4 MB | 3.7 MB | arm64 11.0／x86_64 10.14 |

最低系統都低於本 App 的 macOS 13，沒有衝突。簽章狀態是 ad-hoc，**不能直接發布**，要用 App 的簽章身分重簽（見下）。

**體積增加**（只計 sherpa 的兩個 dylib，不含模型）：

| 方案 | 安裝後增加 | zip 壓縮後 |
|---|---|---|
| universal（arm64＋x86_64） | 約 68 MB | 約 19.4 MB |
| 只做 arm64 | 約 32 MB | 約 9.0 MB |

我的 Mac 是 M1，Intel 沒測。**目前 `build.sh` 本來就是 arm64＋x86_64 各編一次再 `lipo`**，所以沿用 universal 不改變現有流程；是否值得為 19 MB 保留 Intel，是老闆的取捨（Mac App 的安裝包上限規定我沒看到，待 Emily 確認）。

**對現有 `swiftc` 建置的影響**（我在原型裡驗證）：

1. 每個架構的 `swiftc` 多加：`-import-objc-header <SherpaOnnx-Bridging-Header.h>`、`-I <include 目錄>`、`-L <lib 目錄> -lsherpa-onnx-c-api`，再把 `SherpaOnnx.swift` 加進 `SOURCES`。
2. `build.sh` 已有 `-Xlinker -rpath @executable_path/../Frameworks`，把兩個 dylib `ditto` 進 `Contents/Frameworks` 即可被找到。
3. **簽章與公證**：`release-macos.sh` 用 `codesign --verify --deep --strict` 驗證，但**我沒有確認它會重簽 Frameworks 裡的第三方 dylib**，這一點要在 Senior dev 審查時確認，否則公證會失敗。
4. 不改變聽寫路徑：會議辨識放在獨立檔案，聽寫的編譯單元不需要連結 sherpa（見建議）。

**建議**：先不把 sherpa 連進主 App 執行檔。原型是獨立的命令列工具（`MeetingDiarizer`），主 App 之後用 `Process` 呼叫它、讀 JSON。好處：sherpa 當機不會帶走 App；聽寫完全不受影響；體積只在使用會議功能時才需要下載。缺點：要多管一個執行檔的簽章與更新。這是最保守的做法，等 M1 定案後可再改成同進程連結。

## 3. 模型

| 用途 | 檔案 | 大小 | 授權 | 來源 |
|---|---|---|---|---|
| 切段（誰在說話的時間段）| `sherpa-onnx-pyannote-segmentation-3-0.tar.bz2`（內含 `model.onnx` 6.0 MB、`model.int8.onnx` 1.5 MB）| 6.6 MB | **MIT**（tarball 內 `LICENSE`，Copyright 2022 CNRS，我已讀到）| github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models |
| 聲紋（分辨是誰）| `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` | 28.2 MB | **未完全查證**：3D-Speaker 程式庫是 Apache-2.0（我用 GitHub API 確認），但 sherpa 的 release 頁寫明「每個模型有自己的授權」，ModelScope 頁面我抓不到授權欄 | github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models（網址拼字就是 recongition）|

補充：
- 原始的 pyannote segmentation-3.0 在 Hugging Face 是需要登入同意條款的受限模型。sherpa 轉出的版本在 GitHub 可直接下載，且附 MIT 授權，但這是「轉出版本的授權聲明」，不是我跟 pyannote 確認過的結論。
- **發布前必須確認**：CAM++ zh_en 的授權。這是阻擋正式發布的事項，原型可以先用。

**授權明確的備案聲紋模型**（授權欄位取自 Hugging Face 模型卡；sherpa 的檔案是轉出版本）。同一份 AMI 10 分鐘、人數 = 4：

| 模型 | 大小 | 授權（來源）| 歸屬正確率 | 耗時（M1，有雜訊）|
|---|---|---|---|---|
| CAM++ zh_en（目前選用）| 28.2 MB | **未查證** | 94.3% | 111–130 秒 |
| NeMo TitaNet **small** | 40.3 MB | `nvidia/speakerverification_en_titanet_small` 模型卡**沒有標授權欄**，未查證 | 95.1% | 83／103 秒（兩次）|
| NeMo TitaNet **large** | 96.7 MB | **CC-BY-4.0**（`nvidia/speakerverification_en_titanet_large` 模型卡）| 未測 | 未測 |
| WeSpeaker ResNet34（VoxCeleb，英文）| 26.5 MB | **Apache-2.0**（`Wespeaker/wespeaker-voxceleb-resnet34` 模型卡）| 95.4% | 179／287 秒（**超標**）|
| WeSpeaker ResNet34（CN-Celeb，中文）| 26.5 MB | **Apache-2.0**（`Wespeaker/wespeaker-cnceleb-resnet34` 模型卡）| 92.6% | 238 秒（**超標**，且在英文音檔上測）|

重點：
- 耗時在同一台 M1 上兩次相差到 60%（WeSpeaker 英文 179 秒 vs 287 秒），其中一部分是我同時在跑別的測試，所以只能看量級：**TitaNet small 與 CAM++ 約 1.5–2 分鐘，兩個 WeSpeaker 約 3–5 分鐘**。
- 備案建議：**TitaNet（CC-BY-4.0，需要標示出處）**。small 版速度與準確度都和 CAM++ 相當，但它自己的授權欄沒標，要先查 NVIDIA NGC 頁面確認；若確認不了，就用授權已確認的 large 版（97 MB，沒測速度，預期更慢）。
- WeSpeaker 授權最乾淨（Apache-2.0），但在這台機器上超過 3 分鐘上限，只能當最後備案。
- **限制**：TitaNet 與 VoxCeleb 版 WeSpeaker 是英文模型，中文與中英混用的準確度未知。這些模型的訓練資料集（VoxCeleb、CN-Celeb 等）自己有使用條款，「模型授權」不等於「訓練資料條款沒有問題」，我沒有逐一查，需要法務或 Emily 判斷。
- 共需下載約 35 MB（6.6＋28.2）。
- **保守決定**：模型不放進 App 或 repo，**第一次使用會議功能時才下載**到 `~/Library/Application Support/<App>/Models/`，用寫死的 SHA256 驗證檔案（release 附 `checksum.txt`，但 release tag 是可變的，所以要把雜湊寫進程式）。這樣 App 不「散布」模型，授權風險最小，安裝包也不變大。

## 4. 實測

### 4.1 音檔與授權（逐一列出）

| 音檔 | 授權 | 可否用於測試 | 出處 | 說明 |
|---|---|---|---|---|
| AMI Meeting Corpus，`ES2002a.Mix-Headset.wav`（21 分 12 秒，4 位說話者，英文）| **CC BY 4.0**（AMI 官方授權頁：groups.inf.ed.ac.uk/ami/corpus/license.shtml）| 可，需標示出處 | groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2002a/audio/ | 用於人數與時間的主要測試，前 10 分鐘切出來測 10 分鐘 |
| 參考標註 `ES2002a.rttm` | 衍生自 AMI（CC BY 4.0）| 可 | github.com/pyannote/AMI-diarization-setup（`only_words`）| 只用來算分，沒有 commit |
| sherpa-onnx 範例 `0-four-speakers-zh.wav`（57 秒，4 人，中文）| **沒有找到授權聲明** | 只在本機冒煙測試，**不能當成「公開授權語料」**，不進 repo | sherpa-onnx `speaker-segmentation-models` release | 無標註，只能看人數 |
| AISHELL-4（中文會議，CC BY-SA 4.0，OpenSLR 111）| CC BY-SA 4.0 | 可 | openslr.org/111 | **沒有下載**：測試集 5.2 GB，這次不值得。要補中文，這是建議的第一個語料 |

sherpa 的 speaker-recongition release 內附有名人錄音（fangjun、leijun、liudehua），涉及真實人物，**我沒有使用**。音檔、模型全放在我的暫存目錄，沒有 commit。

### 4.2 測試方法

- 硬體：Apple M1、8 核心、8 GB 記憶體；macOS（Darwin 27.0.0）。
- 軟體：sherpa-onnx 2.0.1 的 Python 套件（CPU，4 執行緒）。這是為了快速試參數，**Swift 版沒有一樣的數據，預期接近但沒量**。
- 處理前轉成 16 kHz 單聲道 WAV（ffmpeg）。
- 指標：我寫的簡化版「歸屬正確率」，**不是正式 DER**：只算參考標註中「同一時刻只有一人說話」的畫面（10 毫秒一格，10 分鐘有 371 秒）；說話者標籤用最佳一對一對應；沒有容忍區間。
- 數字會比正式 DER 好看（排除了重疊與漏偵測），只拿來比較參數，不要當成對外的準確率。

### 4.3 結果（AMI，前 10 分鐘，4 位說話者）

| 嵌入模型／設定 | 判斷人數 | 歸屬正確率 | 耗時 | CPU | 記憶體峰值 |
|---|---|---|---|---|---|
| CAM++ 中英，**不給人數**，門檻 0.5（預設）| **55** | 49.0% | 56 秒 | 371% | 342 MB |
| 同上，門檻 0.7／0.8／0.9 | 32／25／17 | 未算 | 67／83／105 秒 | — | — |
| CAM++ 中英，**人數 = 4** | 4 | **94.3%** | 111／125／130 秒（三次）| ~310% | 191–204 MB |
| ERes2Net base，人數 = 4 | 4 | 95.2% | **268 秒（超標）**| 281% | — |
| CAM++，人數 = 4，切段改 int8、8 執行緒 | 4 | 93.3% | 192 秒（變慢）| 473% | — |
| CAM++，人數 = 4，**整份 21 分 12 秒** | 4 | 96.6% | 337 秒（RTF 0.265）| 264% | — |

觀察：
- 「不給人數」那列只有 56 秒，但結果不能用，所以不能拿來當速度參考；為什麼比給人數快，我沒有查原因。
- 耗時三次不一致（111–130 秒），且我在前兩次旁邊同時在下載檔案，所以**實際範圍用 110–130 秒**，離 180 秒上限約 30%。若老闆的機器較舊或同時在錄音，會失去餘裕。
- 全長 21 分鐘約 5.6 分鐘，所以會議要**結束後在背景處理**，不是邊開會邊出結果。以 RTF 0.265（全長那次）外推，**1 小時會議約 16 分鐘**；原型的 CLI 有 `--progress`，每處理完一批就在 stderr 印 `progress 已完成/總數`，App 可據此顯示進度條。進度條只涵蓋 sherpa 內部的分批階段，最後的聚類階段沒有進度。
- 加執行緒或 int8 沒有幫助，維持 4 執行緒、fp32。

### 4.4 「不確定人數」選項（auto 模式）的實測

同一份 AMI 10 分鐘（真實 4 人），人數交給門檻估計，嵌入模型 CAM++ 中英：

| 門檻 | 判斷人數 | 歸屬正確率（對應到 4 位真人）|
|---|---|---|
| 0.5（預設）| 55 | 49.0% |
| 0.7／0.8／0.9 | 32／25／17 | 未算 |
| 1.0 | 10 | 93.3% |
| 1.2 | 2 | 68.9% |
| 1.5 | 1 | 57.8% |

**沒有可靠的門檻**：同一個門檻在不同音檔會給完全不同的人數，而 1.0 與 1.2 之間人數從 10 掉到 2。原型的 `--num-speakers auto` 預設用 1.0（這份音檔上最好，且歸屬正確率 93.3%，但會多出 6 個零碎的說話者），輸出的 JSON 帶 `"numSpeakersMode": "auto"`，呼叫端必須在逐字稿註明「說話者數為自動估計，可能不準」。**這只在一份英文會議上調過，不能推廣。**

### 4.5 say 合成聲音不能用來驗證「分人」

Emily 要求的測試是用 `say` 的 Meijia／Samantha 交替說話。我照做了，結果：
- 切段（誰在什麼時候說話）完全正確：14 句話的邊界都對。
- 聲紋也分得開：兩種聲音的聲紋相似度只有約 0.3，同一種聲音的各句約 0.93。
- **但聚類常把兩種聲音併成 1 人**：要求 2 人時有時只得到 1 人；同一份音檔要求 3 人反而得到 2 人；調門檻也不穩。這些不是 Swift 的問題，Python 版得到一樣的結果。我的推測（沒有驗證）是 pyannote 切段模型在每 10 秒視窗內給的「區域說話者」對合成聲音不可靠，所以拿去算聲紋的段落混了兩種聲音。
- 因此預設測試只驗證**管線**（解碼、說話段落的邊界、JSON 格式、壞輸入、進度輸出），**分人準確度改用選用測試 `AMI=1`**（真人公開語料，要求 4 人、準確率 ≥ 90%）。這是我跟 Emily 原先要求不同的地方，請知悉。

### 4.6 錄音格式對準確度的影響（重要）

Swift 工具直接吃 WAV 時，結果與 Python 版完全一致（94.3%，各說話者時間相同），代表 Swift 實作沒問題。但同一段 AMI 10 分鐘（人數 = 4）經過不同 m4a 格式再交給工具：

| 輸入格式 | 檔案大小（10 分鐘）| 歸屬正確率 | 耗時 |
|---|---|---|---|
| WAV（16 kHz，參考）| 19.2 MB | 94.3% | 140 秒 |
| **AAC 16 kHz 32 kbps（現行 `PinnedMicrophoneRecorder` 格式）**| 2.5 MB | **72.4%** | 152 秒 |
| AAC 16 kHz 48 kbps（afconvert 在 16 kHz 的上限）| 3.7 MB | 86.6% | 113 秒 |
| AAC 44.1 kHz 64 kbps | 4.7 MB | 94.8% | 83 秒 |
| ALAC（無損）16 kHz | 6.0 MB | 94.3% | 80 秒 |

在 32 kbps 時，其中一位說話者吸走了 358 秒（真實約 115 秒），其他人被併掉。**這代表現行聽寫的錄音格式不適合說話者辨識**；聽寫夠用是因為 Whisper 對壓縮容忍度高。

影響：
- 會議錄音要用另一組格式，建議 **ALAC（約 36 MB／小時）或 AAC 44.1 kHz 64 kbps（約 28 MB／小時）**，而不是現行 32 kbps（約 15 MB／小時）。
- `PinnedMicrophoneRecorder` 規定不准改，所以 `MeetingCoordinator` 需要自己的錄音設定（新檔，或給 recorder 新增可選的格式參數），需 Emily 決定。
- 只測了一份音檔、每種格式各一次，且 AMI 是乾淨的頭戴麥克風混音；真實筆電麥克風會更差。結論是方向性的，不是門檻。
- 傳給 Groq 的 5 分鐘分段不受影響：辨識說話者用整場的高品質檔，Groq 另外吃壓縮後的分段即可（兩者可由同一份錄音轉出）。

### 4.7 中文樣本（57 秒，4 人）

CAM++ 中英、不給人數、預設門檻：判成 4 人，耗時 3.7 秒，記憶體 178 MB。**沒有標註，所以不能說對不對**，只代表「人數合理」。中英混用的準確度仍然未知。

## 5. 錄音格式（m4a → PCM）

`PinnedMicrophoneRecorder` 錄的是 m4a（AAC、16 kHz、單聲道、32 kbps），**這個格式會嚴重拉低辨識準確度（§4.6）**，會議錄音應改用較高品質格式。sherpa-onnx 要 16 kHz 單聲道 Float32（範圍 -1…1）。

做法（用 AVFoundation，不需新依賴）：
1. `AVAudioFile(forReading: url)`，用它的 `processingFormat`（解碼後 Float32）。
2. 若取樣率不是 16 kHz 或不是單聲道，建 `AVAudioConverter` 轉到 `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)`。
3. 分批讀（例如每批 16000×30 個 frame）進 `[Float]`，避免一次分配大 buffer；1 小時 16 kHz Float32 約 230 MB，所以**很長的會議要設上限或分段處理**。
4. 回傳 `[Float]` 給 `SherpaOnnxOfflineSpeakerDiarizationWrapper.process(samples:)`。

這一步已在原型實測：`AudioPCMReader` 讀 AAC m4a、ALAC m4a 都可以，輸出與直接讀 WAV 的結果一致（§4.6）。

## 6. 和 Groq 逐字稿對齊（初稿）

### 6.1 Groq 文件確認

查官方文件（console.groq.com/docs/speech-to-text）：
- `response_format=verbose_json` 回傳 segments，每段有 `id`、`seek`、`start`、`end`、`text`、`tokens`、`temperature`、`avg_logprob`、`compression_ratio`、`no_speech_prob`。
- `timestamp_granularities[]` 可選 `segment`、`word`，可同時要；`word` 回傳 `word`、`start`、`end`。
- 模型：`whisper-large-v3`、`whisper-large-v3-turbo`。檔案上限：免費 25 MB、Dev 100 MB。
- **文件完全沒提說話者辨識**，所以辨識說話者必須自己做。
- 文件範例的 Python 註解寫 `"json"`，與前文 `verbose_json` 要求互相矛盾。**Groq 實際回傳是否如文件所述，要等第一次實際呼叫才能確認**（我沒有用 Key 呼叫）。
- Mac 的 `GroqTranscriptionClient` 已支援 `.verboseWithWords`，結構 `TranscriptionResult.segments／words` 可直接使用。

### 6.2 對齊演算法

**原則**：整場會議的音檔**只做一次**說話者辨識，不要每 5 分鐘一段各自辨識，否則 Speaker 1 在各段指的是不同人。M1 每 5 分鐘切一檔做辨識沒問題，但**說話者辨識要吃整場音訊**（把各段 m4a 解碼後接起來，或另存一份完整錄音）。

輸入：
- `turns`：說話者時間段 `[(start, end, speaker)]`（sherpa 輸出，已依開始時間排序）。
- `words`：Groq 的詞級時間，每段加上該段在整場的起點偏移（`chunkOffset + word.start`）。
- `segments`：Groq 的句段，詞級時間不可用時退回。

步驟：
1. **偏移**：每個 chunk 的 Groq 時間加上 chunk 起點。`AudioSilenceTrimmer` 只裁尾端，不會讓時間往前位移，所以不用修正；若之後增加開頭裁切，偏移要同步。
2. **詞級歸屬**：對每個詞取 `[ws, we]`，找與它重疊時間最長的 turn，該 turn 的 speaker 就是詞的 speaker。沒有重疊時，若最近的 turn 在 1.0 秒內就用它，否則沿用前一個詞的 speaker。
3. **平滑**：單一詞（或不到 0.3 秒）的 speaker 與前後兩側相同、自己不同時，改成兩側的 speaker（Whisper 詞時間有約 ±0.3–0.5 秒誤差，會造成邊界跳動）。
4. **合併**：連續同 speaker 的詞合成一則發言；發言內容用詞串接，標點借用該範圍內的 segment 文字（詞級輸出通常沒標點）。
5. **沒有詞級時間時**（`words` 為空）：以整個 segment 為單位，取重疊最長的 speaker；若 segment 內有第二位說話者重疊 ≥ 1.0 秒，就在該處切成兩段，標「可能混合」。
6. **重疊說話**：sherpa 的 pyannote 切段允許重疊。取多數，不拆；重疊太多的段落標 `(重疊)`。
7. **輸出**：`[mm:ss] Speaker 2：文字`，使用者可改名，只改顯示標籤，不動底層 speaker id。

邊界情況：整段沒有語音（Whisper 幻覺文字）→ 沒有 turn 覆蓋，沿用 `AudioSilenceTrimmer` 的防線，仍標「不明」；辨識出多於選定人數時，歸到最近的一人。

**初稿限制**：我沒有用真實 Groq 輸出測過；等第一次實際呼叫，用 §4 的 AMI 音檔（會先確認授權允許上傳到第三方服務，AMI CC BY 4.0 允許）驗證。

## 7. 保守決定（需要老闆決定、我已先選好）

| 問題 | 我先選的做法 | 原因 |
|---|---|---|
| 人數怎麼來 | 會議開始時使用者選人數（2–6，預設 2），另有「不確定」選項；選「不確定」時逐字稿註明「說話者數為自動估計，可能不準」（Emily 裁示）| 不給人數結果不能用；auto 沒有可靠門檻（§4.4）|
| 模型要不要隨 App 發布 | 不發布，第一次使用才下載並驗 SHA256 | 授權與體積風險最小 |
| 要不要保留 Intel（universal） | 原型只做 arm64，universal 發布前再決定（Emily 裁示）| universal 多 19 MB 壓縮／68 MB 安裝後；`build.sh` 本來就各架構各編一次再 lipo |
| 同進程還是獨立工具 | 獨立命令列工具，由 App 用 `Process` 呼叫 | 當機隔離、聽寫不受影響 |
| 說話者辨識是否上雲端 | 本機 | 不外送錄音；沒有付費預算決定 |

## 8. Windows 待辦（延後）

這次沒做，只記下判斷與證據，之後跟進時照此處理：
- sherpa-onnx NuGet `org.k2fsa.sherpa.onnx` 2.0.1（Apache-2.0）。我下載 `.nupkg` 檢查：`lib/` 下有 `net20`、`net35`、`net40`、`net45`、`netstandard2.0`、`net6.0`…`net10.0`，且 nuspec 為 `.NETFramework2.0/3.5/4.0/4.5` 與 `.NETStandard2.0` 都列了依賴；`net48` 專案能解析到 `net45` 或 `netstandard2.0` 的 DLL。`sherpa-onnx.dll` 內有 `OfflineSpeakerDiarizationConfig` 等說話者辨識 API 符號。
- 原生庫：`org.k2fsa.sherpa.onnx.runtime.win-x64` 的 `runtimes/win-x64/native/` 有 `onnxruntime.dll`（17.8 MB）和 `sherpa-onnx-c-api.dll`（4.3 MB）。
- 現有 `Neighbor.Windows` 是 net48、x64、`RuntimeIdentifier=win-x64` 的 SDK 樣式專案，PackageReference 會把原生 DLL 複製到輸出目錄，預期可用。
- **依套件內容與文件判斷，未實際執行。** 沒有確認：是否需要 VC++ 執行階段、模型載入是否正常。
- **下一步**：新 Windows repo 搬家完成後，在 `spike/diarization` 分支建最小的 net48 x64 console，載入 sherpa-onnx 跑一次說話者辨識，加一個 `workflow_dispatch` 的 `windows-latest` workflow；音檔與模型在 CI 執行時從公開來源下載，不 commit。這同時能實測 net48 與 10 分鐘 ≤ 3 分鐘。

## 9. 下一步

1. Emily 確認上面 §7 的保守決定。
2. **發布前必須確認** 聲紋模型授權（CAM++ 未查證；備案見 §3）。
3. 決定會議錄音格式與錄音器改法（§4.6）。
4. 確認 `release-macos.sh` 會重簽 `Contents/Frameworks` 的第三方 dylib（§2 第 3 點）。
5. 補中文語料：AISHELL-4（CC BY-SA 4.0）取幾段會議，量準確度，並測中英混用。
6. 取得老闆的真實會議錄音（需與會者同意，只放本機）後重跑完整驗收。
7. 原型（獨立 CLI＋離線測試）見 `spike/diarization` 的 PR。
