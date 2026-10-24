import AppKit

/// A silent, nonactivating companion. The application owns recording; these two
/// actions only ask it to cancel or finish, and never open a microphone here.
final class CatOverlay {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onGreetingFinished: (() -> Void)?

    private var configuration: CatConfiguration
    private let panel: CatOverlayPanel
    private let artwork: CatArtworkView
    private var mouthTimer: Timer?
    private var expiryTimer: Timer?
    private var motionObserver: NSObjectProtocol?
    private var greetingStarted: TimeInterval = 0
    private var catTopLeft: NSPoint?
    private var disposed = false
    var isVisible: Bool { panel.isVisible }

    init(configuration: CatConfiguration, bundledImageURL: URL? = nil) {
        precondition(Thread.isMainThread)
        self.configuration = configuration
        let assetURL = bundledImageURL ?? Bundle.main.url(forResource: "neko-base", withExtension: "png")
        artwork = CatArtworkView(configuration: configuration, bundledImageURL: assetURL)
        panel = CatOverlayPanel(contentRect: NSRect(origin: .zero, size: artwork.canvasSize),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isMovable = false
        panel.contentView = artwork
        panel.title = "小黑貓語音輸入"
        artwork.cancel.actionHandler = { [weak self] in self?.onCancel?() }
        artwork.finish.actionHandler = { [weak self] in self?.onFinish?() }
        panel.didOrderOut = { [weak self] in self?.stopTimers() }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            self.stopMouthAnimation()
        }
    }

    func setAppearance(_ appearance: CatAppearance) {
        precondition(Thread.isMainThread)
        guard !disposed else { return }
        configuration = configuration.replacingAppearance(appearance)
        artwork.setAppearance(appearance)
    }

    func showRecording() {
        precondition(Thread.isMainThread)
        guard !disposed else { return }
        stopTimers()
        artwork.catAppearance = .recording
        positionAndShow()
    }

    func showGreeting() {
        precondition(Thread.isMainThread)
        guard !disposed else { return }
        stopTimers()
        artwork.catAppearance = .greeting
        artwork.animatesGreeting = artwork.canReplaceMouth && configuration.animateMouth &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        greetingStarted = ProcessInfo.processInfo.systemUptime
        positionAndShow()
        let expiry = Timer(timeInterval: configuration.displaySeconds, repeats: false) { [weak self] _ in
            guard let self = self, !self.disposed, self.artwork.catAppearance == .greeting else { return }
            self.hide()
            self.onGreetingFinished?()
        }
        expiryTimer = expiry
        RunLoop.main.add(expiry, forMode: .common)
        if artwork.animatesGreeting {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - self.greetingStarted
                guard !self.disposed, self.panel.isVisible, self.artwork.catAppearance == .greeting,
                      elapsed < self.configuration.displaySeconds else {
                    self.stopMouthAnimation()
                    return
                }
                self.artwork.mouthFrame = Int(elapsed / 0.1)
            }
            mouthTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func hide() {
        precondition(Thread.isMainThread)
        stopTimers()
        panel.orderOut(nil)
        catTopLeft = nil
    }

    func dispose() {
        precondition(Thread.isMainThread)
        guard !disposed else { return }
        disposed = true
        hide()
        if let observer = motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        motionObserver = nil
        onCancel = nil
        onFinish = nil
        onGreetingFinished = nil
        panel.didOrderOut = nil
        panel.close()
    }

    deinit {
        mouthTimer?.invalidate()
        expiryTimer?.invalidate()
        if let observer = motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        panel.orderOut(nil)
    }

    private func stopMouthAnimation() {
        mouthTimer?.invalidate()
        mouthTimer = nil
        artwork.animatesGreeting = false
        artwork.mouthFrame = 0
    }

    private func stopTimers() {
        stopMouthAnimation()
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    private func positionAndShow() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        if catTopLeft == nil {
            // Reserve the same cat position in both modes; the bubble expands
            // above/right (or above/left), leaving both eye targets stationary.
            catTopLeft = NSPoint(x: area.midX - 170, y: area.minY + 240)
        }
        let anchor = catTopLeft!
        let cat = artwork.catBounds
        let size = artwork.canvasSize
        var frame = NSRect(x: anchor.x - cat.minX, y: anchor.y - size.height + cat.minY,
                           width: size.width, height: size.height)
        frame.origin.x = max(area.minX, min(frame.minX, area.maxX - frame.width))
        frame.origin.y = max(area.minY, min(frame.minY, area.maxY - frame.height))
        panel.setFrame(frame, display: false)
        artwork.frame = NSRect(origin: .zero, size: size)
        artwork.layoutTargets()
        catTopLeft = NSPoint(x: frame.minX + cat.minX, y: frame.maxY - cat.minY)
        panel.orderFrontRegardless()
        artwork.needsDisplay = true
    }
}

private final class CatOverlayPanel: NSPanel {
    var didOrderOut: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        didOrderOut?()
    }
}

private enum CatOverlayMode { case recording, greeting }

private final class CatArtworkView: NSView {
    let cancel = CatEyeButton()
    let finish = CatEyeButton()
    private var configuration: CatConfiguration
    private let bundledImage: NSBitmapImageRep?
    private var originalImage: NSImage?
    private var mouthlessImage: NSImage?
    var canReplaceMouth: Bool { mouthlessImage != nil }
    var catAppearance: CatOverlayMode = .recording {
        didSet { layoutTargets(); needsDisplay = true }
    }
    var animatesGreeting = false { didSet { needsDisplay = true } }
    var mouthFrame = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    var canvasSize: NSSize {
        catAppearance == .greeting ? NSSize(width: 440, height: 260) : NSSize(width: 340, height: 220)
    }
    var catBounds: NSRect {
        NSRect(x: catAppearance == .greeting && configuration.bubblePosition == "upperLeft" ? 100 : 0,
               y: catAppearance == .greeting ? 80 : 0, width: 340, height: 340 * 0.4978)
    }

    init(configuration: CatConfiguration, bundledImageURL: URL?) {
        self.configuration = configuration
        bundledImage = CatPNG.read(bundledImageURL)
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 220))
        updateImages()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("小黑貓語音輸入")
        cancel.toolTip = "取消這次錄音"
        cancel.setAccessibilityLabel("取消這次錄音")
        finish.toolTip = "完成錄音"
        finish.setAccessibilityLabel("完成錄音")
        addSubview(cancel)
        addSubview(finish)
        layoutTargets()
    }

    required init?(coder: NSCoder) { nil }

    func setAppearance(_ appearance: CatAppearance) {
        guard configuration.appearance != appearance else { return }
        configuration = configuration.replacingAppearance(appearance)
        updateImages()
        needsDisplay = true
    }

    private func updateImages() {
        let bundled = bundledImage
        let selected = configuration.imageData.flatMap(CatPNG.decode)
        let image = selected ?? bundled
        if configuration.image == nil && !configuration.appearance.isOriginal, let bundled {
            let painter = CatAppearanceArtwork(configuration.appearance)
            let source = CatPNG.image(bundled)
            originalImage = painter.image(source, layout: .hud)
            mouthlessImage = painter.image(source, layout: .hud, removeMouth: true)
        } else {
            originalImage = image.map(CatPNG.image)
            // An explicit custom selection is never repainted, even when that
            // file fails to load and the bundled fallback is displayed instead.
            mouthlessImage = configuration.image == nil ? bundled.flatMap(CatPNG.withoutNeutralMouth) : nil
        }
    }

    func layoutTargets() {
        let cat = catBounds
        cancel.frame = NSRect(x: cat.minX + cat.width * 0.14, y: cat.minY + cat.height * 0.53,
                              width: cat.width * 0.18, height: cat.height * 0.29)
        finish.frame = NSRect(x: cat.minX + cat.width * 0.67, y: cat.minY + cat.height * 0.53,
                              width: cat.width * 0.19, height: cat.height * 0.29)
        cancel.isEnabled = catAppearance == .recording
        finish.isEnabled = catAppearance == .recording
        setAccessibilityLabel(catAppearance == .greeting ? "小黑貓說：\(configuration.reply)" : "小黑貓語音輸入：正在錄音")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let image = mouthlessImage ?? originalImage
        image?.draw(in: catBounds, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if canReplaceMouth {
            drawMouth(frame: catAppearance == .greeting && animatesGreeting ? mouthFrame : 0)
        }
        if catAppearance == .greeting { drawBubble() } else { drawRecordingLabel() }
    }

    private func drawMouth(frame: Int) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: catBounds.midX, yBy: catBounds.minY + catBounds.height * 0.798)
        transform.concat()
        let openings: [CGFloat] = [0, 3, 7, 4, 0, 0, 5, 7, 2, 0, 4, 0]
        let opening = openings[max(0, frame) % openings.count]
        let ink = configuration.appearance.hasOriginalCoat
            ? NSColor(calibratedRed: 247 / 255, green: 247 / 255, blue: 249 / 255, alpha: 1)
            : CatAppearanceArtwork(configuration.appearance).ink(.muzzle, u: 0.5, v: 0.8)
        if opening > 0 {
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: -5, y: 1))
            mouth.curve(to: NSPoint(x: 5, y: 1), controlPoint1: NSPoint(x: -5, y: opening + 4),
                        controlPoint2: NSPoint(x: 5, y: opening + 4))
            mouth.close()
            NSColor(calibratedRed: 24 / 255, green: 23 / 255, blue: 29 / 255, alpha: 1).setFill()
            mouth.fill()
            NSGraphicsContext.saveGraphicsState()
            mouth.addClip()
            NSColor(calibratedRed: 233 / 255, green: 151 / 255, blue: 172 / 255, alpha: 1).setFill()
            // Keep a small visible tongue inside the lower opening. The cubic
            // reaches 0.75 * opening + 3.25, below its control points.
            NSBezierPath(ovalIn: NSRect(x: -3, y: opening * 0.75 + 0.25, width: 6, height: 4)).fill()
            NSGraphicsContext.restoreGraphicsState()
            ink.setStroke()
            mouth.lineWidth = 1.5
            mouth.stroke()
        }
        let muzzle = NSBezierPath()
        muzzle.move(to: NSPoint(x: -11, y: -2))
        muzzle.curve(to: NSPoint(x: 0, y: -1), controlPoint1: NSPoint(x: -10, y: 4),
                     controlPoint2: NSPoint(x: -3, y: 4))
        muzzle.curve(to: NSPoint(x: 11, y: -2), controlPoint1: NSPoint(x: 3, y: 4),
                     controlPoint2: NSPoint(x: 10, y: 4))
        muzzle.lineWidth = 2.6
        muzzle.lineCapStyle = .round
        muzzle.lineJoinStyle = .round
        ink.setStroke()
        muzzle.stroke()
    }

    private func greetingFont(size: CGFloat) -> NSFont {
        for name in [configuration.fontFamily, configuration.bold ? "ChalkboardSE-Bold" : "ChalkboardSE-Regular",
                     configuration.bold ? "ArialRoundedMTBold" : "ArialRoundedMT"] {
            if let font = NSFont(name: name, size: size) {
                return configuration.bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            }
        }
        let font = NSFont.systemFont(ofSize: size, weight: configuration.bold ? .bold : .regular)
        if #available(macOS 10.15, *), let rounded = font.fontDescriptor.withDesign(.rounded),
           let result = NSFont(descriptor: rounded, size: size) { return result }
        return font
    }

    private func drawBubble() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let left = configuration.bubblePosition == "upperLeft"
        let transform = NSAffineTransform()
        transform.translateX(by: left ? 120 : 320, yBy: 54)
        transform.rotate(byDegrees: CGFloat(configuration.tiltDegrees))
        transform.concat()
        NSColor(calibratedRed: 51 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: -90, y: -28, width: 180, height: 56), xRadius: 18, yRadius: 18).fill()
        let direction: CGFloat = left ? -1 : 1
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: -66 * direction, y: 25))
        tail.line(to: NSPoint(x: -72 * direction, y: 43))
        tail.line(to: NSPoint(x: -42 * direction, y: 25))
        tail.close()
        tail.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let text = configuration.reply as NSString
        var size = CGFloat(configuration.fontSize)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = NSRect.zero
        repeat {
            attributes = [.font: greetingFont(size: size), .paragraphStyle: paragraph,
                          .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1)]
            measured = text.boundingRect(with: NSSize(width: 160, height: 1_000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            if measured.height <= 46 || size <= 10 { break }
            size -= 1
        } while true
        let height = min(46, ceil(measured.height))
        text.draw(with: NSRect(x: -80, y: -height / 2, width: 160, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func drawRecordingLabel() {
        NSColor(calibratedRed: 30 / 255, green: 31 / 255, blue: 35 / 255, alpha: 0.97).setFill()
        let plate = NSRect(x: 18, y: catBounds.maxY + 2, width: 304, height: 45)
        NSBezierPath(roundedRect: plate, xRadius: 12, yRadius: 12).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        ("正在聽你說話…" as NSString).draw(in: NSRect(x: 30, y: plate.minY + 13, width: 280, height: 22),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                                                       .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    }
}

private final class CatEyeButton: NSButton {
    var actionHandler: (() -> Void)?
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        target = self
        action = #selector(performAction)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func performAction() { if isEnabled { actionHandler?() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering && isEnabled else { return }
        NSColor(calibratedRed: 160 / 255, green: 190 / 255, blue: 1, alpha: 0.9).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        ring.lineWidth = 2
        ring.stroke()
    }
}

private enum CatPNG {
    /// Validate and snapshot before AppKit decoding; do not hold a file handle.
    static func read(_ url: URL?) -> NSBitmapImageRep? {
        guard let url = url, url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (33...(4 * 1024 * 1024)).contains(size),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024 + 1) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> NSBitmapImageRep? {
        guard data.count >= 33, data.count <= 4 * 1024 * 1024,
              Array(data.prefix(16)) == [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82] else { return nil }
        func dimension(_ offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = dimension(16), height = dimension(20)
        guard (1...2048).contains(width), (1...2048).contains(height),
              let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide == width,
              bitmap.pixelsHigh == height else { return nil }
        return bitmap
    }

    static func image(_ bitmap: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
        return image
    }

    static func withoutNeutralMouth(_ source: NSBitmapImageRep) -> NSImage? {
        guard let cgImage = source.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let left = Int(Double(bitmap.pixelsWide) * 0.448), right = Int(Double(bitmap.pixelsWide) * 0.552)
        let top = Int(Double(bitmap.pixelsHigh) * 0.755), bottom = Int(Double(bitmap.pixelsHigh) * 0.84)
        guard bottom > top else { return nil }
        let channels = bitmap.samplesPerPixel
        var upper = [Int](repeating: 0, count: channels)
        var lower = upper
        var original = upper
        var replacement = upper
        for x in left...right {
            bitmap.getPixel(&upper, atX: x, y: top)
            bitmap.getPixel(&lower, atX: x, y: bottom)
            for y in (top + 1)..<bottom {
                bitmap.getPixel(&original, atX: x, y: y)
                let fraction = Double(y - top) / Double(bottom - top)
                let background = (0..<channels).map {
                    Double(upper[$0]) + Double(lower[$0] - upper[$0]) * fraction
                }
                // Preserve every existing body pixel; only the old white mouth
                // and its antialiased fringe need reconstruction.
                let lightExcess = (0..<min(3, channels)).map { Double(original[$0]) - background[$0] }.max() ?? 0
                if lightExcess <= 3 { continue }
                // Work in the bitmap's own component space (including alpha).
                // NSColor device-RGB conversion shifted dark sRGB pixels enough
                // to expose a rectangle. Feather the bounds as an extra guard.
                let edge = min(1, min(Double(min(x - left, right - x)) / 12,
                                      Double(min(y - top, bottom - y)) / 10))
                let blend = edge * edge * (3 - 2 * edge)
                for channel in 0..<channels {
                    replacement[channel] = Int((Double(original[channel]) * (1 - blend) + background[channel] * blend).rounded())
                }
                bitmap.setPixel(&replacement, atX: x, y: y)
            }
        }
        return image(bitmap)
    }
}

#if CAT_OVERLAY_TESTS
// Compiled only into the offline macOS UI fixture executable, never the app.
extension CatOverlay {
    var testPanel: NSPanel { panel }
    var testMouthTimerActive: Bool { mouthTimer?.isValid == true }
    var testExpiryTimerActive: Bool { expiryTimer?.isValid == true }
    var testCanReplaceMouth: Bool { artwork.canReplaceMouth }
    var testMouthFrame: Int { artwork.mouthFrame }
    var testCancelScreenRect: NSRect { panel.convertToScreen(artwork.convert(artwork.cancel.frame, to: nil)) }
    var testFinishScreenRect: NSRect { panel.convertToScreen(artwork.convert(artwork.finish.frame, to: nil)) }
    func testClickCancel() { artwork.cancel.performClick(nil) }
    func testClickFinish() { artwork.finish.performClick(nil) }

    func testPNG(greeting: Bool, frame: Int = 0) throws -> Data {
        // Exercise exactly the AppKit view drawing path used by the live panel.
        let oldAppearance = artwork.catAppearance
        let oldFrame = artwork.frame
        let oldAnimation = artwork.animatesGreeting
        let oldMouthFrame = artwork.mouthFrame
        defer {
            artwork.catAppearance = oldAppearance
            artwork.frame = oldFrame
            artwork.animatesGreeting = oldAnimation
            artwork.mouthFrame = oldMouthFrame
        }
        artwork.catAppearance = greeting ? .greeting : .recording
        artwork.frame = NSRect(origin: .zero, size: artwork.canvasSize)
        artwork.animatesGreeting = greeting && configuration.animateMouth && artwork.canReplaceMouth
        artwork.mouthFrame = frame
        let size = artwork.canvasSize
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                             pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NSError(domain: "CatOverlayFixture", code: 1)
        }
        bitmap.size = size
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        artwork.cacheDisplay(in: artwork.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CatOverlayFixture", code: 2)
        }
        return data
    }
}
#endif
