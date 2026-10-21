import AppKit
import SwiftUI

@main
enum OfficePreviewMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = OfficePreviewDelegate()
        app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class OfficePreviewDelegate: NSObject, NSApplicationDelegate {
    private let office = OfficePanelModel()
    private let demo = RemoteAgentPreviewModel()
    private let handoff = RemoteDesktopHandoffModel()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        menu.addItem(item); item.submenu = submenu
        submenu.addItem(withTitle: "結束貓咪辦公室預覽", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(), edit = NSMenu(title: "編輯")
        menu.addItem(editItem); editItem.submenu = edit
        for (title, action, key) in [("剪下", "cut:", "x"), ("複製", "copy:", "c"), ("貼上", "paste:", "v"), ("全選", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "貓咪辦公室 · 獨立預覽"
        window.contentMinSize = NSSize(width: 820, height: 650)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabView {
            OfficePanelView(model: office).tabItem { Text("貓咪辦公室") }
            RemoteAgentView(model: demo, handoff: handoff).tabItem { Text("原有示範與遠端桌面") }
        }.padding(8))
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { office.disconnect(); demo.cancel(); handoff.stop() }
}
