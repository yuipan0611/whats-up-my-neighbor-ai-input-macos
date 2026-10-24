import AppKit

@main enum CatCustomizationTests {
    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var features = CatFeatures()
        features.eyes.left = "#81AFC2"
        features.eyes.right = "#D8AD59"
        features.nose.shape = .triangle
        features.nose.freckles = true
        features.collar.enabled = true
        features.bow.enabled = true
        features.bow.position = .leftEar
        let original = CatAppearance.makePreset("tuxedo")!.replacingFeatures(features)
        let editor = CatCustomizationWindowController(appearance: original, name: "麻糬",
            resources: root.appendingPathComponent("Resources/DesktopPet"))
        var saved: CatAppearance?, name: String?
        editor.onSave = { appearance, value in saved = appearance; name = value }
        editor.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        editor.testSave()
        precondition(saved == original && name == "麻糬", "Opening and saving an existing pack preserves every feature")
        let content = editor.window!.contentView!
        content.layoutSubtreeIfNeeded()
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        // The native window supplies its background separately from the
        // content view. Include that background in the standalone QA capture.
        let contentImage = NSImage(size: content.bounds.size)
        contentImage.addRepresentation(bitmap)
        let capture = NSImage(size: content.bounds.size)
        capture.lockFocus()
        editor.window!.effectiveAppearance.performAsCurrentDrawingAppearance {
            editor.window!.backgroundColor.setFill()
            NSBezierPath(rect: content.bounds).fill()
            contentImage.draw(in: content.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
        capture.unlockFocus()
        let flattened = NSBitmapImageRep(data: capture.tiffRepresentation!)!
        precondition(flattened.colorAt(x: 0, y: 0)!.alphaComponent > 0.99,
                     "Standalone editor capture includes the opaque native window background")
        try flattened.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("customization-window.png"))
        editor.testDisableLeftEye()
        precondition(editor.draft.features.eyes.left == nil)
        precondition(editor.draft.features.eyes.right == original.features.eyes.right,
                     "Editing one eye must not replace the other eye")
        precondition(editor.draft.features.bow == original.features.bow)
        precondition(editor.draft.parts == original.parts, "Feature controls must preserve custom body colors")
        editor.close()
        precondition(saved == original, "Closing unsaved edits does not change the last applied appearance")
        print("CatCustomizationTests passed")
    }
}
