#!/bin/zsh
# 說話者辨識原型的離線測試（不需要 API Key、不用真人錄音）。
#
# 預設測試（只用 macOS 內建的 say，約 1 分鐘）：
#   Meijia 與 Samantha 交替說 14 句 → 轉成 m4a（AAC 16 kHz 單聲道，和 PinnedMicrophoneRecorder 一樣）
#   → 交給 meeting-diarizer。檢查「管線」是否正確：
#     1. m4a 能解碼，長度與合成音檔相符；
#     2. 每一句話都被偵測成說話段落，邊界落在該句時間內外 0.5 秒；
#     3. JSON 欄位正確、時間排序；
#     4. 壞輸入（不存在、非音訊、缺模型、參數錯誤）以非 0 結束。
#   注意：**這個測試不驗證「分得出兩個人」**。實測（見 docs/spikes/2026-11-diarization-s1.md）
#   sherpa 的聲紋聚類在 say 的合成聲音上不穩定：兩種聲音的聲紋相似度明明只有 0.3（同聲音 0.93），
#   聚類卻常把它們併成 1 人。所以分人準確度改用下面真人語料的選用測試。
#
# 選用測試 AMI=1（下載約 40 MB、處理約 2 分鐘）：
#   AMI Meeting Corpus ES2002a 前 10 分鐘（CC BY 4.0，4 位說話者），人數 = 4，
#   以無損 m4a 輸入，人數 = 4，與參考標註比對，要求判成 4 人、歸屬正確率 ≥ 90%（M1 實測 94.3%）、
#   處理時間 ≤ 180 秒。錄音格式對準確度影響很大，見 docs/spikes/2026-11-diarization-s1.md §4.7。
#
# 檔名刻意不叫 test-*.sh：第一次執行要下載約 70 MB 的 sherpa 與模型，不放進 test-all.sh／CI。
set -euo pipefail

ROOT="${0:A:h:h}"
"$ROOT/scripts/build-meeting-diarizer.sh" >&2
OUT="$ROOT/build/meeting-diarizer"
WORK="$OUT/test"
rm -rf "$WORK" && mkdir -p "$WORK"
TOOL="$OUT/bin/meeting-diarizer"
MODELS="$OUT/assets/models"

for voice in Meijia Samantha; do
  say -v "$voice" "test" -o "$WORK/probe.aiff" 2>/dev/null || { print -u2 "FAIL: voice $voice is not installed (System Settings > Accessibility > Spoken Content)"; exit 1; }
done

# 奇數句 Meijia，偶數句 Samantha
typeset -a VOICES=(Meijia Samantha Meijia Samantha Meijia Samantha Meijia Samantha Meijia Samantha Meijia Samantha Meijia Samantha)
typeset -a SENTENCES=(
  "好，我們先看下週的時程。"
  "I think Friday is possible."
  "測試部門還需要兩天。"
  "Then let's confirm with QA."
  "登入頁面的問題呢？"
  "The fix is almost ready."
  "那我下午回報進度。"
  "Great, I will update the notes."
  "還有預算要確認。"
  "Finance replied this morning."
  "他們怎麼說？"
  "They approved the request."
  "太好了，那就這樣決定。"
  "Sounds good, thank you everyone."
)
for i in {1..14}; do
  say -v "${VOICES[$i]}" "${SENTENCES[$i]}" -o "$WORK/u$i.aiff"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/u$i.aiff" "$WORK/u$i.wav"
done

python3 - "$WORK" <<'PY'
import sys, wave, json
work = sys.argv[1]; rate = 16000; gap = int(rate * 0.4)
frames = b""; spans = []; pos = 0
for i in range(1, 15):
    with wave.open(f"{work}/u{i}.wav") as w:
        assert w.getframerate() == rate and w.getnchannels() == 1
        data = w.readframes(w.getnframes())
    n = len(data) // 2
    spans.append([pos / rate, (pos + n) / rate])
    frames += data + b"\x00\x00" * gap
    pos += n + gap
with wave.open(f"{work}/meeting.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(frames)
json.dump({"spans": spans, "duration": pos / rate}, open(f"{work}/spans.json", "w"))
PY
afconvert -f m4af -d aac@16000 -c 1 -b 32000 "$WORK/meeting.wav" "$WORK/meeting.m4a"

"$TOOL" --input "$WORK/meeting.m4a" --models "$MODELS" --num-speakers 2 > "$WORK/turns.json"

python3 - "$WORK" <<'PY'
import sys, json
work = sys.argv[1]
turns = json.load(open(f"{work}/turns.json"))
ref = json.load(open(f"{work}/spans.json"))
segs = turns["segments"]
assert turns["numSpeakersMode"] == "fixed"
assert abs(turns["durationSeconds"] - ref["duration"]) < 0.5, (turns["durationSeconds"], ref["duration"])
assert segs, "no segments"
last = -1.0
for s in segs:
    assert set(s) == {"start", "end", "speaker", "label"}, s
    assert 0 <= s["start"] < s["end"] <= turns["durationSeconds"] + 0.1, s
    assert s["start"] >= last - 1e-6, "segments not sorted by start"
    last = s["start"]
    assert s["label"] == f"Speaker {s['speaker'] + 1}"
for i, (b, e) in enumerate(ref["spans"], 1):
    covered = sum(max(0.0, min(e, s["end"]) - max(b, s["start"])) for s in segs)
    assert covered >= 0.7 * (e - b), f"utterance {i} ({b:.1f}-{e:.1f}s) only {covered:.1f}s covered"
print("pipeline ok:", len(segs), "segments,", turns["numSpeakers"], "speaker id(s) found,",
      "duration", turns["durationSeconds"], "s, processing", turns["processingSeconds"], "s")
PY

# 壞輸入：不存在的檔案、不是音訊的檔案、缺模型、參數錯誤，都要非 0 結束
! "$TOOL" --input "$WORK/nope.m4a" --models "$MODELS" --num-speakers 2 >/dev/null 2>&1 || { print -u2 "FAIL: missing file should fail"; exit 1; }
print "not audio" > "$WORK/bad.m4a"
! "$TOOL" --input "$WORK/bad.m4a" --models "$MODELS" --num-speakers 2 >/dev/null 2>&1 || { print -u2 "FAIL: bad audio should fail"; exit 1; }
! "$TOOL" --input "$WORK/meeting.m4a" --models "$WORK" --num-speakers 2 >/dev/null 2>&1 || { print -u2 "FAIL: missing models should fail"; exit 1; }
! "$TOOL" --input "$WORK/meeting.m4a" --models "$MODELS" --num-speakers 99 >/dev/null 2>&1 || { print -u2 "FAIL: bad --num-speakers should fail"; exit 1; }
! "$TOOL" --input "$WORK/meeting.m4a" --models "$MODELS" --bogus >/dev/null 2>&1 || { print -u2 "FAIL: unknown flag should fail"; exit 1; }

# auto 模式要能執行，且在輸出標明是自動估計
"$TOOL" --input "$WORK/meeting.m4a" --models "$MODELS" --num-speakers auto > "$WORK/auto.json"
python3 -c "import json,sys; d=json.load(open('$WORK/auto.json')); assert d['numSpeakersMode']=='auto', d"

# --progress：stderr 要有 "progress 已完成/總數"，且 JSON 結果與不開進度時一致
"$TOOL" --input "$WORK/meeting.m4a" --models "$MODELS" --num-speakers 2 --progress > "$WORK/progress.json" 2> "$WORK/progress.err"
grep -Eq '^progress [0-9]+/[0-9]+$' "$WORK/progress.err" || { print -u2 "FAIL: no progress lines"; exit 1; }
python3 - "$WORK" <<'PY'
import sys, json
a = json.load(open(f"{sys.argv[1]}/progress.json")); b = json.load(open(f"{sys.argv[1]}/turns.json"))
assert a["segments"] == b["segments"], "--progress changed the result"
PY

print "meeting diarizer spike test (pipeline) passed"

# --manifest：3 段、段與段之間 0.4 秒縫隙（M1 的 chunk_gap）。
# 對照組是「整場一個 WAV」（時間軸的標準答案）；受測的是「3 個 AAC 44.1 kHz 64 kbps 的段檔＋manifest」。
# 兩者的說話活動時間軸，在每一段的區間內，最佳位移都要 ≤ 50 毫秒。
# 負對照：把 offset 改成不含縫隙的「純接起來」，最後一段必須明顯偏掉（證明這個測試抓得到漂移）。
python3 - "$WORK" <<'PY'
import sys, wave, json
work = sys.argv[1]; rate = 16000; gap = int(rate * 0.4)
groups = [range(1, 5), range(5, 10), range(10, 15)]
manifest = {"version": 1, "chunks": []}; naive = {"version": 1, "chunks": []}
pos = 0; naive_pos = 0.0; regions = []
for ci, g in enumerate(groups, 1):
    data = b""
    for k, i in enumerate(g):
        with wave.open(f"{work}/u{i}.wav") as w: d = w.readframes(w.getnframes())
        data += d + (b"\x00\x00" * gap if k < len(g) - 1 else b"")
    n = len(data) // 2
    with wave.open(f"{work}/chunk-{ci:03d}.wav", "wb") as o:
        o.setnchannels(1); o.setsampwidth(2); o.setframerate(rate); o.writeframes(data)
    manifest["chunks"].append({"path": f"chunk-{ci:03d}.m4a", "offset": pos / rate})
    naive["chunks"].append({"path": f"chunk-{ci:03d}.m4a", "offset": naive_pos})
    regions.append([pos / rate, (pos + n) / rate])
    pos += n + gap; naive_pos += n / rate
json.dump(manifest, open(f"{work}/manifest.json", "w")); json.dump(naive, open(f"{work}/manifest-naive.json", "w"))
json.dump(regions, open(f"{work}/regions.json", "w"))
PY
for i in 1 2 3; do afconvert -f m4af -d aac@44100 -c 1 -b 64000 "$WORK/chunk-00$i.wav" "$WORK/chunk-00$i.m4a"; done

"$TOOL" --input "$WORK/meeting.wav" --models "$MODELS" --num-speakers 2 > "$WORK/ref.json"
"$TOOL" --manifest "$WORK/manifest.json" --models "$MODELS" --num-speakers 2 > "$WORK/manifest-out.json"
"$TOOL" --manifest "$WORK/manifest-naive.json" --models "$MODELS" --num-speakers 2 > "$WORK/naive-out.json"

python3 - "$WORK" <<'PY'
import sys, json
work = sys.argv[1]
ref = json.load(open(f"{work}/ref.json")); got = json.load(open(f"{work}/manifest-out.json")); naive = json.load(open(f"{work}/naive-out.json"))
regions = json.load(open(f"{work}/regions.json"))
assert got["warnings"] == [], got["warnings"]
assert abs(got["durationSeconds"] - ref["durationSeconds"]) < 0.5, (got["durationSeconds"], ref["durationSeconds"])
N = int(ref["durationSeconds"] * 100) + 200
def mask(out):
    m = bytearray(N)
    for s in out["segments"]:
        for f in range(max(0, int(s["start"] * 100)), min(N, int(s["end"] * 100))): m[f] = 1
    return m
def best_lag(a, b, lo, hi, span=100):   # b 相對於 a 的最佳位移（10 毫秒為單位）
    best = None
    for lag in range(-span, span + 1):
        mism = sum(1 for f in range(lo, hi) if 0 <= f + lag < N and a[f] != b[f + lag])
        if best is None or mism < best[1]: best = (lag, mism)
    return best
A, B, C = mask(ref), mask(got), mask(naive)
for i, (b0, e0) in enumerate(regions, 1):
    lo, hi = int(b0 * 100), int(e0 * 100)
    lag, mism = best_lag(A, B, lo, hi)
    print(f"chunk {i}: best shift {lag * 10} ms, {mism} of {hi - lo} frames differ")
    assert abs(lag) * 10 <= 50, f"chunk {i} timestamps are off by {lag * 10} ms"
lo, hi = int(regions[2][0] * 100), int(regions[2][1] * 100)
lag, _ = best_lag(A, C, lo, hi, span=150)
print(f"negative control (no gaps), chunk 3: best shift {lag * 10} ms")
assert abs(lag) * 10 >= 500, "negative control should drift by about 0.8 s; the test cannot see drift"
PY

# manifest 的失敗情境
python3 - "$WORK" <<'PY'
import json, sys
work = sys.argv[1]
m = json.load(open(f"{work}/manifest.json"))
m2 = {"version": 1, "chunks": [m["chunks"][0], {"path": "does-not-exist.m4a", "offset": 300}, m["chunks"][2]]}
json.dump(m2, open(f"{work}/manifest-missing-one.json", "w"))
json.dump({"version": 1, "chunks": [{"path": "nope-1.m4a", "offset": 0}, {"path": "nope-2.m4a", "offset": 5}]}, open(f"{work}/manifest-all-missing.json", "w"))
open(f"{work}/manifest-bad.json", "w").write("{not json")
PY
"$TOOL" --manifest "$WORK/manifest-missing-one.json" --models "$MODELS" --num-speakers 2 > "$WORK/missing-one-out.json" 2>/dev/null
python3 -c "
import json
d = json.load(open('$WORK/missing-one-out.json'))
assert len(d['warnings']) == 1 and 'could not be read' in d['warnings'][0], d['warnings']
assert d['segments'], 'the readable chunks must still be processed'"
! "$TOOL" --manifest "$WORK/manifest-all-missing.json" --models "$MODELS" --num-speakers 2 >/dev/null 2>&1 || { print -u2 "FAIL: all chunks missing should fail"; exit 1; }
! "$TOOL" --manifest "$WORK/manifest-bad.json" --models "$MODELS" --num-speakers 2 >/dev/null 2>&1 || { print -u2 "FAIL: bad manifest should fail"; exit 1; }
! "$TOOL" --manifest "$WORK/manifest.json" --input "$WORK/meeting.m4a" --models "$MODELS" --num-speakers 2 >/dev/null 2>&1 || { print -u2 "FAIL: --input with --manifest should fail"; exit 1; }
print "meeting diarizer spike test (manifest) passed"

if [[ "${AMI:-0}" == "1" ]]; then
  CACHE="$OUT/cache"
  fetch() {  # 名稱 網址 SHA256
    local target="$CACHE/$1"
    if [[ ! -f "$target" || "$(shasum -a 256 "$target" | cut -d' ' -f1)" != "$3" ]]; then
      print -u2 "downloading $1"; curl -fsSL --retry 3 -o "$target.part" "$2"
      [[ "$(shasum -a 256 "$target.part" | cut -d' ' -f1)" == "$3" ]] || { rm -f "$target.part"; print -u2 "FAIL: SHA256 mismatch for $1"; exit 1; }
      mv "$target.part" "$target"
    fi
  }
  fetch ES2002a.Mix-Headset.wav https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2002a/audio/ES2002a.Mix-Headset.wav 9c76866990fcc8b84006dc32d273ad99df439090b748ebe72103bb78c3216ee7
  fetch ES2002a.rttm https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/train/ES2002a.rttm 3153efc675b16b7c47c6e49a3b48602613b3dfcf0ca16f590fb7541176c0f0b2
  afconvert -f WAVE -d LEI16@16000 -c 1 "$CACHE/ES2002a.Mix-Headset.wav" "$WORK/ami-full.wav"
  python3 - "$WORK" <<'PY'
import sys, wave
work = sys.argv[1]
with wave.open(f"{work}/ami-full.wav") as w:
    data = w.readframes(600 * w.getframerate())
    with wave.open(f"{work}/ami10.wav", "wb") as o:
        o.setnchannels(1); o.setsampwidth(2); o.setframerate(w.getframerate()); o.writeframes(data)
PY
  # 無損 m4a（ALAC）。S1 實測同一段音檔：AAC 16 kHz 32 kbps（現行聽寫錄音格式）只有 72.4%，
  # 48 kbps 86.6%，AAC 44.1 kHz 64 kbps 94.8%，ALAC／WAV 94.3%。所以這裡用 ALAC。
  afconvert -f m4af -d alac@16000 -c 1 "$WORK/ami10.wav" "$WORK/ami10.m4a"
  "$TOOL" --input "$WORK/ami10.m4a" --models "$MODELS" --num-speakers 4 > "$WORK/ami.json"
  python3 - "$WORK/ami.json" "$CACHE/ES2002a.rttm" <<'PY'
import sys, json, itertools
# 簡化的歸屬正確率（不是正式 DER）：只算參考標註「同時只有一人說話」的 10 毫秒畫面，最佳一對一對應。
hyp = json.load(open(sys.argv[1])); F = 60000
rows = [l.split() for l in open(sys.argv[2])]
refs = sorted({r[7] for r in rows}); ref = {n: bytearray(F) for n in refs}
for r in rows:
    b = int(float(r[3]) * 100); e = int((float(r[3]) + float(r[4])) * 100)
    for f in range(b, min(e, F)): ref[r[7]][f] = 1
hs = sorted({s["speaker"] for s in hyp["segments"]}); hy = {h: bytearray(F) for h in hs}
for s in hyp["segments"]:
    for f in range(int(s["start"] * 100), min(int(s["end"] * 100), F)): hy[s["speaker"]][f] = 1
single = [f for f in range(F) if sum(ref[n][f] for n in refs) == 1]
M = {(n, h): sum(1 for f in single if ref[n][f] and hy[h][f]) for n in refs for h in hs}
best = max(sum(M[(n, h)] for n, h in zip(refs, perm)) for perm in itertools.permutations(hs, len(refs)))
acc = best / len(single)
print(f"AMI ES2002a 10 min: {len(hs)} speakers found, accuracy {acc*100:.1f}%, processing {hyp['processingSeconds']} s")
assert len(hs) == 4, f"expected 4 speakers, got {len(hs)}"
assert acc >= 0.90, f"accuracy {acc:.3f} < 0.90"
assert hyp["processingSeconds"] <= 180, f"processing {hyp['processingSeconds']} s > 180 s"
PY
  print "meeting diarizer spike test (AMI accuracy) passed"
fi
