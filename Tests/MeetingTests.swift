import Foundation

// MARK: - 測試替身

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class FakeRecorder: DictationRecording {
    var onRecordingStarted: ((URL) -> Void)?
    var onRecordingFinished: ((URL, Error?) -> Void)?
    var onStartFailed: ((URL, Error) -> Void)?
    var isBusy = false
    var averagePowerLevel: Float = -60
    var starts: [URL] = []
    var stopCount = 0
    var shutdownCount = 0

    func start(deviceUID: String, url: URL) { starts.append(url) }
    func stop() { stopCount += 1 }
    func shutdown() { shutdownCount += 1 }

    /// 模擬錄音器真的開始寫檔，並放一個假檔案。
    func started(_ url: URL) {
        try? Data([1, 2, 3]).write(to: url)
        onRecordingStarted?(url)
    }
    func finish(_ url: URL, error: Error? = nil) { onRecordingFinished?(url, error) }
    func failStart(_ url: URL, _ message: String) { onStartFailed?(url, StubError(message: message)) }
}

private final class FakeToken: DictationCancellable {
    var cancelCount = 0
    func cancel() { cancelCount += 1 }
}

private final class FakeTranscriber: MeetingTranscribing {
    struct Call {
        let url: URL
        let token: FakeToken
        let completion: (Result<TranscriptionResult, Error>) -> Void
    }
    var calls: [Call] = []
    var synchronousResults: [Result<TranscriptionResult, Error>] = []

    func transcribe(url: URL, language: LanguageSettings,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) -> DictationCancellable {
        let token = FakeToken()
        if !synchronousResults.isEmpty {
            calls.append(Call(url: url, token: token, completion: completion))
            completion(synchronousResults.removeFirst())
        } else {
            calls.append(Call(url: url, token: token, completion: completion))
        }
        return token
    }

    func complete(_ index: Int, _ result: Result<TranscriptionResult, Error>) { calls[index].completion(result) }
}

private func result(_ segments: [(Double, String)], text: String? = nil) -> TranscriptionResult {
    let parsed = segments.enumerated().map { index, item in
        TranscriptionSegment(id: index, start: item.0, end: item.0 + 2, text: item.1,
                             avgLogprob: nil, noSpeechProb: nil)
    }
    return TranscriptionResult(text: text ?? segments.map(\.1).joined(), segments: parsed, words: [],
                               language: "zh", duration: nil)
}

private final class Fixture {
    let directory: URL
    let store: MeetingStore
    let recorder = FakeRecorder()
    let transcriber = FakeTranscriber()
    var uptime: TimeInterval = 0
    var scheduled: [(delay: TimeInterval, action: () -> Void)] = []
    var errors: [String] = []
    var finished: [(URL, Int)] = []
    var statuses: [MeetingStatus] = []
    let coordinator: MeetingCoordinator

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        store = MeetingStore(root: directory, timeZone: TimeZone(identifier: "UTC")!)
        let recorder = self.recorder
        let transcriber = self.transcriber
        let store = self.store
        var clock: () -> TimeInterval = { 0 }
        var schedule: (TimeInterval, @escaping () -> Void) -> Void = { _, _ in }
        coordinator = MeetingCoordinator(
            recorder: recorder, transcriber: transcriber, store: store,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            uptime: { clock() },
            schedule: { delay, action in schedule(delay, action) })
        clock = { [unowned self] in self.uptime }
        schedule = { [unowned self] delay, action in self.scheduled.append((delay, action)) }
        // 上面兩個閉包在 init 之後才綁定：MeetingCoordinator 存的是外層 closure，會讀到新值。
        coordinator.onError = { [unowned self] in self.errors.append($0) }
        coordinator.onFinished = { [unowned self] in self.finished.append(($0, $1)) }
        coordinator.onStatusChange = { [unowned self] in self.statuses.append($0) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var transcript: String {
        guard let url = store.latestTranscriptURL() else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

// MARK: - 測試

@main
enum MeetingTests {
    static func main() throws {
        testTimestampFormatting()
        try testStoreSessionLifecycle()
        try testStoreNeverEscapesRootAndNeverOverwrites()
        testThreeChunksWithFailureInTheMiddle()
        testStopWaitsForQueuedTranscriptions()
        testTooShortFinalChunkIsDropped()
        testStopBeforeFirstChunkStarts()
        testStartFailureOnFirstChunkLeavesNothing()
        testStartFailureLaterKeepsEarlierContent()
        testUnusableRecordingIsMarkedAndMeetingContinues()
        testSynchronousTranscriber()
        testStaleRecorderCallbacksAreIgnored()
        testShutdownMarksUnfinishedChunks()
        testCannotStartWhileRecorderBusyOrActive()
        print("Meeting tests passed (14 scenarios)")
    }

    static func testTimestampFormatting() {
        expect(MeetingStore.timestamp(0) == "00:00:00", "zero")
        expect(MeetingStore.timestamp(300.9) == "00:05:00", "floor")
        expect(MeetingStore.timestamp(3725) == "01:02:05", "hours")
        expect(MeetingStore.timestamp(-5) == "00:00:00", "negative")
        expect(MeetingStore.timestamp(.nan) == "00:00:00", "nan")
    }

    static func testStoreSessionLifecycle() throws {
        let f = Fixture()
        let session = try f.store.beginSession(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), language: "zh", chunkSeconds: 300)
        let started = try String(contentsOf: session.transcriptURL, encoding: .utf8)
        expect(started.hasPrefix("---\nstarted: 2027-01-15T08:00:00Z\nended: in-progress\n"), "frontmatter at start")
        expect(started.contains("status: recording") && started.contains("# 會議記錄 2027-01-15 08:00"), "title")
        expect(session.directory.lastPathComponent == "2027-01-15_0800", "folder name")

        try f.store.appendChunk(session, offset: 0, lines: [
            MeetingLine(offset: 0, text: "第一句，含 Grokbot 與 yui"),
            MeetingLine(offset: 4.7, text: "  第二句\n換行要收成一行  "),
        ])
        try f.store.appendChunk(session, offset: 300, lines: [])
        try f.store.markChunkFailed(session, index: 3, offset: 600, reason: "HTTP 429\nrate limit", audioKept: true)
        let body = try String(contentsOf: session.transcriptURL, encoding: .utf8)
        let first = body.range(of: "[00:00:00] 第一句，含 Grokbot 與 yui")
        let second = body.range(of: "[00:00:04] 第二句 換行要收成一行")
        let empty = body.range(of: "> [00:05:00] （這段沒有辨識到內容）")
        let failed = body.range(of: "> ⚠️ [00:10:00] 第 3 段辨識失敗：HTTP 429 rate limit。音檔保留：chunk-003.m4a")
        expect(first != nil && second != nil && empty != nil && failed != nil, "all lines present: \(body)")
        expect(first!.lowerBound < second!.lowerBound && second!.lowerBound < empty!.lowerBound
               && empty!.lowerBound < failed!.lowerBound, "append order")

        let end = Date(timeIntervalSince1970: 1_800_002_560)
        try f.store.endSession(session, endedAt: end, chunks: 3, failedChunks: 1)
        try f.store.endSession(session, endedAt: end, chunks: 3, failedChunks: 1) // 重複結束不壞檔
        let final = try String(contentsOf: session.transcriptURL, encoding: .utf8)
        expect(final.contains("ended: 2027-01-15T08:42:40Z") && final.contains("status: completed"), "ended")
        expect(final.contains("chunks: 3\nfailed_chunks: 1\n"), "counts")
        expect(final.components(separatedBy: "\n---\n").count == 2, "exactly one frontmatter block")
        expect(final.contains("[00:00:00] 第一句，含 Grokbot 與 yui") && final.contains("音檔保留：chunk-003.m4a"),
               "body untouched by end")
        expect(f.store.latestTranscriptURL() == session.transcriptURL, "latest transcript")
    }

    static func testStoreNeverEscapesRootAndNeverOverwrites() throws {
        let f = Fixture()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try f.store.beginSession(startedAt: date, language: "zh", chunkSeconds: 300)
        let b = try f.store.beginSession(startedAt: date, language: "zh", chunkSeconds: 300)
        expect(a.directory != b.directory && b.directory.lastPathComponent == "2027-01-15_0800-2", "no overwrite")
        for session in [a, b] {
            for index in [-5, 0, 1, 999, 12345] {
                let url = f.store.chunkURL(session, index: index)
                expect(url.deletingLastPathComponent() == session.directory, "chunk stays inside session")
                expect(!url.lastPathComponent.contains("/") && !url.lastPathComponent.contains(".."), "plain filename")
            }
        }
        expect(f.store.latestTranscriptURL() == b.transcriptURL, "suffix sorts after base")
        f.store.discardIfEmpty(a)
        expect(!f.exists(a.directory), "empty session removed")
        let c = try f.store.beginSession(startedAt: date, language: "zh", chunkSeconds: 300)
        try Data([1]).write(to: f.store.chunkURL(c, index: 1))
        f.store.discardIfEmpty(c)
        expect(f.exists(c.directory), "folder with kept audio is never removed")
    }

    // 3 段正常切段；第 2 段辨識失敗，第 3 段照常寫入；時間軸包含切段縫隙。
    static func testThreeChunksWithFailureInTheMiddle() {
        let f = Fixture()
        expect(f.coordinator.start(deviceUID: "mic", language: .default), "start")
        expect(f.coordinator.state == .starting, "starting")
        let c1 = f.recorder.starts[0]
        expect(c1.lastPathComponent == "chunk-001.m4a", "first chunk name")

        f.uptime = 100
        f.recorder.started(c1)
        expect(f.coordinator.state == .recording && f.scheduled.count == 1 && f.scheduled[0].delay == 300, "5 min cut scheduled")
        f.uptime = 250
        expect(f.coordinator.elapsed == 150, "elapsed since first byte")

        f.uptime = 400
        f.scheduled[0].action()
        expect(f.recorder.stopCount == 1, "hard cut stops recorder")
        f.recorder.finish(c1)
        expect(f.transcriber.calls.count == 1 && f.recorder.starts.count == 2, "chunk 1 queued, chunk 2 started")
        let c2 = f.recorder.starts[1]
        f.uptime = 400.4
        f.recorder.started(c2)
        f.transcriber.complete(0, .success(result([(0, "大家好，今天聊 Grokbot"), (4.2, "yui 說 claudecode")])))
        expect(!f.exists(c1), "successful chunk deleted")

        f.uptime = 700.4
        f.scheduled[1].action()
        f.recorder.finish(c2)
        let c3 = f.recorder.starts[2]
        f.uptime = 700.9
        f.recorder.started(c3)
        f.transcriber.complete(1, .failure(StubError(message: "Rate limit reached")))
        expect(f.exists(c2), "failed chunk audio kept")
        expect(f.coordinator.failedChunkCount == 1, "failed count")

        f.uptime = 710
        expect(f.coordinator.stop(), "stop")
        expect(f.coordinator.state == .draining && f.recorder.stopCount == 3, "draining, recorder stopped")
        f.recorder.finish(c3)
        expect(f.transcriber.calls.count == 3, "final chunk queued")
        f.transcriber.complete(2, .success(result([(1.5, "Stack 與 DeepseekHarness")])))

        expect(f.coordinator.state == .idle, "idle after drain")
        expect(f.finished.count == 1 && f.finished[0].1 == 1, "finished once with 1 failure")
        expect(!f.exists(c3), "last chunk deleted")
        let text = f.transcript
        expect(text.contains("[00:00:00] 大家好，今天聊 Grokbot"), "chunk1 line 1: \(text)")
        expect(text.contains("[00:00:04] yui 說 claudecode"), "chunk1 line 2")
        // chunk 2 起點 = 400.4 - 100 = 300.4；chunk 3 = 700.9 - 100 = 600.9，+1.5 = 602.4
        expect(text.contains("> ⚠️ [00:05:00] 第 2 段辨識失敗：Rate limit reached。音檔保留：chunk-002.m4a"), "failed marker")
        expect(text.contains("[00:10:02] Stack 與 DeepseekHarness"), "chunk3 offset includes gaps")
        expect(text.contains("chunks: 3\nfailed_chunks: 1\n") && text.contains("status: completed"), "frontmatter counts")
        expect(f.errors.isEmpty, "no fatal errors")
    }

    static func testStopWaitsForQueuedTranscriptions() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1)
        let c2 = f.recorder.starts[1]
        f.uptime = 300.3
        f.recorder.started(c2)
        f.uptime = 330
        f.coordinator.stop()
        f.recorder.finish(c2)
        // 兩段都在等辨識：結束前不能宣告完成。
        expect(f.coordinator.state == .draining && f.finished.isEmpty, "still draining")
        expect(f.coordinator.status.pendingChunks == 2, "two pending")
        f.transcriber.complete(0, .success(result([(0, "第一段")])))
        expect(f.finished.isEmpty && f.transcriber.calls.count == 2, "second request starts only after first")
        f.transcriber.complete(1, .success(result([(0, "第二段")])))
        expect(f.finished.count == 1 && f.coordinator.state == .idle, "finished after last")
        expect(!f.coordinator.stop(), "stop when idle is a no-op")
        let text = f.transcript
        expect(text.range(of: "第一段")!.lowerBound < text.range(of: "第二段")!.lowerBound, "order preserved")
    }

    static func testTooShortFinalChunkIsDropped() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1)
        let c2 = f.recorder.starts[1]
        f.uptime = 300.3
        f.recorder.started(c2)
        f.uptime = 300.6 // 不到 1 秒就按結束
        f.coordinator.stop()
        f.recorder.finish(c2)
        expect(f.transcriber.calls.count == 1, "short tail is not sent")
        expect(!f.exists(c2), "short tail file removed")
        f.transcriber.complete(0, .success(result([(0, "唯一一段")])))
        expect(f.finished.count == 1 && f.transcript.contains("chunks: 1\n"), "only real chunk counted")
    }

    static func testStopBeforeFirstChunkStarts() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        expect(f.coordinator.stop(), "stop while starting")
        expect(f.recorder.stopCount == 0, "nothing to stop yet")
        f.recorder.started(c1)
        expect(f.recorder.stopCount == 1 && f.scheduled.isEmpty, "stops as soon as it starts, no cut timer")
        f.recorder.finish(c1)
        expect(f.coordinator.state == .idle && f.transcriber.calls.isEmpty, "nothing recorded")
        expect(f.store.latestTranscriptURL() == nil, "empty meeting folder removed")
        expect(f.finished.isEmpty, "no finished notice for an empty meeting")
    }

    static func testStartFailureOnFirstChunkLeavesNothing() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        f.recorder.failStart(f.recorder.starts[0], "無法啟動錄音裝置。")
        expect(f.errors.count == 1 && f.errors[0].contains("無法開始會議錄音"), "error reported: \(f.errors)")
        expect(f.coordinator.state == .idle, "back to idle")
        expect(f.store.latestTranscriptURL() == nil && f.finished.isEmpty, "no folder, no notice")
        expect(f.coordinator.start(deviceUID: "mic", language: .default), "can start again")
    }

    static func testStartFailureLaterKeepsEarlierContent() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1)
        let c2 = f.recorder.starts[1]
        f.recorder.failStart(c2, "找不到指定的錄音裝置")
        expect(f.errors.count == 1 && f.errors[0].contains("會議錄音中斷"), "interrupted message")
        expect(f.coordinator.state == .draining && f.finished.isEmpty, "waits for chunk 1")
        f.transcriber.complete(0, .success(result([(0, "中斷前的內容")])))
        expect(f.coordinator.state == .idle && f.finished.count == 1, "finishes")
        expect(f.transcript.contains("[00:00:00] 中斷前的內容"), "earlier content kept")
    }

    static func testUnusableRecordingIsMarkedAndMeetingContinues() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1, error: StubError(message: "disk full"))
        expect(!f.exists(c1), "unusable file removed")
        expect(f.coordinator.state == .recording && f.recorder.starts.count == 2, "next chunk still starts")
        expect(f.transcript.contains("第 1 段辨識失敗：錄音檔不可用（disk full）。這段沒有保留音檔。"), "marked")
        expect(f.coordinator.failedChunkCount == 1, "counted")
    }

    static func testSynchronousTranscriber() {
        let f = Fixture()
        f.transcriber.synchronousResults = [
            .success(result([(0, "同步一")])),
            .failure(StubError(message: "boom")),
        ]
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1)
        let c2 = f.recorder.starts[1]
        f.uptime = 300.3
        f.recorder.started(c2)
        f.uptime = 320
        f.coordinator.stop()
        f.recorder.finish(c2)
        expect(f.coordinator.state == .idle && f.finished.count == 1 && f.finished[0].1 == 1, "sync results complete the meeting")
        expect(f.transcript.contains("[00:00:00] 同步一") && f.transcript.contains("第 2 段辨識失敗：boom"), "both recorded")
    }

    static func testStaleRecorderCallbacksAreIgnored() {
        let f = Fixture()
        let stray = f.directory.appendingPathComponent("other.m4a")
        f.recorder.onRecordingStarted?(stray)
        f.recorder.onRecordingFinished?(stray, nil)
        f.recorder.onStartFailed?(stray, StubError(message: "x"))
        expect(f.coordinator.state == .idle && f.errors.isEmpty, "idle ignores callbacks")
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.recorder.onRecordingFinished?(stray, nil)
        f.recorder.onStartFailed?(stray, StubError(message: "x"))
        expect(f.coordinator.state == .recording && f.errors.isEmpty && f.transcriber.calls.isEmpty, "foreign urls ignored")
        // 已被取代的切段計時器不能影響新的一段。
        f.coordinator.stop()
        f.scheduled[0].action()
        expect(f.recorder.stopCount == 1, "cut timer cancelled by stop")
    }

    static func testShutdownMarksUnfinishedChunks() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1)
        let c2 = f.recorder.starts[1]
        f.uptime = 300.3
        f.recorder.started(c2)
        f.coordinator.shutdown()
        expect(f.recorder.shutdownCount == 1 && f.transcriber.calls[0].token.cancelCount == 1, "recorder and request stopped")
        expect(f.coordinator.state == .idle, "idle")
        let text = f.transcript
        expect(text.contains("status: interrupted"), "interrupted status")
        expect(text.contains("第 1 段辨識失敗：App 結束前尚未辨識") && text.contains("音檔保留：chunk-001.m4a"), "queued chunk marked")
        expect(text.contains("第 2 段辨識失敗：App 結束時正在錄音，音檔可能不完整"), "recording chunk marked")
        expect(f.exists(c1) && f.exists(c2), "audio kept")
    }

    static func testCannotStartWhileRecorderBusyOrActive() {
        let f = Fixture()
        f.recorder.isBusy = true
        expect(!f.coordinator.start(deviceUID: "mic", language: .default) && f.recorder.starts.isEmpty, "busy recorder")
        f.recorder.isBusy = false
        expect(f.coordinator.start(deviceUID: "mic", language: .default), "start")
        expect(!f.coordinator.start(deviceUID: "mic", language: .default) && f.recorder.starts.count == 1, "already active")
    }
}
