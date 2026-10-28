import AppKit
import SwiftUI

@main
enum RemoteAgentPreviewMain {
    static func main() {
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.count > index + 1 {
            app.setActivationPolicy(.accessory)
            do { try PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { fputs("Preview render failed: \(error)\n", stderr); exit(1) }
            return
        }
        app.setActivationPolicy(.regular)
        let delegate = PreviewAppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

private final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private let model = RemoteAgentPreviewModel()
    private let handoff = RemoteDesktopHandoffModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "遠端分身 · 示範模式"
        window.contentMinSize = NSSize(width: 760, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RemoteAgentView(model: model, handoff: handoff))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.cancel(); handoff.stop() }

    private func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "結束遠端分身預覽", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "編輯"); editItem.submenu = edit
        edit.addItem(withTitle: "復原", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "複製", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
}
