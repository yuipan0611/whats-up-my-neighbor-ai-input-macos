import Foundation

// 說話者辨識用到的檔案層：frontmatter 欄位、manifest、音檔清單。全部是不依賴 App 的純檔案操作。
// 設計文件：docs/spikes/2026-11-diarization-m2-design.md（附錄 A）。

/// `transcript.md` frontmatter 的 `diarization:` 欄位。
enum MeetingDiarizationState: String, Equatable {
    /// 沒有這個欄位：功能關閉時錄的會議，或舊版會議。對摘要來說等於「不需要等」。
    case notApplicable = "n/a"
    case pending, running
    case done, failed, skipped, cancelled
    /// App 在辨識途中結束或當機：啟動掃描把停在 pending／running 的會議改成這個（終態，音檔保留）。
    case interrupted

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

    /// 移除一個鍵（沒有就原樣回傳）。
    static func removing(_ key: String, from text: String) -> String {
        guard let block = frontmatterRange(in: text) else { return text }
        let lines = text[block].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { !$0.hasPrefix("\(key):") }
        guard kept.count != lines.count else { return text }
        return String(text[..<block.lowerBound]) + kept.joined(separator: "\n") + String(text[block.upperBound...])
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

    /// 啟動掃描：frontmatter 停在 `pending`／`running`，而且**確定沒有人還在處理**的會議，改成 `interrupted`
    /// （終態），音檔不動。回傳被改的逐字稿，由新到舊。
    ///
    /// 「沒有人還在處理」的判斷（`DiarizationOwnerLock.claimIfAbandoned`）：會議資料夾裡有擁有者檔，
    /// 我們拿得到它的 flock（沒有任何行程持鎖），而且記錄的 pid 已經不存在（或 pid 被別的行程重用）。
    /// 沒有擁有者檔、檔案壞掉、持鎖中、擁有者還活著，一律不動——寧可讓狀態停著，也不能把別人還在跑的工作
    /// 改成終態（會提早放行摘要、重試與刪音檔）。
    @discardableResult
    func markInterruptedDiarizations() -> [URL] {
        var changed: [URL] = []
        for directory in sessionDirectoriesNewestFirst() {
            let url = directory.appendingPathComponent(Self.transcriptFilename)
            let state = diarizationState(for: url)
            guard state == .pending || state == .running else { continue }
            guard let claim = DiarizationOwnerLock.claimIfAbandoned(in: directory) else { continue }
            if (try? setFrontmatter([("diarization", MeetingDiarizationState.interrupted.rawValue),
                                     ("diarization_reason", "app-exit")], transcriptURL: url)) != nil {
                changed.append(url)
                claim.release(deleteFile: true)
            } else {
                claim.release(deleteFile: false)
            }
        }
        return changed
    }

    /// 最近一場可以（重新）辨識說話者的會議：狀態是 failed／interrupted／cancelled，且段檔與 manifest 都還在。
    func latestRetryableDiarization() -> (transcriptURL: URL, state: MeetingDiarizationState)? {
        let retryable: Set<MeetingDiarizationState> = [.failed, .interrupted, .cancelled]
        for directory in sessionDirectoriesNewestFirst() {
            let url = directory.appendingPathComponent(Self.transcriptFilename)
            let state = diarizationState(for: url)
            guard retryable.contains(state), !chunkFiles(in: directory).isEmpty,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.manifestFilename).path)
            else { continue }
            return (url, state)
        }
        return nil
    }

    /// 寫入 frontmatter 欄位（原子寫入）。
    func setFrontmatter(_ fields: [(String, String)], transcriptURL: URL) throws {
        var text = try String(contentsOf: transcriptURL, encoding: .utf8)
        for (key, value) in fields { text = MeetingFrontmatter.setting(key, to: value, in: text) }
        try text.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    /// 這場會議資料夾裡的段檔（`chunk-NNN.m4a`），依檔名排序。
    /// 只算一般檔案：同名的資料夾或 symlink 不是音檔。
    func chunkFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.range(of: #"^chunk-\d{3,}\.m4a$"#, options: .regularExpression) != nil }
            .sorted().map { directory.appendingPathComponent($0) }
            .filter { SafeFileRemoval.kind(of: $0) == .regularFile }
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

    /// 刪除這場會議的音檔（段檔與 manifest）。只刪會議資料夾底下、符合 `chunk-NNN.m4a` 命名的**一般檔案**與
    /// `manifest.json`；同名的資料夾、symlink、經過 symlink 的路徑一律不碰（見 `SafeFileRemoval`），
    /// 其他檔案（逐字稿、使用者放的東西）不動。回傳刪掉的檔案數。
    @discardableResult
    func deleteAudio(directory: URL) -> Int {
        var removed = 0
        for url in chunkFiles(in: directory) where SafeFileRemoval.removeRegularFile(url, within: directory) { removed += 1 }
        if SafeFileRemoval.removeRegularFile(directory.appendingPathComponent(Self.manifestFilename), within: directory) { removed += 1 }
        return removed
    }
}

// MARK: 辨識工作的擁有者（跨實例安全）

/// 行程身分：用 pid ＋ 啟動時間判斷「那個行程還在嗎」（pid 會被重用）。
enum ProcessIdentity {
    /// 行程啟動時間（秒）。查不到回傳 nil。
    static func startTime(pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    /// pid 存在（`kill(pid, 0)` 成功或 EPERM），而且啟動時間與記錄相符（沒被別的行程重用）。
    static func isSameProcessAlive(pid: Int32, recordedStart: Double?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return false }
        if let recordedStart, let now = startTime(pid: pid), abs(now - recordedStart) > 1 { return false }
        return true
    }
}

struct DiarizationOwnerRecord: Codable, Equatable {
    let v: Int
    let pid: Int32
    let processStart: Double?
    /// 這個 App 實例的 UUID（除錯用）。
    let instance: String
    let createdAt: Double
}

/// 會議資料夾裡的 `diarization.owner`：辨識工作開始（或排進佇列）時由該實例建立，記錄 pid、行程啟動時間、
/// 實例 UUID，並對檔案持有 `flock(LOCK_EX)` 直到工作結束。行程死掉（含當機）時系統自動放鎖。
/// 啟動掃描只有在「拿得到鎖、而且記錄的 pid 已經不存在」時才會把狀態標成 `interrupted`。
final class DiarizationOwnerLock {
    static let filename = "diarization.owner"

    let directory: URL
    private var fd: Int32

    private init(directory: URL, fd: Int32) {
        self.directory = directory
        self.fd = fd
    }

    private static func path(_ directory: URL) -> String { directory.appendingPathComponent(filename).path }

    /// 建立擁有者檔並持鎖。別的行程持鎖（同一場會議已有人在處理）或建不出來時回傳 nil。
    static func acquire(in directory: URL, instance: String,
                        pid: Int32 = getpid(), now: Date = Date()) -> DiarizationOwnerLock? {
        let descriptor = open(path(directory), O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        let record = DiarizationOwnerRecord(v: 1, pid: pid, processStart: ProcessIdentity.startTime(pid: pid),
                                            instance: instance, createdAt: now.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(record) {
            ftruncate(descriptor, 0)
            _ = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, data.count, 0) }
        }
        return DiarizationOwnerLock(directory: directory, fd: descriptor)
    }

    /// 啟動掃描用：只有在擁有者檔存在、記錄可讀、拿得到鎖、而且擁有者行程已經不在時，回傳（持有鎖的）物件。
    static func claimIfAbandoned(in directory: URL) -> DiarizationOwnerLock? {
        let descriptor = open(path(directory), O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }   // 有人持鎖 = 還活著
        let data = (try? Data(contentsOf: directory.appendingPathComponent(filename))) ?? Data()
        guard let record = try? JSONDecoder().decode(DiarizationOwnerRecord.self, from: data),
              !ProcessIdentity.isSameProcessAlive(pid: record.pid, recordedStart: record.processStart) else {
            close(descriptor)
            return nil
        }
        return DiarizationOwnerLock(directory: directory, fd: descriptor)
    }

    /// 放鎖。`deleteFile`：工作到終態時刪掉擁有者檔；佇列被丟掉時保留（記錄的 pid 之後會死，下次啟動掃描才能標成 interrupted）。
    func release(deleteFile: Bool) {
        guard fd >= 0 else { return }
        if deleteFile { unlink(Self.path(directory)) }   // 先刪檔再放鎖，掃描不會看到「無鎖但檔案還在」的空窗
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release(deleteFile: false) }
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
