import AppKit

@main
struct VPSCatWindowLifecycleTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let area = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        var buttons = 1
        var cursor = CGPoint.zero
        var busy = false
        let pet = DesktopPetController(resources: resources, appearance: CatAppearance.makePreset("orange-tabby")!, automaticallyTicks: false,
            world: { DesktopPetWorld(areas: [area], cursor: cursor, idleSeconds: 0) }, pressedButtons: { buttons })
        pet.isBusy = { busy }
        pet.setReleased(true)
        let connection = VPSDesktopConnection()
        let controller = VPSDesktopWindowController(pet: pet, connection: connection, resources: resources)
        // Synthetic connection events exercise the real controller without opening SSH/VNC.
        connection.handle("connected")
        controller.present()
        let window = NSApp.windows.first { $0.title == "VPS 遠端桌面" }!
        var home = pet.model.origin
        var phase = "collapse"
        func park() {
            precondition(pet.parkInVPS())
            precondition(pet.remoteHosted && !pet.testPanel.isVisible)
        }
        func homeAgain() {
            precondition(!pet.remoteHosted && pet.testPanel.isVisible, "Failed recovery: \(phase), hosted=\(pet.remoteHosted), visible=\(pet.testPanel.isVisible), model=\(pet.model.visible)")
            precondition(pet.model.origin == home && !pet.model.isPressed, "Home mismatch in \(phase): \(pet.model.origin), expected \(home), pressed=\(pet.model.isPressed)")
        }
        // The original side-entry component must be reached through actual pet callbacks.
        pet.pointerDown(at: CGPoint(x: pet.model.frame.midX, y: pet.model.frame.midY))
        let edge = CGPoint(x: window.frame.minX - 5, y: window.frame.midY)
        pet.pointerDragged(to: edge)
        let hint = NSApp.windows.first { $0.title == "貓咪拖放提示" }!
        precondition(hint.isVisible && hint.ignoresMouseEvents && !hint.canBecomeKey && !hint.canBecomeMain)
        precondition(hint.frame.width < 12, "The entry hint is only the archived narrow edge line, not a large colored panel")
        if let content = hint.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let output = resources.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/cat-render/vps-original-drop-hint.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        pet.pointerUp(at: edge)
        precondition(pet.remoteHosted && !hint.isVisible, "The original visible entry zone must accept the drop")
        // Verify rendered pixels, not just hosted state or an accessibility node.
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let rendered = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rendered)
        let screenshot = resources.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/cat-render/vps-hosted-cat.png")
        try rendered.representation(using: .png, properties: [:])!.write(to: screenshot)
        var coloredPixels = 0
        for y in stride(from: 0, to: rendered.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rendered.pixelsWide, by: 2) {
                guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.5 && color.redComponent > color.greenComponent * 1.18 &&
                    color.greenComponent > color.blueComponent * 1.1 { coloredPixels += 1 }
            }
        }
        precondition(coloredPixels > 80, "The hosted cat must be visible in the composite VPS view, not only present in state")
        let host = (content as! VPSDesktopContentView).cat
        let painted = host.artwork.convert(CGPoint(x: 104, y: 100), to: content)
        precondition(host.hitTest(painted) === host.artwork, "The visible cat remains draggable")
        let padding = CGPoint(x: host.frame.minX + 1, y: host.frame.minY + 1)
        precondition(host.hitTest(padding) == nil, "Transparent cat padding must pass through to the viewer")
        let originalFrame = window.frame
        window.setFrame(originalFrame.insetBy(dx: -60, dy: -30), display: true)
        content.layoutSubtreeIfNeeded()
        precondition(host.frame.midX == content.bounds.midX && host.frame.maxY < content.bounds.maxY - 48,
                     "Resizing keeps the cat in the desktop area below the header")
        window.setFrame(originalFrame, display: true)
        content.layoutSubtreeIfNeeded()
        pet.returnFromVPS()
        homeAgain()
        // On a real release a display tick can see the physical button up before
        // AppKit delivers mouseUp. Recovery must finish the same transfer once.
        pet.pointerDown(at: CGPoint(x: pet.model.frame.midX, y: pet.model.frame.midY))
        pet.pointerDragged(to: edge)
        cursor = edge
        buttons = 0
        pet.refresh()
        precondition(pet.remoteHosted, "A display tick before mouseUp must complete the VPS drop, not silently cancel it")
        pet.pointerUp(at: edge)
        precondition(pet.remoteHosted, "A late mouseUp must not undo or repeat the recovered transfer")
        // The same recovery must finish a drag out through the real remote callbacks.
        buttons = 1
        let grip = window.convertPoint(toScreen: host.artwork.convert(CGPoint(x: 104, y: 100), to: nil))
        host.artwork.onPointerDown?(grip)
        cursor = CGPoint(x: window.frame.minX - 80, y: window.frame.midY)
        host.artwork.onPointerDragged?(cursor)
        precondition(pet.model.isDragging && !pet.remoteHosted)
        buttons = 0
        pet.refresh()
        precondition(!pet.remoteHosted && pet.testPanel.isVisible && !hint.isVisible,
                     "Recovered release outside VPS must finish the drag out")
        host.artwork.onPointerUp?()
        precondition(!pet.remoteHosted, "Late remote mouseUp must not put the cat back inside")
        buttons = 1
        home = pet.model.origin
        // Busy/hidden cancellation must never become a successful drop.
        pet.pointerDown(at: CGPoint(x: pet.model.frame.midX, y: pet.model.frame.midY))
        pet.pointerDragged(to: edge)
        cursor = edge
        buttons = 0
        busy = true
        pet.refresh()
        precondition(!pet.remoteHosted && !hint.isVisible && !pet.model.isPressed)
        pet.pointerUp(at: edge)
        busy = false
        buttons = 1
        pet.refresh()
        park()
        controller.toggleCollapsed()
        homeAgain()
        controller.toggleCollapsed()
        park()
        phase = "disconnect"
        connection.handle("disconnected")
        homeAgain()
        connection.handle("connected")
        park()
        phase = "close"
        window.close()
        homeAgain()
        precondition(connection.connected, "Closing the window keeps the VNC connection")
        controller.present()
        park()
        phase = "minimize"
        // Command-line AppKit runners do not enter the Dock animation loop.
        // Exercise the delegate notification before the window becomes unavailable.
        controller.windowWillMiniaturize(Notification(name: NSWindow.willMiniaturizeNotification, object: window))
        homeAgain()
        window.deminiaturize(nil)
        park()
        // Explicitly recalling the pet must survive a later disconnect/reconnect.
        pet.setReleased(false)
        precondition(!pet.remoteHosted && !pet.model.released && !pet.testPanel.isVisible)
        connection.handle("disconnected")
        connection.handle("connected")
        precondition(!pet.model.released && !pet.testPanel.isVisible,
                     "Connection changes must not resurrect a pet the user recalled")
        pet.setReleased(true)
        for cancelByRecall in [true, false] {
            pet.pointerDown(at: CGPoint(x: pet.model.frame.midX, y: pet.model.frame.midY))
            pet.pointerDragged(to: edge)
            precondition(hint.isVisible)
            if cancelByRecall { pet.setReleased(false) }
            else { pet.testSuspend(true) }
            precondition(!hint.isVisible, "Cancelled drags must dismiss the original hint")
            pet.testSuspend(false)
            pet.setReleased(false)
            pet.setReleased(true)
            home = pet.model.origin
        }
        park()
        phase = "shutdown"
        controller.shutdown()
        homeAgain()
        precondition(!connection.connected)
        controller.shutdown()
        pet.dispose()
        window.close()
        print("VPS cat window lifecycle passed: collapse, disconnect, close/reopen, minimize notification, idempotent shutdown; no network connection")
    }
}
