import Foundation

// meeting-diarizer：輸入音檔，輸出「誰在什麼時候說話」的 JSON。
// 這是 S1 驗證用原型，尚未接進 App，也不碰聽寫流程。
//
// 用法：
//   meeting-diarizer --input meeting.m4a --models <dir> --num-speakers 2 > turns.json
//   meeting-diarizer --input meeting.m4a --models <dir> --num-speakers auto [--threshold 1.0]
//   加上 --progress 會在 stderr 每處理完一批就印一行 "progress <已完成>/<總數>"，App 可據此顯示進度條。
//
// --num-speakers N（1–10）：使用者在會議開始時選的人數，結果可靠，建議預設 2。
// --num-speakers auto：使用者選「不確定」。人數由門檻估計，**不準**（S1 實測 4 人會議常判成十幾人），
//                      呼叫端必須在逐字稿上註明「說話者數為自動估計，可能不準」；輸出的 "numSpeakersMode" 為 "auto"。
//
// <dir> 內需要：
//   pyannote-segmentation/model.onnx
//   speaker-embedding.onnx
// 進度與耗時印到 stderr，JSON 印到 stdout。

struct Options {
    var input: String?
    var modelsDirectory: String?
    var numSpeakers: Int? = 2   // nil = auto
    var threshold: Float = 1.0   // 僅 auto 模式使用；S1 實測 4 人會議：0.5→55 人、1.0→10 人、1.2→2 人，沒有可靠值
    var threads = 4
    var reportProgress = false
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--input": options.input = arguments.next()
        case "--models": options.modelsDirectory = arguments.next()
        case "--num-speakers":
            guard let value = arguments.next() else { fail("--num-speakers needs a value") }
            if value == "auto" {
                options.numSpeakers = nil
            } else if let number = Int(value), (1...10).contains(number) {
                options.numSpeakers = number
            } else {
                fail("--num-speakers must be an integer from 1 to 10, or auto")
            }
        case "--progress": options.reportProgress = true
        case "--threshold":
            guard let value = arguments.next(), let number = Float(value), number > 0, number <= 3 else {
                fail("--threshold must be a number greater than 0 and at most 3")
            }
            options.threshold = number
        case "--threads":
            guard let value = arguments.next(), let number = Int(value), (1...16).contains(number) else {
                fail("--threads must be an integer from 1 to 16")
            }
            options.threads = number
        default:
            fail("unknown argument: \(argument)")
        }
    }
    return options
}

struct Turn: Codable {
    let start: Double
    let end: Double
    let speaker: Int
    let label: String
}

struct Output: Codable {
    let durationSeconds: Double
    let numSpeakers: Int
    /// "fixed"：人數由使用者指定；"auto"：人數是自動估計，可能不準。
    let numSpeakersMode: String
    let processingSeconds: Double
    let segments: [Turn]
}

func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

let options = parseOptions()
guard let input = options.input else { fail("--input is required") }
guard let modelsDirectory = options.modelsDirectory else { fail("--models is required") }

let segmentationModel = modelsDirectory + "/pyannote-segmentation/model.onnx"
let embeddingModel = modelsDirectory + "/speaker-embedding.onnx"
for path in [input, segmentationModel, embeddingModel] where !FileManager.default.fileExists(atPath: path) {
    fail("file not found: \(path)", code: 3)
}

let samples: [Float]
do {
    samples = try AudioPCMReader.readMono16k(from: URL(fileURLWithPath: input))
} catch {
    fail("\(error)", code: 4)
}
if samples.isEmpty { fail("audio file has no samples", code: 4) }
let duration = Double(samples.count) / AudioPCMReader.targetSampleRate
FileHandle.standardError.write(Data("decoded \(rounded(duration)) s of audio\n".utf8))

var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
    segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
        pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: segmentationModel),
        numThreads: options.threads),
    embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(model: embeddingModel, numThreads: options.threads),
    clustering: sherpaOnnxFastClusteringConfig(
        numClusters: options.numSpeakers ?? -1, threshold: options.threshold))

let diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
guard diarizer.impl != nil, diarizer.sampleRate == Int(AudioPCMReader.targetSampleRate) else {
    fail("could not create the diarizer (check model files)", code: 5)
}

// 進度回呼必須是不捕獲外部變數的 C 函式。
let reportProgress = options.reportProgress
let progressCallback: SherpaOnnxOfflineSpeakerDiarizationProgressCallback = { done, total, _ in
    FileHandle.standardError.write(Data("progress \(done)/\(total)\n".utf8))
    return 0
}

func runDiarization() -> [SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper] {
    guard reportProgress else { return diarizer.process(samples: samples) }
    guard let result = SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
        diarizer.impl, samples, Int32(samples.count), progressCallback, nil) else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
    let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
    guard let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted) }
    return (0..<count).map {
        SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper(
            start: sorted[$0].start, end: sorted[$0].end, speaker: Int(sorted[$0].speaker))
    }
}

let startedAt = Date()
let turns = runDiarization()
let processing = Date().timeIntervalSince(startedAt)
FileHandle.standardError.write(Data("diarized in \(rounded(processing)) s\n".utf8))

let output = Output(
    durationSeconds: rounded(duration),
    numSpeakers: Set(turns.map(\.speaker)).count,
    numSpeakersMode: options.numSpeakers == nil ? "auto" : "fixed",
    processingSeconds: rounded(processing),
    segments: turns.map {
        Turn(start: rounded(Double($0.start)), end: rounded(Double($0.end)),
             speaker: $0.speaker, label: "Speaker \($0.speaker + 1)")
    })
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try! encoder.encode(output))
FileHandle.standardOutput.write(Data("\n".utf8))
