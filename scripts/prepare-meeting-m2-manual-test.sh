#!/bin/zsh
# 會議說話者辨識（M2）的「人手測試」準備腳本。只有你自己執行才會動作，CI 與 test-all.sh 不會跑它。
#
#   scripts/prepare-meeting-m2-manual-test.sh            建立測試用會議資料夾並印出逐步說明
#   scripts/prepare-meeting-m2-manual-test.sh --cleanup  刪掉測試資料夾
#
# 它會在 ~/Documents/Neighbor Meetings/ 建立一個名稱帶 TEST-M2 的「被中斷」會議：
#   AMI 公開會議錄音（ES2002a，CC BY 4.0，4 位說話者）前 9 分鐘，切成 3 段 AAC 44.1 kHz／單聲道／64 kbps 的
#   chunk-001…003.m4a，加上 segments.jsonl、manifest.json、transcript.md（diarization: interrupted）。
#   這樣可以跳過錄音與 Groq，直接測試「重新辨識最近一次會議的說話者」那條路。
#   逐字稿文字是合成的（每 10 秒一句 "sentence N"），不是真實辨識結果。
#
# ⚠️ 實驗版與正式版共用同一個 bundle id（tw.panh.FreeVoiceType），所以也共用 UserDefaults 與鑰匙圈（Groq API 金鑰）。
#    測試時會改到「會議說話者辨識（實驗）」這個開關（寫進同一份偏好設定），並把模型下載到
#    ~/Library/Application Support/tw.panh.FreeVoiceType/models/。兩個版本不要同時開著，測完請照最後的說明還原。
#
# 環境變數（可選）：
#   AMI_WAV                 已經有的 ES2002a.Mix-Headset.wav 路徑；沒有就下載並驗證 SHA256
#   NEIGHBOR_MEETINGS_ROOT  會議資料夾的根目錄（預設 ~/Documents/Neighbor Meetings；測試這支腳本時用）
set -euo pipefail

ROOT="${0:A:h:h}"
MEETINGS="${NEIGHBOR_MEETINGS_ROOT:-$HOME/Documents/Neighbor Meetings}"
NAME="2026-11-11_0900-TEST-M2"
TARGET="$MEETINGS/$NAME"
MARKER=".test-m2-marker"
AMI_URL="https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2002a/audio/ES2002a.Mix-Headset.wav"
AMI_SHA="9c76866990fcc8b84006dc32d273ad99df439090b748ebe72103bb78c3216ee7"

if [[ "${1:-}" == "--cleanup" ]]; then
  [[ -d "$TARGET" ]] || { print "沒有測試資料夾：$TARGET（不用清理）"; exit 0; }
  # 只刪「這支腳本建立的」那個資料夾：必須有標記檔，名稱必須完全相同。
  [[ -f "$TARGET/$MARKER" ]] || { print -u2 "拒絕刪除：$TARGET 裡沒有 $MARKER，不是這支腳本建立的。請自行處理。"; exit 1; }
  rm -rf "$TARGET"
  print "已刪除 $TARGET"
  print "還沒還原的部分（腳本不會替你做）："
  print "  • 選單的「會議說話者辨識（實驗）」開關請手動關掉（或：defaults delete tw.panh.FreeVoiceType meetingDiarizationEnabled）"
  print "  • 想移除已下載的模型：rm -r ~/Library/Application\\ Support/tw.panh.FreeVoiceType/models"
  exit 0
fi
[[ $# -eq 0 ]] || { print -u2 "用法：$0 [--cleanup]"; exit 2; }

if [[ -e "$TARGET" ]]; then
  print -u2 "已經有同名資料夾，停止，不覆寫：$TARGET"
  print -u2 "要重做請先執行：$0 --cleanup"
  exit 1
fi
command -v afconvert >/dev/null || { print -u2 "需要 afconvert（macOS 內建）"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. 取得 AMI 音檔（SHA256 驗證）
WAV="${AMI_WAV:-}"
if [[ -z "$WAV" ]]; then
  WAV="$WORK/ES2002a.Mix-Headset.wav"
  print "下載 AMI ES2002a（公開、CC BY 4.0，約 40 MB）…"
  curl -fsSL --retry 3 -o "$WAV" "$AMI_URL"
fi
[[ "$(shasum -a 256 "$WAV" | cut -d' ' -f1)" == "$AMI_SHA" ]] || { print -u2 "SHA256 不符：$WAV"; exit 1; }

# 2. 切成 3 段（各 180 秒）：16 kHz 單聲道 WAV → AAC 44.1 kHz／64 kbps（與 App 的會議錄音格式相同）
afconvert -f WAVE -d LEI16@16000 -c 1 "$WAV" "$WORK/full.wav"
python3 - "$WORK" <<'PY'
import sys, wave
work = sys.argv[1]
with wave.open(f"{work}/full.wav") as w:
    rate = w.getframerate()
    for index in (1, 2, 3):
        data = w.readframes(180 * rate)
        with wave.open(f"{work}/part{index}.wav", "wb") as o:
            o.setnchannels(1); o.setsampwidth(2); o.setframerate(rate); o.writeframes(data)
PY

# 3. 建立資料夾（用 mkdir 不帶 -p：若這一刻剛好被別人建立就失敗，不會覆寫）
mkdir -p "$MEETINGS"
mkdir "$TARGET"
: > "$TARGET/$MARKER"
for index in 1 2 3; do
  afconvert -f m4af -d aac@44100 -c 1 -b 64000 "$WORK/part$index.wav" "$TARGET/chunk-00$index.m4a"
done

python3 - "$TARGET" <<'PY'
import json, sys
target = sys.argv[1]
offsets = {1: 0, 2: 180, 3: 360}
with open(f"{target}/manifest.json", "w") as f:
    json.dump({"version": 1, "chunks": [{"path": f"chunk-00{i}.m4a", "offset": offsets[i]} for i in (1, 2, 3)]}, f, indent=2)
def ts(s): return "%02d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)
records, lines = [], []
for chunk in (1, 2, 3):
    for k in range(18):
        start = offsets[chunk] + k * 10
        n = start // 10 + 1
        records.append({"v": 1, "chunk": chunk, "start": start, "end": start + 9.5, "text": f"sentence {n}"})
        lines.append(f"[{ts(start)}] sentence {n}")
with open(f"{target}/segments.jsonl", "w") as f:
    for r in records: f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
frontmatter = """---
started: 2026-11-11T09:00:00+08:00
ended: 2026-11-11T09:09:00+08:00
status: completed
language: en
chunks: 3
failed_chunks: 0
chunk_seconds: 180
audio: aac-44100-mono-64k
segments: complete
diarization: interrupted
diarization_reason: app-exit
chunk_gap: 每段錄音之間會有約 0.3–0.5 秒沒有錄到（錄音器停止再重新啟動）
timestamps: 每行時間為「整場會議的相對時間」，一行對應 Whisper 的一個 segment，不一定剛好是一句
---

# 會議記錄 2026-11-11 09:00 （TEST-M2：合成逐字稿，不是真實辨識結果）

"""
with open(f"{target}/transcript.md", "w") as f:
    f.write(frontmatter + "\n".join(lines) + "\n")
PY

cat <<MSG

已建立測試會議：$TARGET
  chunk-001…003.m4a、manifest.json、segments.jsonl、transcript.md（diarization: interrupted）、$MARKER

接下來請你自己做（這支腳本不會動你的 App）：

 1. 先結束正式版 AI語音輸入（選單列貓咪圖示 → 結束）。實驗版與正式版是同一個 bundle id，
    共用偏好設定與鑰匙圈，不要同時開著。
 2. 開啟實驗版：$ROOT/build/AI語音輸入.app
    （沒有的話先 ./scripts/build.sh；第一次開可能要「右鍵 → 打開」。）
 3. 點選單列貓咪圖示，應該會看到：
      「上次說話者辨識被中斷，音檔保留中」＋「重新辨識最近一次會議的說話者」＋「刪除這場會議的音檔」
    （這是啟動掃描找到測試資料夾。看不到就是回報問題，請截圖。）
 4. 選單 →「會議說話者辨識（實驗）」→ 先出現隱私說明（會保留音檔）→ 按「開啟」
    → 出現「下載說話者辨識模型」同意視窗（列出 2 個模型、約 35 MB、來源、存放位置、兩個模型的授權（MIT、Apache 2.0））→ 按「下載」
    → 看進度視窗（百分比、可取消）。下載完成後勾選會出現在開關上。
 5. 選單 →「重新辨識最近一次會議的說話者」→ 出現「這場會議有幾個人說話？」→ 選「4 人」→「開始辨識」。
 6. 看選單列：前約 2 分鐘顯示「說話者辨識準備中…」，之後「說話者辨識中 N%」。9 分鐘音訊在 Apple Silicon 約 1–2 分鐘。
 7. 完成後檢查資料夾 $TARGET ：
      transcript.md        每行應該是 [hh:mm:ss] Speaker N：sentence …，frontmatter 有 diarization: done、speakers_mode: fixed
      transcript.plain.md  辨識前的原版（沒有 Speaker）
      speakers.json        辨識程式的原始輸出
      chunk-00*.m4a、manifest.json 應該已被刪除（辨識成功才刪音檔）
    預期會辨識出 3–4 位說話者（AMI 這段實際有 4 位）。
 8. 測完還原：
      $0 --cleanup          # 刪掉測試資料夾
      選單把「會議說話者辨識（實驗）」關掉
      （可選）刪除模型：rm -r ~/Library/Application\ Support/tw.panh.FreeVoiceType/models
      退出實驗版，再開回正式版。

任何一步與上面描述不同（沒看到視窗、文字怪、卡住、當機），請截圖並記下是第幾步。
音檔來源：AMI Meeting Corpus ES2002a（CC BY 4.0，University of Edinburgh 等）。
MSG
