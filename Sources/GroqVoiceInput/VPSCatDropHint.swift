import AppKit

/// Reuses the archived DirectDrop edge stroke and invisible drop-target geometry.
/// Only the coordinate adapter changes: the reference card becomes the real VPS window.
enum VPSCatDropHintGeometry {
    static let entry = CGRect(x: 455, y: 132, width: 185, height: 384)
    static let home = CGRect(x: 30, y: 180, width: 425, height: 365)

    static func screenRect(_ rect: CGRect, window: CGRect) -> CGRect {
        let scaleX = window.width / 580
        let scaleY = max(0, window.height - 60) / 381
        return CGRect(x: window.minX + (rect.minX - 500) * scaleX,
                      y: window.minY + 10 + (516 - rect.maxY) * scaleY,
                      width: rect.width * scaleX, height: rect.height * scaleY)
    }
}

private final class VPSCatDropHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class VPSCatDropHintView: NSView {
    enum Kind { case entry, home }
    var kind: Kind = .entry
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Preserve only the archived DirectDrop edge stroke (x=501, y=150...506).
        // The larger target rectangles remain invisible hit areas, not visible UI.
        NSColor.systemPink.withAlphaComponent(0.8).setStroke()
        let edge = NSBezierPath(); edge.lineWidth = 4
        edge.move(to: CGPoint(x: 501, y: 150))
        edge.line(to: CGPoint(x: 501, y: 506))
        edge.stroke()
    }
}

/// A mouse-transparent hint surface, never another cat or VNC viewer.
@MainActor final class VPSCatDropHintController {
    private let view = VPSCatDropHintView()
    private let panel = VPSCatDropHintPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)

    init() {
        panel.title = "貓咪拖放提示"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
    }

    func show(_ kind: VPSCatDropHintView.Kind, beside host: NSWindow) {
        let virtual = CGRect(x: 497, y: 132, width: 8, height: 384)
        let frame = VPSCatDropHintGeometry.screenRect(virtual, window: host.frame)
        if panel.isVisible, view.kind == kind, panel.frame == frame { return }
        let wasVisible = panel.isVisible
        view.kind = kind
        panel.setFrame(frame, display: false)
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.bounds = virtual
        view.setAccessibilityLabel(kind == .entry ? "放開，貓咪就進去" : "放開，回到本機")
        view.needsDisplay = true
        // Insert immediately above the host, beneath the already-raised dragged cat.
        if !wasVisible { panel.alphaValue = 0 }
        panel.order(.above, relativeTo: host.windowNumber)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() { panel.orderOut(nil) }
}
