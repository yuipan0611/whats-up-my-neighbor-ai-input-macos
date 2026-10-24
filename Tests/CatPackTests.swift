import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main enum CatPackTests {
    static func main() throws {
        try check(CommandLine.arguments.count == 3, "Pass the ZIP fixture directory and QA pack destination")
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatPackTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let features: [String: Any] = [
            "eyes": ["left": "#60B9C8", "right": "#DEA245"],
            "nose": ["shape": "triangle", "color": "#C98784", "freckles": true],
            "collar": ["enabled": true, "color": "#A45E58"],
            "bow": ["enabled": true, "color": "#C98784", "knotColor": "#9F5B60", "position": "neck"]
        ]
        let appearance = try CatAppearance.parse(["preset": "tuxedo", "seed": 42, "features": features])
        let expected = CatPack(manifest: CatPackManifest(id: "custom-mochi", name: "麻糬"), appearance: appearance)

        for name in ["valid-stored.nekocat", "valid-deflated.nekocat", "valid-streaming.nekocat", "FirstCat.nekocatsetup"] {
            let actual = try CatPackArchive.read(from: fixtures.appendingPathComponent(name))
            try check(actual == expected, "Standard ZIP interoperability and complete feature identity: \(name)")
        }
        let encoded = try CatPackArchive.encode(expected)
        try check(try CatPackArchive.decode(encoded) == expected, "Exported pack round-trip must preserve all data")
        try check(encoded == (try CatPackArchive.encode(expected)), "Export must be deterministic")
        let exported = directory.appendingPathComponent("exported.nekocat")
        try CatPackArchive.write(expected, to: exported)
        try check(try CatPackArchive.read(from: exported) == expected)

        let withPreview = try CatPackArchive.read(from: fixtures.appendingPathComponent("valid-preview.nekocat"))
        try check(withPreview.appearance == expected.appearance)
        try check(withPreview.previewPNG == (try Data(contentsOf: fixtures.appendingPathComponent("preview.png"))))
        try check(try CatPackArchive.decode(CatPackArchive.encode(withPreview)) == withPreview)

        let rejected = [
            "bad-template", "bad-schema", "boolean-schema", "traversal-id", "bad-name", "unknown-manifest-field",
            "missing-appearance", "duplicate", "traversal", "extra-script", "invalid-feature", "wrong-config-shape",
            "huge-expanded", "symlink", "executable-data", "invalid-preview", "huge-preview", "truncated",
            "oversized", "bad-crc", "local-name-mismatch", "encrypted", "unsupported-method"
        ]
        for name in rejected {
            expectFailure("Reject \(name)") { _ = try CatPackArchive.read(from: fixtures.appendingPathComponent(name + ".nekocat")) }
        }
        for id in ["../escape", "/absolute", "UpperCase", ".hidden", "trailing.", "a..b", "contains space", "con", "a/b", "貓咪"] {
            try check(!CatPackManifest.validID(id), "ID must be safe and portable: \(id)")
        }
        for id in ["mochi", "custom-mochi", "org.example.mochi", "cat-2026"] {
            try check(CatPackManifest.validID(id))
        }

        // Reading directories, symlinks and FIFOs must not decode or block.
        expectFailure("Reject directory") { _ = try CatPackArchive.read(from: directory) }
        let symlink = directory.appendingPathComponent("link.nekocat")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: exported)
        expectFailure("Reject source symlink") { _ = try CatPackArchive.read(from: symlink) }
        let fifo = directory.appendingPathComponent("pipe.nekocat")
        try check(mkfifo(fifo.path, 0o600) == 0)
        expectFailure("Reject nonblocking FIFO") { _ = try CatPackArchive.read(from: fifo) }

        // The only mutable data owned by the store is each installed .nekocat file.
        let config = directory.appendingPathComponent("cat.config.json")
        let previousPreferences = Data(#"{"version":1,"reply":"保持原本問候","triggers":["你好貓咪"]}"#.utf8)
        try previousPreferences.write(to: config)
        let store = CatPackStore(rootURL: directory.appendingPathComponent("Cats", isDirectory: true))
        try check(try store.list().isEmpty)
        let source = directory.appendingPathComponent("received.nekocat")
        try encoded.write(to: source)
        try check(try store.importPack(from: source) == expected)
        try FileManager.default.removeItem(at: source)
        try check(try store.load(id: expected.manifest.id) == expected, "Deleting downloaded original must not remove installed cat")
        try check(try store.list() == [expected])
        let installedURL = store.rootURL.appendingPathComponent(expected.manifest.id + ".nekocat")
        let before = try Data(contentsOf: installedURL)
        for name in ["bad-crc", "invalid-feature", "huge-expanded"] {
            expectFailure("Invalid import leaves previous installation intact") {
                _ = try store.importPack(from: fixtures.appendingPathComponent(name + ".nekocat"))
            }
            try check(try Data(contentsOf: installedURL) == before)
        }
        var updated = expected
        updated.manifest.version = "1.1.0"
        updated.manifest.name = "麻糬的新蝴蝶結"
        try store.install(updated)
        try check(try store.load(id: updated.manifest.id) == updated)
        try check(try store.list() == [updated], "Same pack ID updates one installed character")
        try store.export(id: updated.manifest.id, to: exported)
        try check(try CatPackArchive.read(from: exported) == updated)
        try check(try Data(contentsOf: config) == previousPreferences, "Import/export must not rewrite user preferences")
        expectFailure("Invalid lookup cannot escape store") { _ = try store.load(id: "../exported") }

        // One damaged entry does not hide the user's other working cats.
        try Data("invalid".utf8).write(to: store.rootURL.appendingPathComponent("broken.nekocat"))
        try check(try store.list() == [updated])
        try FileManager.default.removeItem(at: installedURL)
        try FileManager.default.createSymbolicLink(at: installedURL, withDestinationURL: config)
        expectFailure("Installed symlink is never followed or overwritten") { _ = try store.install(expected) }
        try check(try Data(contentsOf: config) == previousPreferences)
        let storeLink = directory.appendingPathComponent("CatsLink")
        try FileManager.default.createSymbolicLink(at: storeLink, withDestinationURL: store.rootURL)
        expectFailure("Store directory cannot itself be a symlink") { _ = try CatPackStore(rootURL: storeLink).install(expected) }

        let qaPack = URL(fileURLWithPath: CommandLine.arguments[2])
        try CatPackArchive.write(expected, to: qaPack)
        try check(try CatPackArchive.read(from: qaPack) == expected, "The delivered QA example is a fully validated exported pack")

        print("CatPackTests passed: standard ZIPs, features, previews, \(rejected.count) invalid packs, atomic storage and isolated preferences")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "") throws {
        let satisfied = try condition()
        precondition(satisfied, message)
    }

    private static func expectFailure(_ message: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure(message) }
        catch { }
    }
}
