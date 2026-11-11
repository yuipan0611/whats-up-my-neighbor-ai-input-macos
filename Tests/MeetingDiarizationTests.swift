import AppKit
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
    /// 假的 pid：macOS 的 pid 上限是 99999，這個一定不存在（`kill(pid, 0)` 回 ESRCH）。
    static let deadPID: Int32 = 1_999_999

    static func main() throws {
        // 跨行程測試用：另一個行程持有擁有者鎖，直到被殺掉。
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hold-owner" {
            guard let lock = DiarizationOwnerLock.acquire(in: URL(fileURLWithPath: CommandLine.arguments[2]), instance: "child") else {
                print("FAILED-TO-LOCK"); exit(3)
            }
            print("READY"); fflush(stdout)
            withExtendedLifetime(lock) { sleep(60) }
            exit(0)
        }
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
        testDeleteInstalledModels()
        testModelDeletionNeverLeavesTheModelsFolder()
        testAudioDeletionOnlyRemovesOwnedRegularFiles()
        testStartupScanRespectsOwnership()
        testStartupScanAcrossProcesses()
        testCoordinatorHoldsAndReleasesTheOwnerLock()
        testQuitCancelIsSilent()
        testLockFileIsStableAndNeverDeleted()
        testLockSurvivesReleaseSoAnOpenedDescriptorStillExcludesNewOwners()
        testDialogTexts()
        testRealProcessRunner()
        print("MeetingDiarization tests passed (29 scenarios)")
    }

    /// 在會議資料夾寫一個擁有者檔但不持鎖（模擬「擁有者行程已經結束」或「別的行程」）。
    static func plantOwner(in directory: URL, pid: Int32, start: Double? = nil) {
        let record = DiarizationOwnerRecord(v: 1, pid: pid, processStart: start, instance: "test", createdAt: 0)
        try! JSONEncoder().encode(record).write(to: directory.appendingPathComponent(DiarizationOwnerLock.filename))
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(DiarizationOwnerLock.lockFilename).path) {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(DiarizationOwnerLock.lockFilename).path, contents: Data())
        }
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
        expect(f.store.markInterruptedDiarizations().isEmpty, "this process is still alive and owns the queued job's record: not touched")
        plantOwner(in: second.directory, pid: deadPID)   // 模擬「上次的 App 已經結束」
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
        plantOwner(in: f.directory, pid: deadPID)
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

    // MARK: 模型刪除與對話框

    static func testDeleteInstalledModels() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ModelsTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let assets = MeetingDiarizerAssets(modelsDirectory: dir)
        expect(!assets.hasInstalledFiles && !assets.canDeleteModels(featureEnabled: false, diarizationBusy: false), "nothing to delete in an empty/missing folder")
        for model in MeetingDiarizerModelCatalog.all {
            let url = assets.installedURL(for: model)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data([1]).write(to: url)
        }
        let staleStaging = dir.appendingPathComponent(".download-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: staleStaging, withIntermediateDirectories: true)
        try! Data([1]).write(to: staleStaging.appendingPathComponent("download-1.part"))
        try! Data("mine".utf8).write(to: dir.appendingPathComponent("keep.txt"))
        expect(assets.hasInstalledFiles, "installed files are seen")
        expect(!assets.canDeleteModels(featureEnabled: true, diarizationBusy: false), "cannot delete while the feature is on")
        expect(!assets.canDeleteModels(featureEnabled: false, diarizationBusy: true), "cannot delete while diarization runs")
        expect(assets.canDeleteModels(featureEnabled: false, diarizationBusy: false), "can delete once the feature is off and idle")
        expect(assets.deleteInstalledModels() == MeetingDiarizerModelCatalog.all.count, "both model files removed")
        expect(!assets.hasInstalledFiles && !FileManager.default.fileExists(atPath: staleStaging.path), "models and stale staging gone")
        expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep.txt").path) && FileManager.default.fileExists(atPath: dir.path),
               "unrelated files (and so the folder) are left alone")
        expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pyannote-segmentation").path), "emptied sub-folder removed")
        // 只剩我們的檔案時，連 models 資料夾一起收掉。
        try! FileManager.default.removeItem(at: dir.appendingPathComponent("keep.txt"))
        let first = MeetingDiarizerModelCatalog.all[0]
        let url = assets.installedURL(for: first)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data([1]).write(to: url)
        expect(assets.deleteInstalledModels() == 1 && !FileManager.default.fileExists(atPath: dir.path), "empty models folder removed")
        expect(assets.deleteInstalledModels() == 0, "deleting again is a no-op")
    }

    static func testDialogTexts() {
        _ = NSApplication.shared
        let withDownload = MeetingDiarizationDialogs.privacyAlert(modelsNeedDownload: true).informativeText
        expect(withDownload.contains("約 35.2 MB 的模型") && withDownload.contains("只存放在這台 Mac"), "privacy: download notice and local storage: \(withDownload)")
        expect(withDownload.contains("Groq"), "privacy: does not claim the recording never leaves the Mac")
        expect(!MeetingDiarizationDialogs.privacyAlert(modelsNeedDownload: false).informativeText.contains("接下來會請你下載"), "no download notice once models exist")
        let dialog = MeetingDiarizationDialogs.speakerCountAlert(last: .count(4))
        expect(dialog.alert.informativeText.contains("略過") && dialog.alert.informativeText.contains("音檔會保留")
               && dialog.alert.informativeText.contains("1 小時的會議約需 10 分鐘以上"), "speaker count: skip keeps audio, duration: \(dialog.alert.informativeText)")
        expect(dialog.popup.itemTitles == ["2 人", "3 人", "4 人", "5 人", "6 人", "不確定"], "choices")
        expect(MeetingDiarizationDialogs.choice(from: dialog.popup) == .count(4), "defaults to the last choice")
        dialog.popup.selectItem(at: 5)
        expect(MeetingDiarizationDialogs.choice(from: dialog.popup) == .auto, "last item is auto")
        expect(MeetingDiarizationDialogs.choice(from: MeetingDiarizationDialogs.speakerCountAlert(last: nil).popup) == .count(2), "default 2 people")
        let consent = MeetingDiarizerDownloadText.consentMessage(for: MeetingDiarizerModelCatalog.all, directory: URL(fileURLWithPath: "/tmp/m"))
        expect(consent.contains("\n\n存放位置") && consent.contains("\n\n說話者辨識本身") && consent.contains("刪除已下載的模型"), "consent: blank lines and deletion hint")
    }

    // MARK: 刪除的邊界（Codex 審查探針的回歸測試）

    private static func tempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func write(_ url: URL, _ text: String = "x") {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    static func testModelDeletionNeverLeavesTheModelsFolder() {
        var skipped: [String] = []
        SafeFileRemoval.onSkip = { skipped.append($0) }
        defer { SafeFileRemoval.onSkip = { NSLog("[SafeFileRemoval] skipped: %@", $0) } }
        let models = MeetingDiarizerModelCatalog.all
        let segmentationPath = models[0].installPath      // pyannote-segmentation/model.onnx
        let embeddingPath = models[1].installPath         // speaker-embedding.onnx

        // 1. 與模型同名的「資料夾」，裡面有不相關的巢狀檔：整個保留，也不會被當成「已安裝」而顯示刪除選單。
        let a = tempDir("ModelsA"); defer { try? FileManager.default.removeItem(at: a) }
        let aAssets = MeetingDiarizerAssets(modelsDirectory: a)
        let dirNamedLikeModel = a.appendingPathComponent(embeddingPath)
        write(dirNamedLikeModel.appendingPathComponent("nested/precious.txt"), "keep")
        expect(!aAssets.hasInstalledFiles && !aAssets.canDeleteModels(featureEnabled: false, diarizationBusy: false),
               "a folder with a model's name is not an installed model, so no delete menu")
        expect(aAssets.deleteInstalledModels() == 0, "nothing deleted")
        expect(exists(dirNamedLikeModel.appendingPathComponent("nested/precious.txt")), "folder with the reserved name and its contents survive")
        expect(!skipped.isEmpty, "the skip is recorded")

        // 2. 上層是 symlink（導到 models 以外）：外部的模型檔不能被刪。
        let b = tempDir("ModelsB"); let outside = tempDir("Outside")
        defer { try? FileManager.default.removeItem(at: b); try? FileManager.default.removeItem(at: outside) }
        write(outside.appendingPathComponent("model.onnx"), "external model")
        try! FileManager.default.createSymbolicLink(at: b.appendingPathComponent("pyannote-segmentation"), withDestinationURL: outside)
        let bAssets = MeetingDiarizerAssets(modelsDirectory: b)
        expect(!bAssets.hasInstalledFiles, "a path through a symlinked parent is not counted")
        expect(bAssets.deleteInstalledModels() == 0, "nothing deleted through the symlink")
        expect(exists(outside.appendingPathComponent("model.onnx")), "external model file survives")
        expect(exists(b.appendingPathComponent("pyannote-segmentation")), "the symlink itself is left alone")

        // 3. models 資料夾本身是 symlink：什麼都不刪。
        let c = tempDir("ModelsC"); let real = tempDir("RealModels")
        defer { try? FileManager.default.removeItem(at: c); try? FileManager.default.removeItem(at: real) }
        write(real.appendingPathComponent(segmentationPath)); write(real.appendingPathComponent(embeddingPath))
        let link = c.appendingPathComponent("models")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let cAssets = MeetingDiarizerAssets(modelsDirectory: link)
        expect(!cAssets.hasInstalledFiles && cAssets.deleteInstalledModels() == 0, "symlinked models root: nothing counted or deleted")
        expect(exists(real.appendingPathComponent(segmentationPath)) && exists(real.appendingPathComponent(embeddingPath)), "files behind the symlinked root survive")

        // 4. 模型檔本身是 symlink（指到外部）：只當作不是我們的檔案，不刪連結也不刪目標。
        let d = tempDir("ModelsD"); let target = tempDir("Target")
        defer { try? FileManager.default.removeItem(at: d); try? FileManager.default.removeItem(at: target) }
        write(target.appendingPathComponent("real.onnx"))
        try! FileManager.default.createSymbolicLink(at: d.appendingPathComponent(embeddingPath), withDestinationURL: target.appendingPathComponent("real.onnx"))
        expect(MeetingDiarizerAssets(modelsDirectory: d).deleteInstalledModels() == 0 && exists(target.appendingPathComponent("real.onnx")), "symlinked model file: target survives")

        // 5. 暫存：名稱不符的 .download-* 資料夾、裡面有不認識東西的暫存資料夾都不能被刪。
        let e = tempDir("ModelsE"); defer { try? FileManager.default.removeItem(at: e) }
        let eAssets = MeetingDiarizerAssets(modelsDirectory: e)
        write(e.appendingPathComponent(".download-mine/important.txt"), "keep")            // 不符合 UUID 命名
        let uuidStaging = e.appendingPathComponent(".download-\(UUID().uuidString)")
        write(uuidStaging.appendingPathComponent("download-1.part"))
        write(uuidStaging.appendingPathComponent("unknown-dir/data.bin"), "keep")         // 不認識的子資料夾
        let cleanStaging = e.appendingPathComponent(".download-\(UUID().uuidString)")
        write(cleanStaging.appendingPathComponent("download-1.part"))
        write(cleanStaging.appendingPathComponent("extract-\(UUID().uuidString)/pkg/model.onnx"))
        write(e.appendingPathComponent(segmentationPath)); write(e.appendingPathComponent(embeddingPath))
        expect(eAssets.deleteInstalledModels() == 2, "both owned model files removed")
        expect(exists(e.appendingPathComponent(".download-mine/important.txt")), "non-UUID .download-* folder survives")
        expect(exists(uuidStaging.appendingPathComponent("unknown-dir/data.bin")), "staging with an unknown sub-folder is left alone")
        expect(!exists(uuidStaging.appendingPathComponent("download-1.part")), "its known .part file was removed")
        expect(!exists(cleanStaging), "fully-owned staging folder is removed")
        expect(exists(e), "models folder stays because it still holds other things")
    }

    static func testAudioDeletionOnlyRemovesOwnedRegularFiles() {
        let f = Fixture()
        let store = f.store
        var skipped: [String] = []
        SafeFileRemoval.onSkip = { skipped.append($0) }
        defer { SafeFileRemoval.onSkip = { NSLog("[SafeFileRemoval] skipped: %@", $0) } }
        let dir = f.directory
        // 同名資料夾與 symlink：不是音檔。
        try! FileManager.default.removeItem(at: dir.appendingPathComponent("chunk-002.m4a"))
        write(dir.appendingPathComponent("chunk-002.m4a/precious.txt"), "keep")
        let outside = tempDir("AudioOutside"); defer { try? FileManager.default.removeItem(at: outside) }
        write(outside.appendingPathComponent("external.m4a"), "keep")
        try! FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("chunk-003.m4a"), withDestinationURL: outside.appendingPathComponent("external.m4a"))
        try! FileManager.default.removeItem(at: dir.appendingPathComponent("manifest.json"))
        write(dir.appendingPathComponent("manifest.json/inner.txt"), "keep")           // manifest 也被換成資料夾
        expect(store.chunkFiles(in: dir).map(\.lastPathComponent) == ["chunk-001.m4a"], "only the regular file counts as a chunk")
        expect(store.deleteAudio(directory: dir) == 1, "only the one real chunk file removed")
        expect(!exists(dir.appendingPathComponent("chunk-001.m4a")), "real chunk removed")
        expect(exists(dir.appendingPathComponent("chunk-002.m4a/precious.txt")), "folder named like a chunk survives with its contents")
        expect(exists(outside.appendingPathComponent("external.m4a")), "symlink target outside survives")
        expect(exists(dir.appendingPathComponent("manifest.json/inner.txt")), "folder named manifest.json survives")
        expect(exists(f.transcriptURL) && exists(dir.appendingPathComponent("segments.jsonl")), "other files untouched")
        expect(!skipped.isEmpty, "the manifest skip is recorded: \(skipped)")
    }

    // MARK: 啟動掃描的擁有權

    static func testStartupScanRespectsOwnership() {
        func fresh(_ label: String) -> Fixture {
            let f = Fixture()
            try! f.store.setFrontmatter([("diarization", "running")], transcriptURL: f.transcriptURL)
            return f
        }
        // 沒有鎖檔也沒有擁有者檔：不動（無法確定沒有人在處理）。
        let none = fresh("none")
        expect(none.store.markInterruptedDiarizations().isEmpty && none.store.diarizationState(for: none.transcriptURL) == .running, "no owner file: left alone")
        // 擁有者行程還活著（pid 是自己，沒人持鎖）：不動。
        let alive = fresh("alive")
        plantOwner(in: alive.directory, pid: getpid(), start: ProcessIdentity.startTime(pid: getpid()))
        expect(alive.store.markInterruptedDiarizations().isEmpty, "owner process is alive: left alone")
        // 有人持鎖（同一行程另開一個 fd 也算）：不動。
        let locked = fresh("locked")
        let held = DiarizationOwnerLock.acquire(in: locked.directory, instance: "other")!
        expect(locked.store.markInterruptedDiarizations().isEmpty && locked.store.diarizationState(for: locked.transcriptURL) == .running,
               "owner holds the lock: left alone, state stays running")
        held.release(deleteFile: true)
        // 檔案壞掉：不動。
        let corrupt = fresh("corrupt")
        plantOwner(in: corrupt.directory, pid: deadPID)
        try! Data("not json".utf8).write(to: corrupt.directory.appendingPathComponent(DiarizationOwnerLock.filename))
        expect(corrupt.store.markInterruptedDiarizations().isEmpty, "unreadable owner record: left alone")
        // pid 已不存在：標 interrupted，並清掉擁有者檔。
        let dead = fresh("dead")
        plantOwner(in: dead.directory, pid: deadPID)
        expect(dead.store.markInterruptedDiarizations() == [dead.transcriptURL] && dead.store.diarizationState(for: dead.transcriptURL) == .interrupted, "dead owner: interrupted")
        expect(!exists(dead.directory.appendingPathComponent(DiarizationOwnerLock.filename)), "owner file removed once handled")
        // pid 被別的行程重用（啟動時間不符）：視為已死。
        let reused = fresh("reused")
        plantOwner(in: reused.directory, pid: getpid(), start: (ProcessIdentity.startTime(pid: getpid()) ?? 0) - 100_000)
        expect(reused.store.markInterruptedDiarizations() == [reused.transcriptURL], "reused pid counts as dead")
        // 狀態不是 pending／running：即使擁有者已死也不動。
        let done = Fixture()
        try! done.store.setFrontmatter([("diarization", "done")], transcriptURL: done.transcriptURL)
        plantOwner(in: done.directory, pid: deadPID)
        expect(done.store.markInterruptedDiarizations().isEmpty, "terminal states are never rewritten")
    }

    /// 真的跨行程：另一個行程持鎖時掃描不改狀態；它被殺掉（鎖與 pid 都消失）之後才改。
    static func testStartupScanAcrossProcesses() {
        let f = Fixture()
        try! f.store.setFrontmatter([("diarization", "running")], transcriptURL: f.transcriptURL)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold-owner", f.directory.path]
        let pipe = Pipe()
        child.standardOutput = pipe
        try! child.run()
        let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        expect(line.hasPrefix("READY"), "the other process took the lock: \(line)")
        expect(f.store.markInterruptedDiarizations().isEmpty, "another live instance owns it: untouched")
        expect(f.store.diarizationState(for: f.transcriptURL) == .running, "state unchanged")
        expect(DiarizationOwnerLock.acquire(in: f.directory, instance: "me") == nil, "cannot take over a held job")
        let coordinatorLike = f.coordinator.begin(transcriptURL: f.transcriptURL)
        expect(!coordinatorLike && f.runner.calls.isEmpty, "a coordinator in this instance refuses a meeting another instance is processing")
        expect(f.store.diarizationState(for: f.transcriptURL) == .running, "and does not touch its state")
        child.terminate(); child.waitUntilExit()
        expect(f.store.markInterruptedDiarizations() == [f.transcriptURL], "after the owner died: interrupted")
    }

    static func testCoordinatorHoldsAndReleasesTheOwnerLock() {
        let f = Fixture()
        let second = f.addMeeting()
        let ownerFile = f.directory.appendingPathComponent(DiarizationOwnerLock.filename)
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        expect(exists(ownerFile), "owner file exists while running")
        expect(DiarizationOwnerLock.acquire(in: f.directory, instance: "x") == nil, "and the lock is held")
        expect(f.store.markInterruptedDiarizations().isEmpty, "own live job is never marked by the scan")
        f.coordinator.begin(transcriptURL: second.transcriptURL)
        expect(exists(second.directory.appendingPathComponent(DiarizationOwnerLock.filename)), "queued job is owned too")
        f.succeed(0)
        expect(!exists(ownerFile), "finished job: owner file removed")
        f.succeed(1)
        expect(!exists(second.directory.appendingPathComponent(DiarizationOwnerLock.filename)), "second finished: owner file removed")
    }

    /// 鎖檔固定存在、永遠不刪：放鎖、完成、掃描接手、刪音檔、SafeFileRemoval 都不能動它。
    static func testLockFileIsStableAndNeverDeleted() {
        let dir = tempDir("LockStable"); defer { try? FileManager.default.removeItem(at: dir) }
        let lockURL = dir.appendingPathComponent(DiarizationOwnerLock.lockFilename)
        func inode() -> UInt64? { var s = stat(); return stat(lockURL.path, &s) == 0 ? UInt64(s.st_ino) : nil }
        let first = DiarizationOwnerLock.acquire(in: dir, instance: "a")!
        let ino = inode()
        expect(ino != nil && exists(dir.appendingPathComponent(DiarizationOwnerLock.filename)), "lock file and owner record exist")
        first.release(deleteFile: true)
        expect(inode() == ino && !exists(dir.appendingPathComponent(DiarizationOwnerLock.filename)), "release clears the owner record but keeps the very same lock file")
        let second = DiarizationOwnerLock.acquire(in: dir, instance: "b")!
        second.release(deleteFile: false)
        expect(inode() == ino && exists(dir.appendingPathComponent(DiarizationOwnerLock.filename)), "release without delete keeps the owner record (queued jobs)")
        // 掃描接手（擁有者已死）之後鎖檔還在、inode 不變。
        plantOwner(in: dir, pid: deadPID)
        let claimed = DiarizationOwnerLock.claimIfAbandoned(in: dir)
        expect(claimed != nil, "abandoned owner is claimed")
        claimed?.release(deleteFile: true)
        expect(inode() == ino, "claiming and releasing never replaces the lock file")
        // 刪音檔與 SafeFileRemoval 不會刪它（它不是音檔、不是 manifest、不是暫存）。
        try! Data([1]).write(to: dir.appendingPathComponent("chunk-001.m4a"))
        let store = MeetingStore(root: dir.deletingLastPathComponent())
        expect(store.deleteAudio(directory: dir) == 1 && inode() == ino, "deleteAudio leaves diarization.lock alone")
        expect(SafeFileRemoval.removeRegularFile(dir.appendingPathComponent("chunk-001.m4a"), within: dir) == false, "sanity: nothing left to remove")
        expect(inode() == ino, "lock file still the same inode")
        // 刪音檔會自己的規則：只認 chunk-NNN.m4a 與 manifest.json。
        expect(!"diarization.lock".hasSuffix(".m4a") && "diarization.lock" != MeetingStore.manifestFilename, "name is outside the deletable set")
    }

    /// Codex 的競態：有人已經 open 了鎖檔、還沒 flock；持鎖者放鎖後它鎖到同一個 inode，
    /// 新的 acquire 必須失敗（鎖檔沒有被 unlink 換成新 inode）。
    static func testLockSurvivesReleaseSoAnOpenedDescriptorStillExcludesNewOwners() {
        let dir = tempDir("LockRace"); defer { try? FileManager.default.removeItem(at: dir) }
        let first = DiarizationOwnerLock.acquire(in: dir, instance: "first")!
        let early = open(dir.appendingPathComponent(DiarizationOwnerLock.lockFilename).path, O_RDWR | O_NOFOLLOW)   // 已 open、還沒 flock
        expect(early >= 0, "another process had already opened the lock file")
        first.release(deleteFile: true)
        expect(flock(early, LOCK_EX | LOCK_NB) == 0, "it locks the same (never unlinked) inode")
        expect(DiarizationOwnerLock.acquire(in: dir, instance: "third") == nil, "a new acquire must fail while that lock is held: no double ownership")
        expect(DiarizationOwnerLock.claimIfAbandoned(in: dir) == nil, "and the scan cannot take it either")
        flock(early, LOCK_UN); close(early)
        expect(DiarizationOwnerLock.acquire(in: dir, instance: "fourth") != nil, "free again once released")
    }

    // App 結束：取消不發任何回呼（不啟動摘要、不更新選單），但狀態與音檔照寫照留。
    static func testQuitCancelIsSilent() {
        let f = Fixture()
        let second = f.addMeeting()
        f.coordinator.begin(transcriptURL: f.transcriptURL)
        f.coordinator.begin(transcriptURL: second.transcriptURL)
        let phasesBefore = f.phases.count
        f.coordinator.cancel(notify: false)
        expect(f.finished.isEmpty && f.phases.count == phasesBefore, "no terminal callback during quit")
        expect(f.store.diarizationState(for: f.transcriptURL) == .cancelled, "state still written")
        expect(!exists(f.directory.appendingPathComponent(DiarizationOwnerLock.filename)), "terminal job released its owner file")
        expect(exists(second.directory.appendingPathComponent(DiarizationOwnerLock.filename)), "queued job keeps its (unlocked) owner file for the next launch")
        expect(DiarizationOwnerLock.acquire(in: second.directory, instance: "next") != nil, "its lock was released")
        expect(f.runner.calls[0].token.cancelCount == 1, "process cancelled")
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
