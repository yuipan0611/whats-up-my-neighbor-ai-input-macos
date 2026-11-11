import Foundation

/// 說話者辨識會刪除「模型檔」與「會議音檔」。這些路徑底下可能有使用者自己放的東西，
/// 也可能被換成資料夾或 symlink，所以一律不用遞迴刪除，只刪「自己建立、型別正確」的項目：
/// - 刪除前用 `lstat`（不跟隨 symlink）確認是一般檔案；資料夾、symlink、特殊檔案一律跳過。
/// - 路徑必須在指定的 root 底下：root 本身不能是 symlink，root 到檔案之間的每一層都必須是真的資料夾
///   （不是 symlink），所以「上層被換成 symlink 導到外面」的路徑不會被刪。
/// - 暫存資料夾只刪符合自己命名規則（`.download-<UUID>`）的項目，裡面只認識 `download-N.part` 與
///   `extract-<UUID>/`；遇到不認識的東西就整個跳過、不刪、記錄下來。
/// - 資料夾只用 `rmdir`（非遞迴，非空就失敗），不會連帶刪掉裡面的東西。
enum SafeFileRemoval {
    /// 跳過時的記錄（預設寫到 NSLog）。測試可以換掉它來檢查。
    static var onSkip: (String) -> Void = { NSLog("[SafeFileRemoval] skipped: %@", $0) }

    enum Kind { case missing, regularFile, directory, symlink, other }

    static func kind(of url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// root 本身是真的資料夾（不是 symlink），而且 `url` 在 root 底下，沿途每一層都是真的資料夾。
    static func isConfined(_ url: URL, within root: URL) -> Bool {
        guard kind(of: root) == .directory else { return false }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        var current = root.standardizedFileURL
        let parts = path.dropFirst(rootPath.count + 1).split(separator: "/").dropLast()
        for part in parts {
            current.appendPathComponent(String(part), isDirectory: true)
            guard kind(of: current) == .directory else { return false }
        }
        return true
    }

    /// 刪除 root 底下的一個一般檔案。回傳是否真的刪了。
    @discardableResult
    static func removeRegularFile(_ url: URL, within root: URL) -> Bool {
        guard isConfined(url, within: root) else { onSkip("\(url.path): outside \(root.path) or through a symlink"); return false }
        switch kind(of: url) {
        case .missing: return false
        case .regularFile: break
        default: onSkip("\(url.path): not a regular file"); return false
        }
        return unlink(url.path) == 0
    }

    /// 只在資料夾是空的、而且是真的資料夾時移除（`rmdir`）。`root` 為 nil 表示這個資料夾就是要檢查的 root 本身。
    @discardableResult
    static func removeEmptyDirectory(_ url: URL, within root: URL?) -> Bool {
        if let root, !isConfined(url, within: root) { return false }
        guard kind(of: url) == .directory else { return false }
        return rmdir(url.path) == 0
    }

    // MARK: 下載暫存

    static let stagingPattern = #"^\.download-[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#
    private static let partPattern = #"^download-\d+\.part$"#
    private static let extractPattern = #"^extract-[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#

    static func isStagingName(_ name: String) -> Bool { name.range(of: stagingPattern, options: .regularExpression) != nil }

    /// 刪除一個下載暫存資料夾。名稱不符、型別不符、裡面有不認識的東西，一律不刪（記錄原因）。
    /// 回傳是否整個資料夾都清掉了。
    @discardableResult
    static func removeOwnedStaging(_ directory: URL, within root: URL) -> Bool {
        guard isStagingName(directory.lastPathComponent), isConfined(directory, within: root),
              kind(of: directory) == .directory else {
            onSkip("\(directory.path): not an owned download staging folder"); return false
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        for name in names {
            let item = directory.appendingPathComponent(name)
            switch kind(of: item) {
            case .regularFile where name.range(of: partPattern, options: .regularExpression) != nil:
                unlink(item.path)
            case .directory where name.range(of: extractPattern, options: .regularExpression) != nil:
                removeExtractTree(item)
            default:
                onSkip("\(item.path): unknown item in download staging, left alone")
            }
        }
        return rmdir(directory.path) == 0
    }

    /// `extract-<UUID>/` 是我們呼叫 tar 解出的內容：只刪一般檔案與資料夾，遇到 symlink／特殊檔案就停下來。
    private static func removeExtractTree(_ directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let item = directory.appendingPathComponent(name)
            switch kind(of: item) {
            case .regularFile: unlink(item.path)
            case .directory: removeExtractTree(item)
            default: onSkip("\(item.path): unexpected item in extracted archive, left alone")
            }
        }
        rmdir(directory.path)
    }
}
