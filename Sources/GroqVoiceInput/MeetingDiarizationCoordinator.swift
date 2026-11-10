import Foundation

// 會議結束後的說話者辨識（M2）。設計文件：docs/spikes/2026-11-diarization-m2-design.md。
//
// 這個類別只依賴協定（辨識程式的位置、Process 執行器、「問人數」的對話框），沒有 AppKit，
// 所以可以用假的執行器做離線測試。功能由 `SettingsStore.meetingDiarizationEnabled` 控制（預設關閉），
// 開關關閉時 App 不會建立任何東西、也不會碰這個類別。

/// 辨識程式與模型的位置由 `MeetingDiarizerLocator`（Tom，MeetingDiarizerLocator.swift）提供。

enum SpeakerCountChoice: Equatable {
    case count(Int)
    case auto

    static let supportedCounts = 2...6

    /// `--num-speakers` 的值。
    var argument: String {
        switch self {
        case .count(let n): return String(n)
        case .auto: return "auto"
        }
    }

    /// UserDefaults 用：0 = 不確定。
    var stored: Int {
        switch self {
        case .count(let n): return n
        case .auto: return 0
        }
    }

    init?(stored: Int?) {
        guard let stored else { return nil }
        if stored == 0 { self = .auto }
        else if Self.supportedCounts.contains(stored) { self = .count(stored) }
        else { return nil }
    }
}

struct DiarizerRunResult: Equatable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: String
}

/// 執行 `meeting-diarizer`。所有回呼都必須在主執行緒；`cancel()` 之後不得再呼叫任何回呼。
protocol DiarizerProcessRunning {
    func run(executable: URL, arguments: [String],
             onProgress: @escaping (_ done: Int, _ total: Int) -> Void,
             completion: @escaping (Result<DiarizerRunResult, Error>) -> Void) -> DictationCancellable
}

/// `meeting-diarizer` 的 stdout（附錄 A.3）。
struct DiarizerOutput: Decodable, Equatable {
    let numSpeakers: Int
    let numSpeakersMode: String
    let warnings: [String]
    let segments: [SpeakerTurn]
}

enum MeetingDiarizationPhase: Equatable {
    case idle
    /// 正在等使用者選人數。
    case asking
    /// 程式已啟動、還沒有第一筆進度（載入模型與解碼音檔，約前 2 分鐘）。
    case preparing
    case running(done: Int, total: Int)
}

/// 所有狀態與回呼都在主執行緒（每個入口用 `dispatchPrecondition` 強制）。
/// 取消的規則：`cancel()` 會先把世代數加一、改狀態，**然後**才呼叫執行器的 `cancel()`；
/// 之後任何舊世代的回呼（進度、完成、對話框）都直接丟掉，不寫任何檔案。
final class MeetingDiarizationCoordinator {
    private let store: MeetingStore
    private let locator: MeetingDiarizerLocator
    private let runner: DiarizerProcessRunning
    private let modelsDirectory: () -> URL?
    /// 問人數。`last` 是上次的選擇（預設值）；回傳 nil 代表使用者按了「略過」。完成回呼必須在主執行緒。
    private let askSpeakerCount: (_ last: SpeakerCountChoice?, _ completion: @escaping (SpeakerCountChoice?) -> Void) -> Void
    private let loadLastChoice: () -> SpeakerCountChoice?
    private let saveLastChoice: (SpeakerCountChoice) -> Void

    private(set) var phase: MeetingDiarizationPhase = .idle
    /// 最近一場「辨識沒有成功、音檔還在」的會議（失敗／略過／取消）。選單據此提供「刪除這場會議的音檔」。
    private(set) var retainedAudio: (directory: URL, state: MeetingDiarizationState)?
    var onPhaseChange: ((MeetingDiarizationPhase) -> Void)?
    /// 一次辨識到達終態。參數：逐字稿位置、終態。
    var onFinished: ((URL, MeetingDiarizationState) -> Void)?

    private var generation = 0
    private var job: URL?   // transcript.md
    private var token: DictationCancellable?
    /// 辨識開始前的 transcript.md 全文：備份與新版逐字稿都以它為準（之後 frontmatter 會被改成 pending／running）。
    private var originalTranscript: String?

    init(store: MeetingStore, locator: MeetingDiarizerLocator, runner: DiarizerProcessRunning,
         modelsDirectory: @escaping () -> URL?,
         askSpeakerCount: @escaping (SpeakerCountChoice?, @escaping (SpeakerCountChoice?) -> Void) -> Void,
         loadLastChoice: @escaping () -> SpeakerCountChoice? = { nil },
         saveLastChoice: @escaping (SpeakerCountChoice) -> Void = { _ in }) {
        self.store = store
        self.locator = locator
        self.runner = runner
        self.modelsDirectory = modelsDirectory
        self.askSpeakerCount = askSpeakerCount
        self.loadLastChoice = loadLastChoice
        self.saveLastChoice = saveLastChoice
    }

    var isBusy: Bool { phase != .idle }

    // MARK: 開始

    /// 會議逐字稿完成後呼叫。已有辨識在進行時回傳 false。
    @discardableResult
    func begin(transcriptURL: URL) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard phase == .idle else { return false }
        generation += 1
        let mine = generation
        job = transcriptURL
        originalTranscript = try? String(contentsOf: transcriptURL, encoding: .utf8)
        retainedAudio = nil
        let directory = transcriptURL.deletingLastPathComponent()

        // 1. 沒有旁路檔就沒有可對齊的時間資料：不跑（辨識只會白花時間）。
        let segmentsURL = directory.appendingPathComponent(MeetingStore.segmentsFilename)
        let records: [TranscriptSegmentRecord]
        do {
            let text = (try? String(contentsOf: segmentsURL, encoding: .utf8)) ?? ""
            records = try SpeakerAligner.parseSegments(jsonl: text)
        } catch {
            finish(.failed, reason: "segments.jsonl 損毀：\(error)", directory: directory)
            return true
        }
        guard !records.isEmpty else {
            finish(.skipped, reason: "no-segments", directory: directory)
            return true
        }
        // 2. 辨識程式、模型、manifest 都要在。
        guard locator.executableURL() != nil, locator.modelsReady(), modelsDirectory() != nil else {
            finish(.failed, reason: "辨識程式或模型尚未就緒", directory: directory)
            return true
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStore.manifestFilename).path) else {
            finish(.failed, reason: "找不到 manifest.json（這場會議沒有保留音檔）", directory: directory)
            return true
        }
        // 3. 問人數（使用者剛按下結束，用 modal 沒問題）。
        setState(.pending)
        setPhase(.asking)
        askSpeakerCount(loadLastChoice()) { [weak self] choice in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self, self.generation == mine, self.phase == .asking else { return }
            guard let choice else {
                self.finish(.skipped, reason: "user-declined", directory: directory)
                return
            }
            self.saveLastChoice(choice)
            self.launch(choice: choice, records: records, directory: directory, mine: mine)
        }
        return true
    }

    private func launch(choice: SpeakerCountChoice, records: [TranscriptSegmentRecord], directory: URL, mine: Int) {
        guard let executable = locator.executableURL(), let models = modelsDirectory() else {
            finish(.failed, reason: "辨識程式或模型尚未就緒", directory: directory)
            return
        }
        setState(.running)
        setPhase(.preparing)
        let manifest = directory.appendingPathComponent(MeetingStore.manifestFilename)
        let arguments = ["--manifest", manifest.path, "--models", models.path,
                         "--num-speakers", choice.argument, "--progress"]
        let started = runner.run(
            executable: executable, arguments: arguments,
            onProgress: { [weak self] done, total in
                dispatchPrecondition(condition: .onQueue(.main))
                guard let self, self.generation == mine, self.phase != .idle, self.phase != .asking else { return }
                self.setPhase(.running(done: done, total: total))
            },
            completion: { [weak self] result in
                dispatchPrecondition(condition: .onQueue(.main))
                guard let self, self.generation == mine, self.phase != .idle else { return }
                self.token = nil
                self.completed(result, choice: choice, records: records, directory: directory)
            })
        // 同步完成的假執行器已經把 phase 清掉；只有仍在跑的才記住取消把手。
        if generation == mine, phase != .idle { token = started }
    }

    // MARK: 完成

    private func completed(_ result: Result<DiarizerRunResult, Error>, choice: SpeakerCountChoice,
                           records: [TranscriptSegmentRecord], directory: URL) {
        let run: DiarizerRunResult
        switch result {
        case .failure(let error):
            finish(.failed, reason: "無法執行辨識程式：\(error.localizedDescription)", directory: directory)
            return
        case .success(let value):
            run = value
        }
        guard run.exitCode == 0 else {
            let tail = run.standardError.split(separator: "\n").suffix(3).joined(separator: " ")
            finish(.failed, reason: "辨識程式結束碼 \(run.exitCode)\(tail.isEmpty ? "" : "：\(tail)")", directory: directory)
            return
        }
        guard let output = try? JSONDecoder().decode(DiarizerOutput.self, from: run.standardOutput) else {
            finish(.failed, reason: "辨識程式的輸出無法解析", directory: directory)
            return
        }
        do {
            try writeResults(output: output, rawOutput: run.standardOutput, choice: choice, records: records, directory: directory)
        } catch {
            finish(.failed, reason: "寫入新逐字稿失敗：\(error.localizedDescription)", directory: directory)
            return
        }
        // 新逐字稿已寫入並驗證，才刪段檔。
        store.deleteAudio(directory: directory)
        try? store.setFrontmatter([("audio_files", "deleted")], transcriptURL: directory.appendingPathComponent(MeetingStore.transcriptFilename))
        finish(.done, reason: nil, directory: directory, alreadyWritten: true)
    }

    private func writeResults(output: DiarizerOutput, rawOutput: Data, choice: SpeakerCountChoice,
                              records: [TranscriptSegmentRecord], directory: URL) throws {
        let transcriptURL = directory.appendingPathComponent(MeetingStore.transcriptFilename)
        let plainURL = directory.appendingPathComponent(MeetingStore.plainTranscriptFilename)
        guard let original = originalTranscript else { throw CocoaError(.fileReadUnknown) }
        let body = MeetingStore.bodyAfterFrontmatter(original)
        let incomplete = MeetingFrontmatter.value("segments", in: original) != "complete"

        var aligned = SpeakerAligner.align(segments: records, turns: output.segments)
        if incomplete {
            aligned = SpeakerAligner.reconcile(aligned: aligned, records: records,
                                               plain: SpeakerAligner.parsePlainTranscript(body))
        }
        let heading = body.split(separator: "\n").first { $0.hasPrefix("# ") }.map(String.init) ?? "# 會議記錄"
        var text = String(original.dropLast(body.count)) + "\n" + heading + "\n\n"
        if incomplete { text += "> 部分逐字稿行沒有時間資料，已標 Speaker ?\n\n" }
        text += aligned.map { SpeakerAligner.render($0) }.joined(separator: "\n") + "\n"

        var fields: [(String, String)] = [
            ("diarization", MeetingDiarizationState.done.rawValue),
            ("speakers_mode", choice == .auto ? "auto" : "fixed"),
            ("speakers_detected", String(output.numSpeakers)),
        ]
        if incomplete { fields.append(("speakers_note", "部分逐字稿行沒有時間資料，已標 Speaker ?")) }
        for (key, value) in fields { text = MeetingFrontmatter.setting(key, to: value, in: text) }

        // 先備份原版（只備份一次：重新辨識時 plain 已經是最原始的版本），再寫新版，最後讀回驗證。
        if !FileManager.default.fileExists(atPath: plainURL.path) {
            try original.write(to: plainURL, atomically: true, encoding: .utf8)
        }
        try rawOutput.write(to: directory.appendingPathComponent(MeetingStore.speakersFilename), options: .atomic)
        try text.write(to: transcriptURL, atomically: true, encoding: .utf8)
        guard try String(contentsOf: transcriptURL, encoding: .utf8) == text else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: 取消

    /// App 結束或使用者取消。進行中（含正在問人數）才有作用。
    /// 順序：世代加一、狀態改 idle（之後舊回呼全部無效）→ 寫一次 `cancelled` → 最後才通知執行器取消。
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard phase != .idle, let transcript = job else { return }
        generation += 1
        let pending = token
        token = nil
        let directory = transcript.deletingLastPathComponent()
        phase = .idle
        job = nil
        originalTranscript = nil
        try? store.setFrontmatter([("diarization", MeetingDiarizationState.cancelled.rawValue)], transcriptURL: transcript)
        retainedAudio = store.chunkFiles(in: directory).isEmpty ? nil : (directory, .cancelled)
        onPhaseChange?(.idle)
        onFinished?(transcript, .cancelled)
        pending?.cancel()
    }

    /// 使用者在選單選「刪除這場會議的音檔」。
    @discardableResult
    func deleteRetainedAudio() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard phase == .idle, let retained = retainedAudio else { return false }
        store.deleteAudio(directory: retained.directory)
        let transcript = retained.directory.appendingPathComponent(MeetingStore.transcriptFilename)
        try? store.setFrontmatter([("audio_files", "deleted")], transcriptURL: transcript)
        retainedAudio = nil
        return true
    }

    // MARK: 狀態

    private func finish(_ state: MeetingDiarizationState, reason: String?, directory: URL, alreadyWritten: Bool = false) {
        guard let transcript = job else { return }
        if !alreadyWritten {
            var fields = [("diarization", state.rawValue)]
            if let reason { fields.append(("diarization_reason", reason)) }
            try? store.setFrontmatter(fields, transcriptURL: transcript)
        }
        job = nil
        token = nil
        originalTranscript = nil
        phase = .idle
        retainedAudio = state == .done || store.chunkFiles(in: directory).isEmpty ? nil : (directory, state)
        onPhaseChange?(.idle)
        onFinished?(transcript, state)
    }

    private func setState(_ state: MeetingDiarizationState) {
        guard let job else { return }
        try? store.setFrontmatter([("diarization", state.rawValue)], transcriptURL: job)
    }

    private func setPhase(_ new: MeetingDiarizationPhase) {
        guard phase != new else { return }
        phase = new
        onPhaseChange?(new)
    }
}
