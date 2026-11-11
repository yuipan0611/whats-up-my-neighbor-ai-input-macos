import Foundation

// 選用的端到端測試的 App 端：用真的 `meeting-diarizer`、真的模型與真的 Process 執行器，
// 對一場「由兩個段檔組成」的會議跑完整條路（問人數 → 辨識 → 對齊 → 備份 → 新逐字稿 → 刪音檔）。
// 由 scripts/spike-meeting-diarization-e2e.sh 啟動，不放進 test-all.sh。
// 用法：MeetingDiarizationE2E <段檔資料夾（chunk-001.m4a…）> <meeting-diarizer> <models 資料夾> <會議長度秒數> <人數>

private struct Locator: MeetingDiarizerLocator {
    let exe: URL
    func executableURL() -> URL? { exe }
    func modelsReady() -> Bool { true }
}

@main
enum MeetingDiarizationE2E {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 6, let seconds = Double(args[4]), let people = Int(args[5]) else {
            FileHandle.standardError.write(Data("usage: E2E <chunks dir> <exe> <models> <seconds> <speakers>\n".utf8))
            exit(2)
        }
        let source = URL(fileURLWithPath: args[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiarizationE2E-\(UUID().uuidString)")
        let store = MeetingStore(root: root, timeZone: TimeZone(identifier: "UTC")!)
        let session = try! store.beginSession(startedAt: Date(), language: "en", chunkSeconds: 300)

        // 每 10 秒一句假的逐字稿（真實 Groq 輸出需要金鑰；這裡只驗證時間軸與整條流程）。
        var records: [MeetingSegmentRecord] = []
        var chunkOffsets: [(Int, TimeInterval)] = []
        let half = seconds / 2
        for (index, offset) in [(1, 0.0), (2, half)] {
            chunkOffsets.append((index, offset))
            try! FileManager.default.copyItem(at: source.appendingPathComponent(MeetingStore.chunkFilename(index)),
                                              to: store.chunkURL(session, index: index))
            var lines: [MeetingLine] = []
            var start = offset
            while start + 10 <= offset + half {
                let n = Int(start / 10) + 1
                lines.append(MeetingLine(offset: start, text: "sentence \(n)"))
                records.append(MeetingSegmentRecord(v: 1, chunk: index, start: start, end: start + 9.5,
                                                    text: "sentence \(n)", words: nil, failed: nil))
                start += 10
            }
            try! store.appendChunk(session, offset: offset, lines: lines)
        }
        try! store.appendSegments(session, records: records)
        try! store.endSession(session, endedAt: Date(), chunks: 2, failedChunks: 0)
        try! store.writeManifest(directory: session.directory, chunks: chunkOffsets)

        let coordinator = MeetingDiarizationCoordinator(
            store: store, locator: Locator(exe: URL(fileURLWithPath: args[2])), runner: ProcessDiarizerRunner(),
            modelsDirectory: { URL(fileURLWithPath: args[3]) },
            askSpeakerCount: { _, completion in completion(.count(people)) })
        var finalState: MeetingDiarizationState?
        var lastPercent = -1
        coordinator.onPhaseChange = { phase in
            if case .running(let done, let total) = phase, total > 0, done * 100 / total != lastPercent {
                lastPercent = done * 100 / total
                FileHandle.standardError.write(Data("progress \(lastPercent)%\n".utf8))
            }
        }
        coordinator.onFinished = { _, state in finalState = state }
        guard coordinator.begin(transcriptURL: session.transcriptURL) else { print("FAIL begin refused"); exit(1) }
        let deadline = Date().addingTimeInterval(900)
        while finalState == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        print("STATE \(finalState?.rawValue ?? "timeout")")
        print("DIR \(session.directory.path)")
        exit(finalState == .done ? 0 : 1)
    }
}
