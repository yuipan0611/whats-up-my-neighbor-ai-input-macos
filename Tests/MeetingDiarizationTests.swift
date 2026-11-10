import Foundation

// 會議說話者辨識（M2）的離線測試：協調器用假的 Process 執行器，真的 Process 執行器用 /bin/sh 小腳本。
// 不需要 sherpa、模型、音檔或網路。

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

// MARK: - 替身

private final class FakeToken: DictationCancellable {
    var cancelCount = 0
    /// cancel 被呼叫的當下，協調器是否已經不忙（驗證「先改狀態、後 cancel」）。
    var coordinatorBusyAtCancel: Bool?
    var probe: (() -> Bool)?
    func cancel() { cancelCount += 1; coordinatorBusyAtCancel = probe?() }
}

private final class FakeRunner: DiarizerProcessRunning {
    struct Call {
        let executable: URL
        let arguments: [String]
        let onProgress: (Int, Int) -> Void
        let completion: (Result<DiarizerRunResult, Error>) -> Void
        let token: FakeToken
    }
    var calls: [Call] = []
    var probe: (() -> Bool)?

    func run(executable: URL, arguments: [String], onProgress: @escaping (Int, Int) -> Void,
             completion: @escaping (Result<DiarizerRunResult, Error>) -> Void) -> DictationCancellable {
        let token = FakeToken()
        token.probe = probe
        calls.append(Call(executable: executable, arguments: arguments, onProgress: onProgress,
                          completion: completion, token: token))
        return token
    }
}

private struct FakeLocator: MeetingDiarizerLocator {
    var executable: URL? = URL(fileURLWithPath: "/fake/meeting-diarizer")
    var ready = true
    func executableURL() -> URL? { executable }
    func modelsReady() -> Bool { ready }
}

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class Fixture {
    let root: URL
    let store: MeetingStore
    let session: MeetingSession
    let runner = FakeRunner()
    var asked: [SpeakerCountChoice?] = []
    var answer: SpeakerCountChoice? = .count(3)
    /// 非 nil 時，問人數的回呼不立刻回答，由測試之後呼叫（模擬 modal 還開著）。
    var deferAnswer = false
    var deferred: ((SpeakerCountChoice?) -> Void)?
    var lastChoice: SpeakerCountChoice?
    var finished: [(URL, MeetingDiarizationState)] = []
    var phases: [MeetingDiarizationPhase] = []
    var coordinator: MeetingDiarizationCoordinator!

    var transcriptURL: URL { session.transcriptURL }
    var directory: URL { session.directory }
    var transcript: String { (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? "" }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }

    /// `sidecar`：nil = 不建立 segments.jsonl。`complete`：frontmatter 的 segments 欄位。
    /// `plainExtra`：逐字稿裡多一行 segments.jsonl 沒有的內容（模擬旁路檔寫入失敗）。
    init(sidecar: [MeetingSegmentRecord]? = Fixture.defaultRecords, complete: Bool = true,
         plainExtra: String? = nil, locator: FakeLocator = FakeLocator(), manifest: Bool = true,
         lastChoice: SpeakerCountChoice? = nil) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DiarizationTests-\(UUID().uuidString)", isDirectory: true)
        store = MeetingStore(root: root, timeZone: TimeZone(identifier: "UTC")!)
        session = try! store.beginSession(startedAt: Date(timeIntervalSince1970: 1_800_000_000), language: "zh", chunkSeconds: 300)
        try! store.appendChunk(session, offset: 0, lines: [MeetingLine(offset: 0, text: "大家好"), MeetingLine(offset: 5, text: "我是第二個人")])
        if let plainExtra { try! store.appendChunk(session, offset: 12, lines: [MeetingLine(offset: 12, text: plainExtra)]) }
        try! store.appendChunk(session, offset: 300.4, lines: [MeetingLine(offset: 300.4, text: "第二段")])
        try! store.endSession(session, endedAt: Date(timeIntervalSince1970: 1_800_000_900), chunks: 2, failedChunks: 0,
                              segmentsComplete: complete)
        if let sidecar { try! store.appendSegments(session, records: sidecar) }
        for index in 1...2 { try! Data([1, 2, 3]).write(to: store.chunkURL(session, index: index)) }
        if manifest {
            try! store.writeManifest(directory: session.directory, chunks: [(1, 0), (2, 300.4)])
        }
        self.lastChoice = lastChoice

        var asker: (SpeakerCountChoice?, @escaping (SpeakerCountChoice?) -> Void) -> Void = { _, _ in }
        coordinator = MeetingDiarizationCoordinator(
            store: store, locator: locator, runner: runner,
            modelsDirectory: { URL(fileURLWithPath: "/fake/models") },
            askSpeakerCount: { last, completion in asker(last, completion) },
            loadLastChoice: { [unowned self] in self.lastChoice },
            saveLastChoice: { [unowned self] in self.lastChoice = $0 })
        asker = { [unowned self] last, completion in
            self.asked.append(last)
            if self.deferAnswer { self.deferred = completion } else { completion(self.answer) }
        }
        coordinator.onFinished = { [unowned self] in self.finished.append(($0, $1)) }
        coordinator.onPhaseChange = { [unowned self] in self.phases.append($0) }
        runner.probe = { [unowned self] in self.coordinator.isBusy }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 同一個 root 底下再一場完整的會議（同一分鐘，資料夾會加 -2）。
    func addMeeting() -> MeetingSession {
        let other = try! store.beginSession(startedAt: Date(timeIntervalSince1970: 1_800_000_000), language: "zh", chunkSeconds: 300)
        try! store.appendChunk(other, offset: 0, lines: [MeetingLine(offset: 0, text: "另一場")])
        try! store.endSession(other, endedAt: Date(timeIntervalSince1970: 1_800_000_900), chunks: 1, failedChunks: 0)
        try! store.appendSegments(other, records: [MeetingSegmentRecord(v: 1, chunk: 1, start: 0, end: 3, text: "另一場", words: nil, failed: nil)])
        try! Data([1]).write(to: store.chunkURL(other, index: 1))
        try! store.writeManifest(directory: other.directory, chunks: [(1, 0)])
        return other
    }

    static let defaultRecords: [MeetingSegmentRecord] = [
        MeetingSegmentRecord(v: 1, chunk: 1, start: 0, end: 4, text: "大家好", words: nil, failed: nil),
        MeetingSegmentRecord(v: 1, chunk: 1, start: 5, end: 9, text: "我是第二個人", words: nil, failed: nil),
        MeetingSegmentRecord(v: 1, chunk: 2, start: 300.4, end: 303, text: "第二段", words: nil, failed: nil),
    ]

    static let output = """
    {"durationSeconds":303,"numSpeakers":2,"numSpeakersMode":"fixed","processingSeconds":1,"warnings":[],
     "segments":[{"start":0,"end":4.5,"speaker":0,"label":"Speaker 1"},{"start":4.6,"end":9.5,"speaker":1,"label":"Speaker 2"},
                 {"start":300,"end":304,"speaker":0,"label":"Speaker 1"}]}
    """

    func succeed(_ call: Int = 0, output: String = Fixture.output) {
        runner.calls[call].completion(.success(DiarizerRunResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: "")))
    }
}

// MARK: - 測試

@main
enum MeetingDiarizationTests {
    static func main() throws {
        testFrontmatterHelpers()
        testDiarizationStateReading()
        testReconcile()
        testSuccessFlow()
        testFailureKeepsAudioAndOffersDeletion()
        testCancelDuringRunWritesNothingAfterwards()
        testCancelWhileAskingNeverLaunches()
        testNoSidecarIsSkipped()
        testCorruptSidecarFails()
        testIncompleteSidecarMarksUnmatchedLines()
        testUserDeclineKeepsAudio()
        testNotReadyOrNoManifestFails()
        testBadOutputAndLaunchErrorFail()
        testSecondMeetingIsQueuedAndRunsAfterTheFirst()
        testCancelDropsQueueAndRelaunchMarksInterrupted()
        testStartupScanMarksInterrupted()
        testRetryAfterFailureAndInterruption()
        testRerunKeepsOriginalPlainBackup()
        testRealProcessRunner()
        print("MeetingDiarization tests passed (19 scenarios)")
    }

    // MARK: 純函式

    static func testFrontmatterHelpers() {
        let text = "---\na: 1\nb: two\n---\n\n# 標題\n"
        expect(MeetingFrontmatter.value("a", in: text) == "1" && MeetingFrontmatter.value("b", in: text) == "two", "read values")
        expect(MeetingFrontmatter.value("c", in: text) == nil, "missing key")
        expect(MeetingFrontmatter.removing("a", from: text) == "---\nb: two\n---\n\n# 標題\n" && MeetingFrontmatter.removing("zz", from: text) == text, "remove key")
        expect(MeetingFrontmatter.setting("a", to: "9", in: text) == "---\na: 9\nb: two\n---\n\n# 標題\n", "replace keeps the rest")
        expect(MeetingFrontmatter.setting("c", to: "x\ny", in: text) == "---\na: 1\nb: two\nc: x y\n---\n\n# 標題\n",
               "add before closing marker, newline in value folded")
        expect(MeetingFrontmatter.setting("a", to: "9", in: "沒有 frontmatter") == "沒有 frontmatter", "no frontmatter → unchanged")
        // 正文裡長得像鍵的行不能被當成 frontmatter。
        expect(MeetingFrontmatter.value("a", in: "---\nb: 1\n---\na: 7\n") == nil, "body lines are not frontmatter")
    }

    static func testDiarizationStateReading() {
        let f = Fixture()
        expect(f.store.diarizationState(for: f.transcriptURL) == .notApplicable, "no field → notApplicable")
        expect(MeetingDiarizationState.notApplicable.isTerminal, "no field means nothing to wait for")
        for state in [MeetingDiarizationState.pending, .running] {
            try! f.store.setFrontmatter([("diarization", state.rawValue)], transcriptURL: f.transcriptURL)
            expect(f.store.diarizationState(for: f.transcriptURL) == state && !state.isTerminal, "\(state) is not terminal")
        }
        for state in [MeetingDiarizationState.done, .failed, .skipped, .cancelled] {
            try! f.store.setFrontmatter([("diarization", state.rawValue)], transcriptURL: f.transcriptURL)
            expect(f.store.diarizationState(for: f.transcriptURL) == state && state.isTerminal, "\(state) is terminal")
        }
        expect(f.store.diarizationState(for: f.root.appendingPathComponent("nope.md")) == .notApplicable, "unreadable file")
    }

    static func testReconcile() {
        func rec(_ start: Double, _ text: String, failed: String? = nil) -> TranscriptSegmentRecord {
            TranscriptSegmentRecord(chunk: 1, start: start, end: start + 2, text: text, failed: failed)
        }
        let records = [rec(0, "大家好"), rec(5.2, "第二句"), rec(300, "", failed: "Rate limit")]
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 5, end: 8, speaker: 1)]
        let aligned = SpeakerAligner.align(segments: records, turns: turns)
        let body = """

        # 會議記錄

        [00:00:00] 大家好
        [00:00:05] 第二句
        [00:00:07] 旁路檔沒有這行
        > ⚠️ [00:05:00] 第 2 段辨識失敗：Rate limit。音檔保留：chunk-002.m4a
        > ⚠️ [00:10:00] 第 3 段辨識失敗：沒有失敗記錄
        > [00:15:00] （這段沒有辨識到內容）

        """
        let plain = SpeakerAligner.parsePlainTranscript(body)
        expect(plain.count == 6, "title and blank lines are skipped, markers kept: \(plain)")
        let merged = SpeakerAligner.reconcile(aligned: aligned, records: records, plain: plain).map { SpeakerAligner.render($0) }
        expect(merged == [
            "[00:00:00] Speaker 1：大家好",
            "[00:00:05] Speaker 2：第二句",
            "[00:00:07] Speaker ?：旁路檔沒有這行",
            "> ⚠️ [00:05:00] 這段辨識失敗：Rate limit",
            "> ⚠️ [00:10:00] 第 3 段辨識失敗：沒有失敗記錄",
            "> [00:15:00] （這段沒有辨識到內容）",
        ], "unmatched line → Speaker ?, matched failure not duplicated, unmatched markers kept in place: \(merged)")

        // 時間戳相差 1 秒（毫秒四捨五入）仍視為同一行；文字不同就不算。
        let edge = [rec(59.9996 + 0.0004, "邊界")]
        let edgeMerged = SpeakerAligner.reconcile(aligned: SpeakerAligner.align(segments: edge, turns: []), records: edge,
                                                  plain: [.spoken(seconds: 59, text: "邊界")])
        expect(edgeMerged.count == 1, "rounding edge is not duplicated: \(edgeMerged)")
        let different = SpeakerAligner.reconcile(aligned: SpeakerAligner.align(segments: edge, turns: []), records: edge,
                                                 plain: [.spoken(seconds: 60, text: "別的字")])
        expect(different.count == 2, "different text is not matched")
        // 同一秒內有兩行相同文字：各自對應一筆記錄，不會互相吃掉。
        let twin = [rec(10, "好"), rec(10.5, "好")]
        let twinMerged = SpeakerAligner.reconcile(aligned: SpeakerAligner.align(segments: twin, turns: []), records: twin,
                                                  plain: [.spoken(seconds: 10, text: "好"), .spoken(seconds: 10, text: "好")])
        expect(twinMerged.count == 2, "each record matches at most one line")
        // 記錄有、逐字稿沒有：仍然輸出（旁路檔是資料來源）。
        let onlyRecords = SpeakerAligner.reconcile(aligned: aligned, records: records, plain: [])
        expect(onlyRecords.count == aligned.count, "records without transcript lines are still output")
    }

    // MARK: 協調器

    static func testSuccessFlow() {
        let f = Fixture(lastChoice: .auto)
        let original = f.transcript
        expect(f.coordinator.begin(transcriptURL: f.transcriptURL), "begin accepted")
        expect(f.asked == [.auto], "the dialog gets the last choice as its default: \(f.asked)")
        expect(f.lastChoice == .count(3), "the new choice is remembered")
        expect(f.runner.calls.count == 1, "runner launched once")
        let call = f.runner.calls[0]
        expect(call.executable.path == "/fake/meeting-diarizer", "locator's executable")
        expect(call.arguments == ["--manifest", f.directory.appendingPathComponent("manifest.json").path,
                                  "--models", "/fake/models", "--num-speakers", "3", "--progress"],
               "arguments: \(call.arguments)")
        expect(f.coordinator.phase == .preparing, "preparing until the first progress line")
        expect(f.store.diarizationState(for: f.transcriptURL) == .running, "frontmatter says running")
        expect(f.exists("segments.jsonl") && f.exists("chunk-001.m4a"), "audio still there while running")
        call.onProgress(1, 4)
        expect(f.coordinator.phase == .running(done: 1, total: 4), "progress shown")
        f.succeed()

        expect(f.finished.count == 1 && f.finished[0].1 == .done, "finished as done")
        expect(f.coordinator.phase == .idle && f.coordinator.retainedAudio == nil, "idle, nothing retained")
        let text = f.transcript
        expect(text.contains("[00:00:00] Speaker 1：大家好\n[00:00:05] Speaker 2：我是第二個人\n[00:05:00] Speaker 1：第二段\n"),
               "every line carries a speaker:\n\(text)")
        expect(MeetingFrontmatter.value("diarization", in: text) == "done", "diarization: done")
        expect(MeetingFrontmatter.value("speakers_mode", in: text) == "fixed", "speakers_mode")
        expect(MeetingFrontmatter.value("speakers_detected", in: text) == "2", "speakers_detected")
        expect(MeetingFrontmatter.value("audio_files", in: text) == "deleted", "audio_files: deleted")
        expect(MeetingFrontmatter.value("status", in: text) == "completed" && text.contains("# 會議記錄 "), "other frontmatter and title kept")
        let plain = try? String(contentsOf: f.directory.appendingPathComponent("transcript.plain.md"), encoding: .utf8)
        expect(plain == original, "transcript.plain.md is the untouched original")
        expect(f.exists("speakers.json"), "raw diarizer output saved")
        expect(!f.exists("chunk-001.m4a") && !f.exists("chunk-002.m4a") && !f.exists("manifest.json"), "audio and manifest deleted after success")
        expect(f.exists("segments.jsonl"), "segments.jsonl kept")
    }

    static func testFailureKeepsAudioAndOffersDeletion() {
        let f = Fixture()
        let original = f.transcript
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        f.runner.calls[0].completion(.success(DiarizerRunResult(exitCode: 5, standardOutput: Data(),
                                                                standardError: "loading\ncannot create diarizer")))
        expect(f.finished.map(\.1) == [.failed], "failed")
        let text = f.transcript
        expect(MeetingFrontmatter.value("diarization", in: text) == "failed", "diarization: failed")
        expect(MeetingFrontmatter.value("diarization_reason", in: text)?.contains("結束碼 5") == true, "reason recorded: \(text)")
        expect(MeetingStore.bodyAfterFrontmatter(text) == MeetingStore.bodyAfterFrontmatter(original), "plain transcript body untouched")
        expect(f.exists("chunk-001.m4a") && f.exists("chunk-002.m4a") && f.exists("manifest.json"), "audio kept")
        expect(!f.exists("transcript.plain.md"), "no backup written when nothing was rewritten")
        expect(f.coordinator.retainedAudio?.state == .failed && f.coordinator.retainedAudio?.directory == f.directory,
               "menu can offer deletion")
        expect(f.coordinator.deleteRetainedAudio(), "deletion accepted")
        expect(!f.exists("chunk-001.m4a") && !f.exists("chunk-002.m4a") && !f.exists("manifest.json"), "audio deleted on request")
        expect(f.exists("segments.jsonl") && f.exists("transcript.md"), "nothing else deleted")
        expect(MeetingFrontmatter.value("audio_files", in: f.transcript) == "deleted", "audio_files: deleted")
        expect(f.coordinator.retainedAudio == nil && !f.coordinator.deleteRetainedAudio(), "nothing left to delete")
    }

    static func testCancelDuringRunWritesNothingAfterwards() {
        let f = Fixture()
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        let call = f.runner.calls[0]
        f.coordinator.cancel()
        expect(call.token.cancelCount == 1, "runner cancelled exactly once")
        expect(call.token.coordinatorBusyAtCancel == false, "state is already idle when the runner is told to cancel")
        expect(f.finished.map(\.1) == [.cancelled] && f.coordinator.phase == .idle, "cancelled, idle")
        expect(MeetingFrontmatter.value("diarization", in: f.transcript) == "cancelled", "diarization: cancelled")
        let snapshot = f.transcript
        // 取消之後才到的舊回呼：不准寫任何檔案、不准再通知。
        call.onProgress(3, 4)
        f.succeed()
        expect(f.transcript == snapshot, "transcript.md untouched after cancel")
        expect(!f.exists("transcript.plain.md") && !f.exists("speakers.json"), "no backup / speakers.json after cancel")
        expect(f.exists("chunk-001.m4a") && f.exists("manifest.json"), "audio kept")
        expect(f.finished.count == 1 && f.coordinator.phase == .idle, "late callbacks ignored")
        f.coordinator.cancel()
        expect(call.token.cancelCount == 1 && f.finished.count == 1, "second cancel is a no-op")
        expect(f.coordinator.retainedAudio?.state == .cancelled, "audio retained, deletable from the menu")
    }

    static func testCancelWhileAskingNeverLaunches() {
        let f = Fixture()
        f.deferAnswer = true
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        expect(f.coordinator.phase == .asking && f.store.diarizationState(for: f.transcriptURL) == .pending, "asking, pending")
        f.coordinator.cancel()
        f.deferred?(.count(2))
        expect(f.runner.calls.isEmpty, "answer after cancel must not launch anything")
        expect(f.store.diarizationState(for: f.transcriptURL) == .cancelled && f.finished.map(\.1) == [.cancelled], "cancelled once")
        expect(f.lastChoice == nil, "late answer is not remembered")
    }

    static func testNoSidecarIsSkipped() {
        for records in [nil, [MeetingSegmentRecord]()] {
            let f = Fixture(sidecar: records)
            f.coordinator.begin(transcriptURL: f.transcriptURL)
            expect(f.asked.isEmpty && f.runner.calls.isEmpty, "never asks or runs without segment data")
            expect(f.finished.map(\.1) == [.skipped], "skipped")
            expect(MeetingFrontmatter.value("diarization", in: f.transcript) == "skipped"
                   && MeetingFrontmatter.value("diarization_reason", in: f.transcript) == "no-segments", "reason no-segments")
            expect(f.exists("chunk-001.m4a"), "audio kept (conservative)")
            expect(f.coordinator.retainedAudio?.state == .skipped, "deletable from the menu")
        }
    }

    static func testCorruptSidecarFails() {
        let f = Fixture(sidecar: nil)
        try! Data("{\"v\":1,\"chunk\":1,\"start\":0,\"end\":1,\"text\":\"ok\"}\nnot json\n".utf8)
            .write(to: f.directory.appendingPathComponent("segments.jsonl"))
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        expect(f.finished.map(\.1) == [.failed] && f.runner.calls.isEmpty, "corrupt sidecar → failed, nothing launched")
        expect(MeetingFrontmatter.value("diarization_reason", in: f.transcript)?.contains("line 2") == true, "reason names the line")
    }

    static func testIncompleteSidecarMarksUnmatchedLines() {
        let f = Fixture(complete: false, plainExtra: "旁路檔沒寫進去的一句")
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        f.succeed()
        expect(f.finished.map(\.1) == [.done], "still runs and finishes")
        let text = f.transcript
        expect(text.contains("[00:00:12] Speaker ?：旁路檔沒寫進去的一句"), "unmatched line is Speaker ?:\n\(text)")
        expect(text.contains("[00:00:00] Speaker 1：大家好"), "matched lines keep their speaker")
        expect(MeetingFrontmatter.value("speakers_note", in: text) != nil && text.contains("> 部分逐字稿行沒有時間資料"), "note in frontmatter and top of body")
        expect(text.range(of: "Speaker 2：我是第二個人")!.lowerBound < text.range(of: "Speaker ?：旁路")!.lowerBound
               && text.range(of: "Speaker ?：旁路")!.lowerBound < text.range(of: "Speaker 1：第二段")!.lowerBound, "ordered by time")
    }

    static func testUserDeclineKeepsAudio() {
        let f = Fixture()
        f.answer = nil
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        expect(f.runner.calls.isEmpty && f.finished.map(\.1) == [.skipped], "declined → skipped, never launched")
        expect(MeetingFrontmatter.value("diarization_reason", in: f.transcript) == "user-declined", "reason")
        expect(f.exists("chunk-001.m4a") && f.lastChoice == nil, "audio kept, choice not saved")
    }

    static func testNotReadyOrNoManifestFails() {
        let notReady = Fixture(locator: FakeLocator(executable: nil, ready: true))
        notReady.coordinator.begin(transcriptURL: notReady.transcriptURL)
        expect(notReady.finished.map(\.1) == [.failed] && notReady.asked.isEmpty, "no executable → failed before asking")
        let noModels = Fixture(locator: FakeLocator(ready: false))
        noModels.coordinator.begin(transcriptURL: noModels.transcriptURL)
        expect(noModels.finished.map(\.1) == [.failed] && noModels.runner.calls.isEmpty, "models not ready → failed")
        expect(noModels.exists("chunk-001.m4a"), "audio kept")
        let noManifest = Fixture(manifest: false)
        noManifest.coordinator.begin(transcriptURL: noManifest.transcriptURL)
        expect(noManifest.finished.map(\.1) == [.failed], "no manifest → failed")
    }

    static func testBadOutputAndLaunchErrorFail() {
        let bad = Fixture()
        bad.coordinator.begin(transcriptURL: bad.transcriptURL)
        bad.succeed(output: "not json")
        expect(bad.finished.map(\.1) == [.failed] && bad.exists("chunk-001.m4a"), "unparsable output → failed, audio kept")
        expect(!bad.exists("transcript.plain.md"), "transcript not rewritten")
        let launch = Fixture()
        launch.coordinator.begin(transcriptURL: launch.transcriptURL)
        launch.runner.calls[0].completion(.failure(StubError(message: "拒絕執行")))
        expect(launch.finished.map(\.1) == [.failed]
               && MeetingFrontmatter.value("diarization_reason", in: launch.transcript)?.contains("拒絕執行") == true, "launch error → failed")
    }

    // 辨識進行中又結束一場：排隊，第一場完成後自動接著問人數與辨識；同一場不重複排。
    static func testSecondMeetingIsQueuedAndRunsAfterTheFirst() {
        let f = Fixture()
        let second = f.addMeeting()
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        expect(!f.coordinator.begin(transcriptURL: f.transcriptURL), "the running meeting is not queued again")
        expect(f.coordinator.begin(transcriptURL: second.transcriptURL), "second meeting accepted into the queue")
        expect(!f.coordinator.begin(transcriptURL: second.transcriptURL), "no duplicate in the queue")
        expect(f.runner.calls.count == 1 && f.asked.count == 1, "only the first one runs")
        expect(f.store.diarizationState(for: second.transcriptURL) == .pending, "queued meeting is pending (not terminal)")
        f.succeed(0)
        expect(f.finished.map(\.1) == [.done], "first finished")
        expect(f.runner.calls.count == 2 && f.asked.count == 2, "second starts right after, asking its own speaker count")
        expect(f.store.diarizationState(for: second.transcriptURL) == .running, "second is running")
        f.succeed(1)
        expect(f.finished.map(\.1) == [.done, .done] && f.store.diarizationState(for: second.transcriptURL) == .done, "second done")
        expect(f.coordinator.phase == .idle, "queue drained")
    }

    // App 結束：佇列丟掉（不寫 cancelled 以外的狀態）；排隊的那場停在 pending，下次啟動被標成 interrupted。
    static func testCancelDropsQueueAndRelaunchMarksInterrupted() {
        let f = Fixture()
        let second = f.addMeeting()
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        f.coordinator.begin(transcriptURL: second.transcriptURL)
        f.coordinator.cancel()
        expect(f.runner.calls.count == 1 && f.asked.count == 1, "the queued meeting never starts after cancel")
        expect(f.store.diarizationState(for: f.transcriptURL) == .cancelled, "running one cancelled")
        expect(f.store.diarizationState(for: second.transcriptURL) == .pending, "queued one left pending")
        let changed = f.store.markInterruptedDiarizations()
        expect(changed == [second.transcriptURL], "next launch: only the pending one is marked: \(changed)")
        expect(f.store.diarizationState(for: second.transcriptURL) == .interrupted
               && MeetingDiarizationState.interrupted.isTerminal, "interrupted is terminal")
        expect(f.exists("chunk-001.m4a") && FileManager.default.fileExists(atPath: second.directory.appendingPathComponent("chunk-001.m4a").path),
               "audio kept")
    }

    static func testStartupScanMarksInterrupted() {
        let f = Fixture()
        let b = f.addMeeting()
        // 第一場停在 running（當機），第二場是 done，第三場沒有欄位。
        try! f.store.setFrontmatter([("diarization", "running")], transcriptURL: f.transcriptURL)
        try! f.store.setFrontmatter([("diarization", "done")], transcriptURL: b.transcriptURL)
        let c = f.addMeeting()
        expect(f.store.markInterruptedDiarizations() == [f.transcriptURL], "only running/pending are changed")
        expect(f.store.diarizationState(for: f.transcriptURL) == .interrupted, "running → interrupted")
        expect(MeetingFrontmatter.value("diarization_reason", in: f.transcript) == "app-exit", "reason recorded")
        expect(f.store.diarizationState(for: b.transcriptURL) == .done && f.store.diarizationState(for: c.transcriptURL) == .notApplicable,
               "others untouched")
        expect(f.store.markInterruptedDiarizations().isEmpty, "idempotent")
        expect(f.exists("chunk-001.m4a"), "audio untouched")
        // 選單狀態接回來：最近一場可重試的是第一場（另兩場不是 failed/interrupted/cancelled）。
        f.coordinator.restoreFromDisk()
        expect(f.coordinator.retainedAudio?.state == .interrupted && f.coordinator.retainedAudio?.directory == f.directory,
               "menu knows about the interrupted meeting")
        expect(f.coordinator.canRetry, "retry offered")
    }

    // 重試：failed／interrupted／cancelled 且音檔還在；成功後備份是不帶失敗標記的原版。
    static func testRetryAfterFailureAndInterruption() {
        let f = Fixture()
        expect(!f.coordinator.canRetry && !f.coordinator.retryLatest(), "nothing to retry for a meeting that never ran")
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        f.runner.calls[0].completion(.success(DiarizerRunResult(exitCode: 5, standardOutput: Data(), standardError: "boom")))
        expect(f.finished.map(\.1) == [.failed] && f.coordinator.canRetry, "failed meeting can be retried")
        expect(f.coordinator.retryLatest(), "retry accepted")
        expect(f.asked.count == 2 && f.runner.calls.count == 2, "same lifecycle: asks again and launches")
        expect(f.store.diarizationState(for: f.transcriptURL) == .running, "running again")
        f.succeed(1)
        expect(f.finished.map(\.1) == [.failed, .done], "second attempt done")
        let text = f.transcript
        expect(MeetingFrontmatter.value("diarization", in: text) == "done" && MeetingFrontmatter.value("diarization_reason", in: text) == nil,
               "old failure reason removed")
        let plain = (try? String(contentsOf: f.directory.appendingPathComponent("transcript.plain.md"), encoding: .utf8)) ?? ""
        expect(MeetingFrontmatter.value("diarization", in: plain) == nil && MeetingFrontmatter.value("diarization_reason", in: plain) == nil,
               "backup carries no diarization markers: \(plain)")
        expect(!f.coordinator.canRetry && !f.coordinator.retryLatest(), "audio is gone → nothing to retry")

        // cancelled 與 interrupted 也能重試；busy 時不能。
        let g = Fixture()
        g.coordinator.begin(transcriptURL: g.transcriptURL)
        g.coordinator.cancel()
        expect(g.coordinator.canRetry, "cancelled can be retried")
        g.coordinator.retryLatest()
        expect(!g.coordinator.canRetry && !g.coordinator.retryLatest(), "no retry while running")
        g.coordinator.cancel()
        _ = g.store.markInterruptedDiarizations()
        try! g.store.setFrontmatter([("diarization", "interrupted")], transcriptURL: g.transcriptURL)
        expect(g.coordinator.retryLatest(), "interrupted can be retried")
    }

    // 重新辨識時，plain 備份是最原始的版本，不能被「已經有 Speaker 的版本」覆蓋。
    static func testRerunKeepsOriginalPlainBackup() {
        let f = Fixture()
        let original = f.transcript
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        f.succeed()
        f.coordinator.begin(transcriptURL: f.transcriptURL)   // 音檔已刪，所以這次會因為沒有 manifest 而失敗
        expect(f.finished.map(\.1) == [.done, .failed], "second run fails: audio is gone")
        let plain = try? String(contentsOf: f.directory.appendingPathComponent("transcript.plain.md"), encoding: .utf8)
        expect(plain == original, "backup is still the original")
    }

    // MARK: 真的 Process 執行器

    private static func script(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diarizer-\(UUID().uuidString).sh")
        try! "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func spin(until condition: () -> Bool, seconds: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func testRealProcessRunner() {
        let runner = ProcessDiarizerRunner()
        // 成功：stderr 的 progress 行解析成進度，stdout 完整收回，引數原樣傳入。
        let ok = script("""
        echo "progress 1/4" >&2; echo "noise" >&2; echo "progress 4/4" >&2
        printf '%s' "{\\"args\\":\\"$*\\"}"
        """)
        defer { try? FileManager.default.removeItem(at: ok) }
        var progress: [String] = []
        var result: Result<DiarizerRunResult, Error>?
        _ = runner.run(executable: ok, arguments: ["--a", "b c"], onProgress: { progress.append("\($0)/\($1)") },
                       completion: { result = $0 })
        spin(until: { result != nil })
        guard case .success(let run)? = result else { expect(false, "runner did not complete: \(String(describing: result))"); return }
        expect(run.exitCode == 0 && String(decoding: run.standardOutput, as: UTF8.self) == "{\"args\":\"--a b c\"}", "stdout and exit code: \(run)")
        spin(until: { progress.count == 2 }, seconds: 2)
        expect(progress == ["1/4", "4/4"], "progress parsed, other stderr lines ignored: \(progress)")

        // 失敗：結束碼與 stderr 尾端帶回。
        let bad = script("echo 'cannot create diarizer' >&2; exit 5")
        defer { try? FileManager.default.removeItem(at: bad) }
        var failed: Result<DiarizerRunResult, Error>?
        _ = runner.run(executable: bad, arguments: [], onProgress: { _, _ in }, completion: { failed = $0 })
        spin(until: { failed != nil })
        if case .success(let run)? = failed {
            expect(run.exitCode == 5 && run.standardError.contains("cannot create diarizer"), "exit code and stderr tail: \(run)")
        } else { expect(false, "expected a result") }

        // 找不到程式：回傳錯誤，不當機。
        var missing: Result<DiarizerRunResult, Error>?
        _ = runner.run(executable: URL(fileURLWithPath: "/nonexistent/meeting-diarizer"), arguments: [], onProgress: { _, _ in },
                       completion: { missing = $0 })
        spin(until: { missing != nil })
        if case .failure? = missing {} else { expect(false, "launch failure must be reported") }

        // 取消：程式被終止，而且不會再有任何回呼。
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("diarizer-marker-\(UUID().uuidString)")
        let slow = script("echo 'progress 1/9' >&2; sleep 30; touch '\(marker.path)'")
        defer { try? FileManager.default.removeItem(at: slow); try? FileManager.default.removeItem(at: marker) }
        var started = false
        var late = false
        let token = runner.run(executable: slow, arguments: [], onProgress: { _, _ in started = true; }, completion: { _ in late = true })
        spin(until: { started })
        expect(started, "slow process is running")
        token.cancel()
        spin(until: { false }, seconds: 1)
        expect(!late, "no completion after cancel")
        expect(!FileManager.default.fileExists(atPath: marker.path), "process was terminated before finishing")
    }
}
