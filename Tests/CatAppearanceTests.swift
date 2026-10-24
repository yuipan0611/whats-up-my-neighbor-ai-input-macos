import AppKit

@main enum CatAppearanceTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }
    static func rgba(_ image: NSImage) -> (Int, Int, [UInt8]) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (cg.width, cg.height, pixels)
    }
    static func png(_ image: NSImage, to url: URL) throws {
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
    }
    static func render(_ view: NSView) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
            pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = view.bounds.size
        bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size); image.addRepresentation(bitmap)
        return image
    }
    static func sheet(_ images: [NSImage], labels: [String], columns: Int, cell: NSSize) -> NSImage {
        let size = NSSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat((images.count + columns - 1) / columns))
        return NSImage(size: size, flipped: true) { _ in
            NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            for (i, image) in images.enumerated() {
                let x = CGFloat(i % columns) * cell.width, y = CGFloat(i / columns) * cell.height
                let area = CGRect(x: x + 8, y: y + 28, width: cell.width - 16, height: cell.height - 42)
                let scale = min(area.width / image.size.width, area.height / image.size.height)
                let rect = CGRect(x: area.midX - image.size.width * scale / 2,
                    y: area.midY - image.size.height * scale / 2, width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                (labels[i] as NSString).draw(at: CGPoint(x: x + 12, y: y + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            }
            return true
        }
    }
    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let configURL = output.appendingPathComponent("test.config.json")
        func load(_ object: [String: Any]) throws -> CatConfiguration {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: configURL)
            return CatConfiguration.load(from: configURL)
        }
        for id in CatAppearance.presetIDs {
            let result = try load(["version": 2, "appearance": ["preset": id]])
            check(result.loadError == nil && result.appearance.preset == id, "preset loads: \(id)")
            check(result.appearance.parts.count == CatBodyPart.allCases.count, "every anatomical part filled")
            check(try! CatAppearance.parse(result.appearance.jsonObject) == result.appearance, "full example round trips")
        }
        check(try! load(["version": 1]).appearance == .original, "legacy v1 stays original")
        check(try! load(["version": 2]).appearance == .original, "v2 appearance optional")
        var template = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cat.config.json"))) as! [String: Any]
        var templateAppearance = template["appearance"] as! [String: Any]
        templateAppearance["preset"] = "tuxedo"; template["appearance"] = templateAppearance
        check(try! load(template).appearance == CatAppearance.makePreset("tuxedo")!, "new template permits changing only the preset without stale overrides")
        let custom = try load(["version": 2, "appearance": ["preset": "tuxedo", "parts": ["tail": ["color": "#abcdef", "pattern": "none"]]]])
        check(custom.appearance[.tail].color == "#ABCDEF", "override and color normalization")
        check(custom.appearance[.chest].color == "#F4EFE5", "unmentioned features inherited")
        for pattern in CatPattern.allCases {
            let c = try load(["version": 2, "appearance": ["preset": "blue", "parts": ["head": ["pattern": pattern.rawValue]]]])
            check(c.loadError == nil && c.appearance[.head].pattern == pattern, "pattern accepted")
        }
        let invalid: [[String: Any]] = [
            ["version": 1, "appearance": ["preset": "white"]],
            ["appearance": ["preset": "white"]], ["version": 3],
            ["version": 2, "appearance": NSNull()],
            ["version": 2, "appearance": ["preset": "unknown"]],
            ["version": 2, "appearance": ["preset": "white", "seed": true]],
            ["version": 2, "appearance": ["preset": "white", "seed": -1]],
            ["version": 2, "appearance": ["preset": "white", "seed": 1.5]],
            ["version": 2, "appearance": ["preset": "white", "seed": 4_294_967_296 as UInt64]],
            ["version": 2, "appearance": ["preset": "white", "url": "https://example.invalid"]],
            ["version": 2, "appearance": ["preset": "white", "parts": ["wing": [:]]]],
            ["version": 2, "appearance": ["preset": "white", "parts": ["head": ["color": "red"]]]],
            ["version": 2, "appearance": ["preset": "white", "parts": ["head": ["color": "#12345678"]]]],
            ["version": 2, "appearance": ["preset": "white", "parts": ["head": ["color": "#１２３４５６"]]]],
            ["version": 2, "appearance": ["preset": "white", "parts": ["head": ["pattern": "random"]]]],
            ["version": 2, "appearance": ["preset": "white", "parts": ["head": ["unknown": true]]]]
        ]
        for object in invalid {
            let c = try load(object), preserved = try Data(contentsOf: configURL)
            check(c.loadError != nil && c.appearance == .original, "invalid appearance falls back as a whole")
            check(preserved == (try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])), "input preserved")
        }
        let resources = root.appendingPathComponent("Resources/DesktopPet"), hudURL = root.appendingPathComponent("Resources/neko-base.png")
        let maps = CatAnatomy.pickupMaps(at: resources.appendingPathComponent("Pickup/anatomy.json"))!
        check(maps.count == 36, "all 36 frame maps load")
        check(CatAnatomy.pickupMaps(at: output.appendingPathComponent("missing.json")) == nil, "missing maps fail closed")
        let cheekPainter = CatAppearanceArtwork(CatAppearance.makePreset("calico")!)
        func isWhite(_ color: CatAppearanceArtwork.RGB) -> Bool { color.r == 244 && color.g == 239 && color.b == 229 }
        // These side samples reproduce the white slivers in the owner's
        // screenshot; the central blaze is intentionally still white.
        for u in [0.01, 0.02, 0.98, 0.99] {
            for v in [0.53, 0.55, 0.58, 0.61] {
                check(!isWhite(cheekPainter.rgb(.init(part: .head, u: u, v: v))), "cheek patches meet at either lateral contour")
            }
        }
        check(isWhite(cheekPainter.rgb(.init(part: .head, u: 0.5, v: 0.55))), "central white blaze preserved")
        check(isWhite(cheekPainter.rgb(.init(part: .muzzle, u: 0.5, v: 0.9))), "independent white muzzle preserved")
        let tabbyPainter = CatAppearanceArtwork(CatAppearance.makePreset("orange-tabby")!)
        func sameRGB(_ a: CatAppearanceArtwork.RGB, _ b: CatAppearanceArtwork.RGB) -> Bool {
            abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
        }
        let tabbyBase = CatAppearanceArtwork.RGB("#D6A366"), tabbyStripe = CatAppearanceArtwork.RGB("#9A5F2D")
        // Owner-reported belts across the torso and stripes over the eyes must
        // not return. These are anatomical landmarks, not mask implementation.
        for part in [CatBodyPart.body, .chest, .belly] {
            for v in stride(from: 0.1, through: 0.9, by: 0.1) {
                check(sameRGB(tabbyPainter.rgb(.init(part: part, u: 0.5, v: v)), tabbyBase), "tabby keeps the middle of the chest and belly clear")
            }
        }
        for u in [0.18, 0.23, 0.28, 0.72, 0.77, 0.82] {
            for v in [0.64, 0.70, 0.76] {
                check(sameRGB(tabbyPainter.rgb(.init(part: .head, u: u, v: v)), tabbyBase), "tabby markings leave both eye glyphs clear")
            }
        }
        for (part, u, v) in [(CatBodyPart.head, 0.5, 0.30), (.head, 0.39, 0.30), (.head, 0.61, 0.30),
                              (.head, 0.05, 0.55), (.head, 0.95, 0.55), (.body, 0.15, 0.35),
                              (.body, 0.85, 0.35), (.tail, 0.60, 0.10), (.tail, 0.90, 0.50)] {
            check(sameRGB(tabbyPainter.rgb(.init(part: part, u: u, v: v)), tabbyStripe), "tabby retains visible forehead, cheek, flank and tail markings")
        }
        check(sameRGB(tabbyPainter.rgb(.init(part: .head, u: 0.5, v: 0.75)), tabbyBase), "forehead markings cannot be vertically flipped onto the nose")
        let hudForehead = CatAnatomy.sample(x: 500, y: 465, width: 1000, height: 1000, layout: .hud)
        check(sameRGB(tabbyPainter.rgb(hudForehead), tabbyStripe), "recording forehead marks remain below its flat top contour")
        let unpatternedTail = try load(["version": 2, "appearance": ["preset": "orange-tabby", "parts": ["tail": ["color": "#345678", "pattern": "none"]]]])
        check(sameRGB(CatAppearanceArtwork(unpatternedTail.appearance).rgb(.init(part: .tail, u: 0.6, v: 0.1)), .init("#345678")), "part override can remove a tail ring")
        let alternateStripe = try load(["version": 2, "appearance": ["preset": "orange-tabby", "parts": ["head": ["patternColor": "#ABCDEF"]]]])
        check(sameRGB(CatAppearanceArtwork(alternateStripe.appearance).rgb(.init(part: .head, u: 0.5, v: 0.3)), .init("#ABCDEF")), "authored markings still use the part's custom pattern color")
        var lineup: [NSImage] = [], hudLineup: [NSImage] = [], recordingLineup: [NSImage] = []
        var visibleParts = Set<CatBodyPart>()
        var paintMilliseconds: [Double] = []
        let examples = output.appendingPathComponent("examples")
        try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
        let poses: [DesktopPetPose] = [.sitting, .standing, .walking, .curious, .petted, .carried, .grooming, .yawning, .loafing, .sleeping]
        let liveView = DesktopPetView(resources: resources)
        let liveOverlay = CatOverlay(configuration: .defaults, bundledImageURL: hudURL)
        defer { liveOverlay.dispose() }
        let liveOverlayPanel = liveOverlay.testPanel
        let liveRecording = NekoRecordingView(image: NSImage(contentsOf: hudURL))
        liveRecording.update(state: .recording)
        var liveCancelCount = 0, liveFinishCount = 0
        liveRecording.onCancel = { liveCancelCount += 1 }
        liveRecording.onFinish = { liveFinishCount += 1 }
        liveOverlay.onCancel = { liveCancelCount += 1 }
        liveOverlay.onFinish = { liveFinishCount += 1 }
        for id in CatAppearance.presetIDs {
            try autoreleasepool {
                let appearance = CatAppearance.makePreset(id)!, painter = CatAppearanceArtwork(appearance)
                let object: [String: Any] = ["version": 2, "appearance": appearance.jsonObject]
                let configuration = try load(object)
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: examples.appendingPathComponent(id + ".json"))
                let shippedExample = CatConfiguration.load(from: root.appendingPathComponent("Examples/CatAppearance/\(id).json"))
                check(shippedExample.loadError == nil && shippedExample.appearance == appearance, "delivered example matches preset")
                var frames: [NSImage] = []
                for i in 0..<36 {
                    let source = NSImage(contentsOf: resources.appendingPathComponent(String(format: "Pickup/%02d.png", i)))!
                    let start = ProcessInfo.processInfo.systemUptime
                    let colored = painter.image(source, layout: .pickup(maps[i]))!
                    if !appearance.isOriginal { paintMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                    let before = rgba(source), after = rgba(colored)
                    check(before.0 == after.0 && before.1 == after.1, "source dimensions preserved")
                    check(stride(from: 3, to: before.2.count, by: 4).allSatisfy { before.2[$0] == after.2[$0] }, "every alpha pixel preserved: \(id)/\(i)")
                    if i == 0 || i == 19 || i == 35 {
                        check(rgba(painter.image(source, layout: .pickup(maps[i]))!).2 == after.2, "deterministic source-frame repaint")
                    }
                    if appearance.isOriginal { check(colored === source, "original bypasses repaint") }
                    if appearance.isOriginal {
                        for y in stride(from: 0, to: before.1, by: 2) { for x in stride(from: 0, to: before.0, by: 2) {
                            if before.2[(y * before.0 + x) * 4 + 3] > 200 {
                                visibleParts.insert(CatAnatomy.sample(x: Double(x), y: Double(y), width: Double(before.0), height: Double(before.1), layout: .pickup(maps[i])).part)
                            }
                        } }
                    }
                    frames.append(colored)
                }
                try png(sheet(frames, labels: (0..<36).map { String(format: "%02d", $0) }, columns: 6, cell: NSSize(width: 208, height: 220)), to: output.appendingPathComponent(id + "-pickup.png"))
                let view = DesktopPetView(resources: resources, appearance: appearance)
                let renders = poses.map { NSImage(data: view.renderPNG(pose: $0, phase: 0.8, walkDistance: 15))! }
                // Switch one live view through every coat after priming its
                // pickup and vector caches with the preceding coat.
                liveView.setAppearance(appearance)
                for (pose, expected) in zip(poses, renders) {
                    let actual = NSImage(data: liveView.renderPNG(pose: pose, phase: 0.8, walkDistance: 15))!
                    check(rgba(actual).2 == rgba(expected).2, "live coat has no stale pixels: \(id)/\(pose)")
                }
                try png(sheet(renders, labels: poses.map(\.description), columns: 5, cell: NSSize(width: 240, height: 235)), to: output.appendingPathComponent(id + "-poses.png"))
                lineup.append(NSImage(data: view.renderPNG(pose: .sitting))!)
                check(!view.containsCat(CGPoint(x: 1, y: 1)), "transparent desktop pixels pass through")
                check(view.containsCat(CGPoint(x: 104, y: 69)), "opaque head remains clickable")
                let recording = NekoRecordingView(image: painter.image(NSImage(contentsOf: hudURL)!, layout: .hud))
                recording.update(state: .recording)
                var recordingCancel = false, recordingFinish = false
                recording.onCancel = { recordingCancel = true }; recording.onFinish = { recordingFinish = true }
                recording.cancelButton.performClick(nil); recording.finishButton.performClick(nil)
                check(recordingCancel && recordingFinish, "recording HUD colored eye actions preserved")
                let recordingImage = render(recording)
                recordingLineup.append(recordingImage)
                liveRecording.setImage(painter.image(NSImage(contentsOf: hudURL)!, layout: .hud))
                check(rgba(render(liveRecording)).2 == rgba(recordingImage).2, "live recording HUD refreshes coat")
                liveRecording.cancelButton.performClick(nil); liveRecording.finishButton.performClick(nil)
                let overlay = CatOverlay(configuration: configuration, bundledImageURL: hudURL)
                let greeting = try overlay.testPNG(greeting: true, frame: 2)
                liveOverlay.setAppearance(appearance)
                check(liveOverlay.testPanel === liveOverlayPanel, "greeting keeps its nonactivating window")
                check(try! liveOverlay.testPNG(greeting: true, frame: 2) == greeting, "live greeting refreshes coat and mouth")
                liveOverlay.showRecording(); liveOverlay.testClickCancel(); liveOverlay.testClickFinish(); liveOverlay.hide()
                try greeting.write(to: output.appendingPathComponent(id + "-greeting.png"))
                hudLineup.append(NSImage(data: greeting)!)
                check(overlay.testCanReplaceMouth, "bundled colored cat retains mouth animation")
                var cancelled = false, finished = false
                overlay.onCancel = { cancelled = true }; overlay.onFinish = { finished = true }
                overlay.showRecording(); overlay.testClickCancel(); overlay.testClickFinish()
                check(cancelled && finished, "eye actions preserved")
                check(!overlay.testPanel.canBecomeKey && !overlay.testPanel.canBecomeMain, "colored panel stays nonactivating")
                overlay.dispose()
                let explicit = try load(["version": 2, "image": "missing.png", "appearance": ["preset": id]])
                let overridden = CatOverlay(configuration: explicit, bundledImageURL: hudURL)
                check(!overridden.testCanReplaceMouth, "explicit image selection retains mouth opt-out")
                overridden.dispose()
            }
        }
        check(liveCancelCount == 18 && liveFinishCount == 18, "live updates preserve recording and overlay callbacks")
        liveView.setAppearance(.original)
        let originalView = DesktopPetView(resources: resources)
        for pose in [DesktopPetPose.sitting, .carried, .walking] {
            check(liveView.renderPNG(pose: pose) == originalView.renderPNG(pose: pose), "return to original clears colored caches")
        }
        check(visibleParts == Set(CatBodyPart.allCases), "all 16 anatomical slots reach visible source pixels across the 36 frames")
        let customSourceURL = output.appendingPathComponent("custom.png")
        try Data(contentsOf: hudURL).write(to: customSourceURL)
        let customConfig = try load(["version": 2, "image": "custom.png", "appearance": ["preset": "calico"]])
        let legacyCustom = try load(["version": 1, "image": "custom.png"])
        check(customConfig.imageData != nil, "valid custom artwork snapshot loads")
        let customOverlay = CatOverlay(configuration: customConfig, bundledImageURL: hudURL)
        let legacyOverlay = CatOverlay(configuration: legacyCustom, bundledImageURL: hudURL)
        check(try! customOverlay.testPNG(greeting: false) == legacyOverlay.testPNG(greeting: false), "explicit valid custom PNG is byte-identical with or without a coat")
        customOverlay.setAppearance(CatAppearance.makePreset("white")!)
        check(try! customOverlay.testPNG(greeting: false) == legacyOverlay.testPNG(greeting: false), "live coat selection preserves explicit custom PNG")
        customOverlay.dispose(); legacyOverlay.dispose()
        try FileManager.default.removeItem(at: customSourceURL)
        try png(sheet(lineup, labels: CatAppearance.presetNames, columns: 3, cell: NSSize(width: 320, height: 280)), to: output.appendingPathComponent("natural-coats.png"))
        try png(sheet(hudLineup, labels: CatAppearance.presetNames, columns: 3, cell: NSSize(width: 440, height: 280)), to: output.appendingPathComponent("greeting-coats.png"))
        try png(sheet(recordingLineup, labels: CatAppearance.presetNames, columns: 3, cell: NSSize(width: 368, height: 250)), to: output.appendingPathComponent("recording-coats.png"))
        try featureChecks(root: root, output: output, resources: resources, hudURL: hudURL, maps: maps)
        try? FileManager.default.removeItem(at: configURL)
        let sortedTimes = paintMilliseconds.sorted()
        print(String(format: "Uncached pickup paint: median %.1f ms, p95 %.1f ms", sortedTimes[sortedTimes.count / 2], sortedTimes[Int(Double(sortedTimes.count - 1) * 0.95)]))
        print("Cat appearance: \(checks) checks passed; 9 coats, 36 source frames each, 10 poses each, live overlay actions, full examples, custom eyes/noses/collars/bows rendered.")
    }

    /// Pixel checks exercise real source frames and the native views. The eye
    /// symbols must stay left/right, disappear when eyes close, and keep their
    /// existing button callbacks after changing every feature.
    static func featureChecks(root: URL, output: URL, resources: URL, hudURL: URL,
                              maps: [CatAnatomy.PickupMap]) throws {
        let data: [String: Any] = ["preset": "tuxedo", "features": [
            "eyes": ["left": "#41B7DB", "right": "#E4A640"],
            "nose": ["shape": "triangle", "color": "#CD8C92", "freckles": true],
            "collar": ["enabled": true, "color": "#5C708A"],
            "bow": ["enabled": true, "color": "#B36A85", "knotColor": "#69415A", "position": "neck"]]]
        let appearance = try CatAppearance.parse(data)
        check(try! CatAppearance.parse(appearance.jsonObject) == appearance, "complete facial/accessory features round trip")
        check(!appearance.isOriginal && !appearance.features.isEmpty, "custom features enter the renderer")
        check(try! CatAppearance.parse(["preset": "original", "features": [:]]).isOriginal, "empty features preserve the original bypass")
        for shape in CatNoseShape.allCases {
            check((try? CatAppearance.parse(["preset": "original", "features": ["nose": ["shape": shape.rawValue]]])) != nil,
                  "all supported nose shapes parse")
        }
        let invalidFeatures: [[String: Any]] = [
            ["eyes": ["left": "blue"]], ["eyes": ["left": "#12345678"]], ["eyes": ["upper": "#123456"]],
            ["nose": ["shape": "folded"]], ["nose": ["freckles": 1]], ["nose": ["color": true]],
            ["collar": ["enabled": 1]], ["collar": ["size": 100]],
            ["bow": ["position": "tail"]], ["bow": ["enabled": "true"]], ["bow": ["knotColor": "red"]],
            ["script": "untrusted"], ["eyes": NSNull()]
        ]
        for features in invalidFeatures {
            check((try? CatAppearance.parse(["preset": "black", "features": features])) == nil, "invalid feature data is rejected")
        }
        func pixels(_ image: NSImage, matching hex: String) -> (count: Int, meanX: Double) {
            let target = CatAppearanceArtwork.RGB(hex), raster = rgba(image)
            var count = 0, sumX = 0.0
            for y in 0..<raster.1 { for x in 0..<raster.0 {
                let i = (y * raster.0 + x) * 4
                if raster.2[i + 3] > 230 && abs(Double(raster.2[i]) - target.r) < 6 &&
                    abs(Double(raster.2[i + 1]) - target.g) < 6 && abs(Double(raster.2[i + 2]) - target.b) < 6 {
                    count += 1; sumX += Double(x)
                }
            } }
            return (count, count > 0 ? sumX / Double(count) : 0)
        }
        func openEyes(_ image: NSImage, label: String) {
            let left = pixels(image, matching: "#41B7DB"), right = pixels(image, matching: "#E4A640")
            check(left.count > 1 && right.count > 1, "both eye colors visible: " + label)
            check(left.meanX < right.meanX, "front-view left/right eyes never swap: " + label)
        }
        let painter = CatAppearanceArtwork(appearance)
        var eyeOnly = CatFeatures()
        eyeOnly.eyes = appearance.features.eyes
        let eyePainter = CatAppearanceArtwork(CatAppearance.original.replacingFeatures(eyeOnly))
        let firstSource = NSImage(contentsOf: resources.appendingPathComponent("Pickup/00.png"))!
        let eyeImage = eyePainter.image(firstSource, layout: .pickup(maps[0]))!
        let originalPixels = rgba(firstSource), eyePixels = rgba(eyeImage)
        check(stride(from: 3, to: originalPixels.2.count, by: 4).allSatisfy { originalPixels.2[$0] == eyePixels.2[$0] },
              "eye colors never change original transparency or silhouette")
        openEyes(eyeImage, label: "original black coat")
        var frames: [NSImage] = []
        for i in 0..<36 {
            let source = NSImage(contentsOf: resources.appendingPathComponent(String(format: "Pickup/%02d.png", i)))!
            let decorated = painter.image(source, layout: .pickup(maps[i]))!
            check(decorated.size == source.size, "features preserve pickup frame size")
            let before = rgba(source), after = rgba(decorated)
            check(before.0 == after.0 && before.1 == after.1, "feature composition keeps native raster dimensions")
            check(stride(from: 3, to: before.2.count, by: 4).allSatisfy { before.2[$0] < 250 || after.2[$0] > 230 },
                  "accessories never move or erase the original pickup silhouette")
            openEyes(decorated, label: "pickup \(i)")
            check(pixels(decorated, matching: "#5C708A").count > 1, "collar follows every pickup pose")
            check(pixels(decorated, matching: "#B36A85").count > 1, "neck bow follows every pickup pose")
            check(pixels(decorated, matching: "#CD8C92").count > 1, "nose survives every pickup pose")
            frames.append(decorated)
        }
        try png(sheet(frames, labels: (0..<36).map { String(format: "%02d", $0) }, columns: 6,
            cell: NSSize(width: 208, height: 220)), to: output.appendingPathComponent("features-pickup.png"))
        let view = DesktopPetView(resources: resources, appearance: appearance)
        let poses: [DesktopPetPose] = [.sitting, .standing, .walking, .curious, .petted, .carried, .grooming, .yawning, .loafing, .sleeping]
        var poseImages: [NSImage] = []
        for pose in poses {
            let rendered = NSImage(data: view.renderPNG(pose: pose, phase: 1.6, walkDistance: 15))!
            poseImages.append(rendered)
            if [.petted, .grooming, .yawning, .sleeping].contains(pose) {
                check(pixels(rendered, matching: "#41B7DB").count == 0 && pixels(rendered, matching: "#E4A640").count == 0,
                      "closed eyes do not retain colored open glyphs: \(pose)")
            } else { openEyes(rendered, label: pose.description) }
            check(pixels(rendered, matching: "#B36A85").count > 0, "bow remains attached in pose: \(pose)")
        }
        for direction in [false, true] {
            openEyes(NSImage(data: view.renderPNG(pose: .walking, facingLeft: direction, walkDistance: 33))!, label: "walking direction \(direction)")
        }
        check(!view.containsCat(CGPoint(x: 1, y: 1)), "custom accessories keep transparent desktop area clickable-through")
        check(view.containsCat(CGPoint(x: 104, y: 69)), "customized head remains draggable")
        try png(sheet(poseImages, labels: poses.map(\.description), columns: 5, cell: NSSize(width: 240, height: 235)),
            to: output.appendingPathComponent("features-poses.png"))
        let fresh = DesktopPetView(resources: resources, appearance: appearance)
        view.setAppearance(.original); view.setAppearance(appearance)
        check(view.renderPNG(pose: .carried, phase: 0.8) == fresh.renderPNG(pose: .carried, phase: 0.8), "feature hot switching leaves no stale pickup cache")
        view.setAppearance(.original)
        check(view.renderPNG(pose: .sitting) == DesktopPetView(resources: resources).renderPNG(pose: .sitting), "removing all features restores exact original art")
        let config = CatConfiguration.defaults.replacingAppearance(appearance)
        let overlay = CatOverlay(configuration: config, bundledImageURL: hudURL)
        defer { overlay.dispose() }
        let greeting = try overlay.testPNG(greeting: true, frame: 2)
        try greeting.write(to: output.appendingPathComponent("features-greeting.png"))
        let recording = NekoRecordingView(image: painter.image(NSImage(contentsOf: hudURL)!, layout: .hud))
        recording.update(state: .recording)
        var cancelled = 0, finished = 0
        recording.onCancel = { cancelled += 1 }; recording.onFinish = { finished += 1 }
        recording.cancelButton.performClick(nil); recording.finishButton.performClick(nil)
        overlay.onCancel = { cancelled += 1 }; overlay.onFinish = { finished += 1 }
        overlay.showRecording(); overlay.testClickCancel(); overlay.testClickFinish(); overlay.hide()
        check(cancelled == 2 && finished == 2, "heterochromia keeps both recording and greeting eye button actions")
        check(overlay.testCanReplaceMouth, "custom nose preserves greeting mouth animation")
        let recordingImage = render(recording)
        openEyes(recordingImage, label: "recording HUD")
        openEyes(NSImage(data: greeting)!, label: "greeting")
        try png(recordingImage, to: output.appendingPathComponent("features-recording.png"))
        var variants: [NSImage] = [], labels: [String] = []
        for position in CatBowPosition.allCases {
            for shape in [CatNoseShape.triangle, .round, .heart] {
                var features = appearance.features
                features.bow.position = position; features.nose.shape = shape
                let variant = appearance.replacingFeatures(features)
                let variantView = DesktopPetView(resources: resources, appearance: variant)
                variants.append(NSImage(data: variantView.renderPNG(pose: .sitting))!)
                labels.append(position.rawValue + " / " + shape.rawValue)
            }
        }
        try png(sheet(variants, labels: labels, columns: 3, cell: NSSize(width: 280, height: 250)),
            to: output.appendingPathComponent("features-options.png"))
    }

}
