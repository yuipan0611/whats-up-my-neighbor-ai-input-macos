import Foundation

// 說話者辨識用到的檔案層：frontmatter 欄位、manifest、音檔清單。全部是不依賴 App 的純檔案操作。
// 設計文件：docs/spikes/2026-11-diarization-m2-design.md（附錄 A）。

/// `transcript.md` frontmatter 的 `diarization:` 欄位。
enum MeetingDiarizationState: String, Equatable {
    /// 沒有這個欄位：功能關閉時錄的會議，或舊版會議。對摘要來說等於「不需要等」。
    case notApplicable = "n/a"
    case pending, running
    case done, failed, skipped, cancelled

    /// 之後不會再變的狀態（摘要可以開始產生）。`pending`／`running` 之外都是終態。
    var isTerminal: Bool { self != .pending && self != .running }
}

/// 純字串版的 frontmatter 讀寫。只動指定的鍵，其他行原樣保留。
enum MeetingFrontmatter {
    /// 取得鍵的值；沒有 frontmatter 或沒有這個鍵回傳 nil。
    static func value(_ key: String, in text: String) -> String? {
        guard let block = frontmatterRange(in: text) else { return nil }
        for line in text[block].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\(key):") {
                return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 設定（有就取代、沒有就加在結尾 `---` 之前）。沒有 frontmatter 時原樣回傳。
    /// 值裡的換行會被折成空白，不會破壞 frontmatter。
    static func setting(_ key: String, to value: String, in text: String) -> String {
        guard let block = frontmatterRange(in: text) else { return text }
        let clean = value.components(separatedBy: .newlines).joined(separator: " ")
        var lines = text[block].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
            lines[index] = "\(key): \(clean)"
        } else {
            lines.append("\(key): \(clean)")
        }
        return String(text[..<block.lowerBound]) + lines.joined(separator: "\n") + String(text[block.upperBound...])
    }

    /// 兩個 `---` 之間的內容（不含 `---` 本身與它們的換行）。
    private static func frontmatterRange(in text: String) -> Range<String.Index>? {
        guard text.hasPrefix("---\n") else { return nil }
        let start = text.index(text.startIndex, offsetBy: 4)
        guard let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
                ?? (text.hasSuffix("\n---") ? text.range(of: "\n---", options: .backwards) : nil)
        else { return nil }
        return start <= close.lowerBound ? start..<close.lowerBound : nil
    }
}

extension MeetingStore {
    static let manifestFilename = "manifest.json"
    static let plainTranscriptFilename = "transcript.plain.md"
    static let speakersFilename = "speakers.json"

    /// 一場會議的說話者辨識狀態（給 AGy 的摘要等 diarization 進入終態再產生用）。
    /// 傳入逐字稿位置；讀不到檔或沒有欄位都回傳 `.notApplicable`（視為不需要等）。
    func diarizationState(for transcriptURL: URL) -> MeetingDiarizationState {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let value = MeetingFrontmatter.value("diarization", in: text) else { return .notApplicable }
        return MeetingDiarizationState(rawValue: value) ?? .notApplicable
    }

    /// 寫入 frontmatter 欄位（原子寫入）。
    func setFrontmatter(_ fields: [(String, String)], transcriptURL: URL) throws {
        var text = try String(contentsOf: transcriptURL, encoding: .utf8)
        for (key, value) in fields { text = MeetingFrontmatter.setting(key, to: value, in: text) }
        try text.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    /// 這場會議資料夾裡的段檔（`chunk-NNN.m4a`），依檔名排序。
    func chunkFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.range(of: #"^chunk-\d{3,}\.m4a$"#, options: .regularExpression) != nil }
            .sorted().map { directory.appendingPathComponent($0) }
    }

    /// 寫 `manifest.json`（`meeting-diarizer --manifest` 的輸入）。只列檔案真的存在的段。
    /// 路徑用相對檔名（相對於 manifest 所在資料夾），offset 四捨五入到毫秒。
    func writeManifest(directory: URL, chunks: [(index: Int, offset: TimeInterval)]) throws {
        let entries = chunks.sorted { $0.offset < $1.offset }.compactMap { chunk -> MeetingDiarizationManifest.Chunk? in
            let name = Self.chunkFilename(chunk.index)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else { return nil }
            return .init(path: name, offset: (chunk.offset * 1000).rounded() / 1000)
        }
        let manifest = MeetingDiarizationManifest(version: 1, chunks: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(Self.manifestFilename), options: .atomic)
    }

    /// 刪除這場會議的音檔（段檔與 manifest）。只刪符合 `chunk-NNN.m4a` 命名的檔案與 `manifest.json`，
    /// 其他檔案（逐字稿、使用者放的東西）不動。回傳刪掉的檔案數。
    @discardableResult
    func deleteAudio(directory: URL) -> Int {
        var removed = 0
        for url in chunkFiles(in: directory) where (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        let manifest = directory.appendingPathComponent(Self.manifestFilename)
        if (try? FileManager.default.removeItem(at: manifest)) != nil { removed += 1 }
        return removed
    }
}

/// `manifest.json` 的內容（與 Tools/MeetingDiarizer/MeetingManifest.swift 的 schema 相同：version 1）。
struct MeetingDiarizationManifest: Codable, Equatable {
    struct Chunk: Codable, Equatable {
        let path: String
        let offset: Double
    }
    let version: Int
    let chunks: [Chunk]
}
