import Foundation

@main
enum PasteDiagnosticsTests {
    static func main() throws {
        if CommandLine.arguments.contains("--enabled-fixture") {
            try runEnabledFixture()
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neighbor-paste-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try testDisabledDoesNotWrite(directory)
        try testBoundedPrivateReport(directory)
        try testServicesDoNotRecordContent(directory)
        try testFailureSurvivesNextCapture(directory)
        try testFocusTrace(directory)
        print("PasteDiagnosticsTests passed: opt-in only, private bounded JSON, typed metadata, retained last failure, no transcript or destination identity")
    }

    private static func testDisabledDoesNotWrite(_ directory: URL) throws {
        precondition(ProcessInfo.processInfo.environment[PasteDiagnostics.environmentKey] == nil,
                     "The test wrapper must remove the diagnostic environment variable")
        precondition(!PasteDiagnostics.shared.isEnabled)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let disabled = PasteDiagnostics(environment: [:])
        let empty = PasteDiagnostics(environment: [PasteDiagnostics.environmentKey: ""])
        let relative = PasteDiagnostics(environment: [PasteDiagnostics.environmentKey: "must-not-create.json"])
        for logger in [PasteDiagnostics.shared, disabled, empty, relative] {
            precondition(!logger.isEnabled)
            for _ in 0..<50 { logger.record(.init(tag: .capture, trusted: true), beginCapture: true) }
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(after == before)
        precondition(!FileManager.default.fileExists(atPath: "must-not-create.json"))
    }

    private static func testBoundedPrivateReport(_ directory: URL) throws {
        let output = directory.appendingPathComponent("bounded.json")
        let logger = PasteDiagnostics(environment: [PasteDiagnostics.environmentKey: output.path])
        precondition(logger.isEnabled)
        precondition(!FileManager.default.fileExists(atPath: output.path), "Initialization must not create a file")
        for index in 0..<55 {
            logger.record(.init(tag: .focusSystemQuery, queryResult: Int32(index)))
        }
        let first = try readReport(output)
        let events = first["events"] as! [[String: Any]]
        precondition(events.count == 40)
        precondition(events.first?["queryResult"] as? Int == 15)
        precondition(events.last?["queryResult"] as? Int == 54)
        let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        logger.record(.init(tag: .capture, trusted: true), beginCapture: true)
        logger.record(.init(tag: .snapshotCapabilities,
                            role: .init(attribute: "DO_NOT_RECORD_ROLE_CONTENT"),
                            subrole: .init(attribute: "DO_NOT_RECORD_SUBROLE_CONTENT")))
        let restarted = try readReport(output)["events"] as! [[String: Any]]
        precondition(restarted.count == 2)
        precondition(restarted.last?["role"] as? String == "other")
        precondition(restarted.last?["subrole"] as? String == "other")
        logger.record(.init(tag: .learningStart, learningStage: .range,
                            learningReason: .rangeUnavailable, selectionAvailable: true,
                            selectionCollapsed: true, characterCountAvailable: true,
                            rangeReadable: false, rangeReadMethod: .attributed))
        let learningEvent = (try readReport(output)["events"] as! [[String: Any]]).last!
        precondition(learningEvent["learningStage"] as? String == "range")
        precondition(learningEvent["learningReason"] as? String == "rangeUnavailable")
        precondition(learningEvent["rangeReadMethod"] as? String == "attributed")
        let text = try String(contentsOf: output, encoding: .utf8)
        precondition(!text.contains("DO_NOT_RECORD"))
        let leftoverTemporaryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".neighbor-paste-") }
        precondition(leftoverTemporaryFiles.isEmpty)
    }

    private static func testFailureSurvivesNextCapture(_ directory: URL) throws {
        let output = directory.appendingPathComponent("last-failure.json")
        let environment = [PasteDiagnostics.environmentKey: output.path]
        let logger = PasteDiagnostics(environment: environment)
        logger.record(.init(tag: .capture, trusted: true), beginCapture: true)
        logger.record(.init(tag: .recordingStop, stopMethod: .hudButton))
        logger.record(.init(tag: .validation, elementMatches: false, windowMatches: true))
        logger.record(.init(tag: .insertionResult, failure: .targetChanged, copySucceeded: true))
        let failure = try readReport(output)["lastFailure"] as! [[String: Any]]
        precondition(failure.count == 4 && failure.last?["failure"] as? String == "targetChanged")
        logger.record(.init(tag: .capture, trusted: true), beginCapture: true)
        logger.record(.init(tag: .recordingStop, stopMethod: .shortcut))
        logger.record(.init(tag: .insertionResult, copySucceeded: true, postEventReturned: true))
        for _ in 0..<50 { logger.record(.init(tag: .stateChange, state: .idle)) }
        let report = try readReport(output)
        precondition(report["schemaVersion"] as? Int == 3)
        precondition((report["events"] as! [[String: Any]]).count == 40)
        let saved = report["lastFailure"] as! [[String: Any]]
        precondition(NSArray(array: saved).isEqual(to: failure), "A later success must not erase a failure")
        precondition(saved[1]["stopMethod"] as? String == "hudButton")

        let relaunched = PasteDiagnostics(environment: environment)
        relaunched.record(.init(tag: .startup))
        let restored = try readReport(output)["lastFailure"] as! [[String: Any]]
        precondition(NSArray(array: restored).isEqual(to: failure),
                     "Relaunching the same opt-in diagnostic session preserves its failure")
        relaunched.record(.init(tag: .capture), beginCapture: true)
        relaunched.record(.init(tag: .insertionResult, failure: .accessibilityDenied, copySucceeded: true))
        let latest = try readReport(output)["lastFailure"] as! [[String: Any]]
        precondition(latest.count == 2 && latest.last?["failure"] as? String == "accessibilityDenied")
        let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        var legacy = try readReport(output)
        legacy["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: legacy).write(to: output)
        PasteDiagnostics(environment: environment).record(.init(tag: .startup))
        let migrated = try readReport(output)
        precondition(migrated["schemaVersion"] as? Int == 3)
        precondition(NSArray(array: migrated["lastFailure"] as! [[String: Any]]).isEqual(to: latest),
                     "Upgrading diagnostics must preserve the existing schema-2 failure")
    }

    private static func testFocusTrace(_ directory: URL) throws {
        var reads = 0
        let disabled = DictationFocusTrace(logger: PasteDiagnostics(environment: [:]), read: {
            reads += 1
            return .init(trusted: true)
        })
        disabled.begin(method: .shortcut)
        disabled.checkpoint(.recording)
        precondition(reads == 0 && !disabled.isActive, "Normal launches must not query extra accessibility data")

        let output = directory.appendingPathComponent("focus-trace.json")
        let logger = PasteDiagnostics(environment: [PasteDiagnostics.environmentKey: output.path])
        let editor = NSObject(), page = NSObject(), window = NSObject()
        let editable = DictationFocusTrace.Element(reference: editor, window: window, queryResult: 0,
            available: true, ownerMatches: true, role: .textArea, focused: true, localEligible: true)
        let container = DictationFocusTrace.Element(reference: page, window: window, queryResult: 0,
            available: true, ownerMatches: true, role: .webArea, focused: true, localEligible: false)
        var observation = DictationFocusTrace.Observation(trusted: true, foregroundPID: 42,
            foregroundIsSelf: false, foregroundUnchanged: true, system: container, application: editable)
        let trace = DictationFocusTrace(logger: logger, read: { reads += 1; return observation }, matches: { $0 === $1 })
        trace.begin(method: .hudButton)
        trace.checkpoint(.afterControls)
        observation.application = container
        trace.checkpoint(.beforeStop)
        observation.foregroundPID = 84
        observation.application = .init(reference: NSObject(), window: NSObject(), queryResult: 0,
            available: true, ownerMatches: true, role: .textArea, focused: true, localEligible: true)
        trace.checkpoint(.beforeDelivery)
        trace.end()
        let priorReads = reads
        trace.checkpoint(.recording)
        precondition(reads == priorReads, "Idle sessions must stop observing focus")
        let events = try readReport(output)["events"] as! [[String: Any]]
        let checkpoints = events.filter { $0["tag"] as? String == "focus.checkpoint" }
        precondition(checkpoints.count == 8)
        let appEvents = checkpoints.filter { $0["focusSource"] as? String == "application" }
        precondition(appEvents[0]["role"] as? String == "AXTextArea")
        precondition(appEvents[0]["elementMatches"] as? Bool == true)
        precondition(appEvents[0]["startMethod"] as? String == "hudButton")
        precondition(appEvents[2]["role"] as? String == "AXWebArea")
        precondition(appEvents[2]["elementMatches"] as? Bool == false)
        precondition(appEvents[2]["processMatches"] as? Bool == true && appEvents[2]["windowMatches"] as? Bool == true,
                     "Losing the editor within the same window must differ from switching apps")
        precondition(appEvents[3]["processMatches"] as? Bool == false && appEvents[3]["windowMatches"] as? Bool == false)
        let forbidden: Set<String> = ["text", "transcript", "clipboard", "appName", "windowTitle", "pid", "foregroundPID",
                                      "bundleIdentifier", "reference", "window", "apiKey"]
        for event in events { precondition(forbidden.isDisjoint(with: event.keys)) }
    }

    private static func testServicesDoNotRecordContent(_ directory: URL) throws {
        let output = directory.appendingPathComponent("integration.json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--enabled-fixture"]
        var environment = ProcessInfo.processInfo.environment
        environment[PasteDiagnostics.environmentKey] = output.path
        child.environment = environment
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
        let report = try readReport(output)
        let events = report["events"] as! [[String: Any]]
        let tags = events.compactMap { $0["tag"] as? String }
        precondition(tags.contains("capture") && tags.contains("capture.result"))
        precondition(tags.contains("focus.checkpoint"), "Capture must retain the diagnostic checkpoint from before controls were dismissed")
        precondition(tags.contains("validation") && tags.contains("validation.result"))
        precondition(tags.contains("insertion") && tags.contains("insertion.result"))
        precondition(events.last?["postEventReturned"] as? Bool == true)
        let forbiddenKeys: Set<String> = ["text", "transcript", "clipboard", "appName", "windowTitle", "pid",
                                           "bundleIdentifier", "macName", "sessionID", "apiKey", "path"]
        for event in events { precondition(forbiddenKeys.isDisjoint(with: event.keys)) }
        let text = try String(contentsOf: output, encoding: .utf8)
        precondition(!text.contains("DO_NOT_RECORD"))
    }

    private static func runEnabledFixture() throws {
        precondition(PasteDiagnostics.shared.isEnabled)
        let element = NSObject()
        let window = NSObject()
        let now = Date(timeIntervalSince1970: 1_000)
        let focus = FocusTargetService(environment: .init(
            isAccessibilityTrusted: { true },
            currentSnapshot: {
                FocusTargetSnapshot(pid: 42, bundleIdentifier: "DO_NOT_RECORD_BUNDLE",
                                    appName: "DO_NOT_RECORD_APP", windowTitle: "DO_NOT_RECORD_TITLE",
                                    element: element, isEditable: true, windowElement: window)
            },
            elementsMatch: { $0 === $1 }, now: { now },
            newSessionID: { "DO_NOT_RECORD_SESSION" }, macName: { "DO_NOT_RECORD_MACHINE" }
        ))
        let insertion = TextInsertionService(focusTargets: focus, environment: .init(
            copyText: { _ in true }, postPasteEvent: { true }
        ))
        PasteDiagnostics.shared.record(.init(tag: .focusCheckpoint, startMethod: .shortcut, focusPhase: .beforeControls))
        let target = try focus.captureTarget(policy: .localDictation, beginDiagnosticCapture: false)
        precondition(insertion.insert("DO_NOT_RECORD_TRANSCRIPT", target: target) == .pasteEventPosted)
    }

    private static func readReport(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
