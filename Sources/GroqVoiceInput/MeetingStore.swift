import Foundation

/// 一場會議在磁碟上的位置。只由 `MeetingStore.beginSession` 建立。
struct MeetingSession: Equatable {
    let directory: URL
    let startedAt: Date
    let language: String
    let chunkSeconds: Int
    var transcriptURL: URL { directory.appendingPathComponent(MeetingStore.transcriptFilename) }
}

/// 逐字稿裡的一行：已經換算成「整場會議」的相對秒數。
struct MeetingLine: Equatable {
    let offset: TimeInterval
    let text: String
}

/// 會議逐字稿的檔案層。只管資料夾與 `transcript.md`，不知道錄音器或網路。
///
/// 檔案結構：
///   <root>/<yyyy-MM-dd_HHmm>/transcript.md   ← 每段辨識完立刻 append
///   <root>/<yyyy-MM-dd_HHmm>/chunk-003.m4a   ← 只有辨識失敗的段會留下
///
/// 路徑只由內部的日期與整數段號組成，呼叫端不能指定任意檔名，
/// 因此不可能寫到會議資料夾以外的地方。
final class MeetingStore {
    static let transcriptFilename = "transcript.md"
    static let summaryFilename = "summary.md"

    /// 預設存在 ~/Documents/Neighbor Meetings，好找，不藏在系統暫存區。
    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Neighbor Meetings", isDirectory: true)
    }

    let root: URL
    private let fileManager: FileManager
    private let timeZone: TimeZone

    init(root: URL = MeetingStore.defaultRoot, fileManager: FileManager = .default,
         timeZone: TimeZone = .current) {
        self.root = root
        self.fileManager = fileManager
        self.timeZone = timeZone
    }

    // MARK: 開始／結束

    func beginSession(startedAt: Date, language: String, chunkSeconds: Int) throws -> MeetingSession {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = folderName(for: startedAt)
        var directory = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        // 同一分鐘開兩場會議時不能覆蓋前一場。
        while fileManager.fileExists(atPath: directory.path) {
            directory = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let session = MeetingSession(directory: directory, startedAt: startedAt,
                                     language: language, chunkSeconds: chunkSeconds)
        let text = frontmatter(session, ended: nil, chunks: 0, failed: 0, status: "recording")
            + "\n# 會議記錄 \(titleDate(startedAt))\n\n"
        try write(text, to: session.transcriptURL)
        return session
    }

    /// 重寫 frontmatter（結束時間與段數），正文不動。可重複呼叫，不會壞檔。
    /// `status`：`completed` 正常結束；`interrupted` 是 App 在會議中被關閉。
    func endSession(_ session: MeetingSession, endedAt: Date, chunks: Int, failedChunks: Int,
                    status: String = "completed") throws {
        let current = try String(contentsOf: session.transcriptURL, encoding: .utf8)
        let body = Self.bodyAfterFrontmatter(current)
        let text = frontmatter(session, ended: endedAt, chunks: chunks, failed: failedChunks, status: status)
            + body
        try write(text, to: session.transcriptURL)
    }

    /// 一段都沒錄到就結束（例如麥克風一開始就起不來）：只剩空逐字稿的資料夾沒有保留價值。
    /// 資料夾裡有任何別的檔案（例如保留的失敗音檔）就一律不動。
    func discardIfEmpty(_ session: MeetingSession) {
        let names = (try? fileManager.contentsOfDirectory(atPath: session.directory.path)) ?? []
        guard names == [Self.transcriptFilename] else { return }
        try? fileManager.removeItem(at: session.directory)
    }

    // MARK: 段落

    func chunkURL(_ session: MeetingSession, index: Int) -> URL {
        session.directory.appendingPathComponent(Self.chunkFilename(index))
    }

    static func chunkFilename(_ index: Int) -> String {
        String(format: "chunk-%03d.m4a", max(index, 0))
    }

    /// 辨識成功：把這一段的每一行 append 到逐字稿。沒有內容時留一行說明，方便對照時間。
    func appendChunk(_ session: MeetingSession, offset: TimeInterval, lines: [MeetingLine]) throws {
        var text = ""
        if lines.isEmpty {
            text = "> [\(Self.timestamp(offset))] （這段沒有辨識到內容）\n"
        } else {
            for line in lines { text += "[\(Self.timestamp(line.offset))] \(Self.oneLine(line.text))\n" }
        }
        try append(text + "\n", to: session.transcriptURL)
    }

    /// 辨識失敗：在逐字稿標出來。`audioKept` 為 true 時說明保留的檔名。
    func markChunkFailed(_ session: MeetingSession, index: Int, offset: TimeInterval,
                         reason: String, audioKept: Bool) throws {
        var text = "> ⚠️ [\(Self.timestamp(offset))] 第 \(index) 段辨識失敗：\(Self.oneLine(reason))"
        text += audioKept ? "。音檔保留：\(Self.chunkFilename(index))\n\n" : "。這段沒有保留音檔。\n\n"
        try append(text, to: session.transcriptURL)
    }

    // MARK: 查詢

    /// 指定逐字稿對應的 summary.md 位置。
    func summaryURL(for transcriptURL: URL) -> URL {
        transcriptURL.deletingLastPathComponent().appendingPathComponent(Self.summaryFilename)
    }

    /// 將會議摘要寫入同一資料夾的 summary.md。
    @discardableResult
    func writeSummary(_ text: String, for transcriptURL: URL) throws -> URL {
        let url = summaryURL(for: transcriptURL)
        try write(text, to: url)
        return url
    }

    /// 最近一場有逐字稿的會議。
    func latestTranscriptURL() -> URL? {
        for directory in sessionDirectoriesNewestFirst() {
            let url = directory.appendingPathComponent(Self.transcriptFilename)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 最近一場有摘要的會議。
    func latestSummaryURL() -> URL? {
        sessionDirectoriesNewestFirst()
            .first { fileManager.fileExists(atPath: $0.appendingPathComponent(Self.summaryFilename).path) }?
            .appendingPathComponent(Self.summaryFilename)
    }

    /// root 底下的會議資料夾，由新到舊。依「日期時間，再依同分鐘的序號」排序：
    /// `…_2130-10` 比 `…_2130-9` 新（單純字串排序會把 -9 排在 -10 後面）。
    /// 名稱不符合會議資料夾格式的資料夾（使用者自己放的）排在最後；檔案不會出現在結果裡。
    /// 其他需要「最近一場」的功能（例如摘要）一律用這個，不要自己 sort 檔名。
    func sessionDirectoriesNewestFirst() -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var entries: [(url: URL, key: (base: String, number: Int)?, name: String)] = []
        for name in names {
            let url = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            entries.append((url, Self.sortKey(name), name))
        }
        entries.sort { lhs, rhs in
            switch (lhs.key, rhs.key) {
            case let (a?, b?):
                if a.base != b.base { return a.base > b.base }
                return a.number != b.number ? a.number > b.number : lhs.name > rhs.name
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.name > rhs.name
            }
        }
        return entries.map(\.url)
    }

    private static let folderPattern = try! NSRegularExpression(
        pattern: "^(\\d{4}-\\d{2}-\\d{2}_\\d{4})(?:-(\\d+))?$")

    /// `(日期時間, 序號)`。沒有 suffix 的第一場序號是 1，`-2` 起才有 suffix。不符合格式回傳 nil。
    private static func sortKey(_ name: String) -> (base: String, number: Int)? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = folderPattern.firstMatch(in: name, range: range),
              let base = Range(match.range(at: 1), in: name) else { return nil }
        var number = 1
        if let suffix = Range(match.range(at: 2), in: name), let value = Int(name[suffix]) { number = value }
        return (String(name[base]), number)
    }

    // MARK: 格式

    /// `[hh:mm:ss]` 用的字串。負數與非數值一律當 0。
    static func timestamp(_ offset: TimeInterval) -> String {
        let total = offset.isFinite ? max(0, Int(offset)) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 一行一句：辨識文字裡的換行會破壞「每行一個時間戳」的格式。
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func frontmatter(_ session: MeetingSession, ended: Date?, chunks: Int,
                             failed: Int, status: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        return """
        ---
        started: \(iso.string(from: session.startedAt))
        ended: \(ended.map { iso.string(from: $0) } ?? "in-progress")
        status: \(status)
        language: \(session.language)
        chunks: \(chunks)
        failed_chunks: \(failed)
        chunk_seconds: \(session.chunkSeconds)
        chunk_gap: 每段錄音之間會有約 0.3–0.5 秒沒有錄到（錄音器停止再重新啟動）
        timestamps: 每行時間為「整場會議的相對時間」，一行對應 Whisper 的一個 segment，不一定剛好是一句
        ---

        """
    }

    private func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }

    private func titleDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 去掉開頭的 `---` … `---` 區塊，回傳其後的所有內容（從 frontmatter 的結尾換行開始）。
    static func bodyAfterFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"),
              let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { return text }
        return String(text[close.upperBound...])
    }

    // MARK: 檔案 I/O

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
