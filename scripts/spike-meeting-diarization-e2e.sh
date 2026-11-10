#!/bin/zsh
# 選用的端到端測試（不放進 test-all.sh，不在 CI 跑）：真的 meeting-diarizer ＋ 真的模型 ＋ AMI 10 分鐘會議，
# 走完 App 端整條路（MeetingDiarizationCoordinator ＋ 真的 Process 執行器）。約 2–3 分鐘。
#
#   AMI=1 scripts/spike-meeting-diarization-e2e.sh
#
# 需要先有 #49（spike/diarization）的產物：scripts/fetch-meeting-diarizer-assets.sh 與
# scripts/build-meeting-diarizer.sh 產生的 build/meeting-diarizer/（bin、assets/models、cache 的 AMI 檔案）。
# 也可以用 MEETING_DIARIZER_HOME 指到別處。沒有 AMI=1 時什麼都不做。
set -euo pipefail

if [[ "${AMI:-0}" != "1" ]]; then
  print "skipped (set AMI=1 to run the end-to-end diarization test)"
  exit 0
fi

ROOT="${0:A:h:h}"
HOME_DIR="${MEETING_DIARIZER_HOME:-$ROOT/build/meeting-diarizer}"
TOOL="$HOME_DIR/bin/meeting-diarizer"
MODELS="$HOME_DIR/assets/models"
WAV="$HOME_DIR/cache/ES2002a.Mix-Headset.wav"
RTTM="$HOME_DIR/cache/ES2002a.rttm"
for required in "$TOOL" "$MODELS" "$WAV" "$RTTM"; do
  [[ -e "$required" ]] || { print -u2 "missing $required — build the tool and run the AMI=1 test of scripts/spike-meeting-diarizer-test.sh first (PR #49)"; exit 1; }
done

WORK="$ROOT/build/MeetingDiarizationE2E-work"
HARNESS="$ROOT/build/MeetingDiarizationE2E"
mkdir -p "$ROOT/build"
rm -rf "$WORK"; mkdir -p "$WORK"

swiftc -swift-version 5 \
  "$ROOT/Sources/GroqVoiceInput/LanguagePolicy.swift" \
  "$ROOT/Sources/GroqVoiceInput/TextPostProcessor.swift" \
  "$ROOT/Sources/GroqVoiceInput/DictationCoordinator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingStore.swift" \
  "$ROOT/Sources/GroqVoiceInput/SpeakerAligner.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizationFiles.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizationCoordinator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerProcess.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingAudio.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerLocator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerAssets.swift" \
  "$ROOT/Tests/MeetingDiarizationE2E.swift" \
  -o "$HARNESS"

# 前 10 分鐘，切成兩個 5 分鐘段檔，編成與 App 相同的格式（AAC 44.1 kHz／單聲道／64 kbps）。
afconvert -f WAVE -d LEI16@16000 -c 1 "$WAV" "$WORK/full.wav"
python3 - "$WORK" <<'PY'
import sys, wave
work = sys.argv[1]
with wave.open(f"{work}/full.wav") as w:
    rate = w.getframerate()
    for index in (1, 2):
        data = w.readframes(300 * rate)
        with wave.open(f"{work}/half{index}.wav", "wb") as o:
            o.setnchannels(1); o.setsampwidth(2); o.setframerate(rate); o.writeframes(data)
PY
mkdir -p "$WORK/chunks"
for index in 1 2; do
  afconvert -f m4af -d aac@44100 -c 1 -b 64000 "$WORK/half$index.wav" "$WORK/chunks/chunk-00$index.m4a"
done

"$HARNESS" "$WORK/chunks" "$TOOL" "$MODELS" 600 4 | tee "$WORK/out.txt"
DIR="$(sed -n 's/^DIR //p' "$WORK/out.txt")"
grep -q '^STATE done$' "$WORK/out.txt" || { print -u2 "FAIL: diarization did not finish as done"; exit 1; }

[[ -f "$DIR/transcript.plain.md" ]] || { print -u2 "FAIL: no backup"; exit 1; }
[[ ! -e "$DIR/chunk-001.m4a" && ! -e "$DIR/chunk-002.m4a" && ! -e "$DIR/manifest.json" ]] || { print -u2 "FAIL: audio not deleted"; exit 1; }
[[ -f "$DIR/speakers.json" && -f "$DIR/segments.jsonl" ]] || { print -u2 "FAIL: speakers.json / segments.jsonl missing"; exit 1; }
grep -q '^diarization: done$' "$DIR/transcript.md" || { print -u2 "FAIL: frontmatter"; exit 1; }

python3 - "$DIR/transcript.md" "$RTTM" <<'PY'
import re, sys
from collections import Counter, defaultdict
lines = [l for l in open(sys.argv[1], encoding="utf-8") if re.match(r"\[\d\d:\d\d:\d\d\] ", l)]
ref = []
for l in open(sys.argv[2]):
    p = l.split()
    if p and p[0] == "SPEAKER": ref.append((float(p[3]), float(p[3]) + float(p[4]), p[7]))
def dominant(a, b):
    c = Counter()
    for s, e, spk in ref:
        o = min(b, e) - max(a, s)
        if o > 0: c[spk] += o
    if len(c) != 1: return None   # 只看「這 9.5 秒內只有一個人在說話」的句子
    return next(iter(c))
pairs = []
for l in lines:
    m = re.match(r"\[(\d\d):(\d\d):(\d\d)\] (Speaker \S+)：sentence (\d+)", l)
    if not m: sys.exit(f"FAIL: line without a speaker label: {l!r}")
    start = (int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3]))
    r = dominant(start, start + 9.5)
    if r: pairs.append((m[4], r))
if len(lines) != 60: sys.exit(f"FAIL: expected 60 lines, got {len(lines)}")
hyp = {h for h, _ in pairs}
if len(hyp) < 3: sys.exit(f"FAIL: only {len(hyp)} speakers in the transcript")
# 每個辨識出的說話者對應到最常重疊的參考說話者（人數相同時足夠；這是粗略的整合檢查，不是 DER）。
conf = defaultdict(Counter)
for h, r in pairs: conf[h][r] += 1
correct = sum(c.most_common(1)[0][1] for c in conf.values())
acc = correct / len(pairs)
print(f"AMI e2e: {len(lines)} lines, {len(hyp)} speakers, {len(pairs)} single-speaker lines, attribution {acc*100:.1f}%")
if acc < 0.85: sys.exit(f"FAIL: attribution {acc*100:.1f}% < 85%")
PY
print "meeting diarization end-to-end test passed"
