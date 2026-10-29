import AppKit
import ApplicationServices

/// Opt-in observation only. These references never become insertion targets.
final class DictationFocusTrace {
    struct Element {
        var reference: AnyObject? = nil
        var window: AnyObject? = nil
        var queryResult: Int32? = nil
        var available = false
        var ownerMatches: Bool? = nil
        var role: PasteDiagnostics.Role? = nil
        var focused: Bool? = nil
        var localEligible: Bool? = nil
    }

    struct Observation {
        var trusted: Bool
        var foregroundPID: pid_t? = nil
        var foregroundIsSelf: Bool? = nil
        var foregroundUnchanged: Bool? = nil
        var system = Element()
        var application = Element()
    }

    private let logger: PasteDiagnostics
    private let read: () -> Observation
    private let matches: (AnyObject, AnyObject) -> Bool
    private var anchor: Observation?
    private var method: PasteDiagnostics.StopMethod?
    private(set) var isActive = false

    init(logger: PasteDiagnostics = .shared, read: @escaping () -> Observation = DictationFocusTrace.observe,
         matches: @escaping (AnyObject, AnyObject) -> Bool = { CFEqual($0, $1) }) {
        self.logger = logger
        self.read = read
        self.matches = matches
    }

    func begin(method: PasteDiagnostics.StopMethod) {
        guard logger.isEnabled else { return }
        isActive = true
        self.method = method
        logger.record(.init(tag: .toggle, startMethod: method), beginCapture: true)
        let observation = read()
        anchor = observation
        record(observation, phase: .beforeControls)
    }

    func checkpoint(_ phase: PasteDiagnostics.FocusPhase) {
        guard isActive, logger.isEnabled else { return }
        record(read(), phase: phase)
    }

    func end() { isActive = false; anchor = nil; method = nil }

    private func record(_ observation: Observation, phase: PasteDiagnostics.FocusPhase) {
        let expected = anchor.map { $0.application.reference != nil ? $0.application : $0.system }
        for (source, element) in [(PasteDiagnostics.FocusSource.system, observation.system),
                                  (.application, observation.application)] {
            var event = PasteDiagnostics.Event(tag: .focusCheckpoint)
            event.startMethod = method
            event.focusPhase = phase
            event.focusSource = source
            event.trusted = observation.trusted
            event.frontmostAvailable = observation.foregroundPID != nil
            event.frontmostIsSelf = observation.foregroundIsSelf
            event.frontmostUnchanged = observation.foregroundUnchanged
            event.focusedElementAvailable = element.available
            event.queryResult = element.queryResult
            event.elementOwnerMatches = element.ownerMatches
            event.role = element.role
            event.focused = element.focused
            event.localEligible = element.localEligible
            event.processMatches = anchor?.foregroundPID.map { $0 == observation.foregroundPID }
            event.elementMatches = expected?.reference.map { old in element.reference.map { matches(old, $0) } ?? false }
            event.windowMatches = expected?.window.map { old in element.window.map { matches(old, $0) } ?? false }
            logger.record(event)
        }
    }

    static func observe() -> Observation {
        var result = Observation(trusted: AXIsProcessTrusted())
        guard result.trusted, let front = NSWorkspace.shared.frontmostApplication else { return result }
        let pid = front.processIdentifier
        result.foregroundPID = pid
        result.foregroundIsSelf = pid == ProcessInfo.processInfo.processIdentifier
        result.system = observeElement(AXUIElementCreateSystemWide(), expectedPID: pid)
        result.application = observeElement(AXUIElementCreateApplication(pid), expectedPID: pid)
        result.foregroundUnchanged = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        return result
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func observeElement(_ owner: AXUIElement, expectedPID: pid_t) -> Element {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &value)
        var result = Element(queryResult: status.rawValue)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return result }
        result.available = true
        let element = value as! AXUIElement
        var pid: pid_t = 0
        result.ownerMatches = AXUIElementGetPid(element, &pid) == .success && pid == expectedPID
        guard result.ownerMatches == true else { return result }
        result.reference = element
        let role = attribute(kAXRoleAttribute, of: element) as? String ?? ""
        result.role = .init(attribute: role)
        result.focused = attribute(kAXFocusedAttribute, of: element) as? Bool
        if let window = attribute(kAXWindowAttribute, of: element), CFGetTypeID(window) == AXUIElementGetTypeID() {
            result.window = window as AnyObject
        }
        var settable = DarwinBoolean(false)
        let canSet = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        result.localEligible = FocusTargetService.isLocalPasteTarget(
            role: role, subrole: attribute(kAXSubroleAttribute, of: element) as? String, canSetValue: canSet,
            isEnabled: attribute(kAXEnabledAttribute, of: element) as? Bool,
            isReadOnly: attribute("AXReadOnly", of: element) as? Bool,
            isExplicitlyEditable: attribute("AXEditable", of: element) as? Bool,
            hasProtectedContent: attribute("AXProtectedContent", of: element) as? Bool
        )
        return result
    }
}
