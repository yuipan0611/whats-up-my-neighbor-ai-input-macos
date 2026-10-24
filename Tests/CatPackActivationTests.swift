import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main enum CatPackActivationTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2, "Pass the ZIP fixture directory")
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatPackActivationTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cat.config.json")
        let appearance = try CatAppearance.parse([
            "preset": "tuxedo", "seed": 23,
            "parts": ["tail": ["color": "#8D9295", "pattern": "none"]],
            "features": [
                "eyes": ["left": "#60B9C8", "right": "#DEA245"],
                "nose": ["shape": "heart", "color": "#C98784", "freckles": true],
                "collar": ["enabled": true, "color": "#A45E58"],
                "bow": ["enabled": true, "color": "#C98784", "knotColor": "#9F5B60", "position": "leftEar"]
            ]
        ])

        try check(CatCoatSelection.mayApplyInitialPack(to: file), "A missing configuration can receive its first cat")
        try CatCoatSelection.saveAppearance(appearance, to: file)
        try check(CatConfiguration.load(from: file).appearance == appearance)
        try check(!CatCoatSelection.mayApplyInitialPack(to: file), "A persisted choice blocks setup replacement")

        let image = try Data(contentsOf: fixtures.appendingPathComponent("preview.png"))
        try image.write(to: directory.appendingPathComponent("my-cat.png"))
        let previous: [String: Any] = [
            "version": 1, "image": "my-cat.png", "triggers": ["你好貓咪", "hello mochi"],
            "reply": "我在這裡喵", "fontFamily": "Helvetica", "fontSize": 22,
            "bold": false, "bubblePosition": "upperLeft", "tiltDegrees": 5,
            "cooldownSeconds": 7, "displaySeconds": 4, "animateMouth": false
        ]
        try JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys]).write(to: file)
        try check(!CatCoatSelection.mayApplyInitialPack(to: file), "Even an old v1 configuration belongs to its user")
        try CatCoatSelection.saveAppearance(appearance, to: file)
        let actual = CatConfiguration.load(from: file)
        try check(actual.loadError == nil && actual.version == 2 && actual.appearance == appearance)
        try check(actual.reply == "我在這裡喵" && actual.triggers == ["你好貓咪", "hello mochi"])
        try check(actual.image == "my-cat.png" && actual.imageData == image, "Custom HUD PNG remains active")
        try check(actual.fontFamily == "Helvetica" && actual.fontSize == 22 && !actual.bold)
        try check(actual.bubblePosition == "upperLeft" && actual.tiltDegrees == 5)
        try check(actual.cooldownSeconds == 7 && actual.displaySeconds == 4 && !actual.animateMouth)
        try check(actual.matches("  HELLO   MOCHI! ") && actual.matches("你好貓咪。"))
        try check(!actual.matches("what's up") && !actual.matches("請幫我說 hello mochi"), "Activation retains complete-utterance trigger policy")
        let greeting = CatGreeting(configuration: actual)
        try check(greeting.consume("你好貓咪", now: 10) == .greet)
        try check(greeting.consume("hello mochi", now: 11) == .cooldown)
        try check(greeting.consume("hello mochi", now: 18) == .greet)
        var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        saved.removeValue(forKey: "version")
        saved.removeValue(forKey: "appearance")
        var unrelated = previous
        unrelated.removeValue(forKey: "version")
        try check(NSDictionary(dictionary: saved).isEqual(to: unrelated), "Only version and appearance may change")

        let accepted = try Data(contentsOf: file)
        expectFailure("The simple preset menu must not silently erase explicit features") {
            try CatCoatSelection.save("white", to: file)
        }
        try check(try Data(contentsOf: file) == accepted)
        var invalidFeatures = appearance.features
        invalidFeatures.eyes.left = "invalid"
        expectFailure("Invalid editor data must not change settings") {
            try CatCoatSelection.saveAppearance(appearance.replacingFeatures(invalidFeatures), to: file)
        }
        try check(try Data(contentsOf: file) == accepted)

        // Every failed write preserves the exact original, including malformed documents.
        for invalid in [Data(#"{"version":1,"reply":"保留","unknown":true}"#.utf8),
                        Data("{broken-json".utf8), Data([0xff, 0xfe, 0x00]),
                        Data(repeating: 32, count: CatConfiguration.maximumFileBytes + 1)] {
            try invalid.write(to: file)
            try check(!CatCoatSelection.mayApplyInitialPack(to: file), "An invalid existing file still blocks setup")
            expectFailure("Failed activation preserves invalid settings for repair") {
                try CatCoatSelection.saveAppearance(appearance, to: file)
            }
            try check(try Data(contentsOf: file) == invalid)
        }
        try FileManager.default.removeItem(at: file)
        let original = directory.appendingPathComponent("original.json")
        try accepted.write(to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        try check(!CatCoatSelection.mayApplyInitialPack(to: file))
        expectFailure("Existing symlink is not a writable configuration") {
            try CatCoatSelection.saveAppearance(appearance, to: file)
        }
        try check(try Data(contentsOf: original) == accepted)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("missing.json"))
        try check(!CatCoatSelection.mayApplyInitialPack(to: file), "Dangling symlink must not look like first use")
        expectFailure("Dangling symlink is preserved") { try CatCoatSelection.saveAppearance(appearance, to: file) }
        try check(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).hasSuffix("missing.json"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try check(!CatCoatSelection.mayApplyInitialPack(to: file))
        expectFailure("Directory is not replaced by setup") { try CatCoatSelection.saveAppearance(appearance, to: file) }
        try FileManager.default.removeItem(at: file)
        try check(mkfifo(file.path, 0o600) == 0)
        try check(!CatCoatSelection.mayApplyInitialPack(to: file))
        expectFailure("FIFO is rejected without blocking") { try CatCoatSelection.saveAppearance(appearance, to: file) }

        try FileManager.default.removeItem(at: file)
        let store = CatPackStore(rootURL: directory.appendingPathComponent("Cats", isDirectory: true))
        let importer = CatPackImporter(store: store, configurationURL: file)
        let initialPack = CatPack(manifest: CatPackManifest(id: "custom-mochi", name: "麻糬"), appearance: appearance)
        let seedURL = directory.appendingPathComponent("FirstCat.nekocatsetup")
        try CatPackArchive.write(initialPack, to: seedURL)
        let firstImport = try importer.importDocument(from: seedURL, initial: true)
        try check(firstImport.applied && firstImport.pack == initialPack)
        try check(CatConfiguration.load(from: file).appearance == appearance)
        try check(try store.load(id: "custom-mochi") == initialPack)

        var editedFeatures = appearance.features
        editedFeatures.bow.position = .rightEar
        editedFeatures.nose.shape = .round
        let editedPack = CatPack(manifest: CatPackManifest(id: "custom-mochi", name: "麻糬的日常", version: "1.1.0"),
                                 appearance: appearance.replacingFeatures(editedFeatures))
        try importer.saveAndActivate(editedPack)
        let installedURL = store.rootURL.appendingPathComponent("custom-mochi.nekocat")
        let editedBytes = try Data(contentsOf: installedURL)
        let editedConfig = try Data(contentsOf: file)
        let replay = try importer.importDocument(from: seedURL, initial: true)
        try check(!replay.applied && replay.pack == editedPack, "Replaying setup returns the edited local copy")
        try check(try Data(contentsOf: installedURL) == editedBytes, "Setup replay cannot overwrite edited character")
        try check(try Data(contentsOf: file) == editedConfig, "Setup replay cannot overwrite active configuration")
        var anotherSeed = initialPack
        anotherSeed.manifest.id = "another-mochi"
        let secondURL = directory.appendingPathComponent("AnotherCat.nekocatsetup")
        try CatPackArchive.write(anotherSeed, to: secondURL)
        let secondImport = try importer.importDocument(from: secondURL, initial: true)
        try check(!secondImport.applied && secondImport.pack == anotherSeed)
        try check(try store.load(id: anotherSeed.manifest.id) == anotherSeed, "A new setup cat can join the library")
        try check(try Data(contentsOf: file) == editedConfig, "Adding a setup cat preserves an existing selection")

        let brokenConfig = Data("{existing-broken-config".utf8)
        try brokenConfig.write(to: file)
        expectFailure("Failed activation restores the same-ID edited pack") {
            try importer.saveAndActivate(initialPack)
        }
        try check(try Data(contentsOf: installedURL) == editedBytes)
        try check(try Data(contentsOf: file) == brokenConfig)
        var newPack = initialPack
        newPack.manifest.id = "new-failed-cat"
        expectFailure("Failed activation rolls back a new library entry") {
            try importer.saveAndActivate(newPack)
        }
        try check(try store.existing(id: newPack.manifest.id) == nil)
        try check(try Data(contentsOf: file) == brokenConfig)
        let corruptURL = store.rootURL.appendingPathComponent("corrupt-cat.nekocat")
        let corruptData = Data("Do not overwrite this user's damaged pack".utf8)
        try corruptData.write(to: corruptURL)
        var replacement = initialPack
        replacement.manifest.id = "corrupt-cat"
        expectFailure("Existing corrupt packs are preserved for recovery") {
            try importer.saveAndActivate(replacement)
        }
        try check(try Data(contentsOf: corruptURL) == corruptData)

        try JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys]).write(to: file)
        let explicit = try importer.importDocument(from: seedURL, initial: false)
        try check(explicit.applied && explicit.pack == initialPack, "Explicit import may replace an existing cat")
        try check(try store.load(id: initialPack.manifest.id) == initialPack)
        let explicitConfiguration = CatConfiguration.load(from: file)
        try check(explicitConfiguration.appearance == appearance && explicitConfiguration.matches("你好貓咪。"))
        try check(explicitConfiguration.imageData == image && explicitConfiguration.reply == "我在這裡喵")

        print("CatPackActivationTests passed: appearance-only updates, first-use policy, setup replay, v1/PNG/greetings and two-file rollback")
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
