import Foundation

enum CatCoatSelection {
    enum Error: LocalizedError {
        case unknownCoat
        case invalidConfiguration
        case customAppearance
        case unsafeFile
        case configurationTooLarge

        var errorDescription: String? {
            switch self {
            case .unknownCoat: return "找不到這種貓咪花色。"
            case .invalidConfiguration: return "現有貓咪設定格式無效；為避免覆寫，請先從設定資料夾修正。"
            case .customAppearance: return "現有設定包含自訂部位或花紋；選單不會覆寫它們。請從貓咪設定資料夾調整。"
            case .unsafeFile: return "貓咪設定檔不是一般檔案；為避免覆寫，請先檢查設定資料夾。"
            case .configurationTooLarge: return "貓咪設定超過大小限制，無法儲存花色。"
            }
        }
    }

    /// Selects a complete preset without changing greetings, custom images or other settings.
    /// A detailed per-part appearance stays under the user's manual control.
    static func save(_ preset: String, to file: URL = CatConfiguration.directoryURL.appendingPathComponent("cat.config.json")) throws {
        guard let appearance = CatAppearance.makePreset(preset) else { throw Error.unknownCoat }
        try write(appearance, to: file, preservingCustomAppearance: true)
    }

    /// An explicit editor/import action replaces appearance only. Greetings,
    /// custom HUD images and every unrelated preference remain in the document.
    static func saveAppearance(_ appearance: CatAppearance,
                              to file: URL = CatConfiguration.directoryURL.appendingPathComponent("cat.config.json")) throws {
        try write(appearance, to: file, preservingCustomAppearance: false)
    }

    /// Setup documents may establish a first choice, but never overwrite an
    /// existing configuration (including malformed files or dangling links).
    static func mayApplyInitialPack(to file: URL = CatConfiguration.directoryURL.appendingPathComponent("cat.config.json")) -> Bool {
        let manager = FileManager.default
        return !manager.fileExists(atPath: file.path) &&
            (try? manager.destinationOfSymbolicLink(atPath: file.path)) == nil
    }

    private static func write(_ appearance: CatAppearance, to file: URL, preservingCustomAppearance: Bool) throws {
        guard let checked = try? CatAppearance.parse(appearance.jsonObject), checked == appearance else {
            throw Error.invalidConfiguration
        }
        let manager = FileManager.default
        var document: [String: Any] = [:]
        if (try? manager.destinationOfSymbolicLink(atPath: file.path)) != nil { throw Error.unsafeFile }
        if manager.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Error.unsafeFile }
            let configuration = CatConfiguration.load(from: file)
            guard configuration.loadError == nil else { throw Error.invalidConfiguration }
            var original = try Data(contentsOf: file)
            if original.starts(with: [0xEF, 0xBB, 0xBF]) { original.removeFirst(3) }
            guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw Error.invalidConfiguration
            }
            document = parsed
            if preservingCustomAppearance && document["appearance"] != nil {
                // The bundled full examples resolve to the same preset. Only
                // actual custom colors, patterns or seeds need manual care.
                guard configuration.appearance == CatAppearance.makePreset(configuration.appearance.preset) else {
                    throw Error.customAppearance
                }
            }
        }

        document["version"] = 2
        document["appearance"] = appearance.jsonObject
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= CatConfiguration.maximumFileBytes else { throw Error.configurationTooLarge }

        let directory = file.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let validationFile = directory.appendingPathComponent(".cat-coat-check-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: validationFile) }
        try data.write(to: validationFile, options: .atomic)
        let validated = CatConfiguration.load(from: validationFile)
        guard validated.loadError == nil, validated.appearance == appearance else { throw Error.invalidConfiguration }
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
