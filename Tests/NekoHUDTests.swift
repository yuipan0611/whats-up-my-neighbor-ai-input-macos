import AppKit

@main
struct NekoHUDTests {
    static func main() {
        for input: Float? in [nil, -.infinity, .infinity, .nan, -160, -48, -50] {
            precondition(NekoSignalMeter.normalizedPower(input) == 0, "Quiet or missing input must stay flat")
        }
        precondition(NekoSignalMeter.normalizedPower(-30) == 0.5)
        precondition(NekoSignalMeter.normalizedPower(-12) == 1)
        precondition(NekoSignalMeter.normalizedPower(0) == 1)
        var meter = NekoSignalMeter()
        meter.update(decibels: -20)
        precondition(meter.levels.first! > 0 && meter.levels.dropFirst().allSatisfy { $0 == 0 })
        let firstSample = meter.levels[0]
        meter.update(decibels: -30)
        precondition(meter.levels[0] == 0.5 && meter.levels[1] == firstSample, "Sound must enter from the left and move right")
        meter.update(decibels: nil)
        precondition(meter.levels.allSatisfy { $0 == 0 }, "Lost meter data must immediately flatten the head")
        meter.update(decibels: -20)
        meter.update(decibels: -60)
        precondition(meter.levels.allSatisfy { $0 == 0 }, "Silence must leave no idle teeth")
        meter.update(decibels: -30, reducedMotion: true)
        precondition(meter.levels.allSatisfy { $0 == 0.5 })

        let suite = "NekoIntroductionTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let introduction = NekoIntroductionPreferences(defaults: preferences)
        precondition(introduction.shouldShow, "Fresh users should see the guide")
        introduction.markShown()
        precondition(!NekoIntroductionPreferences(defaults: UserDefaults(suiteName: suite)!).shouldShow,
                     "A new controller must remember that the guide was shown")
        preferences.set("a-new-build", forKey: "nekoHUD.lastPresentedBuild")
        precondition(!introduction.shouldShow, "An application update must not repeat the guide")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let panel = NekoFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 230),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        precondition(!panel.canBecomeKey && !panel.canBecomeMain, "HUD must preserve the original typing target")
        let hud = NekoRecordingHUD(defaults: preferences)
        precondition(hud.testPanel.level == .statusBar,
                     "Recording HUD must remain above fullscreen application windows")
        precondition(!hud.testPanel.canHide,
                     "Closing settings must not hide the recording HUD with its app")
        precondition(hud.testPanel.collectionBehavior.contains(.canJoinAllSpaces)
                     && hud.testPanel.collectionBehavior.contains(.fullScreenAuxiliary)
                     && hud.testPanel.collectionBehavior.contains(.canJoinAllApplications),
                     "Recording HUD must join other applications' fullscreen Spaces")
        precondition(hud.testPanel.styleMask.contains(.nonactivatingPanel)
                     && !hud.testPanel.canBecomeKey && !hud.testPanel.canBecomeMain,
                     "Fullscreen visibility must preserve the original typing focus")
        hud.hide()
        let asset = NSImage(contentsOfFile: CommandLine.arguments[1])!
        precondition(asset.size.width > 0)
        let view = NekoRecordingView(image: asset)
        precondition(view.bounds.width <= 184 && view.bounds.height <= 112, "HUD must stay compact beside the editor")
        precondition(!view.mouseDownCanMoveWindow, "Voice HUD uses top/bottom anchors; free dragging belongs to the companion design")
        let screen = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let top = NekoRecordingHUD.origin(for: .topCenter, in: screen, size: view.bounds.size)
        let bottom = NekoRecordingHUD.origin(for: .bottomCenter, in: screen, size: view.bounds.size)
        precondition(top.x == screen.midX - view.bounds.width / 2 && bottom.x == top.x)
        precondition(top.y == screen.maxY - view.bounds.height - 12 && bottom.y == screen.minY + 12)
        panel.contentView = view
        let visibleStartButtons = {
            view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title.hasPrefix("開始錄音") }
        }
        let visibleLabels = {
            view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        }
        view.update(state: .idle)
        view.showMessage("已複製，請按 ⌘V", detail: "請點選要貼上的位置。", showsDetail: true)
        precondition(visibleLabels().map(\.stringValue).contains("請點選要貼上的位置。"),
                     "Copy-only recovery must explain what to do inside the nonactivating HUD")
        precondition(view.bounds.height == 146)
        precondition(visibleLabels().allSatisfy { view.bounds.contains($0.frame) && !$0.isSelectable })
        view.update(state: .recording)
        precondition(visibleLabels().isEmpty && view.bounds.height == 112,
                     "The next recording must remove the recovery hint and restore the compact cat")
        view.configurePreview(shortcut: "⌥↑", showIntroduction: false)
        precondition(visibleStartButtons().isEmpty && visibleLabels().isEmpty,
                     "Ordinary previews must show only the cat, without a start button or replacement hint")
        precondition(view.cancelButton.isEnabled && view.finishButton.isEnabled,
                     "Cat-only previews must preserve the eye actions")
        view.configurePreview(shortcut: "⌥↑", showIntroduction: true)
        precondition(visibleStartButtons().map(\.title) == ["開始錄音  ⌥↑"],
                     "First-use and explicitly requested guides must retain the start button")
        precondition(view.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue == "左眼取消，右眼完成。"
        })
        precondition(view.bounds.size == NSSize(width: 184, height: 138))
        view.configurePreview(shortcut: "⌥↑", showIntroduction: false)
        precondition(visibleStartButtons().isEmpty && visibleLabels().isEmpty && view.bounds.height == 112,
                     "Returning from an explicit guide to ordinary preview must remove all guidance")
        view.configurePreview(shortcut: "⌥↑", showIntroduction: true)
        view.update(state: .recording)
        precondition(visibleStartButtons().isEmpty && visibleLabels().isEmpty,
                     "Starting actual recording must clear the guide and its start button")
        precondition(view.bounds.size == NSSize(width: 184, height: 112), "Recording must return to the compact size")
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                      clickCount: 0, pressure: 0)!
        for button in [view.cancelButton, view.finishButton] {
            button.mouseMoved(with: hover)
            precondition(button.hovered, "Colored hover feedback must remain enabled")
            precondition(button.toolTip == nil, "No delayed system tooltip should appear")
            precondition(view.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.isHidden },
                         "Hover must not reveal a text label")
            precondition(!(button.accessibilityLabel() ?? "").isEmpty, "VoiceOver still needs button labels")
            button.mouseExited(with: hover)
            precondition(!button.hovered)
        }
        var cancellations = 0, finishes = 0
        view.onCancel = { cancellations += 1 }
        view.onFinish = { finishes += 1 }
        for state: DictationState in [.idle, .starting, .recording, .finalizing, .transcribing, .awaitingRetry, .delivering] {
            view.update(state: state)
            if state == .recording {
                view.updateMeter(decibels: -30, elapsed: 10)
                let visibleText = view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
                precondition(visibleText.isEmpty, "Recording must not show a status line or elapsed time")
            }
            let beforeCancel = cancellations, beforeFinish = finishes
            view.cancelButton.performClick(nil)
            view.finishButton.performClick(nil)
            let cancellable = state != .idle && state != .delivering
            precondition(cancellations - beforeCancel == (cancellable ? 1 : 0))
            precondition(finishes - beforeFinish == (state == .recording ? 1 : 0), "Finish must be disabled during finalization/transcription")
            precondition(view.cancelButton.frame.width >= 44 && view.cancelButton.frame.height >= 44)
            precondition(view.finishButton.frame.width >= 44 && view.finishButton.frame.height >= 44)
        }
        precondition(NekoHUDPresentation(state: .transcribing).cancelLabel == "取消處理")
        precondition(NekoHUDPresentation(state: .recording).cancelLabel == "取消錄音")
        print("Neko HUD tests passed: real signal gating, flat silence, reduced motion, non-activating panel, state-gated actions and hit targets")
    }
}
