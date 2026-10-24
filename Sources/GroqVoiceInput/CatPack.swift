import Foundation
import CoreFoundation
#if canImport(Compression)
import Compression
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Display-only metadata. A pack never carries commands, provider settings or an agent identity.
struct CatPackManifest: Equatable {
    var schemaVersion = 1
    var id: String
    var name: String
    var version = "1.0.0"
    var templateId = "yui-cat-v1"

    var jsonObject: [String: Any] {
        ["schemaVersion": schemaVersion, "id": id, "name": name,
         "version": version, "templateId": templateId]
    }

    static func parse(_ value: Any) throws -> CatPackManifest {
        guard let object = value as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "id", "name", "version", "templateId"]),
              let number = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.int64Value == 1,
              let id = object["id"] as? String, validID(id),
              let name = object["name"] as? String,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.unicodeScalars.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let version = object["version"] as? String,
              !version.isEmpty, version.utf8.count <= 32,
              version.utf8.allSatisfy({ asciiAlphanumeric($0) || $0 == 45 || $0 == 46 }),
              let template = object["templateId"] as? String else {
            throw CatPackError.invalidManifest
        }
        guard template == "yui-cat-v1" else { throw CatPackError.incompatibleTemplate }
        return CatPackManifest(id: id, name: name, version: version, templateId: template)
    }

    static func validID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, let last = bytes.last,
              lowercaseAlphanumeric(first), lowercaseAlphanumeric(last),
              !id.contains(".."),
              bytes.allSatisfy({ lowercaseAlphanumeric($0) || $0 == 45 || $0 == 46 }) else { return false }
        let stem = id.split(separator: ".").first.map(String.init) ?? id
        let reserved = ["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] }
        return !reserved.contains(stem)
    }

    private static func lowercaseAlphanumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }
    private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
        lowercaseAlphanumeric(byte) || (65...90).contains(byte)
    }
}

struct CatPack: Equatable {
    var manifest: CatPackManifest
    var appearance: CatAppearance
    var previewPNG: Data? = nil
}

enum CatPackError: Error, LocalizedError {
    case invalidArchive, tooLarge, unsupportedCompression, invalidManifest, incompatibleTemplate
    case invalidAppearance, invalidPreview, unsafeFile, missingPack, rollbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "貓咪包格式無效。請使用包含 manifest.json 與 appearance.json 的 .nekocat 檔。"
        case .tooLarge: return "貓咪包超過大小限制，未變更目前的貓咪。"
        case .unsupportedCompression: return "此貓咪包使用不支援的 ZIP 格式；請使用一般 ZIP 的 Store 或 Deflate 壓縮。"
        case .invalidManifest: return "貓咪包的名稱、識別碼或格式版本無效。"
        case .incompatibleTemplate: return "這隻貓使用其他造型模板，目前版本只支援 yui-cat-v1。"
        case .invalidAppearance: return "貓咪包的毛色或特徵設定無效。"
        case .invalidPreview: return "貓咪包縮圖必須是 512 × 512 以內的單張 PNG。"
        case .unsafeFile: return "無法讀寫此貓咪檔案；請選擇一般檔案及資料夾。"
        case .missingPack: return "找不到這隻已安裝的貓咪。"
        case .rollbackFailed: return "貓咪設定未能儲存，角色包也無法還原。請檢查設定資料夾的寫入權限，再重新匯入原本的貓咪包。"
        }
    }
}

/// A small data-only ZIP dialect. Read and decode in bounded memory; never extract paths to disk.
/// Ordinary ZIP Store and Deflate are supported, including data descriptors.
enum CatPackArchive {
    static let maximumArchiveBytes = 1024 * 1024
    static let maximumManifestBytes = 4 * 1024
    static let maximumAppearanceBytes = 16 * 1024
    static let maximumPreviewBytes = 512 * 1024
    static let maximumExpandedBytes = maximumManifestBytes + maximumAppearanceBytes + maximumPreviewBytes
    private static let limits = ["manifest.json": maximumManifestBytes,
                                 "appearance.json": maximumAppearanceBytes,
                                 "preview.png": maximumPreviewBytes]

    static func read(from url: URL) throws -> CatPack {
        try decode(CatPackFileIO.readBounded(url, maximumBytes: maximumArchiveBytes))
    }

    static func decode(_ data: Data) throws -> CatPack {
        guard data.count <= maximumArchiveBytes else { throw CatPackError.tooLarge }
        let files = try entries(in: data)
        guard let manifestData = files["manifest.json"], let appearanceData = files["appearance.json"] else {
            throw CatPackError.invalidArchive
        }
        let manifest: CatPackManifest
        do {
            guard String(data: manifestData, encoding: .utf8) != nil else { throw CatPackError.invalidManifest }
            manifest = try CatPackManifest.parse(JSONSerialization.jsonObject(with: manifestData))
        } catch let error as CatPackError { throw error }
        catch { throw CatPackError.invalidManifest }
        let appearance: CatAppearance
        do {
            guard String(data: appearanceData, encoding: .utf8) != nil else { throw CatPackError.invalidAppearance }
            appearance = try CatAppearance.parse(JSONSerialization.jsonObject(with: appearanceData))
        } catch { throw CatPackError.invalidAppearance }
        if let preview = files["preview.png"] { try validatePreview(preview) }
        return CatPack(manifest: manifest, appearance: appearance, previewPNG: files["preview.png"])
    }

    /// Export deterministic Store ZIPs. Preview PNGs are already compressed; JSON is very small.
    static func encode(_ pack: CatPack) throws -> Data {
        _ = try CatPackManifest.parse(pack.manifest.jsonObject)
        do { _ = try CatAppearance.parse(pack.appearance.jsonObject) }
        catch { throw CatPackError.invalidAppearance }
        var files: [(String, Data)] = [
            ("manifest.json", try JSONSerialization.data(withJSONObject: pack.manifest.jsonObject,
                                                         options: [.sortedKeys, .prettyPrinted])),
            ("appearance.json", try JSONSerialization.data(withJSONObject: pack.appearance.jsonObject,
                                                           options: [.sortedKeys, .prettyPrinted]))
        ]
        if let preview = pack.previewPNG {
            try validatePreview(preview)
            files.append(("preview.png", preview))
        }
        var archive = Data(), central = Data()
        for (name, content) in files {
            guard content.count <= limits[name]! else { throw CatPackError.tooLarge }
            let filename = Data(name.utf8), checksum = crc32(content), offset = UInt32(archive.count)
            // Local file header: UTF-8 names, stored content, deterministic 1980-01-01 date.
            archive.appendLE(UInt32(0x04034b50)); archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0x0021))
            archive.appendLE(checksum); archive.appendLE(UInt32(content.count)); archive.appendLE(UInt32(content.count))
            archive.appendLE(UInt16(filename.count)); archive.appendLE(UInt16(0))
            archive.append(filename); archive.append(content)
            // Unix regular file, owner read/write. No directory/symlink/executable entries.
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0x0021))
            central.appendLE(checksum); central.appendLE(UInt32(content.count)); central.appendLE(UInt32(content.count))
            central.appendLE(UInt16(filename.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt32(0o100600) << 16); central.appendLE(offset); central.append(filename)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(files.count)); archive.appendLE(UInt16(files.count))
        archive.appendLE(UInt32(central.count)); archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        guard archive.count <= maximumArchiveBytes else { throw CatPackError.tooLarge }
        return archive
    }

    static func write(_ pack: CatPack, to url: URL) throws {
        let data = try encode(pack)
        try CatPackFileIO.writeAtomically(data, to: url)
    }

    private struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let expandedSize: Int
        let localOffset: Int
    }

    private static func entries(in data: Data) throws -> [String: Data] {
        guard data.count >= 22 else { throw CatPackError.invalidArchive }
        let bytes = [UInt8](data)
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65535), by: -1) {
            if u32(bytes, offset) == 0x06054b50,
               offset + 22 + Int(u16(bytes, offset + 20)) == bytes.count { end = offset; break }
        }
        guard let end, u16(bytes, end + 4) == 0, u16(bytes, end + 6) == 0 else {
            throw CatPackError.invalidArchive
        }
        let count = Int(u16(bytes, end + 10))
        let directorySize = Int(u32(bytes, end + 12)), directoryOffset = Int(u32(bytes, end + 16))
        guard (2...3).contains(count), Int(u16(bytes, end + 8)) == count,
              directoryOffset >= 0, directoryOffset <= end,
              directorySize == end - directoryOffset else { throw CatPackError.invalidArchive }
        var cursor = directoryOffset, records: [Entry] = [], names = Set<String>(), expandedTotal = 0
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(bytes, cursor) == 0x02014b50 else { throw CatPackError.invalidArchive }
            let flags = u16(bytes, cursor + 8), method = u16(bytes, cursor + 10)
            let nameLength = Int(u16(bytes, cursor + 28)), extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, (10...20).contains(Int(u16(bytes, cursor + 6))),
                  u16(bytes, cursor + 34) == 0 else { throw CatPackError.invalidArchive }
            guard method == 0 || method == 8,
                  flags & ~UInt16(method == 8 ? 0x080e : 0x0808) == 0 else {
                throw CatPackError.unsupportedCompression
            }
            guard let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  let maximum = limits[name], names.insert(name).inserted else { throw CatPackError.invalidArchive }
            let attributes = u32(bytes, cursor + 38)
            let mode = (attributes >> 16) & 0xffff, kind = mode & 0o170000
            guard (kind == 0 || kind == 0o100000), mode & 0o111 == 0, attributes & 0x10 == 0 else {
                throw CatPackError.invalidArchive
            }
            try validateExtra(bytes, start: cursor + 46 + nameLength, length: extraLength)
            let compressed = Int(u32(bytes, cursor + 20)), expanded = Int(u32(bytes, cursor + 24))
            guard compressed <= maximumArchiveBytes, expanded <= maximum else { throw CatPackError.tooLarge }
            expandedTotal += expanded
            guard expandedTotal <= maximumExpandedBytes else { throw CatPackError.tooLarge }
            records.append(Entry(name: name, flags: flags, method: method, checksum: u32(bytes, cursor + 16),
                                 compressedSize: compressed, expandedSize: expanded,
                                 localOffset: Int(u32(bytes, cursor + 42))))
            cursor = next
        }
        guard cursor == end, names.contains("manifest.json"), names.contains("appearance.json") else {
            throw CatPackError.invalidArchive
        }
        var result: [String: Data] = [:], nextLocal = 0
        for entry in records.sorted(by: { $0.localOffset < $1.localOffset }) {
            let offset = entry.localOffset
            guard offset == nextLocal, offset + 30 <= directoryOffset,
                  u32(bytes, offset) == 0x04034b50,
                  (10...20).contains(Int(u16(bytes, offset + 4))),
                  u16(bytes, offset + 6) == entry.flags, u16(bytes, offset + 8) == entry.method else {
                throw CatPackError.invalidArchive
            }
            let nameLength = Int(u16(bytes, offset + 26)), extraLength = Int(u16(bytes, offset + 28))
            let start = offset + 30 + nameLength + extraLength, stop = start + entry.compressedSize
            guard start <= directoryOffset, stop <= directoryOffset,
                  String(bytes: bytes[(offset + 30)..<(offset + 30 + nameLength)], encoding: .utf8) == entry.name else {
                throw CatPackError.invalidArchive
            }
            try validateExtra(bytes, start: offset + 30 + nameLength, length: extraLength)
            if entry.flags & 8 == 0 {
                guard u32(bytes, offset + 14) == entry.checksum,
                      Int(u32(bytes, offset + 18)) == entry.compressedSize,
                      Int(u32(bytes, offset + 22)) == entry.expandedSize else { throw CatPackError.invalidArchive }
                nextLocal = stop
            } else {
                // Streaming ZIPs repeat the central values in a trailing descriptor.
                let descriptor = stop + (stop + 4 <= directoryOffset && u32(bytes, stop) == 0x08074b50 ? 4 : 0)
                guard descriptor + 12 <= directoryOffset,
                      u32(bytes, descriptor) == entry.checksum,
                      Int(u32(bytes, descriptor + 4)) == entry.compressedSize,
                      Int(u32(bytes, descriptor + 8)) == entry.expandedSize else { throw CatPackError.invalidArchive }
                nextLocal = descriptor + 12
            }
            let compressed = Data(bytes[start..<stop])
            let decoded: Data
            if entry.method == 0 {
                guard entry.compressedSize == entry.expandedSize else { throw CatPackError.invalidArchive }
                decoded = compressed
            } else { decoded = try inflate(compressed, expectedSize: entry.expandedSize) }
            guard decoded.count == entry.expandedSize, crc32(decoded) == entry.checksum else {
                throw CatPackError.invalidArchive
            }
            result[entry.name] = decoded
        }
        guard nextLocal == directoryOffset else { throw CatPackError.invalidArchive }
        return result
    }

    private static func validateExtra(_ bytes: [UInt8], start: Int, length: Int) throws {
        var offset = start
        let end = start + length
        guard end <= bytes.count else { throw CatPackError.invalidArchive }
        while offset < end {
            guard offset + 4 <= end else { throw CatPackError.invalidArchive }
            let identifier = u16(bytes, offset), size = Int(u16(bytes, offset + 2))
            // ZIP64 is unnecessary for bounded character packs and is deliberately unsupported.
            guard identifier != 0x0001, offset + 4 + size <= end else { throw CatPackError.invalidArchive }
            offset += 4 + size
        }
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        #if canImport(Compression)
        // One extra byte detects a stream expanding beyond its declared size.
        var buffer = [UInt8](repeating: 0, count: expectedSize + 1)
        let decoded = buffer.withUnsafeMutableBufferPointer { destination in
            data.withUnsafeBytes { source -> Int in
                guard let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destination.baseAddress!, destination.count, input,
                                                 data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == expectedSize else { throw CatPackError.invalidArchive }
        return Data(buffer.prefix(decoded))
        #else
        throw CatPackError.unsupportedCompression
        #endif
    }

    private static func validatePreview(_ data: Data) throws {
        guard data.count <= maximumPreviewBytes else { throw CatPackError.tooLarge }
        guard data.count >= 33, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]) else {
            throw CatPackError.invalidPreview
        }
        func dimension(_ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let width = dimension(16), height = dimension(20)
        guard (1...512).contains(width), (1...512).contains(height) else { throw CatPackError.invalidPreview }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == Int(width), image.height == Int(height),
              CGImageSourceGetStatus(source) == .statusComplete else { throw CatPackError.invalidPreview }
        #else
        throw CatPackError.invalidPreview
        #endif
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ UInt32.max
    }
}

/// External user packs are independently replaceable files. Updating one never replaces user settings.
final class CatPackStore {
    let rootURL: URL

    init(rootURL: URL = CatConfiguration.directoryURL.appendingPathComponent("Cats", isDirectory: true)) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func list() throws -> [CatPack] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        try CatPackFileIO.requireDirectory(rootURL)
        let files = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
        return files.filter { $0.pathExtension == "nekocat" }.compactMap { url in
            try? load(id: url.deletingPathExtension().lastPathComponent)
        }.sorted {
            if $0.manifest.name == $1.manifest.name { return $0.manifest.id < $1.manifest.id }
            return $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
        }
    }

    func load(id: String) throws -> CatPack {
        let url = try fileURL(id: id)
        try CatPackFileIO.requireDirectory(rootURL)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CatPackError.missingPack }
        let pack = try CatPackArchive.read(from: url)
        guard pack.manifest.id == id else { throw CatPackError.invalidManifest }
        return pack
    }

    /// Distinguish a missing ID from an invalid existing file. Import never
    /// replaces a damaged/symlinked entry while pretending it was absent.
    func existing(id: String) throws -> CatPack? {
        let url = try fileURL(id: id)
        var status = stat()
        if lstat(rootURL.path, &status) != 0 {
            guard errno == ENOENT else { throw CatPackError.unsafeFile }
            return nil
        }
        try CatPackFileIO.requireDirectory(rootURL)
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw CatPackError.unsafeFile }
            return nil
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw CatPackError.unsafeFile }
        return try load(id: id)
    }

    @discardableResult func install(_ pack: CatPack) throws -> CatPack {
        // Validate all content before creating a directory or replacing an installed pack.
        let data = try CatPackArchive.encode(pack)
        let target = try fileURL(id: pack.manifest.id)
        if !FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try CatPackFileIO.requireDirectory(rootURL)
        try CatPackFileIO.writeAtomically(data, to: target)
        return pack
    }

    @discardableResult func importPack(from url: URL) throws -> CatPack {
        try install(CatPackArchive.read(from: url))
    }

    func export(id: String, to url: URL) throws {
        try CatPackArchive.write(load(id: id), to: url)
    }

    /// Used only for rolling back a newly installed pack. No recursive removal.
    func remove(id: String) throws {
        guard try existing(id: id) != nil else { return }
        let url = try fileURL(id: id)
        try CatPackFileIO.requireDirectory(rootURL)
        guard unlink(url.path) == 0 else { throw CatPackError.unsafeFile }
    }

    private func fileURL(id: String) throws -> URL {
        guard CatPackManifest.validID(id), rootURL.isFileURL else { throw CatPackError.invalidManifest }
        return rootURL.appendingPathComponent(id + ".nekocat")
    }
}

/// One application service for the editor, Finder imports and installer seeds.
/// The active-pack preference/UI can change only after this operation succeeds.
final class CatPackImporter {
    let store: CatPackStore
    let configurationURL: URL

    init(store: CatPackStore,
         configurationURL: URL = CatConfiguration.directoryURL.appendingPathComponent("cat.config.json")) {
        self.store = store
        self.configurationURL = configurationURL
    }

    func saveAndActivate(_ pack: CatPack) throws {
        let previous = try store.existing(id: pack.manifest.id)
        try store.install(pack)
        do {
            try CatCoatSelection.saveAppearance(pack.appearance, to: configurationURL)
        } catch {
            let activationError = error
            do {
                if let previous { try store.install(previous) }
                else { try store.remove(id: pack.manifest.id) }
            } catch { throw CatPackError.rollbackFailed }
            throw activationError
        }
    }

    func importDocument(from url: URL, initial: Bool) throws -> (pack: CatPack, applied: Bool) {
        let pack = try CatPackArchive.read(from: url)
        if initial && !CatCoatSelection.mayApplyInitialPack(to: configurationURL) {
            // Replaying an installer must not overwrite a locally edited copy
            // of its original pack, even when the active config stays intact.
            if let existing = try store.existing(id: pack.manifest.id) { return (existing, false) }
            return (try store.install(pack), false)
        }
        try saveAndActivate(pack)
        return (pack, true)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private enum CatPackFileIO {
    static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else { throw CatPackError.unsafeFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CatPackError.unsafeFile }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size >= 0 else { throw CatPackError.unsafeFile }
        guard status.st_size <= Int64(maximumBytes) else { throw CatPackError.tooLarge }
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1), total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { memory -> Int in
                #if canImport(Darwin)
                return Darwin.read(descriptor, memory.baseAddress!.advanced(by: total), memory.count - total)
                #else
                return Glibc.read(descriptor, memory.baseAddress!.advanced(by: total), memory.count - total)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw CatPackError.unsafeFile
            }
            if count == 0 { break }
            total += count
        }
        guard total <= maximumBytes else { throw CatPackError.tooLarge }
        return Data(buffer.prefix(total))
    }

    static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw CatPackError.unsafeFile }
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw CatPackError.unsafeFile
        }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw CatPackError.unsafeFile }
        try requireDirectory(url.deletingLastPathComponent())
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw CatPackError.unsafeFile }
        } else if errno != ENOENT { throw CatPackError.unsafeFile }
        try data.write(to: url, options: .atomic)
    }
}
