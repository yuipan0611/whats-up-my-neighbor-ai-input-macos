import AppKit

// MARK: - 錄音 HUD 視覺元件與浮動面板
// 實現緊湊、非侵入性的黑貓錄音抬頭顯示器（HUD）。
// 包含音量視覺波形棒（11 根具正弦包絡線之音波）、眼球點擊互動（左眼取消、右眼完成）
// 以及全螢幕 App 支援。

enum NekoAppearance {
    static let background = NSColor(calibratedRed: 0.973, green: 0.969, blue: 0.953, alpha: 1)
    static let ink = NSColor(calibratedWhite: 0.086, alpha: 1)
    static let mint = NSColor(calibratedRed: 0.592, green: 0.890, blue: 0.749, alpha: 1)
    static let coral = NSColor(calibratedRed: 0.957, green: 0.525, blue: 0.525, alpha: 1)
    static var catImage: NSImage? {
        Bundle.main.url(forResource: "neko-base", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}

// 錄音浮動面板：禁止成為 Key 或 Main 視窗，避免在錄音開始時偷走使用者的打字焦點。
/// The floating controls must not replace the user's typing target.
final class NekoFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// 眼睛點擊按鈕：以黑貓的左右眼作為取消與完成動作的熱區，具備滑鼠懸停（Hover）發光效果。
final class NekoEyeButton: NSButton {
    let accent: NSColor
    var hovered = false
    private var tracking: NSTrackingArea?

    init(accent: NSColor) {
        self.accent = accent
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled && (hovered || isHighlighted) else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 17, yRadius: 17)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.28)
        glow.shadowBlurRadius = 10
        glow.shadowOffset = .zero
        glow.set()
        accent.withAlphaComponent(isHighlighted ? 0.32 : 0.18).setFill()
        path.fill()
        accent.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// 錄音 HUD 專屬主檢視：
// 繪製黑貓圖像、狀態說明文字標籤，以及錄音中的動態波形棒（水平排列，具備正弦包絡線振幅加權）。
final class NekoRecordingView: NSView {
    let cancelButton = NekoEyeButton(accent: NekoAppearance.coral)
    let finishButton = NekoEyeButton(accent: NekoAppearance.mint)
    private let startButton = NSButton(title: "開始錄音", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let introductionLabel = NSTextField(labelWithString: "左眼取消，右眼完成。")
    private var catImage: NSImage?
    private var meter = NekoSignalMeter()
    private var currentState: DictationState = .idle
    private let catRect = NSRect(x: 2, y: 0, width: 180, height: 90)
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onStart: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(image: NSImage? = NekoAppearance.catImage) {
        catImage = image
        super.init(frame: NSRect(x: 0, y: 0, width: 184, height: 112))
        appearance = NSAppearance(named: .aqua)
        setAccessibilityElement(false)
        for label in [statusLabel, detailLabel, introductionLabel] {
            label.alignment = .center
            label.isSelectable = false
            addSubview(label)
        }
        statusLabel.frame = NSRect(x: 6, y: 88, width: 172, height: 20)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NekoAppearance.ink
        statusLabel.wantsLayer = true
        statusLabel.layer?.backgroundColor = NekoAppearance.background.withAlphaComponent(0.96).cgColor
        statusLabel.layer?.cornerRadius = 8
        statusLabel.layer?.masksToBounds = true
        detailLabel.isHidden = true
        detailLabel.frame = NSRect(x: 6, y: 110, width: 172, height: 32)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = NekoAppearance.ink
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.wantsLayer = true
        detailLabel.layer?.backgroundColor = NekoAppearance.background.withAlphaComponent(0.96).cgColor
        detailLabel.layer?.cornerRadius = 8
        detailLabel.layer?.masksToBounds = true
        introductionLabel.frame = NSRect(x: 6, y: 88, width: 172, height: 20)
        introductionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        introductionLabel.textColor = NekoAppearance.ink
        introductionLabel.wantsLayer = true
        introductionLabel.layer?.backgroundColor = NekoAppearance.background.withAlphaComponent(0.96).cgColor
        introductionLabel.layer?.cornerRadius = 8
        introductionLabel.layer?.masksToBounds = true
        introductionLabel.isHidden = true
        cancelButton.frame = NSRect(x: catRect.minX + 180 * 0.222 - 22, y: 90 * 0.66 - 22, width: 44, height: 44)
        finishButton.frame = NSRect(x: catRect.minX + 180 * 0.77 - 22, y: 90 * 0.66 - 22, width: 44, height: 44)
        for button in [cancelButton, finishButton] {
            button.target = self
            addSubview(button)
        }
        cancelButton.action = #selector(cancel)
        finishButton.action = #selector(finish)
        startButton.frame = NSRect(x: 27, y: 87, width: 130, height: 25)
        startButton.font = .systemFont(ofSize: 11)
        startButton.bezelStyle = .rounded
        startButton.refusesFirstResponder = true
        startButton.target = self
        startButton.action = #selector(start)
        startButton.isHidden = true
        addSubview(startButton)
        finishButton.setAccessibilityLabel("完成錄音並開始辨識")
        update(state: .idle)
    }

    required init?(coder: NSCoder) { nil }

    func setImage(_ image: NSImage?) {
        catImage = image
        needsDisplay = true
    }

    func update(state: DictationState) {
        startButton.isHidden = true
        introductionLabel.isHidden = true
        detailLabel.isHidden = true
        setFrameSize(NSSize(width: 184, height: 112))
        startButton.frame.origin.y = 87
        statusLabel.isHidden = state == .recording
        currentState = state
        let presentation = NekoHUDPresentation(state: state)
        statusLabel.stringValue = presentation.title
        cancelButton.isEnabled = presentation.canCancel
        finishButton.isEnabled = presentation.canFinish
        cancelButton.setAccessibilityLabel(presentation.cancelLabel)
        finishButton.setAccessibilityLabel("完成錄音並開始辨識")
        detailLabel.stringValue = state == .recording ? "左眼取消 · 右眼完成" : "What's up my neighbor"
        if state != .recording { meter.reset() }
        cancelButton.needsDisplay = true
        finishButton.needsDisplay = true
        window?.invalidateCursorRects(for: cancelButton)
        window?.invalidateCursorRects(for: finishButton)
        needsDisplay = true
    }

    func updateMeter(decibels: Float?, elapsed: TimeInterval) {
        guard currentState == .recording else { return }
        meter.update(decibels: decibels, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        needsDisplay = true
    }

    func showMessage(_ message: String, detail: String, showsDetail: Bool = false) {
        statusLabel.stringValue = message
        detailLabel.stringValue = detail
        detailLabel.isHidden = !showsDetail
        setFrameSize(NSSize(width: 184, height: showsDetail ? 146 : 112))
    }

    func configurePreview(shortcut: String, showIntroduction: Bool) {
        update(state: .recording)
        updateMeter(decibels: nil, elapsed: 0)
        if showIntroduction {
            showStartButton(shortcut: shortcut)
            self.showIntroduction()
        }
        // Normal previews remain cat-only. Eye actions are still discoverable
        // to assistive technology without repeating the first-use guide.
        cancelButton.setAccessibilityLabel("關閉預覽")
        finishButton.setAccessibilityLabel("完成預覽")
    }

    func showStartButton(shortcut: String) {
        startButton.title = "開始錄音  \(shortcut)"
        startButton.isHidden = false
        statusLabel.isHidden = true
    }

    func showIntroduction() {
        introductionLabel.isHidden = false
        startButton.frame.origin.y = 110
        setFrameSize(NSSize(width: 184, height: 138))
    }

    @objc private func cancel() { if cancelButton.isEnabled { onCancel?() } }
    @objc private func finish() { if finishButton.isEnabled { onFinish?() } }
    @objc private func start() { onStart?() }

    override func draw(_ dirtyRect: NSRect) {
        // A transparent, compact character instead of a large card over the editor.
        NSGraphicsContext.saveGraphicsState()
        let edge = NSShadow()
        edge.shadowColor = NSColor.white.withAlphaComponent(0.75)
        edge.shadowBlurRadius = 3
        edge.shadowOffset = .zero
        edge.set()
        if currentState == .recording {
            let scale = catRect.width / 1774
            NekoAppearance.ink.setFill()
            for (index, level) in meter.levels.enumerated() where level > 0 {
                let envelope = sin(Double(index + 1) / 12 * .pi)
                let height = CGFloat(level * (35 + envelope * 205))
                let rect = NSRect(x: catRect.minX + CGFloat(551 + index * 62) * scale,
                                  y: catRect.minY + (385 - height) * scale,
                                  width: 43 * scale, height: (height + 12) * scale)
                NSBezierPath(roundedRect: rect, xRadius: 22 * scale, yRadius: 22 * scale).fill()
            }
        }
        catImage?.draw(in: catRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}

// 錄音 HUD 視窗控制器：
// 管理浮動面板的顯示、隱藏、螢幕定位（頂部中央或底部中央）、逾時自動收合與初次操作指引引導。
final class NekoRecordingHUD {
    var isVisible: Bool { panel.isVisible }
    private let panel: NekoFloatingPanel
    private let view: NekoRecordingView
    private var startedAt: Date?
    private var dismissResult: DispatchWorkItem?
    private var preview = false
    private let introduction: NekoIntroductionPreferences
    private(set) var position = NekoHUDPosition(rawValue: UserDefaults.standard.string(forKey: "nekoHUD.position") ?? "") ?? .topCenter
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onStart: (() -> Void)?

    init(defaults: UserDefaults = .standard, image: NSImage? = NekoAppearance.catImage) {
        view = NekoRecordingView(image: image)
        introduction = NekoIntroductionPreferences(defaults: defaults)
        panel = NekoFloatingPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "What's up my neighbor"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Match the nonactivating vocabulary toast: fullscreen apps and hiding
        // the agent after settings must not conceal the recording controls.
        panel.level = .statusBar
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = view
        view.onStart = { [weak self] in self?.onStart?() }
        view.onCancel = { [weak self] in
            guard let self else { return }
            if self.preview { self.hide() } else { self.onCancel?() }
        }
        view.onFinish = { [weak self] in
            guard let self else { return }
            if self.preview { self.showResult("預覽完成", detail: "未啟用麥克風") }
            else { self.onFinish?() }
        }
    }

    func update(state: DictationState) {
        preview = false
        if state == .idle {
            if dismissResult == nil { hide() }
            return
        }
        dismissResult?.cancel()
        dismissResult = nil
        view.update(state: state)
        if state == .recording { if startedAt == nil { startedAt = Date() } }
        else { startedAt = nil }
        present()
    }

    func setImage(_ image: NSImage?) {
        view.setImage(image)
    }

    func updateMeter(decibels: Float?) {
        guard let startedAt else { return }
        view.updateMeter(decibels: decibels, elapsed: Date().timeIntervalSince(startedAt))
    }

    func showResult(_ message: String, detail: String, showsDetail: Bool = false, duration: TimeInterval = 1.5) {
        dismissResult?.cancel()
        view.update(state: .idle)
        view.showMessage(message, detail: detail, showsDetail: showsDetail)
        present()
        let task = DispatchWorkItem { [weak self] in self?.hide() }
        dismissResult = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    func showIntroductionIfNeeded(shortcut: String) {
        guard introduction.shouldShow else { return }
        showPreview(shortcut: shortcut, showIntroduction: true)
    }

    func showPreview(shortcut: String, showIntroduction: Bool = false) {
        dismissResult?.cancel()
        dismissResult = nil
        preview = true
        startedAt = nil
        view.configurePreview(shortcut: shortcut, showIntroduction: showIntroduction)
        if showIntroduction {
            introduction.markShown()
        }
        present()
    }

    func hide() {
        dismissResult?.cancel()
        dismissResult = nil
        startedAt = nil
        preview = false
        panel.orderOut(nil)
    }

    func setPosition(_ value: NekoHUDPosition) {
        position = value
        UserDefaults.standard.set(value.rawValue, forKey: "nekoHUD.position")
        positionPanel()
    }

    static func origin(for position: NekoHUDPosition, in visibleFrame: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: visibleFrame.midX - size.width / 2,
                y: position == .topCenter ? visibleFrame.maxY - size.height - 12 : visibleFrame.minY + 12)
    }

    #if NEKO_HUD_TESTING
    var testPanel: NekoFloatingPanel { panel }
    #endif

    private func positionPanel() {
        let screen = panel.isVisible && panel.isOnActiveSpace ? panel.screen :
            (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(Self.origin(for: position, in: frame, size: panel.frame.size))
        }
    }

    private func present() {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        let resized = panel.contentRect(forFrameRect: panel.frame).size != view.bounds.size
        if resized { panel.setContentSize(view.bounds.size) }
        if resized || !panel.isVisible || !panel.isOnActiveSpace { positionPanel() }
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
    }
}
