import AppKit

/// 把會議逐字稿放進剪貼簿，但不讓它進「剪貼簿歷史」。
///
/// 為什麼需要：`ClipboardHistoryMonitor` 看 `NSPasteboard.general` 的 changeCount，
/// 只會略過帶有 `ignoredTypes`（例如 TransientType）的內容。直接 `setString` 會被當成
/// 一般複製，整場逐字稿被收進歷史清單，而且 `ClipboardHistoryStore` 會把它寫到磁碟。
/// 所以這裡額外宣告 `org.nspasteboard.TransientType`，這是剪貼簿管理工具之間通用的「暫時內容」標記。
enum MeetingClipboard {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func item(for text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        return item
    }

    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item(for: text)])
    }
}
