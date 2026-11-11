import Foundation

/// `meeting-diarizer --manifest` 的輸入。schema 見 docs/spikes/2026-11-diarization-m2-design.md 附錄 A。
///
/// ```json
/// {"version": 1, "chunks": [{"path": "chunk-001.m4a", "offset": 0.0}, {"path": "chunk-002.m4a", "offset": 300.4}]}
/// ```
struct MeetingManifest: Codable, Equatable {
    struct Chunk: Codable, Equatable {
        /// 絕對路徑，或相對於 manifest 所在資料夾的路徑。
        let path: String
        /// 這段錄音在整場會議的開始時間（秒，>= 0）。
        let offset: Double
    }

    static let supportedVersion = 1
    let version: Int
    let chunks: [Chunk]

    enum ManifestError: Error, CustomStringConvertible {
        case unreadable(String)
        case unsupportedVersion(Int)
        case empty
        case badOffset(String)

        var description: String {
            switch self {
            case .unreadable(let message): return "cannot read manifest: \(message)"
            case .unsupportedVersion(let version): return "unsupported manifest version \(version) (expected \(MeetingManifest.supportedVersion))"
            case .empty: return "manifest has no chunks"
            case .badOffset(let path): return "invalid offset for \(path)"
            }
        }
    }

    static func load(from url: URL) throws -> MeetingManifest {
        let manifest: MeetingManifest
        do {
            manifest = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: url))
        } catch {
            throw ManifestError.unreadable(error.localizedDescription)
        }
        guard manifest.version == supportedVersion else { throw ManifestError.unsupportedVersion(manifest.version) }
        guard !manifest.chunks.isEmpty else { throw ManifestError.empty }
        for chunk in manifest.chunks where !chunk.offset.isFinite || chunk.offset < 0 {
            throw ManifestError.badOffset(chunk.path)
        }
        return manifest
    }

    func resolvedURL(for chunk: Chunk, relativeTo manifestURL: URL) -> URL {
        if chunk.path.hasPrefix("/") { return URL(fileURLWithPath: chunk.path) }
        return manifestURL.deletingLastPathComponent().appendingPathComponent(chunk.path)
    }
}
