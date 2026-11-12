import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

@main
enum MeetingClipboardTests {
    static func main() {
        let board = NSPasteboard(name: NSPasteboard.Name("MeetingClipboardTests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let defaults = UserDefaults(suiteName: "MeetingClipboardTests-" + UUID().uuidString)!
        let store = ClipboardHistoryStore(directoryURL: nil)
        let monitor = ClipboardHistoryMonitor(store: store, defaults: defaults, environment: .live(board))
        monitor.start()
        defer { monitor.stop() }

        // 對照組：一般複製會進歷史，證明這個測試真的抓得到問題。
        board.clearContents()
        board.setString("一般複製", forType: .string)
        monitor.checkForChanges()
        expect(store.items.count == 1, "plain copy should be recorded (control)")

        // 會議逐字稿：文字要真的在剪貼簿裡，但歷史不能多一筆。
        let transcript = "---\nstarted: x\n---\n[00:00:00] Grokbot 與 yui 的會議內容\n"
        expect(MeetingClipboard.copy(transcript, to: board), "copy succeeds")
        expect(board.string(forType: .string) == transcript, "text is on the pasteboard")
        expect(board.types?.contains(MeetingClipboard.transientType) == true, "transient marker present")
        monitor.checkForChanges()
        expect(store.items.count == 1, "meeting transcript must not enter clipboard history")
        expect(!store.items.contains { String(data: $0.data, encoding: .utf8) == transcript }, "transcript not stored")

        expect(!MeetingClipboard.copy("", to: board), "empty text is refused")
        print("Meeting clipboard tests passed (history monitor skips transcript)")
    }
}
