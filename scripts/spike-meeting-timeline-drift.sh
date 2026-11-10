#!/bin/zsh
# 12 段（模擬 1 小時：每段 5 分鐘、段間 0.4 秒縫隙）的時間軸漂移測試。
# 不需要 sherpa 或模型，只測「段檔解碼 + 依 offset 放回整場時間軸」這一段：
#   用 AMI ES2002a（CC BY 4.0，下載約 40 MB）切 12 段，編成 AAC 44.1 kHz／64 kbps 的 m4a（和會議錄音規格一樣），
#   以 --manifest 的同一套程式碼串回整場，再和「整場 WAV」逐段做互相關，量三個位置（開頭／中間／結尾）的位移。
# 通過標準：每個位置 |位移| ≤ 5 毫秒，且解碼後每段的樣本數與編碼前相同。
# 負對照：故意把第 2 段（chunk-002）的 offset 加 50 毫秒，檢查器必須量到約 50 毫秒（證明它看得到 50 毫秒的錯）。
# 檔名刻意不叫 test-*.sh：要下載 AMI，不放進 test-all.sh／CI。
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$ROOT/build/meeting-diarizer/drift"
CACHE="$ROOT/build/meeting-diarizer/cache"
SRC="$ROOT/Tools/MeetingDiarizer"
rm -rf "$WORK" && mkdir -p "$WORK" "$CACHE"

AMI="$CACHE/ES2002a.Mix-Headset.wav"
AMI_SHA=9c76866990fcc8b84006dc32d273ad99df439090b748ebe72103bb78c3216ee7
if [[ ! -f "$AMI" || "$(shasum -a 256 "$AMI" | cut -d' ' -f1)" != "$AMI_SHA" ]]; then
  print -u2 "downloading ES2002a.Mix-Headset.wav"
  curl -fsSL --retry 3 -o "$AMI.part" https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2002a/audio/ES2002a.Mix-Headset.wav
  [[ "$(shasum -a 256 "$AMI.part" | cut -d' ' -f1)" == "$AMI_SHA" ]] || { rm -f "$AMI.part"; print -u2 "FAIL: SHA256 mismatch"; exit 1; }
  mv "$AMI.part" "$AMI"
fi
afconvert -f WAVE -d LEI16@16000 -c 1 "$AMI" "$WORK/ami16k.wav"

python3 - "$WORK" <<'PY'
import sys, json, wave, subprocess
work = sys.argv[1]; rate = 16000; chunks = 12; dur = 300; gap = 0.4
src = wave.open(f"{work}/ami16k.wav"); total = src.getnframes() // rate
manifest = {"version": 1, "chunks": []}
ref = wave.open(f"{work}/ref.wav", "wb"); ref.setnchannels(1); ref.setsampwidth(2); ref.setframerate(rate)
pos = 0
for i in range(chunks):
    start = (i * 97) % (total - dur - 1)          # 每段取不同位置，內容不同
    src.setpos(start * rate); data = src.readframes(dur * rate)
    with wave.open(f"{work}/c{i:02d}.wav", "wb") as o:
        o.setnchannels(1); o.setsampwidth(2); o.setframerate(rate); o.writeframes(data)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac@44100", "-c", "1", "-b", "64000",
                    f"{work}/c{i:02d}.wav", f"{work}/chunk-{i + 1:03d}.m4a"], check=True)
    offset = i * (dur + gap); first = round(offset * rate)
    if first > pos: ref.writeframes(b"\x00\x00" * (first - pos)); pos = first
    ref.writeframes(data); pos += len(data) // 2
    manifest["chunks"].append({"path": f"chunk-{i + 1:03d}.m4a", "offset": offset})  # 與 M1 一樣從 chunk-001 起
ref.close(); json.dump(manifest, open(f"{work}/manifest.json", "w"))
shifted = json.loads(json.dumps(manifest)); shifted["chunks"][1]["offset"] += 0.05
json.dump(shifted, open(f"{work}/manifest-shifted.json", "w"))
PY

mkdir -p "$WORK/checker"
cat > "$WORK/checker/main.swift" <<'SWIFT'
import Foundation
import Accelerate

// 用法：checker <manifest.json> <ref.wav>
// 把 manifest 的段檔解碼並依 offset 串回整場，與參考 WAV 逐段互相關，印出每段開頭／中間／結尾的位移（毫秒，+ = 解碼後較晚）。
let rate = 16000, window = 5 * rate, maxLag = rate / 10    // 5 秒窗口、搜尋 ±100 毫秒
let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
let manifest = try MeetingManifest.load(from: manifestURL)
let reference = try AudioPCMReader.readMono16k(from: URL(fileURLWithPath: CommandLine.arguments[2]))
var chunks: [ChunkTimeline.Chunk] = []
var decodedCounts: [Int] = []
for entry in manifest.chunks {
    let samples = try AudioPCMReader.readMono16k(from: manifest.resolvedURL(for: entry, relativeTo: manifestURL))
    decodedCounts.append(samples.count)
    chunks.append(ChunkTimeline.Chunk(samples: samples, offset: entry.offset))
}
let timeline = try ChunkTimeline.assemble(chunks, sampleRate: rate).samples

func lag(at start: Int) -> Double {
    let signal = Array(timeline[(start - maxLag)..<(start + window + maxLag)])
    let filter = Array(reference[start..<(start + window)])
    var result = [Float](repeating: 0, count: 2 * maxLag + 1)
    vDSP_conv(signal, 1, filter, 1, &result, 1, vDSP_Length(result.count), vDSP_Length(window))
    let best = result.indices.max { result[$0] < result[$1] }!
    return Double(best - maxLag) / Double(rate) * 1000
}

var worst = 0.0
print("decoded samples per chunk: \(Set(decodedCounts).sorted())")
print("chunk  offset(s)  lag@start  lag@middle  lag@end   (ms; + = decoded audio is late)")
for (index, entry) in manifest.chunks.enumerated() {
    let first = Int((entry.offset * Double(rate)).rounded())
    let length = decodedCounts[index]
    let positions = [first + maxLag, first + (length - window) / 2, first + length - window - maxLag]
    let lags = positions.map(lag(at:))
    worst = max(worst, lags.map { abs($0) }.max()!)
    print(String(format: "%5d  %9.1f  %9.2f  %10.2f  %8.2f", index + 1, entry.offset, lags[0], lags[1], lags[2]))
}
print(String(format: "worst |lag| = %.2f ms", worst))
SWIFT
swiftc -swift-version 5 -O -framework AVFoundation -framework Accelerate \
  "$SRC/AudioPCMReader.swift" "$SRC/ChunkTimeline.swift" "$SRC/MeetingManifest.swift" "$WORK/checker/main.swift" \
  -o "$WORK/checker/drift-checker" 2>&1 | grep -v "^$" || true

"$WORK/checker/drift-checker" "$WORK/manifest.json" "$WORK/ref.wav" | tee "$WORK/result.txt"
python3 - "$WORK/result.txt" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
counts = re.search(r"decoded samples per chunk: \[(.*?)\]", text).group(1).split(",")
assert len(counts) == 1 and int(counts[0]) == 300 * 16000, f"decoded length changed by the codec: {counts}"
worst = float(re.search(r"worst \|lag\| = ([\d.]+) ms", text).group(1))
assert worst <= 5.0, f"timestamps drift: worst |lag| {worst} ms"
PY

# 負對照：第 2 段的 offset 加 50 毫秒，檢查器要量得到
"$WORK/checker/drift-checker" "$WORK/manifest-shifted.json" "$WORK/ref.wav" > "$WORK/shifted.txt"
python3 - "$WORK/shifted.txt" <<'PY'
import sys
row = [l.split() for l in open(sys.argv[1]) if l.strip().startswith("2 ")][0]
lags = [float(x) for x in row[2:5]]
print("negative control (chunk 2 offset +50 ms): measured", lags)
assert all(abs(abs(v) - 50) <= 2 for v in lags), "the checker cannot see a 50 ms error"
PY
print "meeting timeline drift test passed"
