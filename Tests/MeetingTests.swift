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
        testSegmentRecordsArePureAndFollowSchema()
        testSegmentsSidecarForThreeChunks()
        testSidecarIsWrittenBeforeTranscript()
        testSidecarFailureIsBestEffort()
        try testLatestTranscriptUsesNumericSuffixOrder()
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
        print("Meeting tests passed (19 scenarios)")
    }

    // MARK: segments.jsonl

    private static func segmentLines(_ f: Fixture) -> [String] {
        guard let url = f.store.latestTranscriptURL() else { return [] }
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("segments.jsonl")
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func json(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    private static func near(_ value: Any?, _ expected: Double) -> Bool {
        guard let number = value as? Double else { return false }
        return abs(number - expected) < 0.0005
    }

    static func testSegmentRecordsArePureAndFollowSchema() {
        func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionWord {
            TranscriptionWord(text: text, start: start, end: end)
        }
        func segment(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> TranscriptionSegment {
            TranscriptionSegment(id: id, start: start, end: end, text: text, avgLogprob: nil, noSpeechProb: nil)
        }
        let value = TranscriptionResult(
            text: "x", segments: [segment(0, 0, 2, " 大家好"), segment(1, 2.5, 3, "   "), segment(2, 4.2, 6.2, " A/B 測試\n")],
            words: [word(" 大家好", 0, 0.5), word(" gap", 2.2, 2.4), word(" blank", 2.6, 2.9), word(" A/B", 4.2, 4.6), word("測試", 4.6, 5.0)],
            language: "zh", duration: 6.2)
        let records = MeetingSegments.records(chunk: 2, offset: 300.4, result: value)
        expect(records.count == 2, "blank-text segment is skipped: \(records)")
        expect(records[0].chunk == 2 && records[0].v == 1, "schema version and chunk number")
        expect(records[0].start == 300.4 && records[0].end == 302.4, "offset added: \(records[0])")
        // 300.4 + 4.2 在浮點數是 304.59999999999997，必須收成 304.6。
        expect(records[1].start == 304.6 && records[1].end == 306.6, "rounded to milliseconds: \(records[1])")
        expect(records[1].text == "A/B 測試", "text trimmed, newline removed at the ends")
        // 字級時間：落在 segment 之間空隙的字（gap）歸前一個 segment；屬於被跳過的空白 segment 的字（blank）
        // 不會出現在任何一行；w 原樣保留（包含前導空白）。
        expect(records[0].words == [.init(w: " 大家好", s: 300.4, e: 300.9), .init(w: " gap", s: 302.6, e: 302.8)],
               "words of segment 0: \(String(describing: records[0].words))")
        expect(!records.contains { $0.words?.contains { $0.w == " blank" } == true }, "word of a skipped blank segment is dropped")
        expect(records[1].words == [.init(w: " A/B", s: 304.6, e: 305.0), .init(w: "測試", s: 305.0, e: 305.4)], "words of segment 2")

        let raw = records[1].jsonLine()
        expect(raw == "{\"v\":1,\"chunk\":2,\"start\":304.6,\"end\":306.6,\"text\":\"A/B 測試\",\"words\":[{\"w\":\" A/B\",\"s\":304.6,\"e\":305},{\"w\":\"測試\",\"s\":305,\"e\":305.4}]}",
               "fixed field order, no slash escaping, minimal numbers: \(raw)")
        // 特殊字元要被正確跳脫，整行仍是合法 JSON。
        let tricky = MeetingSegmentRecord(v: 1, chunk: 1, start: 0, end: 1, text: "他說\"好\"\\\t路徑/x", words: nil, failed: nil)
        expect(json(tricky.jsonLine())["text"] as? String == "他說\"好\"\\\t路徑/x", "escaping round-trips: \(tricky.jsonLine())")
        expect(!raw.contains("failed"), "failed is omitted when nil")

        let noWords = TranscriptionResult(text: "x", segments: [segment(0, 1, 2, "沒有字級時間")], words: [], language: nil, duration: nil)
        let plain = MeetingSegments.records(chunk: 1, offset: 0, result: noWords)
        let plainRaw = plain[0].jsonLine()
        expect(plainRaw == "{\"v\":1,\"chunk\":1,\"start\":1,\"end\":2,\"text\":\"沒有字級時間\"}", "no words key at all: \(plainRaw)")

        let whole = TranscriptionResult(text: " 只有全文 ", segments: [], words: [], language: nil, duration: 4)
        let fallback = MeetingSegments.records(chunk: 3, offset: 600, result: whole)
        expect(fallback.count == 1 && fallback[0].start == 600 && fallback[0].end == 604 && fallback[0].text == "只有全文", "whole-text fallback")
        expect(MeetingSegments.records(chunk: 1, offset: 0, result: TranscriptionResult(text: " ", segments: [], words: [], language: nil, duration: nil)).isEmpty,
               "nothing recognised writes no lines")

        let failed = MeetingSegments.failure(chunk: 2, offset: 300.4, duration: 300, reason: "HTTP 429: rate limited")
        let failedRaw = failed.jsonLine()
        expect(failedRaw == "{\"v\":1,\"chunk\":2,\"start\":300.4,\"end\":600.4,\"text\":\"\",\"failed\":\"HTTP 429: rate limited\"}", "failed line: \(failedRaw)")
        expect(MeetingSegments.failure(chunk: 1, offset: 5, duration: 0, reason: "x").end == 5, "unknown length: end == start")
    }

    // 完整流程：成功、失敗、整段沒內容。段序號 = 段檔名的 NNN（M1 從 001 開始）。
    static func testSegmentsSidecarForThreeChunks() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.uptime = 100
        f.recorder.started(c1)
        f.uptime = 400
        f.scheduled[0].action()
        f.recorder.finish(c1)
        let c2 = f.recorder.starts[1]
        f.uptime = 400.4
        f.recorder.started(c2)
        let words = [TranscriptionWord(text: " 大家好", start: 0, end: 0.5), TranscriptionWord(text: " Grokbot", start: 0.6, end: 1.2),
                     TranscriptionWord(text: " yui", start: 4.2, end: 4.5)]
        var first = result([(0, " 大家好 Grokbot"), (4.2, " yui 說 claudecode")])
        first = TranscriptionResult(text: first.text, segments: first.segments, words: words, language: "zh", duration: 6)
        f.transcriber.complete(0, .success(first))
        f.uptime = 700.4
        f.scheduled[1].action()
        f.recorder.finish(c2)
        let c3 = f.recorder.starts[2]
        f.uptime = 700.9
        f.recorder.started(c3)
        f.transcriber.complete(1, .failure(StubError(message: "Rate limit reached")))
        f.uptime = 710
        f.coordinator.stop()
        f.recorder.finish(c3)
        f.transcriber.complete(2, .success(TranscriptionResult(text: "", segments: [], words: [], language: nil, duration: nil)))

        let lines = segmentLines(f)
        expect(lines.count == 3, "2 segments of chunk 1 + 1 failed line for chunk 2, nothing for empty chunk 3: \(lines)")
        expect(lines[0] == "{\"v\":1,\"chunk\":1,\"start\":0,\"end\":2,\"text\":\"大家好 Grokbot\",\"words\":[{\"w\":\" 大家好\",\"s\":0,\"e\":0.5},{\"w\":\" Grokbot\",\"s\":0.6,\"e\":1.2}]}",
               "first line exactly: \(lines[0])")
        let second = json(lines[1]), failed = json(lines[2])
        expect(second["chunk"] as? Int == 1 && near(second["start"], 4.2) && near(second["end"], 6.2), "second segment: \(lines[1])")
        expect((second["words"] as? [[String: Any]])?.count == 1, "only its own word")
        expect(failed["chunk"] as? Int == 2 && near(failed["start"], 300.4) && near(failed["end"], 600.4), "failed line times: \(lines[2])")
        expect(failed["failed"] as? String == "Rate limit reached" && failed["text"] as? String == "" && failed["words"] == nil, "failed line fields")
        // 逐字稿的時間與旁路檔同一個 offset（時間軸共用 chunk.offset）。
        let transcript = f.transcript
        expect(transcript.contains("[00:00:00] 大家好 Grokbot") && transcript.contains("[00:00:04] yui 說 claudecode"), "transcript.md unchanged by the sidecar")
        expect(transcript.contains("> ⚠️ [00:05:00] 第 2 段辨識失敗：Rate limit reached。音檔保留：chunk-002.m4a"), "failure marker unchanged")
        expect(f.coordinator.sidecarFailureCount == 0, "no sidecar failures")
        expect(transcript.contains("audio: aac-44100-mono-64k\nsegments: complete\n"), "complete sidecar is declared in frontmatter")
        expect(!f.exists(c1) && f.exists(c2) && !f.exists(c3), "chunk deletion behaviour unchanged: success deleted, failure kept")
    }

    // 規則 2：先寫旁路檔，再寫逐字稿。逐字稿寫不進去時，旁路檔仍有這段（多一行比少一行好），
    // 且不會再補一條 failed（同一段不能既有內容又被標失敗）。
    static func testSidecarIsWrittenBeforeTranscript() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1)
        let transcript = f.store.latestTranscriptURL()!
        try! FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: transcript.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.path) }
        f.transcriber.complete(0, .success(result([(0, "只進得了旁路檔")])))
        let lines = segmentLines(f)
        expect(lines.count == 1 && json(lines[0])["text"] as? String == "只進得了旁路檔" && json(lines[0])["failed"] == nil,
               "sidecar has the segment and no failed line: \(lines)")
        expect(!f.transcript.contains("只進得了旁路檔"), "transcript.md could not be written")
        expect(f.exists(c1) && f.coordinator.failedChunkCount == 1, "audio kept and counted as failed, as before")
    }

    // 旁路檔是盡力而為：寫不進去不能影響逐字稿與刪檔行為，只留下計數。
    static func testSidecarFailureIsBestEffort() {
        let f = Fixture()
        f.coordinator.start(deviceUID: "mic", language: .default)
        let c1 = f.recorder.starts[0]
        f.recorder.started(c1)
        let directory = f.store.latestTranscriptURL()!.deletingLastPathComponent()
        try! FileManager.default.createDirectory(at: directory.appendingPathComponent("segments.jsonl"), withIntermediateDirectories: false)
        f.uptime = 300
        f.scheduled[0].action()
        f.recorder.finish(c1)
        f.transcriber.complete(0, .success(result([(0, "逐字稿照寫")])))
        expect(f.coordinator.sidecarFailureCount == 1, "sidecar failure counted")
        expect(f.transcript.contains("[00:00:00] 逐字稿照寫"), "transcript still written")
        expect(!f.exists(c1) && f.coordinator.failedChunkCount == 0, "successful chunk still deleted and not marked failed")
        // 結束會議後，frontmatter 要說明旁路檔不完整，讓說話者辨識讀得到。
        let c2 = f.recorder.starts[1]
        f.coordinator.stop()
        f.recorder.started(c2)
        f.recorder.finish(c2)
        expect(f.coordinator.state == .idle, "meeting finished")
        expect(f.transcript.contains("audio: aac-44100-mono-64k\nsegments: incomplete\n"), "incomplete sidecar is declared: \(f.transcript.prefix(400))")
        expect(f.transcript.contains("[00:00:00] 逐字稿照寫"), "body untouched by the frontmatter rewrite")
    }

    static func testTimestampFormatting() {
        expect(MeetingStore.timestamp(0) == "00:00:00", "zero")
        expect(MeetingStore.timestamp(300.9) == "00:05:00", "floor")
        expect(MeetingStore.timestamp(3725) == "01:02:05", "hours")
        expect(MeetingStore.timestamp(-5) == "00:00:00", "negative")
        expect(MeetingStore.timestamp(.nan) == "00:00:00", "nan")
    }

    // 同一分鐘建立 10 場：字串排序會把 -9 排在 -10 之後，「最近一次」就會拿錯。
    static func testLatestTranscriptUsesNumericSuffixOrder() throws {
        let f = Fixture()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var sessions: [MeetingSession] = []
        for _ in 1...11 { sessions.append(try f.store.beginSession(startedAt: date, language: "zh", chunkSeconds: 300)) }
        expect(sessions[8].directory.lastPathComponent == "2027-01-15_0800-9", "ninth is -9")
        expect(sessions[9].directory.lastPathComponent == "2027-01-15_0800-10", "tenth is -10")
        expect(f.store.latestTranscriptURL() == sessions[10].transcriptURL, "-11 is latest of eleven")
        try FileManager.default.removeItem(at: sessions[10].directory)
        expect(f.store.latestTranscriptURL() == sessions[9].transcriptURL, "-10 beats -9")
        // 較晚的分鐘永遠比較新，不論 suffix；使用者自己放的資料夾不會壓過會議資料夾。
        let later = try f.store.beginSession(startedAt: date.addingTimeInterval(120), language: "zh", chunkSeconds: 300)
        let stray = f.directory.appendingPathComponent("zzz-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        expect(f.store.latestTranscriptURL() == later.transcriptURL, "later minute wins; stray folder without transcript ignored")
        // 公開給其他功能（摘要等）用的由新到舊清單：順序正確、檔案不算、雜項資料夾在最後。
        try Data([1]).write(to: f.directory.appendingPathComponent("2099-01-01_0000.txt"))
        let names = f.store.sessionDirectoriesNewestFirst().map(\.lastPathComponent)
        expect(names.first == "2027-01-15_0802", "newest first: \(names)")
        expect(names.last == "zzz-notes", "unrecognised folder sorts last: \(names)")
        expect(!names.contains("2099-01-01_0000.txt"), "plain files are not sessions")
        let ten = names.firstIndex(of: "2027-01-15_0800-10")!, nine = names.firstIndex(of: "2027-01-15_0800-9")!
        expect(ten < nine, "-10 listed before -9: \(names)")
        expect(names.firstIndex(of: "2027-01-15_0800")! == names.count - 2, "unsuffixed first meeting is oldest of its minute")
    }

    static func testStoreSessionLifecycle() throws {
        let f = Fixture()
        let session = try f.store.beginSession(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), language: "zh", chunkSeconds: 300)
        let started = try String(contentsOf: session.transcriptURL, encoding: .utf8)
        expect(started.hasPrefix("---\nstarted: 2027-01-15T08:00:00Z\nended: in-progress\n"), "frontmatter at start")
        expect(started.contains("status: recording") && started.contains("# 會議記錄 2027-01-15 08:00"), "title")
        expect(session.directory.lastPathComponent == "2027-01-15_0800", "folder name")
        expect(started.contains("chunk_seconds: 300\naudio: aac-44100-mono-64k\n"), "audio format recorded in frontmatter")

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
