import AppKit
import SwiftUI
import Combine

/// Floating VPS desktop opened from the cat menu; it never adds a second status item.
/// Closing or collapsing keeps the connection; only 中斷 or quitting the app ends it.
@MainActor final class VPSDesktopWindowController: NSObject, NSWindowDelegate {
    private let connection: VPSDesktopConnection
    private let panel = VPSDesktopPanel()
    private let dropHint = VPSCatDropHintController()
    private let pet: DesktopPetController
    private let catHost: VPSCatHostView
    private let window: NSWindow
    private let minimumSize = NSSize(width: 400, height: 330)
    // 48pt title bar plus a 450-wide view of the VPS's 1440×900 desktop.
    private var expandedSize = NSSize(width: 450, height: 330)
    private var hasConnected = false
    private var draggingFromVPS = false
    private var escapeMonitor: Any?
    private var connectionObserver: AnyCancellable?

    init(pet: DesktopPetController, connection: VPSDesktopConnection? = nil,
         resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("DesktopPet")) {
        self.pet = pet
        self.connection = connection ?? VPSDesktopConnection()
        catHost = VPSCatHostView(resources: resources, appearance: pet.appearance)
        window = VPSDesktopWindow(contentRect: NSRect(origin: .zero, size: expandedSize), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.title = "VPS 遠端桌面"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentMinSize = minimumSize
        window.hasShadow = true
        window.tabbingMode = .disallowed
        let desktop = NSHostingView(rootView: VPSDesktopView(panel: panel, connection: self.connection))
        window.contentView = VPSDesktopContentView(desktop: desktop, cat: catHost)
        window.contentView?.layoutSubtreeIfNeeded()
        panel.toggle = { [weak self] in self?.toggleCollapsed() }
        panel.returnCat = { [weak self] in self?.pet.returnFromVPS() }
        catHost.artwork.onPointerDown = { [weak self] point in self?.remotePointerDown(at: point) }
        catHost.artwork.onPointerDragged = { [weak self] point in self?.remotePointerDragged(to: point) }
        catHost.artwork.onPointerUp = { [weak self] in self?.remotePointerUp(at: NSEvent.mouseLocation) }
        pet.onDragMoved = { [weak self] point in self?.updateDropHover(at: point) }
        pet.onDragReleased = { [weak self] point in self?.finishDrag(at: point) }
        pet.onDragCancelled = { [weak self] in
            self?.dropHint.hide()
            self?.panel.dropHovered = false
        }
        pet.onRemoteHostedChange = { [weak self] _ in self?.updateCatVisibility() }
        pet.onRemoteFrame = { [weak self] model, reduceMotion, appearance in
            self?.catHost.artwork.setAppearance(appearance)
            self?.catHost.artwork.update(model, reduceMotion: reduceMotion)
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.draggingFromVPS, event.keyCode == 53 else { return event }
            self.draggingFromVPS = false
            self.pet.cancelVPSDrag()
            self.dropHint.hide()
            self.updateCatVisibility()
            return nil
        }
        connectionObserver = self.connection.$connected.removeDuplicates().sink { [weak self] connected in
            if !connected { self?.recoverCat() }
        }
        placeTopRight()
    }

    func present() {
        if panel.collapsed { toggleCollapsed() }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Connect once on first open; after a disconnect the user chooses when to retry.
        if !hasConnected {
            hasConnected = true
            connection.connect()
        }
    }

    func shutdown() {
        recoverCat()
        connectionObserver = nil
        window.delegate = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        pet.onDragMoved = nil; pet.onDragReleased = nil; pet.onDragCancelled = nil
        pet.onRemoteHostedChange = nil; pet.onRemoteFrame = nil
        catHost.removeFromSuperview()
        connection.disconnect()
    }

    func windowWillClose(_ notification: Notification) { recoverCat() }
    func windowWillMiniaturize(_ notification: Notification) { recoverCat() }

    private func recoverCat() {
        if draggingFromVPS { pet.cancelVPSDrag() }
        draggingFromVPS = false
        pet.returnFromVPS()
        panel.dropHovered = false
        dropHint.hide()
        updateCatVisibility()
    }

    private var acceptsDrop: Bool {
        connection.connected && !panel.collapsed && window.isVisible && !window.isMiniaturized
    }

    private func updateDropHover(at point: CGPoint) {
        guard !draggingFromVPS else { return }
        panel.dropHovered = VPSCatTransferZone.accepts(point, window: window.frame,
            connected: acceptsDrop, collapsed: panel.collapsed, visible: window.isVisible)
        if panel.dropHovered { dropHint.show(.entry, beside: window) }
        else { dropHint.hide() }
    }

    private func finishDrag(at point: CGPoint) {
        panel.dropHovered = false
        dropHint.hide()
        if draggingFromVPS {
            draggingFromVPS = false
            if !VPSCatTransferZone.hasExited(point, window: window.frame) {
                _ = pet.parkInVPS(preservingHome: true)
            }
            updateCatVisibility()
        } else if VPSCatTransferZone.accepts(point, window: window.frame,
                    connected: acceptsDrop, collapsed: panel.collapsed, visible: window.isVisible) {
            _ = pet.parkInVPS()
        }
    }

    private func remotePointerDown(at point: CGPoint) {
        guard pet.remoteHosted, acceptsDrop else { return }
        let screenRect = window.convertToScreen(catHost.convert(catHost.bounds, to: nil))
        draggingFromVPS = true
        catHost.followsRemoteDrag = true
        pet.beginVPSDrag(at: point, from: screenRect)
    }

    private func remotePointerDragged(to point: CGPoint) {
        if draggingFromVPS {
            pet.pointerDragged(to: point)
            let home = VPSCatDropHintGeometry.screenRect(VPSCatDropHintGeometry.home, window: window.frame)
            if home.contains(point) && acceptsDrop { dropHint.show(.home, beside: window) }
            else { dropHint.hide() }
        }
    }

    private func remotePointerUp(at point: CGPoint) {
        guard draggingFromVPS else { return }
        let wasDragging = pet.model.isDragging
        pet.pointerUp(at: point)
        if !wasDragging {
            draggingFromVPS = false
            _ = pet.parkInVPS(preservingHome: true)
            updateCatVisibility()
        }
    }

    private func updateCatVisibility() {
        panel.catInside = pet.remoteHosted
        catHost.followsRemoteDrag = draggingFromVPS
        catHost.acceptsCatInput = !panel.collapsed && (pet.remoteHosted || draggingFromVPS)
    }

    private func placeTopRight() {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let width = min(expandedSize.width, visible.width - 48)
        window.setFrame(NSRect(x: visible.maxX - width - 24, y: visible.maxY - expandedSize.height - 22, width: width, height: expandedSize.height), display: true)
    }

    func toggleCollapsed() {
        let collapsing = !panel.collapsed
        if collapsing {
            recoverCat()
            expandedSize = window.frame.size
        }
        panel.collapsed = collapsing
        let old = window.frame
        window.contentMinSize = collapsing ? NSSize(width: 320, height: 48) : minimumSize
        let size = collapsing ? NSSize(width: 340, height: 48) : expandedSize
        window.setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height), display: true)
        if collapsing { window.styleMask.remove(.resizable) } else { window.styleMask.insert(.resizable) }
        updateCatVisibility()
    }
}

/// The app has no Edit menu, so route the standard editing shortcuts here (e.g. pasting the VNC password).
private final class VPSDesktopWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let actions: [String: Selector] = [
            "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
            "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
            "w": #selector(NSWindow.performClose(_:)),
        ]
        if let action = actions[key], NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
