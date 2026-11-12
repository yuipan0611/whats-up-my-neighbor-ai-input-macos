import Foundation

enum MeetingState: Equatable {
    case idle
    /// 已要求錄音器開始，第一段還沒真的開始寫檔。
    case starting
    case recording
    /// 使用者已按結束：最後一段停止後，等剩下的段辨識完。
    case draining
}

struct MeetingStatus: Equatable {
    let state: MeetingState
    /// 還在排隊或辨識中的段數。
    let pendingChunks: Int
    let failedChunks: Int
}

/// 辨識一段會議錄音。與聽寫的 `DictationTranscribing` 不同：會議需要句級時間，
/// 所以回傳完整的 `TranscriptionResult`（含 segments）。完成回呼在主執行緒。
protocol MeetingTranscribing {
    func transcribe(
        url: URL, language: LanguageSettings,
        completion: @escaping (Result<TranscriptionResult, Error>) -> Void
    ) -> DictationCancellable
}

/// 一場會議：長時間錄音 → 每 `chunkSeconds` 切一段 → 依序辨識 → append 進逐字稿。
///
/// 為什麼不擴充 `DictationCoordinator`：聽寫的承諾（300 秒上限、成功即刪檔、
/// 暫存兩分鐘、只貼不送出）都寫死在那個類別裡，改它等於改聽寫行為。
/// 這裡只重用它的 `DictationRecording` 協定，而且必須拿到**自己專用**的錄音器實例，
/// 不能與聽寫共用。
///
/// 所有呼叫、錄音器事件與辨識完成回呼都在主執行緒（每個入口都用 `dispatchPrecondition` 強制，
/// 違反時直接中止，不會悄悄產生競態）。沒有 AppKit，也不碰金鑰。
final class MeetingCoordinator {
    private struct Chunk {
        let index: Int
        let url: URL
        var startedUptime: TimeInterval?
    }

    private struct PendingChunk {
        let index: Int
        let url: URL
        let offset: TimeInterval
    }

    static let defaultChunkSeconds: TimeInterval = 300
    /// 比這短的最後一段（按結束時剛好剛切段）直接丟掉，不送辨識。
    static let minimumChunkSeconds: TimeInterval = 1

    private let recorder: DictationRecording
    private let transcriber: MeetingTranscribing
    private let store: MeetingStore
    private let now: () -> Date
    /// 單調時鐘。切段間的縫隙也算在時間軸上，所以時間戳不會慢慢漂移。
    private let uptime: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let chunkSeconds: TimeInterval
    private let vocabularyTerms: () -> [String]

    private(set) var state: MeetingState = .idle
    private(set) var failedChunkCount = 0
    var onStatusChange: ((MeetingStatus) -> Void)?
    /// 無法繼續的錯誤（建不了資料夾、錄音器啟動失敗）。單段辨識失敗不走這裡，
    /// 只會標在逐字稿裡並反映在 `failedChunkCount`。
    var onError: ((String) -> Void)?
    /// 逐字稿完成。參數：逐字稿位置、失敗段數。
    var onFinished: ((URL, Int) -> Void)?

    private var session: MeetingSession?
    private var language = LanguageSettings.default
    private var deviceUID = ""
    private var current: Chunk?
    private var nextIndex = 1
    private var meetingStartUptime: TimeInterval?
    private var stopRequested = false
    private var cutToken: UUID?
    private var queue: [PendingChunk] = []
    private var inFlight: PendingChunk?
    private var inFlightToken: DictationCancellable?
    private var totalChunkCount = 0

    init(
        recorder: DictationRecording, transcriber: MeetingTranscribing, store: MeetingStore,
        chunkSeconds: TimeInterval = MeetingCoordinator.defaultChunkSeconds,
        vocabularyTerms: @escaping () -> [String] = { [] },
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.store = store
        self.chunkSeconds = chunkSeconds
        self.vocabularyTerms = vocabularyTerms
        self.now = now
        self.uptime = uptime
        self.schedule = schedule
        recorder.onRecordingStarted = { [weak self] url in self?.recordingStarted(url) }
        recorder.onStartFailed = { [weak self] url, error in self?.recordingStartFailed(url, error: error) }
        recorder.onRecordingFinished = { [weak self] url, error in self?.recordingFinished(url, error: error) }
    }

    var canStart: Bool { state == .idle && !recorder.isBusy }

    var status: MeetingStatus {
        MeetingStatus(state: state, pendingChunks: queue.count + (inFlight == nil ? 0 : 1),
                      failedChunks: failedChunkCount)
    }

    /// 整場會議已經過的秒數；第一段還沒開始寫檔前是 0。
    var elapsed: TimeInterval {
        guard let start = meetingStartUptime, state != .idle else { return 0 }
        return max(0, uptime() - start)
    }

    var transcriptURL: URL? { session?.transcriptURL }

    // MARK: 開始／結束

    @discardableResult
    func start(deviceUID: String, language: LanguageSettings) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard canStart else { return false }
        do {
            session = try store.beginSession(
                startedAt: now(), language: language.primary.rawValue, chunkSeconds: Int(chunkSeconds))
        } catch {
            onError?("無法建立會議資料夾：\(error.localizedDescription)")
            return false
        }
        self.language = language
        self.deviceUID = deviceUID
        resetCounters()
        state = .starting
        notify()
        startNextChunk()
        return true
    }

    /// 使用者結束會議。最後一段停止後，剩下的段會繼續辨識，全部完成才算結束。
    @discardableResult
    func stop() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .starting || state == .recording, !stopRequested else { return false }
        stopRequested = true
        cutToken = nil
        state = .draining
        notify()
        // 尚未真的開始寫檔的段，等 recordingStarted 再停。
        if current?.startedUptime != nil { recorder.stop() }
        return true
    }

    /// App 結束時呼叫：不等辨識，把還沒處理的段在逐字稿裡標出來，檔案保留。
    func shutdown() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .idle, let session else { return }
        cutToken = nil
        inFlightToken?.cancel()
        recorder.shutdown()
        if let current {
            record(failure: "App 結束時正在錄音，音檔可能不完整", index: current.index,
                   offset: offset(of: current), audioKept: true)
        }
        var abandoned = queue
        if let inFlight { abandoned.insert(inFlight, at: 0) }
        for chunk in abandoned {
            record(failure: "App 結束前尚未辨識", index: chunk.index, offset: chunk.offset, audioKept: true)
        }
        try? store.endSession(session, endedAt: now(), chunks: totalChunkCount,
                              failedChunks: failedChunkCount, status: "interrupted")
        current = nil
        queue = []
        inFlight = nil
        inFlightToken = nil
        state = .idle
        stopRequested = false
        notify()
    }

    // MARK: 錄音器事件

    private func recordingStarted(_ url: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .idle, current?.url == url else { return }
        let started = uptime()
        current?.startedUptime = started
        if meetingStartUptime == nil { meetingStartUptime = started }
        if stopRequested {
            recorder.stop()
            return
        }
        if state == .starting {
            state = .recording
            notify()
        }
        let token = UUID()
        cutToken = token
        schedule(chunkSeconds) { [weak self] in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self, self.cutToken == token else { return }
            self.cutToken = nil
            // 硬切：停掉這一段，recordingFinished 之後立刻開下一段。
            self.recorder.stop()
        }
    }

    private func recordingStartFailed(_ url: URL, error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .idle, current?.url == url else { return }
        current = nil
        let firstChunk = meetingStartUptime == nil
        let reason = error.localizedDescription
        onError?(firstChunk ? "無法開始會議錄音：\(reason)" : "會議錄音中斷：\(reason)。已錄下的內容會保留在逐字稿。")
        stopRequested = true
        cutToken = nil
        state = .draining
        notify()
        finishIfDrained()
    }

    private func recordingFinished(_ url: URL, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .idle, let chunk = current, chunk.url == url else { return }
        current = nil
        cutToken = nil
        let offset = offset(of: chunk)
        let duration = chunk.startedUptime.map { uptime() - $0 } ?? 0

        if let error {
            // 錄音器說這一段不可用：沒有東西可辨識，也不留半截檔。
            try? FileManager.default.removeItem(at: url)
            totalChunkCount += 1
            record(failure: "錄音檔不可用（\(error.localizedDescription)）", index: chunk.index,
                   offset: offset, audioKept: false)
        } else if stopRequested && duration < Self.minimumChunkSeconds {
            try? FileManager.default.removeItem(at: url)
        } else {
            totalChunkCount += 1
            queue.append(PendingChunk(index: chunk.index, url: url, offset: offset))
            pumpQueue()
        }

        if stopRequested {
            finishIfDrained()
        } else {
            startNextChunk()
        }
        notify()
    }

    // MARK: 內部流程

    private func startNextChunk() {
        let index = nextIndex
        nextIndex += 1
        let url = store.chunkURL(session!, index: index)
        current = Chunk(index: index, url: url, startedUptime: nil)
        recorder.start(deviceUID: deviceUID, url: url)
    }

    private func pumpQueue() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        inFlight = next
        notify()
        let token = transcriber.transcribe(url: next.url, language: language) { [weak self] result in
            self?.transcriptionFinished(next, result: result)
        }
        // 同步完成的假辨識器已經清掉 inFlight；只有仍在等的才記住取消把手。
        if inFlight?.index == next.index { inFlightToken = token }
    }

    private func transcriptionFinished(_ chunk: PendingChunk, result: Result<TranscriptionResult, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard inFlight?.index == chunk.index, let session else { return }
        inFlight = nil
        inFlightToken = nil
        switch result {
        case .success(let value):
            do {
                try store.appendChunk(session, offset: chunk.offset, lines: lines(from: value, offset: chunk.offset))
                try? FileManager.default.removeItem(at: chunk.url)
            } catch {
                record(failure: "寫入逐字稿失敗（\(error.localizedDescription)）", index: chunk.index,
                       offset: chunk.offset, audioKept: true)
            }
        case .failure(let error):
            record(failure: error.localizedDescription, index: chunk.index,
                   offset: chunk.offset, audioKept: true)
        }
        pumpQueue()
        finishIfDrained()
        notify()
    }

    /// 逐行寫入前，套用與聽寫相同的 `TextPostProcessor`，但固定用純逐字模式：
    /// 簡轉繁、標點正規化、空白整理、詞庫大小寫修正；不刪語助詞（會議逐字稿要保留原話）。
    /// 聽寫的「中文數字轉阿拉伯」是使用者設定，會議不套用，避免改動數字與日期。
    private func clean(_ raw: String) -> String {
        TextPostProcessor.process(
            raw, mode: .verbatim, vocabulary: vocabularyTerms(),
            applyChineseRules: language.primary.usesChineseTextRules,
            convertChineseNumerals: false)
    }

    private func lines(from result: TranscriptionResult, offset: TimeInterval) -> [MeetingLine] {
        let fromSegments = result.segments.compactMap { segment -> MeetingLine? in
            let text = clean(segment.text)
            return text.isEmpty ? nil : MeetingLine(offset: offset + segment.start, text: text)
        }
        if !fromSegments.isEmpty { return fromSegments }
        let whole = clean(result.text)
        return whole.isEmpty ? [] : [MeetingLine(offset: offset, text: whole)]
    }

    private func record(failure reason: String, index: Int, offset: TimeInterval, audioKept: Bool) {
        failedChunkCount += 1
        guard let session else { return }
        try? store.markChunkFailed(session, index: index, offset: offset, reason: reason, audioKept: audioKept)
    }

    private func offset(of chunk: Chunk) -> TimeInterval {
        guard let start = chunk.startedUptime, let origin = meetingStartUptime else { return 0 }
        return max(0, start - origin)
    }

    private func finishIfDrained() {
        guard state == .draining, stopRequested, current == nil, queue.isEmpty, inFlight == nil,
              let session else { return }
        do {
            try store.endSession(session, endedAt: now(), chunks: totalChunkCount, failedChunks: failedChunkCount)
        } catch {
            onError?("無法完成逐字稿：\(error.localizedDescription)")
        }
        let failed = failedChunkCount
        let recordedAnything = totalChunkCount > 0
        if !recordedAnything { store.discardIfEmpty(session) }
        state = .idle
        stopRequested = false
        notify()
        // 一段都沒錄到時沒有逐字稿可通知。
        if recordedAnything { onFinished?(session.transcriptURL, failed) }
    }

    private func resetCounters() {
        current = nil
        nextIndex = 1
        meetingStartUptime = nil
        stopRequested = false
        cutToken = nil
        queue = []
        inFlight = nil
        inFlightToken = nil
        failedChunkCount = 0
        totalChunkCount = 0
    }

    private func notify() { onStatusChange?(status) }
}
