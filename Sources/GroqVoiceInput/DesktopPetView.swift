import AppKit

/// The approved Figma C mascot, composed locally into new resting expressions.
/// The SVG files remain unchanged; no temporary Figma URLs are used at runtime.
final class DesktopPetView: NSView {
    private var images: [String: NSImage]
    private let resources: URL?
    private let pickupFrames: [URL]
    private let pickupMaps: [CatAnatomy.PickupMap]?
    private var coatArtwork: CatAppearanceArtwork
    private let pickupCache = NSCache<NSNumber, NSImage>()
    static let pickupSampleCount = 36

    private func pickupImage(at index: Int) -> NSImage? {
        let key = NSNumber(value: index)
        if let cached = pickupCache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: pickupFrames[index]),
              let bitmap = NSBitmapImageRep(data: data) else { return nil }
        let original = NSImage(size: Self.panelSize)
        original.addRepresentation(bitmap)
        let image: NSImage
        if !coatArtwork.appearance.isOriginal, let maps = pickupMaps {
            guard let colored = coatArtwork.image(original, layout: .pickup(maps[index])) else { return nil }
            image = colored
        } else { image = original }
        pickupCache.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return image
    }
    // Padding expands only the visual panel. Model/grip coordinates retain the
    // original 128pt nominal frame, and sitting feet keep their world position.
    static let panelSize = CGSize(width: 208, height: 192)
    static let panelOffset = CGPoint(x: -40, y: -64)
    var pose: DesktopPetPose = .sitting
    var phase: Double = 0
    var walkDistance: CGFloat = 0
    var facingLeft = false
    var reduceMotion = false
    var carryLean: CGFloat = 0
    var isSettling = false
    var lift = DesktopPetLift()
    var onPointerDown: ((CGPoint) -> Void)?
    var onPointerDragged: ((CGPoint) -> Void)?
    var onPointerUp: (() -> Void)?
    var onAccessibilityPress: (() -> Void)?
    private var hitBitmap: NSBitmapImageRep?
    private var hitPose: DesktopPetPose?
    private var hitFacing = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("DesktopPet"), appearance: CatAppearance = .original) {
        self.resources = resources
        let painter = CatAppearanceArtwork(appearance)
        coatArtwork = painter
        pickupMaps = CatAnatomy.pickupMaps(at: resources?.appendingPathComponent("Pickup/anatomy.json"))
        images = Self.loadImages(resources: resources, painter: painter)
        pickupFrames = (0..<Self.pickupSampleCount).compactMap { index in
            guard let url = resources?.appendingPathComponent("Pickup/" + String(format: "%02d.png", index)) else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        super.init(frame: CGRect(origin: .zero, size: Self.panelSize))
        pickupCache.countLimit = 16
        pickupCache.totalCostLimit = 12 * 1024 * 1024
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(appearance.title + "桌面夥伴")
        setAccessibilityHelp("點一下逗逗牠，或按住拖曳，把牠拎起放下。")
    }

    private static func loadImages(resources: URL?, painter: CatAppearanceArtwork) -> [String: NSImage] {
        let names = ["sit", "walk", "reply", "body", "tail", "walk-body", "walk-paws", "walk-front-face", "walk-foot-0", "walk-foot-1", "walk-foot-2", "walk-foot-3", "groom-body", "groom-head"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            guard let url = resources?.appendingPathComponent(name + ".svg"),
                  let image = painter.desktopImage(at: url, asset: name) else { return nil }
            image.cacheMode = .never
            return (name, image)
        })
    }

    required init?(coder: NSCoder) { nil }

    /// Replace only artwork so switching coats keeps the same pose, grip and
    /// desktop coordinates. A prior coat must never survive in a frame cache.
    func setAppearance(_ appearance: CatAppearance) {
        precondition(Thread.isMainThread)
        guard appearance != coatArtwork.appearance else { return }
        let painter = CatAppearanceArtwork(appearance)
        images = Self.loadImages(resources: resources, painter: painter)
        coatArtwork = painter
        pickupCache.removeAllObjects()
        hitBitmap = nil
        setAccessibilityLabel(appearance.title + "桌面夥伴")
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
    }
    override func mouseDragged(with event: NSEvent) {
        onPointerDragged?(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
    }
    override func mouseUp(with event: NSEvent) { onPointerUp?() }
    override func accessibilityPerformPress() -> Bool {
        guard let action = onAccessibilityPress else { return false }
        action()
        return true
    }

    /// Cache a native alpha mask per pose, rather than putting a rectangular
    /// click target over the desktop. Motion only changes this silhouette a few
    /// pixels; a 2pt tolerance keeps the boundary usable without a broad hotspot.
    func containsCat(_ point: CGPoint) -> Bool {
        guard bounds.contains(point), point.y >= 29 else { return false }
        if hitBitmap == nil || hitPose != pose || hitFacing != facingLeft {
            let image = NSImage(size: bounds.size, flipped: true) { _ in self.draw(self.bounds); return true }
            hitBitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            hitPose = pose
            hitFacing = facingLeft
        }
        guard let bitmap = hitBitmap else { return false }
        for dy in -2...2 {
            for dx in -2...2 {
                let x = Int((point.x + CGFloat(dx)) / bounds.width * CGFloat(bitmap.pixelsWide))
                let y = Int((point.y + CGFloat(dy)) / bounds.height * CGFloat(bitmap.pixelsHigh))
                if x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                   (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { return true }
            }
        }
        return false
    }

    func update(_ model: DesktopPetModel, reduceMotion: Bool) {
        if pose != model.pose || phase != model.phase || facingLeft != model.facingLeft ||
           walkDistance != model.walkDistance || self.reduceMotion != reduceMotion ||
           carryLean != model.carryLean || isSettling != model.isSettling || lift != model.lift {
            hitBitmap = nil
        }
        if pose != model.pose { setAccessibilityValue(model.pose.description) }
        pose = model.pose
        phase = model.phase
        walkDistance = model.walkDistance
        facingLeft = model.facingLeft
        self.reduceMotion = reduceMotion
        carryLean = model.carryLean
        isSettling = model.isSettling
        lift = model.lift
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if pose == .petted {
            NSGraphicsContext.saveGraphicsState()
            let bubble = NSAffineTransform(); bubble.translateX(by: 40, yBy: 0); bubble.concat()
            drawResponseBubble()
            NSGraphicsContext.restoreGraphicsState()
        }
        if [.sitting, .carried].contains(pose), pickupFrames.count == Self.pickupSampleCount,
           coatArtwork.appearance.isOriginal || pickupMaps != nil {
            drawPickupFrame()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        // The original 400-point artwork's feet (y=367) sit 2pt above the
        // panel's bottom. This is also the model's folder-perch contact point.
        transform.translateX(by: 48, yBy: 128 - 2 - 367 * 0.28)
        transform.scale(by: 0.28)
        transform.concat()
        switch pose {
        case .sitting, .curious:
            breathe { drawImage(pose == .curious ? "reply" : "sit") }
        case .standing: drawImage("walk")
        case .walking: drawWalking()
        case .grooming: drawGrooming()
        case .petted:
            breathe { drawImage("reply"); closeEyes(inHeadAt: .zero, scale: 1) }
        case .carried: drawImage("sit")
        case .yawning: drawYawning()
        case .loafing, .sleeping: drawLoaf(sleeping: pose == .sleeping)
        }
        if pose == .curious { drawQuestion() }
        if pose == .sleeping { drawSleepMarks() }
    }

    private var fur: NSColor { coatArtwork.color(.body) }
    private var ink: NSColor {
        coatArtwork.appearance.hasOriginalCoat ? NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1) : coatArtwork.ink()
    }

    private func drawPickupFrame() {
        // No sway, morph, blended image, or per-frame scale: show the sliced
        // Gemini drawing at its fixed grip anchor, including both idle ends.
        let index = max(0, min(Self.pickupSampleCount - 1, DesktopPetLift.imageIndex(for: lift.spriteFrame)))
        pickupImage(at: index)?.draw(in: CGRect(origin: .zero, size: Self.panelSize), from: .zero,
                                 operation: .sourceOver, fraction: 1, respectFlipped: true,
                                 hints: [.interpolation: NSImageInterpolation.high])
    }

    private func drawResponseBubble() {
        let fur = NSColor(srgbRed: 16 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        let ink = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
        let bubble = NSBezierPath(roundedRect: CGRect(x: 66, y: 1, width: 59, height: 24), xRadius: 9, yRadius: 9)
        ink.setFill(); bubble.fill()
        fur.setStroke(); bubble.lineWidth = 1.1; bubble.stroke()
        ("呼嚕～" as NSString).draw(at: CGPoint(x: 76, y: 5), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: fur
        ])
    }

    private func drawGrooming() {
        let palm = DesktopPetGroomingPalm.sample(time: phase, reduceMotion: reduceMotion)
        drawImage("groom-body")
        // The unoutlined foreleg is occluded by the original head/torso. Keep
        // the visible drawing focused on the paw, as requested by the owner.
        let hiddenWrist = NSBezierPath()
        hiddenWrist.move(to: CGPoint(x: 149, y: 248))
        hiddenWrist.line(to: CGPoint(x: palm.center.x, y: palm.center.y + 15 * palm.activity))
        coatArtwork.color(.frontLeftLeg).setStroke()
        hiddenWrist.lineWidth = 29; hiddenWrist.lineCapStyle = .round; hiddenWrist.stroke()

        NSGraphicsContext.saveGraphicsState()
        let head = NSAffineTransform()
        head.translateX(by: 200, yBy: 214 + palm.headDrop)
        head.rotate(byDegrees: palm.headTilt)
        head.translateX(by: -200, yBy: -214)
        head.concat()
        drawImage("groom-head")
        closeEyes(inHeadAt: .zero, scale: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: palm.center.x, yBy: palm.center.y)
        turn.rotate(byDegrees: palm.angle)
        turn.concat()
        // Three soft toe lobes and a broad heel read as a cat's rounded paw.
        // The lower wrist is open into the black body, not an outlined ring.
        let paw = NSBezierPath()
        paw.move(to: CGPoint(x: -13, y: 20))
        paw.curve(to: CGPoint(x: -23, y: -3), controlPoint1: CGPoint(x: -23, y: 14), controlPoint2: CGPoint(x: -25, y: 7))
        paw.curve(to: CGPoint(x: -13, y: -18), controlPoint1: CGPoint(x: -25, y: -17), controlPoint2: CGPoint(x: -21, y: -23))
        paw.curve(to: CGPoint(x: 2, y: -23), controlPoint1: CGPoint(x: -12, y: -30), controlPoint2: CGPoint(x: 0, y: -30))
        paw.curve(to: CGPoint(x: 16, y: -18), controlPoint1: CGPoint(x: 7, y: -28), controlPoint2: CGPoint(x: 17, y: -27))
        paw.curve(to: CGPoint(x: 22, y: 2), controlPoint1: CGPoint(x: 25, y: -19), controlPoint2: CGPoint(x: 28, y: -7))
        paw.curve(to: CGPoint(x: 13, y: 20), controlPoint1: CGPoint(x: 22, y: 13), controlPoint2: CGPoint(x: 19, y: 18))
        let rim = paw.copy() as! NSBezierPath
        paw.close()
        let pawFur = coatArtwork.appearance.hasOriginalCoat ? fur : coatArtwork.color(.frontLeftPaw)
        let shade = coatArtwork.appearance.hasOriginalCoat
            ? (fur.blended(withFraction: palm.activity, of: NSColor(srgbRed: 38/255, green: 40/255, blue: 45/255, alpha: 1)) ?? fur)
            : pawFur
        shade.setFill(); paw.fill()
        if !coatArtwork.appearance.hasOriginalCoat {
            coatArtwork.fill(paw, layout: .part(.frontLeftPaw), in: CGRect(x: -28, y: -30, width: 56, height: 60), cacheKey: "groom-paw")
        }
        NSColor(calibratedWhite: 0.48, alpha: palm.activity).setStroke()
        rim.lineWidth = 3.5; rim.lineCapStyle = .round; rim.stroke()
        // A short dark wrist merges into the surrounding fur, without drawing
        // a complete arm or leaving a closed circular badge on the face.
        let wrist = NSBezierPath(roundedRect: CGRect(x: -12, y: 13, width: 24, height: 19 * palm.activity), xRadius: 8, yRadius: 8)
        shade.setFill(); wrist.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A broad, rounded tongue tip peeks out only nine artwork units.
        // Retract vertically so it keeps its soft shape instead of tapering
        // into the previous long diagonal point.
        if palm.lick > 0.01 {
            NSGraphicsContext.saveGraphicsState()
            head.concat()
            let tongue = NSBezierPath()
            tongue.move(to: CGPoint(x: 193, y: 197))
            tongue.curve(to: CGPoint(x: 194, y: 197 + 6 * palm.lick),
                         controlPoint1: CGPoint(x: 193, y: 197 + 3 * palm.lick),
                         controlPoint2: CGPoint(x: 193, y: 197 + 5 * palm.lick))
            tongue.curve(to: CGPoint(x: 206, y: 197 + 6 * palm.lick),
                         controlPoint1: CGPoint(x: 196, y: 197 + 10 * palm.lick),
                         controlPoint2: CGPoint(x: 204, y: 197 + 10 * palm.lick))
            tongue.curve(to: CGPoint(x: 207, y: 197),
                         controlPoint1: CGPoint(x: 207, y: 197 + 5 * palm.lick),
                         controlPoint2: CGPoint(x: 207, y: 197 + 3 * palm.lick))
            tongue.close()
            NSColor(srgbRed: 0.85, green: 0.49, blue: 0.53, alpha: 1).setFill()
            tongue.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawImage(_ name: String, in rect: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400)) {
        images[name]?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if ["sit", "reply", "walk", "walk-front-face", "groom-head"].contains(name) {
            let headX: CGFloat = name.hasPrefix("walk") ? 25 : 45
            let head = CGRect(x: rect.minX + headX / 400 * rect.width, y: rect.minY + 18 / 400 * rect.height,
                width: 312 / 400 * rect.width, height: 208 / 400 * rect.height)
            coatArtwork.drawAccessories(headIn: head)
        }
    }

    private func breathe(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let breath = reduceMotion ? 0 : sin(phase * .pi / 2.8) * 0.006
        let transform = NSAffineTransform()
        transform.translateX(by: 200, yBy: 367)
        transform.scaleX(by: 1 + breath * 0.35, yBy: 1 + breath)
        transform.translateX(by: -200, yBy: -367)
        transform.concat()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWalking() {
        let stride = reduceMotion ? 0 : sin(walkDistance / Self.strideDistance * 2 * .pi)
        NSGraphicsContext.saveGraphicsState()
        // Only the silhouette turns. Mirroring the complete mascot swaps X/✓
        // and reverses the check itself, including after a leftward walk.
        if !facingLeft {
            let turn = NSAffineTransform()
            turn.translateX(by: 400, yBy: 0)
            turn.scaleX(by: -1, yBy: 1)
            turn.concat()
        }
        let bob = reduceMotion ? 0 : -abs(stride) * 3
        let distance = reduceMotion ? 0 : walkDistance
        // Preserve the original paw contours. Broad roots begin well inside
        // the torso and overlap the paw's upper half, avoiding a narrow stalk
        // with an exposed oval end when a foot reaches beyond the body.
        let paws: [(root: CGPoint, neck: CGPoint, rootWidth: CGFloat, neckWidth: CGFloat, pair: Int)] = [
            (CGPoint(x: 112, y: 244), CGPoint(x: 103, y: 303), 58, 50, 0),
            (CGPoint(x: 159, y: 270), CGPoint(x: 161, y: 322), 54, 48, 1),
            (CGPoint(x: 270, y: 270), CGPoint(x: 271, y: 322), 56, 48, 0),
            (CGPoint(x: 309, y: 247), CGPoint(x: 321, y: 313), 54, 44, 1)
        ]
        for (index, paw) in paws.enumerated() {
            let step = Self.pawOffset(distance: distance, pair: paw.pair)
            let root = CGPoint(x: paw.root.x, y: paw.root.y + bob)
            let neck = CGPoint(x: paw.neck.x + step.x, y: paw.neck.y + step.y)
            let rootHalf = paw.rootWidth / 2, neckHalf = paw.neckWidth / 2
            let height = max(10, neck.y - root.y)
            let join = NSBezierPath()
            join.move(to: CGPoint(x: root.x - rootHalf, y: root.y))
            join.curve(to: CGPoint(x: neck.x - neckHalf, y: neck.y),
                       controlPoint1: CGPoint(x: root.x - rootHalf, y: root.y + height * 0.4),
                       controlPoint2: CGPoint(x: neck.x - neckHalf, y: neck.y - height * 0.3))
            join.line(to: CGPoint(x: neck.x + neckHalf, y: neck.y))
            join.curve(to: CGPoint(x: root.x + rootHalf, y: root.y),
                       controlPoint1: CGPoint(x: neck.x + neckHalf, y: neck.y - height * 0.3),
                       controlPoint2: CGPoint(x: root.x + rootHalf, y: root.y + height * 0.4))
            join.close()
            if coatArtwork.appearance.hasOriginalCoat { fur.setFill(); join.fill() }
            else {
                coatArtwork.fill(join, layout: .desktop("walk-foot-\(index)"),
                    in: CGRect(x: 0, y: 0, width: 400, height: 400),
                    cacheKey: "leg-\(index)")
            }
            NSGraphicsContext.saveGraphicsState()
            let motion = NSAffineTransform()
            motion.translateX(by: step.x, yBy: step.y)
            motion.concat()
            drawImage("walk-foot-\(index)")
            NSGraphicsContext.restoreGraphicsState()
        }
        let lift = NSAffineTransform()
        lift.translateX(by: 0, yBy: bob)
        lift.concat()
        drawImage("walk-body")
        NSGraphicsContext.restoreGraphicsState()

        // Keep the approved front-facing head, eyes and mouth together.
        // Only the body turns; the face keeps its original proportions.
        NSGraphicsContext.saveGraphicsState()
        let faceLift = NSAffineTransform()
        faceLift.translateX(by: 0, yBy: bob)
        faceLift.concat()
        drawWalkingFace()
        NSGraphicsContext.restoreGraphicsState()
    }

    // One cycle covers 40pt of actual screen travel. During 60% of the
    // cycle each planted paw moves back relative to the body by exactly the
    // distance the body moves forward, so the paw stays fixed on the desktop.
    // The remaining 40% lifts it in an arc and brings it forward for landing.
    static let strideDistance: CGFloat = 86 * 0.28 / 0.6

    static func pawOffset(distance: CGFloat, pair: Int) -> CGPoint {
        let distance = max(0, distance)
        // Start at the neutral stance instead of jumping an entire half-step.
        // The initial airborne pair rises from the floor over real travel.
        let cycle = (distance / strideDistance + 0.3 + CGFloat(pair) * 0.5)
            .truncatingRemainder(dividingBy: 1)
        if cycle < 0.6 {
            return CGPoint(x: -43 + 86 * cycle / 0.6, y: 0)
        }
        let swing = (cycle - 0.6) / 0.4
        let eased = swing * swing * (3 - 2 * swing)
        let startup = min(1, distance / (strideDistance * 0.08))
        let lift = startup * startup * (3 - 2 * startup)
        return CGPoint(x: 43 - 86 * eased, y: -sin(swing * .pi) * 28 * lift)
    }

    private func drawWalkingFace() {
        // A small shoulder offset follows travel without stretching the head
        // or mirroring the X-left / check-right face.
        drawImage("walk-front-face", in: CGRect(x: facingLeft ? 0 : 40, y: 0, width: 400, height: 400))
    }

    private func drawYawning() {
        drawImage("sit")
        let opening = reduceMotion ? 0.8 : sin(min(1, phase / 3.2) * .pi)
        fillFacePatch(NSBezierPath(ovalIn: CGRect(x: 174, y: 168, width: 57, height: 43)))
        ink.setStroke()
        let mouth = NSBezierPath(ovalIn: CGRect(x: 187, y: 181 - opening * 3,
                                               width: 25, height: 8 + opening * 30))
        mouth.lineWidth = 6
        mouth.stroke()
        coatArtwork.drawNose(headIn: CGRect(x: 45, y: 18, width: 312, height: 208))
        if opening > 0.4 {
            closeEyes(inHeadAt: CGPoint.zero, scale: 1)
        }
    }

    private func drawLoaf(sleeping: Bool) {
        breathe {
            drawImage("tail", in: CGRect(x: 272, y: 283, width: 102.33, height: 79))
            drawImage("body", in: CGRect(x: 62, y: 272, width: 280, height: 94))
            // Head remains round and uncompressed while the body tucks down.
            // Its source rectangle is the head of the approved sitting asset.
            images["sit"]?.draw(in: CGRect(x: 16, y: 118, width: 360, height: 203.4),
                                 from: CGRect(x: 0, y: 174, width: 400, height: 226),
                                 operation: .sourceOver, fraction: 1, respectFlipped: true,
                                 hints: [.interpolation: NSImageInterpolation.high])
            // Neck attachments are drawn after the cropped head, so a bow is
            // never cut off by the head-only source rectangle while loafing.
            coatArtwork.drawAccessories(headIn: CGRect(x: 16 + 45 * 0.9, y: 118 + 18 * 0.9,
                width: 312 * 0.9, height: 208 * 0.9))
            if sleeping { closeEyes(inHeadAt: CGPoint(x: 16, y: 118), scale: 0.9) }
        }
    }

    private func closeEyes(inHeadAt origin: CGPoint, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.scale(by: scale)
        transform.concat()
        fillFacePatch(NSBezierPath(ovalIn: CGRect(x: 85, y: 130, width: 62, height: 59)))
        fillFacePatch(NSBezierPath(ovalIn: CGRect(x: 247, y: 129, width: 77, height: 57)))
        ink.setStroke()
        for x: CGFloat in [99, 267] {
            if !coatArtwork.appearance.hasOriginalCoat { coatArtwork.ink(.head, u: Double(x + 16 - 45) / 312, v: 0.68).setStroke() }
            let eyelid = NSBezierPath()
            eyelid.move(to: CGPoint(x: x, y: 159))
            eyelid.curve(to: CGPoint(x: x + 32, y: 159), controlPoint1: CGPoint(x: x + 9, y: 170),
                         controlPoint2: CGPoint(x: x + 23, y: 170))
            eyelid.lineWidth = 6
            eyelid.lineCapStyle = .round
            eyelid.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func fillFacePatch(_ path: NSBezierPath) {
        if coatArtwork.appearance.hasOriginalCoat { fur.setFill(); path.fill() }
        else { coatArtwork.fill(path, layout: .desktop("sit"), in: CGRect(x: 0, y: 0, width: 400, height: 400), cacheKey: "face") }
    }

    private func drawQuestion() {
        let fur = NSColor(srgbRed: 16 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        let ink = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
        let bob = reduceMotion ? 0 : sin(phase * 2) * 2
        let bubble = CGRect(x: 308, y: -44 + bob, width: 64, height: 65)
        fur.setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 22, yRadius: 22).fill()
        ink.setStroke()
        let question = NSBezierPath()
        question.move(to: CGPoint(x: 329, y: -23 + bob))
        question.curve(to: CGPoint(x: 343, y: -9 + bob), controlPoint1: CGPoint(x: 330, y: -39 + bob),
                       controlPoint2: CGPoint(x: 365, y: -28 + bob))
        question.line(to: CGPoint(x: 340, y: -3 + bob))
        question.lineWidth = 6
        question.lineCapStyle = .round
        question.stroke()
        ink.setFill()
        NSBezierPath(ovalIn: CGRect(x: 336, y: 5 + bob, width: 7, height: 7)).fill()
    }

    private func drawSleepMarks() {
        let fur = NSColor(srgbRed: 16 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        let ink = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1)
        for i in 0..<3 {
            let opacity: CGFloat = reduceMotion ? 0.8 : 0.5 + 0.35 * CGFloat(sin(phase * 0.8 + Double(i)))
            let x = CGFloat(310 + i * 19), y = CGFloat(104 - i * 25)
            let z = NSBezierPath()
            z.move(to: CGPoint(x: x, y: y))
            z.line(to: CGPoint(x: x + 13, y: y))
            z.line(to: CGPoint(x: x, y: y + 14))
            z.line(to: CGPoint(x: x + 13, y: y + 14))
            z.lineCapStyle = .round
            z.lineJoinStyle = .round
            fur.withAlphaComponent(opacity).setStroke()
            z.lineWidth = 9
            z.stroke()
            ink.withAlphaComponent(opacity).setStroke()
            z.lineWidth = 4
            z.stroke()
        }
    }

    #if DESKTOP_PET_TESTS
    func renderPNG(pose: DesktopPetPose, phase: Double = 0, facingLeft: Bool = false, walkDistance: CGFloat = 0,
                   carryLean: CGFloat = 0, isSettling: Bool = false, lift: DesktopPetLift? = nil) -> Data {
        self.pose = pose
        self.phase = phase
        self.facingLeft = facingLeft
        self.walkDistance = walkDistance
        self.carryLean = carryLean
        self.isSettling = isSettling
        self.lift = lift ?? (pose == .carried
            ? .lifting(elapsed: reduceMotion ? 1 : phase, lean: reduceMotion ? 0 : carryLean)
            : DesktopPetLift())
        let image = NSImage(size: bounds.size, flipped: true) { _ in self.draw(self.bounds); return true }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }
    var loadedAssets: Set<String> { Set(images.keys) }
    var loadedPickupFrames: Int { pickupFrames.count }
    #endif
}
