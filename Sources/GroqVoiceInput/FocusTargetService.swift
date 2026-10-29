import AppKit
import ApplicationServices

enum FocusTargetError: Error, Equatable {
    case accessibilityDenied
    case noEditableTarget
    case targetChanged
    case targetExpired

    var diagnosticFailure: PasteDiagnostics.Failure {
        switch self {
        case .accessibilityDenied: return .accessibilityDenied
        case .noEditableTarget: return .noEditableTarget
        case .targetChanged: return .targetChanged
        case .targetExpired: return .targetExpired
        }
    }
}

enum FocusTargetPolicy {
    /// Relay actions retain the original direct-edit and title checks.
    case remoteStrict
    /// Local Cmd+V can work even when an editor does not expose a writable AXValue.
    case localDictation
}

/// A snapshot identifies the focused element without reading its text contents.
// 隱私與安全設計原則：
// 快照僅保存焦點元素的識別屬性（PID、BundleID、Window ID、Role、可編輯狀態），
// 絕對不讀取編輯框內的現有文字或未送出的內容，嚴格落實 PRIVACY.md 的零個人資料外流承諾。
struct FocusTargetSnapshot {
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let element: AnyObject
    let isEditable: Bool
    let isLocalPasteTarget: Bool
    let windowElement: AnyObject?

    init(
        pid: pid_t, bundleIdentifier: String, appName: String, windowTitle: String,
        element: AnyObject, isEditable: Bool,
        isLocalPasteTarget: Bool? = nil, windowElement: AnyObject? = nil
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.element = element
        self.isEditable = isEditable
        self.isLocalPasteTarget = isLocalPasteTarget ?? isEditable
        self.windowElement = windowElement
    }
}

struct FocusTarget {
    let sessionID: String
    let macName: String
    let expiresAt: Date
    let snapshot: FocusTargetSnapshot
    let policy: FocusTargetPolicy

    var appName: String { snapshot.appName }
    var windowTitle: String { snapshot.windowTitle }
}

/// Shared by local dictation and iPhone relay. It never changes focus or types.
final class FocusTargetService {
    struct Environment {
        var isAccessibilityTrusted: () -> Bool
        var currentSnapshot: () -> FocusTargetSnapshot?
        var elementsMatch: (AnyObject, AnyObject) -> Bool
        var now: () -> Date
        var newSessionID: () -> String
        var macName: () -> String

        static var system: Environment {
            Environment(
                isAccessibilityTrusted: { AXIsProcessTrusted() },
                currentSnapshot: { FocusTargetService.systemSnapshot() },
                elementsMatch: { CFEqual($0, $1) },
                now: Date.init,
                newSessionID: { UUID().uuidString },
                macName: { Host.current().localizedName ?? "Mac" }
            )
        }
    }

    private let environment: Environment

    init(environment: Environment = .system) {
        self.environment = environment
    }

    /// Local dictation permits five minutes of recording plus transcription time.
    /// Relay callers explicitly retain their existing five-minute lifetime.
    func captureTarget(
        ttl: TimeInterval = 600, policy: FocusTargetPolicy = .remoteStrict,
        beginDiagnosticCapture: Bool = true
    ) throws -> FocusTarget {
        let trusted = environment.isAccessibilityTrusted()
        PasteDiagnostics.shared.record(.init(tag: .capture, trusted: trusted,
                                              localPolicy: policy == .localDictation), beginCapture: beginDiagnosticCapture)
        guard trusted else {
            PasteDiagnostics.shared.record(.init(tag: .captureResult, accepted: false, failure: .accessibilityDenied))
            throw FocusTargetError.accessibilityDenied
        }
        // 策略檢驗差異：
        // 1. localDictation（本機語音）：使用 isLocalPasteTarget。現代編輯器（如 VS Code、瀏覽器 Web 編輯區）
        //    的 AXValue 往往不可直接設值（canSetValue == false），但完全支援 ⌘V 鍵盤貼上。
        // 2. remoteStrict（iPhone 接力）：要求嚴格的 isEditable，避免向不可控的遠端目標盲目注入按鍵。
        guard let snapshot = environment.currentSnapshot(),
              policy == .localDictation ? snapshot.isLocalPasteTarget : snapshot.isEditable else {
            PasteDiagnostics.shared.record(.init(tag: .captureResult, accepted: false, failure: .noEditableTarget))
            throw FocusTargetError.noEditableTarget
        }
        PasteDiagnostics.shared.record(.init(tag: .captureResult, accepted: true))
        return FocusTarget(
            sessionID: environment.newSessionID(),
            macName: environment.macName(),
            expiresAt: environment.now().addingTimeInterval(ttl),
            snapshot: snapshot,
            policy: policy
        )
    }

    func validateTarget(_ target: FocusTarget) throws {
        let trusted = environment.isAccessibilityTrusted()
        guard trusted else {
            PasteDiagnostics.shared.record(.init(tag: .validation, trusted: false,
                                                  localPolicy: target.policy == .localDictation))
            PasteDiagnostics.shared.record(.init(tag: .validationResult, accepted: false, failure: .accessibilityDenied))
            throw FocusTargetError.accessibilityDenied
        }
        let current = environment.currentSnapshot()
        let expected = target.snapshot
        let elementMatches = current.map { environment.elementsMatch(expected.element, $0.element) } ?? false
        let windowMatches = current.map { localWindowsMatch(expected, $0) } ?? false
        let now = environment.now()
        PasteDiagnostics.shared.record(.init(
            tag: .validation, trusted: trusted, localPolicy: target.policy == .localDictation,
            localEligible: current?.isLocalPasteTarget, strictEligible: current?.isEditable,
            hasCurrent: current != nil,
            processMatches: current?.pid == expected.pid,
            bundleMatches: current?.bundleIdentifier == expected.bundleIdentifier,
            elementMatches: elementMatches, windowMatches: windowMatches,
            windowTitleMatches: current?.windowTitle == expected.windowTitle,
            expired: target.expiresAt <= now
        ))
        if target.policy == .localDictation {
            guard target.expiresAt > now else {
                PasteDiagnostics.shared.record(.init(tag: .validationResult, accepted: false, failure: .targetExpired))
                throw FocusTargetError.targetExpired
            }
            guard let current,
                  current.pid == expected.pid,
                  current.bundleIdentifier == expected.bundleIdentifier,
                  current.isLocalPasteTarget,
                  elementMatches,
                  windowMatches else {
                PasteDiagnostics.shared.record(.init(tag: .validationResult, accepted: false, failure: .targetChanged))
                throw FocusTargetError.targetChanged
            }
            PasteDiagnostics.shared.record(.init(tag: .validationResult, accepted: true))
            return
        }
        let failure = RemoteTargetValidationPolicy.evaluate(
            expectedPID: expected.pid,
            currentPID: current?.pid,
            expectedBundleIdentifier: expected.bundleIdentifier,
            currentBundleIdentifier: current?.bundleIdentifier,
            expectedWindowTitle: expected.windowTitle,
            currentWindowTitle: current?.windowTitle,
            elementMatches: elementMatches,
            isEditable: current?.isEditable ?? false,
            expiresAt: target.expiresAt,
            now: now
        )
        switch failure {
        case .expired:
            PasteDiagnostics.shared.record(.init(tag: .validationResult, accepted: false, failure: .targetExpired))
            throw FocusTargetError.targetExpired
        case .changed:
            PasteDiagnostics.shared.record(.init(tag: .validationResult, accepted: false, failure: .targetChanged))
            throw FocusTargetError.targetChanged
        case nil:
            PasteDiagnostics.shared.record(.init(tag: .validationResult, accepted: true))
            return
        }
    }

    private func localWindowsMatch(_ expected: FocusTargetSnapshot, _ current: FocusTargetSnapshot) -> Bool {
        switch (expected.windowElement, current.windowElement) {
        case let (expectedWindow?, currentWindow?):
            // 視窗物件層級容錯：
            // 瀏覽器分頁標題或線上文檔名稱常因未讀訊息數或自動存檔而變動。
            // 此處比對 Window AXUIElement 的實體參照（CFEqual）而非字串標題，避免標題變更導致貼上失效。
            // Browser chat titles and document names can change without moving the caret.
            return environment.elementsMatch(expectedWindow, currentWindow)
        case (nil, nil):
            return expected.windowTitle == current.windowTitle
        default:
            return false
        }
    }

    static func isLocalPasteTarget(
        role: String, subrole: String?, canSetValue: Bool,
        isEnabled: Bool? = nil, isReadOnly: Bool? = nil,
        isExplicitlyEditable: Bool? = nil, hasProtectedContent: Bool? = nil
    ) -> Bool {
        // 安全不可逾越條件：
        // 絕對不將語音辨識明文注入 AXSecureTextField（密碼框）或具有 protectedContent 的敏感區域，
        // 避免使用者的口述內容意外暴露於敏感欄位。
        guard subrole != "AXSecureTextField", role != "AXSecureTextField",
              isEnabled != false, isReadOnly != true,
              isExplicitlyEditable != false, hasProtectedContent != true else { return false }
        // AXStaticText and arbitrary text-like roles are never keyboard destinations.
        // Text fields/areas often support keyboard editing while AXValue is read-only.
        if ["AXTextField", "AXTextArea"].contains(role) { return true }
        return role == "AXComboBox" && (canSetValue || isExplicitlyEditable == true)
    }

    static func isEditable(role: String, subrole: String?, canSetValue: Bool) -> Bool {
        guard subrole != "AXSecureTextField", canSetValue else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
            || role.localizedCaseInsensitiveContains("text")
    }

    private static func systemSnapshot() -> FocusTargetSnapshot? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        PasteDiagnostics.shared.record(.init(
            tag: .snapshotFrontmost,
            frontmostAvailable: frontmost != nil,
            frontmostIsSelf: frontmost.map { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier }
        ))
        guard let frontmost,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement(pid: frontmost.processIdentifier, recordDiagnostics: true) else { return nil }
        var elementPID: pid_t = 0
        let ownerResult = AXUIElementGetPid(element, &elementPID)
        let ownerMatches = elementPID == frontmost.processIdentifier
        let foregroundUnchanged = NSWorkspace.shared.frontmostApplication?.processIdentifier == elementPID
        PasteDiagnostics.shared.record(.init(tag: .snapshotIdentity, queryResult: ownerResult.rawValue,
                                              elementOwnerMatches: ownerMatches, frontmostUnchanged: foregroundUnchanged))
        guard ownerResult == .success, ownerMatches, foregroundUnchanged else { return nil }

        var settable = DarwinBoolean(false)
        let valueResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let canSetValue = valueResult == .success && settable.boolValue
        let window = focusedWindow(pid: elementPID)
        let enabled = boolAttribute(kAXEnabledAttribute, from: element)
        let readOnly = boolAttribute("AXReadOnly", from: element)
        let explicitlyEditable = boolAttribute("AXEditable", from: element)
        let protectedContent = boolAttribute("AXProtectedContent", from: element)
        let localEligible = isLocalPasteTarget(
            role: role, subrole: subrole, canSetValue: canSetValue, isEnabled: enabled,
            isReadOnly: readOnly, isExplicitlyEditable: explicitlyEditable, hasProtectedContent: protectedContent
        )
        let strictEligible = isEditable(role: role, subrole: subrole, canSetValue: canSetValue)
        PasteDiagnostics.shared.record(.init(
            tag: .snapshotCapabilities, queryResult: valueResult.rawValue,
            role: .init(attribute: role), subrole: .init(attribute: subrole),
            canSetValue: canSetValue, localEligible: localEligible, strictEligible: strictEligible,
            enabled: enabled, readOnly: readOnly, explicitlyEditable: explicitlyEditable,
            protectedContent: protectedContent, hasWindow: window != nil
        ))
        return FocusTargetSnapshot(
            pid: elementPID,
            bundleIdentifier: frontmost.bundleIdentifier ?? "",
            appName: frontmost.localizedName ?? "Mac App",
            windowTitle: window.flatMap { stringAttribute(kAXTitleAttribute, from: $0) } ?? "",
            element: element,
            isEditable: strictEligible,
            isLocalPasteTarget: localEligible,
            windowElement: window
        )
    }

    /// Some Electron editors expose focus on their application element while the
    /// system-wide query returns cannotComplete. Only the foreground PID is eligible.
    static func firstFocusedElement(
        matchingPID pid: pid_t,
        readSystem: () -> AXUIElement?,
        readApplication: () -> AXUIElement?
    ) -> AXUIElement? {
        func matches(_ element: AXUIElement) -> Bool {
            var candidatePID: pid_t = 0
            return AXUIElementGetPid(element, &candidatePID) == .success && candidatePID == pid
        }
        if let element = readSystem(), matches(element) { return element }
        if let element = readApplication(), matches(element) { return element }
        return nil
    }

    static func focusedElement(pid: pid_t, recordDiagnostics: Bool = false) -> AXUIElement? {
        firstFocusedElement(
            matchingPID: pid,
            readSystem: { focusedElement(of: AXUIElementCreateSystemWide(),
                                         diagnosticTag: recordDiagnostics ? .focusSystemQuery : nil) },
            readApplication: { focusedElement(of: AXUIElementCreateApplication(pid),
                                              diagnosticTag: recordDiagnostics ? .focusApplicationQuery : nil) }
        )
    }

    private static func focusedElement(
        of owner: AXUIElement, diagnosticTag: PasteDiagnostics.Tag?
    ) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &value)
        let hasElement = value.map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false
        if let diagnosticTag {
            PasteDiagnostics.shared.record(.init(tag: diagnosticTag, focusedElementAvailable: hasElement,
                                                  queryResult: result.rawValue))
        }
        guard result == .success, hasElement, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return (windowValue as! AXUIElement)
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
