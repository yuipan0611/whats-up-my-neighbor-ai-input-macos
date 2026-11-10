import Foundation

// 把 Groq 的逐字稿（segments.jsonl）和說話者時間段（meeting-diarizer 的輸出）對齊，
// 得到「每一行是誰說的」。純函式，不碰檔案、不碰網路、不接 App。
// 演算法與取捨見 docs/spikes/2026-11-diarization-s1.md §6.2 與 m2-design.md §4。

/// segments.jsonl 的一行（schema 見設計檔附錄 A）。時間都是整場會議的相對秒數。
struct TranscriptSegmentRecord: Codable, Equatable {
    struct Word: Codable, Equatable {
        /// 詞本身。Whisper 的英文詞常帶前導空白，保留原樣，輸出時才整理。
        let w: String
        let s: Double
        let e: Double
    }

    let v: Int
    let chunk: Int
    let start: Double
    let end: Double
    let text: String
    let words: [Word]?
    /// 這一段辨識失敗時的原因（此時 `text` 為空字串）。重新產生逐字稿時要把失敗標記留在原本的時間位置。
    let failed: String?

    init(v: Int = 1, chunk: Int, start: Double, end: Double, text: String,
         words: [Word]? = nil, failed: String? = nil) {
        self.v = v; self.chunk = chunk; self.start = start; self.end = end; self.text = text
        self.words = words; self.failed = failed
    }
}

/// meeting-diarizer 輸出的一段說話者時間（`segments` 陣列裡的元素）。`label` 對齊不需要，解碼時忽略。
struct SpeakerTurn: Codable, Equatable {
    let start: Double
    let end: Double
    let speaker: Int
}

/// 對齊後的一行。`speaker == nil` 代表無法歸屬（顯示成 `Speaker ?`）。
struct AlignedLine: Equatable {
    let start: Double
    let end: Double
    let speaker: Int?
    let text: String
    /// 非 nil 代表這是「這段辨識失敗」的標記行（沒有說話者、沒有文字）。
    var failureNote: String? = nil
}

enum SpeakerAligner {
    struct Options {
        /// 詞的時間離任何說話段落都超過這個距離才算「無法歸屬」。
        var maxNearestDistance: Double = 1.0
        /// 單一詞短於這個長度，且前後兩個詞同一個人時，視為邊界抖動，改成前後那個人。
        var flickerWordSeconds: Double = 0.3
        /// 一個 segment 內，某位說話者連續的時間短於這個長度就併回相鄰的人，不為了很短的插話切行。
        var minimumRunSeconds: Double = 1.0
    }

    // MARK: segments.jsonl

    enum ParseError: Error, CustomStringConvertible {
        case badLine(Int, String)
        case unsupportedVersion(Int, Int)
        var description: String {
            switch self {
            case .badLine(let number, let message): return "segments.jsonl line \(number): \(message)"
            case .unsupportedVersion(let number, let version): return "segments.jsonl line \(number): unsupported version \(version)"
            }
        }
    }

    /// 每行一個 JSON。空行略過；任何一行壞掉就整份失敗，**不默默丟資料**（呼叫端決定要不要退回純文字逐字稿）。
    static func parseSegments(jsonl: String) throws -> [TranscriptSegmentRecord] {
        let decoder = JSONDecoder()
        var records: [TranscriptSegmentRecord] = []
        for (index, line) in jsonl.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            do {
                let record = try decoder.decode(TranscriptSegmentRecord.self, from: Data(trimmed.utf8))
                guard record.v == 1 else { throw ParseError.unsupportedVersion(index + 1, record.v) }
                guard record.start.isFinite, record.end.isFinite, record.start >= 0, record.end >= record.start else {
                    throw ParseError.badLine(index + 1, "invalid start/end")
                }
                records.append(record)
            } catch let error as ParseError {
                throw error
            } catch {
                throw ParseError.badLine(index + 1, error.localizedDescription)
            }
        }
        return records
    }

    // MARK: 對齊

    static func align(segments: [TranscriptSegmentRecord], turns: [SpeakerTurn],
                      options: Options = Options()) -> [AlignedLine] {
        let sortedTurns = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var lines: [AlignedLine] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let reason = segment.failed {
                lines.append(AlignedLine(start: segment.start, end: segment.end, speaker: nil, text: "", failureNote: reason))
                continue
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let words = segment.words, !words.isEmpty {
                lines.append(contentsOf: alignWords(segment: segment, text: text, words: words,
                                                    turns: sortedTurns, options: options))
            } else {
                // 沒有字級時間：整個 segment 取重疊最長的人，不切行（沒有字時間就無法切文字）。
                guard !text.isEmpty else { continue }
                let speaker = dominantSpeaker(start: segment.start, end: segment.end, turns: sortedTurns,
                                              maxDistance: options.maxNearestDistance)
                lines.append(AlignedLine(start: segment.start, end: segment.end, speaker: speaker, text: text))
            }
        }
        return lines
    }

    private static func alignWords(segment: TranscriptSegmentRecord, text: String,
                                   words: [TranscriptSegmentRecord.Word], turns: [SpeakerTurn],
                                   options: Options) -> [AlignedLine] {
        // 1. 每個詞取重疊最長的說話者
        var speakers: [Int?] = words.map {
            dominantSpeaker(start: $0.s, end: $0.e, turns: turns, maxDistance: options.maxNearestDistance)
        }
        // 2. 沒有歸屬的詞沿用前一個詞，開頭的沿用後一個詞
        for index in speakers.indices where speakers[index] == nil && index > 0 { speakers[index] = speakers[index - 1] }
        for index in speakers.indices.reversed() where speakers[index] == nil && index + 1 < speakers.count {
            speakers[index] = speakers[index + 1]
        }
        // 3. 邊界抖動：A B A 且 B 很短 → A A A
        if words.count >= 3 {
            for index in 1..<(words.count - 1) {
                guard let previous = speakers[index - 1], let next = speakers[index + 1],
                      previous == next, speakers[index] != previous,
                      words[index].e - words[index].s < options.flickerWordSeconds else { continue }
                speakers[index] = previous
            }
        }
        // 4. 連續同一個人合成 run
        var runs: [(speaker: Int?, first: Int, last: Int)] = []
        for index in words.indices {
            if let lastRun = runs.last, lastRun.speaker == speakers[index] {
                runs[runs.count - 1].last = index
            } else {
                runs.append((speakers[index], index, index))
            }
        }
        // 5. 太短的 run 併回相鄰較長的 run（反覆做到沒有為止）
        func duration(_ run: (speaker: Int?, first: Int, last: Int)) -> Double { words[run.last].e - words[run.first].s }
        while runs.count > 1, let shortest = runs.indices.min(by: { duration(runs[$0]) < duration(runs[$1]) }),
              duration(runs[shortest]) < options.minimumRunSeconds {
            let neighbor: Int
            if shortest == 0 { neighbor = 1 }
            else if shortest == runs.count - 1 { neighbor = shortest - 1 }
            else { neighbor = duration(runs[shortest - 1]) >= duration(runs[shortest + 1]) ? shortest - 1 : shortest + 1 }
            let merged = (speaker: runs[neighbor].speaker, first: min(runs[neighbor].first, runs[shortest].first),
                          last: max(runs[neighbor].last, runs[shortest].last))
            runs[min(neighbor, shortest)] = merged
            runs.remove(at: max(neighbor, shortest))
            // 併完之後，相鄰且同一個人的 run 要再併成一個（A B(短) A → A）
            var position = 0
            while position + 1 < runs.count {
                if runs[position].speaker == runs[position + 1].speaker {
                    runs[position] = (runs[position].speaker, runs[position].first, runs[position + 1].last)
                    runs.remove(at: position + 1)
                } else {
                    position += 1
                }
            }
        }
        // 6. 整個 segment 只有一個人：保留 Groq 原本的文字（含標點），維持 M1 一行一個 segment 的格式
        if runs.count == 1 {
            guard !text.isEmpty else { return [] }
            return [AlignedLine(start: segment.start, end: segment.end, speaker: runs[0].speaker, text: text)]
        }
        // 7. 多個人：用字級時間切行（這時文字來自詞，標點可能少）
        return runs.compactMap { run in
            let joined = words[run.first...run.last].map(\.w).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return nil }
            return AlignedLine(start: words[run.first].s, end: words[run.last].e, speaker: run.speaker, text: joined)
        }
    }

    /// 與 [start, end] 重疊最久的說話者；重疊一樣久時取較早開始的 turn。
    /// 完全沒有重疊時，取距離最近且在 `maxDistance` 以內的 turn；否則 nil。
    static func dominantSpeaker(start: Double, end: Double, turns: [SpeakerTurn], maxDistance: Double) -> Int? {
        var overlapBySpeaker: [Int: Double] = [:]
        var firstStart: [Int: Double] = [:]
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 {
                overlapBySpeaker[turn.speaker, default: 0] += overlap
                firstStart[turn.speaker] = min(firstStart[turn.speaker] ?? .infinity, turn.start)
            }
        }
        if let best = overlapBySpeaker.max(by: {
            $0.value != $1.value ? $0.value < $1.value : (firstStart[$0.key] ?? 0) > (firstStart[$1.key] ?? 0)
        }) {
            return best.key
        }
        var nearest: (speaker: Int, distance: Double)?
        for turn in turns {
            let distance = turn.end <= start ? start - turn.end : max(0, turn.start - end)
            if distance <= maxDistance, nearest == nil || distance < nearest!.distance {
                nearest = (turn.speaker, distance)
            }
        }
        return nearest?.speaker
    }

    // MARK: 輸出格式（與 M1 的 `[hh:mm:ss] 文字` 一致，只在時間戳後加說話者）

    /// `names`：使用者改的名字，key 是 sherpa 的 speaker id（0 起算）。沒有就顯示 `Speaker N`（N = id + 1）。
    static func render(_ line: AlignedLine, names: [Int: String] = [:]) -> String {
        if let reason = line.failureNote {
            let oneLineReason = reason.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return "> ⚠️ [\(timestamp(line.start))] 這段辨識失敗：\(oneLineReason)"
        }
        let label: String
        if let speaker = line.speaker {
            let name = names[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            label = name.isEmpty ? "Speaker \(speaker + 1)" : name
        } else {
            label = "Speaker ?"
        }
        let oneLine = line.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return "[\(timestamp(line.start))] \(label)：\(oneLine)"
    }

    static func timestamp(_ offset: TimeInterval) -> String {
        let total = offset.isFinite ? max(0, Int(offset)) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
