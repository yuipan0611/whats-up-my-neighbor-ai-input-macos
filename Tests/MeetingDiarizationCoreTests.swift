import Foundation

// 說話者辨識原型裡的純函式測試：段檔時間軸、manifest、對齊演算法。
// 不需要 sherpa、模型或網路，可以放進 test-all.sh。

@main
enum MeetingDiarizationCoreTests {
    static func main() throws {
        try testTimelineInsertsGapsSoLaterChunksKeepTheirTime()
        try testTimelineSortsChunksByOffset()
        try testTimelineKeepsFractionalOffsetsExact()
        try testTimelineOverlapKeepsLaterAudioInPlace()
        try testTimelineDropsChunkInsideEarlierAudio()
        testTimelineRejectsBadOffsets()
        try testManifestDecodingAndValidation()
        try testManifestResolvesPaths()
        try testParseSegmentsJSONL()
        testAlignSegmentLevelWithoutWords()
        testAlignTieAndNearestRules()
        testAlignSplitsSegmentWhenSpeakerChangesInside()
        testAlignKeepsOriginalTextWhenOneSpeaker()
        testAlignAbsorbsFlickerAndShortInterjection()
        testAlignChineseWordsJoinWithoutSpaces()
        testAlignOverlappingTurnsUseMajority()
        testAlignSkipsEmptyText()
        testRender()
        try testFailedChunksSurviveAlignment()
        print("MeetingDiarization core tests passed (18 scenarios)")
    }

    // MARK: helpers

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        precondition(condition(), "\(message) (test line \(line))")
    }

    private static func chunk(_ value: Float, seconds: Double, offset: Double, rate: Int) -> ChunkTimeline.Chunk {
        ChunkTimeline.Chunk(samples: Array(repeating: value, count: Int(seconds * Double(rate))), offset: offset)
    }

    // MARK: ChunkTimeline

    /// 3 段、每段 2 秒、中間 0.4 秒縫隙（M1 的 chunk_gap）：後面的段不能往前漂。
    static func testTimelineInsertsGapsSoLaterChunksKeepTheirTime() throws {
        let rate = 1000
        let result = try ChunkTimeline.assemble([
            chunk(1, seconds: 2, offset: 0, rate: rate),
            chunk(2, seconds: 2, offset: 2.4, rate: rate),
            chunk(3, seconds: 2, offset: 4.8, rate: rate)
        ], sampleRate: rate)
        check(result.samples.count == 6800, "total length should be 6.8 s, got \(result.samples.count)")
        check(result.samples[1999] == 1 && result.samples[2000] == 0, "gap starts right after chunk 1")
        check(result.samples[2399] == 0 && result.samples[2400] == 2, "chunk 2 starts exactly at 2.4 s")
        check(result.samples[4800] == 3, "chunk 3 starts exactly at 4.8 s (naive concatenation would put it at 4.0 s)")
        check(abs(result.duration - 6.8) < 1e-9, "duration")
        check(result.warnings.isEmpty, "no warnings expected")
    }

    static func testTimelineSortsChunksByOffset() throws {
        let rate = 1000
        let result = try ChunkTimeline.assemble([
            chunk(2, seconds: 1, offset: 1.5, rate: rate),
            chunk(1, seconds: 1, offset: 0, rate: rate)
        ], sampleRate: rate)
        check(result.samples[0] == 1 && result.samples[1500] == 2, "chunks must be placed by offset, not by array order")
    }

    /// 16 kHz、offset 300.4 s → 剛好第 4,806,400 個樣本；四捨五入不能偏掉。
    static func testTimelineKeepsFractionalOffsetsExact() throws {
        let rate = 16000
        let result = try ChunkTimeline.assemble([
            ChunkTimeline.Chunk(samples: [1], offset: 0),
            ChunkTimeline.Chunk(samples: [9], offset: 300.4)
        ], sampleRate: rate)
        check(result.samples.count == 4_806_401, "length \(result.samples.count)")
        check(result.samples[4_806_400] == 9, "sample must sit at exactly 300.4 s")
    }

    static func testTimelineOverlapKeepsLaterAudioInPlace() throws {
        let rate = 1000
        // chunk 1 到 2.0 s；chunk 2 宣稱從 1.9 s 開始，長 2 s → 前 0.1 s 重疊要丟掉，其餘仍從 2.0 s 起算。
        let result = try ChunkTimeline.assemble([
            chunk(1, seconds: 2, offset: 0, rate: rate),
            chunk(2, seconds: 2, offset: 1.9, rate: rate)
        ], sampleRate: rate)
        check(result.samples.count == 3900, "end stays at 1.9 + 2.0 s, got \(result.samples.count)")
        check(result.samples[1999] == 1 && result.samples[2000] == 2, "later audio continues without a gap")
        check(result.warnings.count == 1 && result.warnings[0].contains("overlaps"), "overlap must be reported")
    }

    static func testTimelineDropsChunkInsideEarlierAudio() throws {
        let rate = 1000
        let result = try ChunkTimeline.assemble([
            chunk(1, seconds: 5, offset: 0, rate: rate),
            chunk(2, seconds: 1, offset: 2, rate: rate)
        ], sampleRate: rate)
        check(result.samples.count == 5000 && result.samples[2500] == 1, "earlier audio is untouched")
        check(result.warnings.count == 1 && result.warnings[0].contains("dropped"), "drop must be reported")
    }

    static func testTimelineRejectsBadOffsets() {
        for offset in [-1.0, Double.nan, Double.infinity] {
            do {
                _ = try ChunkTimeline.assemble([ChunkTimeline.Chunk(samples: [1], offset: offset)], sampleRate: 1000)
                check(false, "offset \(offset) should throw")
            } catch {}
        }
        do {
            // 把毫秒當成秒的典型錯誤：不能配置巨大的記憶體
            _ = try ChunkTimeline.assemble([ChunkTimeline.Chunk(samples: [1], offset: 5_000_000)], sampleRate: 16000)
            check(false, "absurd offset should throw")
        } catch {}
    }

    // MARK: MeetingManifest

    static func testManifestDecodingAndValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ text: String) throws -> URL {
            let url = directory.appendingPathComponent("m.json")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let good = try MeetingManifest.load(from: write(#"{"version":1,"chunks":[{"path":"chunk-001.m4a","offset":0},{"path":"chunk-002.m4a","offset":300.4}]}"#))
        check(good.chunks.count == 2 && good.chunks[1].offset == 300.4, "decoded chunks")
        for (name, json) in [
            ("version", #"{"version":2,"chunks":[{"path":"a.m4a","offset":0}]}"#),
            ("empty", #"{"version":1,"chunks":[]}"#),
            ("negative", #"{"version":1,"chunks":[{"path":"a.m4a","offset":-1}]}"#),
            ("missing field", #"{"version":1,"chunks":[{"path":"a.m4a"}]}"#),
            ("not json", "nope")
        ] {
            do { _ = try MeetingManifest.load(from: write(json)); check(false, "\(name) should throw") } catch {}
        }
    }

    static func testManifestResolvesPaths() throws {
        let manifestURL = URL(fileURLWithPath: "/tmp/Meetings/2026-11-11_2130/manifest.json")
        let manifest = MeetingManifest(version: 1, chunks: [
            .init(path: "chunk-001.m4a", offset: 0), .init(path: "/abs/chunk.m4a", offset: 1)
        ])
        check(manifest.resolvedURL(for: manifest.chunks[0], relativeTo: manifestURL).path == "/tmp/Meetings/2026-11-11_2130/chunk-001.m4a", "relative path")
        check(manifest.resolvedURL(for: manifest.chunks[1], relativeTo: manifestURL).path == "/abs/chunk.m4a", "absolute path")
    }

    // MARK: SpeakerAligner

    static func testParseSegmentsJSONL() throws {
        let text = """
        {"v":1,"chunk":1,"start":1.5,"end":4.0,"text":"你好","words":[{"w":"你","s":1.5,"e":2.0},{"w":"好","s":2.0,"e":2.5}]}

        {"v":1,"chunk":2,"start":300.4,"end":303.0,"text":"Hello"}
        """
        let records = try SpeakerAligner.parseSegments(jsonl: text)
        check(records.count == 2 && records[0].words?.count == 2 && records[1].words == nil, "records and optional words")
        for (name, bad) in [("bad json", "{oops"), ("version", #"{"v":2,"chunk":1,"start":0,"end":1,"text":"x"}"#),
                            ("end before start", #"{"v":1,"chunk":1,"start":5,"end":1,"text":"x"}"#)] {
            do { _ = try SpeakerAligner.parseSegments(jsonl: bad); check(false, "\(name) should throw") } catch {}
        }
        do {
            _ = try SpeakerAligner.parseSegments(jsonl: text + "\nnot json")
            check(false, "a bad last line must fail the whole file, not be skipped")
        } catch let error as SpeakerAligner.ParseError {
            check("\(error)".contains("line 4"), "error should name the line: \(error)")
        }
    }

    static func testAlignSegmentLevelWithoutWords() {
        let segments = [
            TranscriptSegmentRecord(chunk: 1, start: 0, end: 5, text: "第一句"),
            TranscriptSegmentRecord(chunk: 1, start: 5, end: 10, text: "第二句")
        ]
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 5, end: 10, speaker: 1)]
        let lines = SpeakerAligner.align(segments: segments, turns: turns)
        check(lines.map(\.speaker) == [0, 1] && lines.map(\.text) == ["第一句", "第二句"], "\(lines)")
    }

    static func testAlignTieAndNearestRules() {
        // 重疊一樣久：取較早開始的 turn
        let tie = SpeakerAligner.dominantSpeaker(start: 4, end: 6, turns: [
            SpeakerTurn(start: 0, end: 5, speaker: 7), SpeakerTurn(start: 5, end: 9, speaker: 3)
        ], maxDistance: 1)
        check(tie == 7, "tie goes to the earlier turn, got \(String(describing: tie))")
        // 沒有重疊但在 1 秒內：取最近的
        let near = SpeakerAligner.dominantSpeaker(start: 10.5, end: 11, turns: [SpeakerTurn(start: 0, end: 10, speaker: 2)], maxDistance: 1)
        check(near == 2, "nearest within 1 s")
        // 超過 1 秒：無法歸屬
        let far = SpeakerAligner.dominantSpeaker(start: 12, end: 13, turns: [SpeakerTurn(start: 0, end: 10, speaker: 2)], maxDistance: 1)
        check(far == nil, "too far means unknown")
        let lines = SpeakerAligner.align(segments: [TranscriptSegmentRecord(chunk: 1, start: 50, end: 52, text: "沒人說話的地方")], turns: [])
        check(lines.count == 1 && lines[0].speaker == nil, "no turns at all keeps the line with unknown speaker")
    }

    static func testAlignSplitsSegmentWhenSpeakerChangesInside() {
        func words(_ items: [(String, Double)]) -> [TranscriptSegmentRecord.Word] {
            items.map { .init(w: $0.0, s: $0.1, e: $0.1 + 0.5) }
        }
        // 10–20 秒的 segment，15 秒換人，雙方都說了 2 秒以上（超過 minimumRunSeconds）
        let w = words([(" I", 10), (" think", 10.5), (" so", 11), (" yes", 11.5), (" agreed", 12), (" good", 12.5),
                       (" Then", 15), (" let's", 15.5), (" go", 16), (" ahead", 16.5), (" now", 17), (" please", 17.5)])
        let segment = TranscriptSegmentRecord(chunk: 1, start: 10, end: 18, text: "I think so, yes agreed good. Then let's go ahead now please.", words: w)
        let lines = SpeakerAligner.align(segments: [segment], turns: [
            SpeakerTurn(start: 10, end: 14.9, speaker: 0), SpeakerTurn(start: 15, end: 18, speaker: 1)
        ])
        check(lines.count == 2, "expected a split, got \(lines)")
        check(lines[0].speaker == 0 && lines[0].text == "I think so yes agreed good", "first half: \(lines[0])")
        check(lines[1].speaker == 1 && lines[1].text == "Then let's go ahead now please", "second half: \(lines[1])")
        check(abs(lines[1].start - 15) < 1e-9, "second line starts at its first word")
    }

    static func testAlignKeepsOriginalTextWhenOneSpeaker() {
        let w: [TranscriptSegmentRecord.Word] = [.init(w: " Hello", s: 1, e: 1.5), .init(w: " world", s: 1.5, e: 3)]
        let segment = TranscriptSegmentRecord(chunk: 1, start: 1, end: 3, text: " Hello, world! ", words: w)
        let lines = SpeakerAligner.align(segments: [segment], turns: [SpeakerTurn(start: 0, end: 4, speaker: 2)])
        check(lines == [AlignedLine(start: 1, end: 3, speaker: 2, text: "Hello, world!")], "punctuation from the segment text must survive: \(lines)")
    }

    static func testAlignAbsorbsFlickerAndShortInterjection() {
        // A A B A A A，B 只有 0.2 秒 → 邊界抖動，不切行
        var w: [TranscriptSegmentRecord.Word] = []
        for index in 0..<6 { w.append(.init(w: " w\(index)", s: Double(index), e: Double(index) + (index == 2 ? 0.2 : 0.9))) }
        let flicker = SpeakerAligner.align(
            segments: [TranscriptSegmentRecord(chunk: 1, start: 0, end: 6, text: "原文。", words: w)],
            turns: [SpeakerTurn(start: 0, end: 2, speaker: 0), SpeakerTurn(start: 2, end: 2.2, speaker: 1), SpeakerTurn(start: 2.2, end: 6, speaker: 0)])
        check(flicker.count == 1 && flicker[0].speaker == 0 && flicker[0].text == "原文。", "\(flicker)")

        // 插話 0.6 秒（比 1 秒短，但每個詞都比 0.3 秒長，所以不是抖動）→ 仍然併回，不切行
        var w2: [TranscriptSegmentRecord.Word] = []
        for index in 0..<8 { w2.append(.init(w: " v\(index)", s: Double(index), e: Double(index) + 1)) }
        let interjection = SpeakerAligner.align(
            segments: [TranscriptSegmentRecord(chunk: 1, start: 0, end: 8, text: "原文二。", words: w2)],
            turns: [SpeakerTurn(start: 0, end: 3.7, speaker: 0), SpeakerTurn(start: 3.7, end: 4.3, speaker: 1), SpeakerTurn(start: 4.3, end: 8, speaker: 0)])
        check(interjection.count == 1 && interjection[0].speaker == 0, "short interjection should not split the line: \(interjection)")
    }

    static func testAlignChineseWordsJoinWithoutSpaces() {
        var w: [TranscriptSegmentRecord.Word] = []
        for (index, token) in ["我們", "先", "看", "時程", "好", "的", "沒問題", "謝謝"].enumerated() {
            w.append(.init(w: token, s: Double(index) * 0.6, e: Double(index) * 0.6 + 0.6))
        }
        let lines = SpeakerAligner.align(
            segments: [TranscriptSegmentRecord(chunk: 1, start: 0, end: 4.8, text: "我們先看時程。好的，沒問題，謝謝。", words: w)],
            turns: [SpeakerTurn(start: 0, end: 2.4, speaker: 0), SpeakerTurn(start: 2.4, end: 4.8, speaker: 1)])
        check(lines.map(\.text) == ["我們先看時程", "好的沒問題謝謝"], "\(lines.map(\.text))")
        check(lines.map(\.speaker) == [0, 1], "speakers")
    }

    static func testAlignOverlappingTurnsUseMajority() {
        // 兩個人的 turn 重疊（sherpa 允許）：該詞與 speaker 1 重疊 0.8 秒、與 speaker 0 重疊 0.2 秒
        let speaker = SpeakerAligner.dominantSpeaker(start: 1, end: 2, turns: [
            SpeakerTurn(start: 0, end: 1.2, speaker: 0), SpeakerTurn(start: 1.2, end: 3, speaker: 1)
        ], maxDistance: 1)
        check(speaker == 1, "majority overlap wins")
    }

    static func testAlignSkipsEmptyText() {
        let lines = SpeakerAligner.align(
            segments: [TranscriptSegmentRecord(chunk: 1, start: 0, end: 2, text: "  \n "), TranscriptSegmentRecord(chunk: 1, start: 2, end: 4, text: "有字")],
            turns: [SpeakerTurn(start: 0, end: 4, speaker: 0)])
        check(lines.map(\.text) == ["有字"], "empty-text segments are dropped")
    }

    static func testFailedChunksSurviveAlignment() throws {
        let records = try SpeakerAligner.parseSegments(jsonl: """
        {"v":1,"chunk":1,"start":0,"end":5,"text":"前面","words":null}
        {"v":1,"chunk":2,"start":300,"end":600,"text":"","failed":"HTTP 429\\nrate limited"}
        {"v":1,"chunk":3,"start":600.4,"end":603,"text":"後面"}
        """)
        let lines = SpeakerAligner.align(segments: records, turns: [SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 600.4, end: 603, speaker: 1)])
        check(lines.count == 3 && lines[1].failureNote == "HTTP 429\nrate limited" && lines[1].speaker == nil, "failure marker keeps its place: \(lines)")
        check(SpeakerAligner.render(lines[1]) == "> ⚠️ [00:05:00] 這段辨識失敗：HTTP 429 rate limited", SpeakerAligner.render(lines[1]))
        check(lines[0].speaker == 0 && lines[2].speaker == 1, "neighbors are still aligned")
    }

    static func testRender() {
        let line = AlignedLine(start: 4331.9, end: 4335, speaker: 1, text: "第一行\n  第二行 ")
        check(SpeakerAligner.render(line) == "[01:12:11] Speaker 2：第一行 第二行", SpeakerAligner.render(line))
        check(SpeakerAligner.render(line, names: [1: "Tom"]) == "[01:12:11] Tom：第一行 第二行", "rename")
        check(SpeakerAligner.render(line, names: [1: "  "]) == "[01:12:11] Speaker 2：第一行 第二行", "blank name falls back")
        check(SpeakerAligner.render(AlignedLine(start: 72, end: 75, speaker: nil, text: "嗯")) == "[00:01:12] Speaker ?：嗯", "unknown speaker")
        check(SpeakerAligner.timestamp(-3) == "00:00:00" && SpeakerAligner.timestamp(.nan) == "00:00:00", "timestamp guards")
    }
}
