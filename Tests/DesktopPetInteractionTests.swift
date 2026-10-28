import AppKit

@main
struct DesktopPetInteractionTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        let area = CGRect(x: 0, y: 0, width: 1000, height: 700)
        var world = DesktopPetWorld(areas: [area], cursor: CGPoint(x: 50, y: 600), idleSeconds: 0)
        var model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 0, world: world)
        let initial = model.origin
        var transfer = DesktopPetModel(seed: 43)
        transfer.setReleased(true, now: 0, world: world)
        let saved = transfer.origin
        transfer.relocateForTransfer(to: CGPoint(x: 600, y: 150), now: 0.1, world: world)
        expect(transfer.origin == CGPoint(x: 600, y: 150), "transfer can place the original cat at the VPS edge")
        transfer.arriveFromTransfer(at: saved, now: 1, world: world)
        expect(transfer.origin == saved && transfer.isSettling &&
               DesktopPetLift.sourceImageIndex(for: transfer.lift.spriteFrame) == 19,
               "return changes location immediately and begins the approved held drawing")
        transfer.tick(now: 1.41, world: world)
        expect(!transfer.isSettling && DesktopPetLift.sourceImageIndex(for: transfer.lift.spriteFrame) == 35,
               "return stops on the accepted seated drawing")
        for step in 1...20 {
            world.cursor = CGPoint(x: CGFloat(step * 43), y: CGFloat(step * 29))
            model.tick(now: Double(step) / 4, world: world)
            expect(model.origin == initial && model.pose == .sitting, "moving mouse cannot attract or animate the cat")
            expect(model.visible, "moving mouse cannot hide the clickable cat")
        }
        let grip = CGPoint(x: model.origin.x + 50, y: model.origin.y + 70)
        model.pointerDown(at: grip, now: 6, world: world)
        model.pointerDragged(to: CGPoint(x: grip.x + 2, y: grip.y + 1), now: 6.1, world: world)
        expect(model.isPressed && !model.isDragging && model.origin == initial, "small click jitter is not a drag")
        model.pointerUp(now: 6.2, world: world)
        expect(model.pose == .petted && !model.isPressed, "only mouse-up completes a click")
        model.tick(now: 6.8, world: world)
        expect(model.pose == .petted && model.phase > 0, "click response remains visible despite active mouse")
        model.tick(now: 8, world: world)
        expect(model.pose == .sitting && model.origin == initial, "click response expires without moving the cat")

        model.pointerDown(at: grip, now: 9, world: world)
        model.pointerDragged(to: CGPoint(x: grip.x - 240, y: grip.y + 180), now: 9.1, world: world)
        let dragged = model.origin
        expect(model.pose == .carried && model.isDragging, "crossing drag threshold picks cat up")
        expect(dragged == CGPoint(x: initial.x - 240, y: initial.y + 180), "drag preserves exact grab offset")
        model.tick(now: 9.4, world: world)
        expect(model.origin == dragged && model.pose == .carried, "autonomous movement cannot interrupt a held cat")
        model.pointerUp(now: 9.5, world: world)
        expect(model.pose == .sitting && !model.isDragging && model.origin == dragged, "drop sits at release position without click response")
        model.pointerDragged(to: .zero, now: 9.6, world: world)
        expect(model.origin == dragged, "mouse move after release cannot drag or chase")
        model.pointerUp(now: 9.7, world: world)
        expect(model.pose == .sitting, "duplicate mouse-up is ignored")

        let again = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: again, now: 10, world: world)
        model.pointerDragged(to: CGPoint(x: 9000, y: 9000), now: 10.1, world: world)
        expect(area.contains(model.frame), "drag clamps the whole cat within a display")
        world.hidden = true
        model.tick(now: 10.2, world: world)
        expect(!model.visible && !model.isPressed && !model.isDragging, "lock or suspension cancels an active drag")
        model.pointerUp(now: 10.3, world: world)
        expect(model.pose != .petted, "cancelled drag cannot produce a delayed click")
        world.hidden = false
        model.tick(now: 10.4, world: world)
        model.pointerDown(at: again, now: 11, world: world)
        model.setReleased(false, now: 11.1, world: world)
        expect(!model.visible && !model.isPressed && !model.isDragging, "recall cancels interaction")
        model.pointerUp(now: 11.2, world: world)
        expect(!model.visible, "recall cannot be undone by late release")

        world.areas.append(CGRect(x: -1400, y: -200, width: 1400, height: 900))
        model.setReleased(true, now: 12, world: world)
        model.pointerDown(at: CGPoint(x: model.frame.midX, y: model.frame.midY), now: 12.1, world: world)
        model.pointerDragged(to: CGPoint(x: -500, y: 400), now: 12.2, world: world)
        expect(world.areas[1].contains(model.frame), "drag crosses into a negative-origin monitor")
        model.pointerUp(now: 12.3, world: world)
        world.areas = [area]
        model.tick(now: 12.4, world: world)
        expect(area.contains(model.frame), "display removal recovers a dropped cat")

        world = DesktopPetWorld(areas: [area], cursor: CGPoint(x: 20, y: 600), idleSeconds: 30)
        model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 0, world: world)
        var poses = Set<DesktopPetPose>()
        for step in 0...3000 {
            model.tick(now: Double(step) / 4, world: world)
            poses.insert(model.pose)
            expect(area.contains(model.frame), "idle animation stays within bounds")
        }
        expect(poses.contains(.grooming) && poses.contains(.walking) && poses.contains(.sleeping), "idle reaches washing, walking and sleep")
        expect(!poses.contains(.petted) && !poses.contains(.carried), "idle cannot pretend the user interacted")

        // Cursor-independent seeded destinations while idle: no pursuit, even
        // when the user moves the pointer around the cat's own frame.
        var other = DesktopPetModel(seed: 42)
        model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 0, world: world)
        other.setReleased(true, now: 0, world: world)
        for step in 1...200 {
            let now = Double(step) / 4
            model.tick(now: now, world: world)
            var shifted = world
            shifted.cursor = CGPoint(x: CGFloat(step % 10) * 90, y: CGFloat(step % 7) * 90)
            other.tick(now: now, world: shifted)
            expect(model.origin == other.origin && model.pose == other.pose, "idle movement is independent of pointer position")
        }
        world.reduceMotion = true
        world.idleSeconds = 90
        model.tick(now: 51, world: world)
        expect(model.phase == 0 && !model.isTravelling, "reduce-motion disables autonomous movement")

        var testTime: Double = 0
        world = DesktopPetWorld(areas: [area], cursor: CGPoint(x: 10, y: 600), idleSeconds: 0)
        var buttons = 1
        let controller = DesktopPetController(resources: resources, automaticallyTicks: false, world: { world },
                                             clock: { testTime }, pressedButtons: { buttons })
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let key = NSApp.keyWindow, main = NSApp.mainWindow
        var releaseChanges: [Bool] = []
        controller.onReleasedChange = { releaseChanges.append($0) }
        let petPanel = controller.testPanel, petArtwork = controller.testArtwork
        controller.show(appearance: CatAppearance.makePreset("white")!)
        expect(controller.isReleased && controller.testPanel.isVisible && releaseChanges == [true],
               "an explicit coat choice releases a recalled pet and publishes the persisted release state")
        controller.show(appearance: .original)
        expect(controller.testPanel === petPanel && controller.testArtwork === petArtwork && releaseChanges == [true],
               "switching visible coats retains the controller, window, view and release state")
        expect(!controller.testPanel.canBecomeKey && !controller.testPanel.canBecomeMain, "pet panel cannot take keyboard focus")
        expect(controller.testPanel.styleMask.contains(.nonactivatingPanel), "pet panel is nonactivating")
        let frame = controller.model.frame
        expect(controller.testPanel.frame.origin == CGPoint(x: frame.minX - 40, y: frame.minY - 64),
               "expanded visual panel preserves the nominal grab coordinate system")
        expect(controller.testPanel.frame.size == CGSize(width: 208, height: 192), "hanging paws fit inside visual padding")
        controller.updateHitRegion(at: CGPoint(x: controller.testPanel.frame.minX + 2, y: controller.testPanel.frame.minY + 2))
        expect(controller.testPanel.ignoresMouseEvents, "new hanging-body padding remains click-through")
        controller.updateHitRegion(at: CGPoint(x: frame.minX + 1, y: frame.minY + 1))
        expect(controller.testPanel.ignoresMouseEvents, "transparent padding passes mouse events through")
        controller.updateHitRegion(at: CGPoint(x: frame.minX + 64, y: frame.minY + 65))
        expect(!controller.testPanel.ignoresMouseEvents, "cat body accepts an intentional click")
        controller.pointerDown(at: CGPoint(x: frame.midX, y: frame.midY))
        testTime = 0.1
        controller.pointerUp()
        expect(controller.model.pose == .petted, "controller forwards completed click")
        let petOrigin = controller.model.origin, petPhase = controller.model.phase
        controller.show(appearance: CatAppearance.makePreset("calico")!)
        expect(controller.model.pose == .petted && controller.model.origin == petOrigin && controller.model.phase == petPhase,
               "changing coat preserves a live interaction's pose, position and animation progress")
        controller.show(appearance: .original)
        expect(NSApp.keyWindow === key && NSApp.mainWindow === main &&
               NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "click and coat changes preserve foreground and typing target")
        controller.pointerDown(at: CGPoint(x: frame.midX, y: frame.midY))
        controller.pointerDragged(to: CGPoint(x: frame.midX - 100, y: frame.midY + 100))
        expect(controller.model.isDragging, "native controller forwards dragging")
        buttons = 0
        testTime = 0.2
        controller.refresh()
        expect(!controller.model.isDragging && controller.model.pose == .sitting, "lost mouse-up recovers on next tick without click")
        let finalOrigin = controller.model.origin
        controller.pointerDragged(to: .zero)
        expect(controller.model.origin == finalOrigin, "late drag after recovered release is ignored")
        buttons = 1
        testTime = 0.3
        controller.pointerDown(at: CGPoint(x: controller.model.frame.midX, y: controller.model.frame.midY))
        controller.pointerDragged(to: CGPoint(x: frame.midX - 160, y: frame.midY + 140))
        controller.isBusy = { true }
        controller.refresh()
        expect(!controller.model.visible && !controller.model.isPressed && !controller.model.isSettling,
               "recording or clipboard selection cancels dragging and landing")
        expect(controller.testPanel.ignoresMouseEvents, "busy app never intercepts desktop input")
        controller.isBusy = { false }
        controller.refresh()
        controller.testSuspend(true)
        expect(!controller.testPanel.isVisible && controller.testPanel.ignoresMouseEvents, "suspended panel is invisible and cannot block clicks")
        controller.show(appearance: CatAppearance.makePreset("blue")!)
        expect(!controller.testPanel.isVisible && controller.isReleased, "coat selection respects screen-lock suspension")
        controller.show(appearance: .original)
        controller.testSuspend(false)
        controller.setReleased(false)
        expect(!controller.testPanel.isVisible, "recalled preview panel stays hidden")
        // Deliver native AppKit events through the real window/responder path,
        // in addition to the deterministic model and callback checks above.
        controller.setReleased(true)
        testTime = 1
        let nativeStart = controller.model.origin
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: testTime,
                windowNumber: controller.testPanel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        controller.testPanel.sendEvent(mouse(.leftMouseDown, CGPoint(x: 104, y: 129)))
        expect(controller.model.isPressed, "native window mouse-down reaches the cat responder")
        testTime = 1.1
        controller.testPanel.sendEvent(mouse(.leftMouseDragged, CGPoint(x: 64, y: 149)))
        expect(controller.model.isDragging && controller.model.pose == .carried,
               "native window drag reaches the production pickup state")
        expect(controller.model.origin == CGPoint(x: nativeStart.x - 40, y: nativeStart.y + 20),
               "native event coordinates retain the exact screen grab offset")
        testTime = 1.17
        controller.refresh()
        testTime = 1.2
        controller.testPanel.sendEvent(mouse(.leftMouseUp, CGPoint(x: 104, y: 129)))
        expect(!controller.model.isPressed && controller.model.isSettling,
               "native window mouse-up starts the release animation")
        controller.setReleased(false)
        controller.dispose()

        var transferNow: Double = 30
        let sameCat = DesktopPetController(resources: resources, automaticallyTicks: false, world: { world },
                                           clock: { transferNow }, pressedButtons: { 1 })
        var hostedEvents: [Bool] = []
        var remoteFrames = 0
        sameCat.onRemoteHostedChange = { hostedEvents.append($0) }
        sameCat.onRemoteFrame = { _, _, _ in remoteFrames += 1 }
        sameCat.setReleased(true)
        let homeBeforeVPS = sameCat.model.origin
        let firstGrip = CGPoint(x: homeBeforeVPS.x + 55, y: homeBeforeVPS.y + 60)
        sameCat.pointerDown(at: firstGrip)
        transferNow += 0.1
        sameCat.pointerDragged(to: CGPoint(x: firstGrip.x - 100, y: firstGrip.y + 60))
        sameCat.pointerUp(at: CGPoint(x: 700, y: 400))
        expect(sameCat.parkInVPS() && sameCat.remoteHosted && !sameCat.testPanel.isVisible,
               "existing cat is hidden locally after entering VPS, without another cat panel")
        expect(sameCat.model.origin == homeBeforeVPS && remoteFrames > 0 && hostedEvents == [true],
               "VPS retains the original home position and receives the same model's animation")
        transferNow += 0.5
        sameCat.refresh()
        let remoteArtworkRect = CGRect(x: 600, y: 350, width: 208, height: 192)
        let remoteGrip = CGPoint(x: 700, y: 440)
        sameCat.beginVPSDrag(at: remoteGrip, from: remoteArtworkRect)
        expect(!sameCat.remoteHosted && sameCat.testPanel.isVisible && sameCat.testPanel.frame.size == CGSize(width: 208, height: 192),
               "dragging out reuses the one original desktop cat panel")
        transferNow += 0.1
        sameCat.pointerDragged(to: CGPoint(x: 300, y: 400))
        sameCat.pointerUp(at: CGPoint(x: 300, y: 400))
        expect(!sameCat.remoteHosted && sameCat.model.frame.midX < remoteArtworkRect.minX,
               "releasing outside VPS leaves the original cat on the local desktop")
        sameCat.pointerDown(at: CGPoint(x: sameCat.model.frame.midX, y: sameCat.model.frame.midY))
        transferNow += 0.1
        sameCat.pointerDragged(to: CGPoint(x: 690, y: 420))
        sameCat.pointerUp(at: CGPoint(x: 690, y: 420))
        expect(sameCat.parkInVPS() && sameCat.remoteHosted, "the same cat can enter VPS again")
        transferNow += 0.5
        sameCat.returnFromVPS()
        expect(!sameCat.remoteHosted && sameCat.testPanel.isVisible && sameCat.model.isSettling &&
               DesktopPetLift.sourceImageIndex(for: sameCat.model.lift.spriteFrame) == 19,
               "return button switches the original cat home immediately, then lands")
        sameCat.dispose()

        // Exercise a real screen callback as well as deterministic model time.
        // No synthetic OS mouse events are posted; button state is a fixture.
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            var pulseTime: Double = 0
            let pulseWorld = DesktopPetWorld(areas: [screen.visibleFrame], cursor: screen.visibleFrame.origin)
            let pulse = DesktopPetController(resources: resources, world: { pulseWorld },
                clock: { pulseTime }, pressedButtons: { 1 })
            pulse.setReleased(true)
            let point = CGPoint(x: pulse.model.frame.midX, y: pulse.model.frame.midY)
            pulse.pointerDown(at: point)
            pulseTime = 0.01
            pulse.pointerDragged(to: CGPoint(x: point.x - 30, y: point.y + 40))
            expect(pulse.usesDisplaySynchronization, "active pickup uses the screen display link")
            pulseTime = 0.11
            let deadline = Date(timeIntervalSinceNow: 0.5)
            while pulse.model.phase < 0.09 && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            expect(pulse.model.phase >= 0.09, "a real display callback advances pickup without a timer or manual refresh")
            pulse.testSuspend(true)
            expect(!pulse.usesDisplaySynchronization && !pulse.testPanel.isVisible,
                   "suspending the preview stops the screen callback and hides its panel")
            pulse.testSuspend(false)
            pulse.setReleased(false)
            expect(!pulse.usesDisplaySynchronization, "recall leaves no active display link")
            pulse.dispose()
        }

        let view = DesktopPetView(resources: resources)
        expect(view.loadedPickupFrames == 36, "all direct Gemini source assets load into the native renderer")
        let timingData = try Data(contentsOf: resources.appendingPathComponent("Pickup/timing.json"))
        let timing = try JSONSerialization.jsonObject(with: timingData) as! [String: Any]
        let playback = timing["playback"] as! [String: Any]
        let positions = playback["positions"] as! [Double]
        let times = playback["times"] as! [Double]
        let sources = playback["source_indices"] as! [Int]
        expect((timing["records"] as! [[String: Any]]).count == 36, "all source PNG provenance remains available")
        expect(positions.count == 28 && times.count == 28 && sources.count == 28,
               "active playback declares 28 selected complete drawings")
        expect(sources == DesktopPetLift.sourceImageIndices, "packaged source map agrees with the renderer")
        expect(Array(sources.prefix(27)) == Array(0...26) && sources.last == 35,
               "pickup remains unchanged and landing ends on native source35 at its original size")
        expect(zip(positions, DesktopPetLift.framePositions).allSatisfy { abs($0 - Double($1)) < 0.0000001 },
               "native pose selection matches the packaged image order")
        expect(zip(times, DesktopPetLift.frameTimes).allSatisfy { abs($0 - $1) < 0.0000001 },
               "bundle and native player agree on each drawing timestamp")

        expect(!view.containsCat(CGPoint(x: 1, y: 1)), "alpha mask rejects transparent padding")
        expect(view.containsCat(CGPoint(x: 104, y: 63)), "alpha mask accepts central body")
        expect(view.renderPNG(pose: .carried, phase: 0) == view.renderPNG(pose: .sitting, phase: 0),
               "pickup starts from the original sitting image without a double silhouette")

        world = DesktopPetWorld(areas: [area], idleSeconds: 0)
        model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 0, world: world)
        let pickup = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: pickup, now: 0, world: world)
        model.pointerDragged(to: CGPoint(x: pickup.x - 40, y: pickup.y + 10), now: 0.1, world: world)
        model.pointerDragged(to: CGPoint(x: pickup.x - 60, y: pickup.y + 10), now: 0.14, world: world)
        expect(model.carryLean < 0 && model.carryLean >= -5, "left drag creates bounded side-body inertia")
        let tilt = abs(model.carryLean)
        for i in 1...10 { model.tick(now: 0.14 + Double(i) / 24, world: world) }
        expect(abs(model.carryLean) < tilt * 0.1, "held still settles quickly instead of swaying forever")
        model.pointerUp(now: 0.6, world: world)
        expect(model.isSettling && model.carryLean == 0, "drop starts a bounded settle and clears carried tilt")
        world.hidden = true
        model.tick(now: 0.7, world: world)
        expect(!model.isSettling, "suspension cancels landing feedback")
        world.hidden = false; world.reduceMotion = true
        model.setReleased(true, now: 1, world: world)
        model.pointerDown(at: pickup, now: 1, world: world)
        model.pointerDragged(to: CGPoint(x: pickup.x - 40, y: pickup.y + 10), now: 1.1, world: world)
        expect(model.isDragging && model.carryLean == 0 && model.phase == 0, "reduce motion keeps explicit dragging without secondary movement")
        view.reduceMotion = true
        expect(view.renderPNG(pose: .carried, phase: 0) == view.renderPNG(pose: .carried, phase: 1),
               "reduce motion has one static carried image with no arrival or sway")
        model.pointerUp(now: 1.2, world: world)
        expect(!model.isSettling, "reduce motion disables drop compression")
        view.reduceMotion = false

        // R3: release and rapid re-grab must preserve the rendered silhouette,
        // including when pickup has not reached its hanging pose yet.
        world.reduceMotion = false
        model.setReleased(true, now: 2, world: world)
        let quickGrip = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: quickGrip, now: 2, world: world)
        model.pointerDragged(to: CGPoint(x: quickGrip.x - 20, y: quickGrip.y + 20), now: 2.02, world: world)
        model.tick(now: 2.1, world: world)
        expect(model.lift.shoulder > model.lift.hip && model.lift.hip > model.lift.paws,
               "shoulders lead hips and paws during pickup")
        let beforeRelease = model.lift
        let beforePNG = view.renderPNG(pose: .carried, lift: beforeRelease)
        model.pointerUp(now: 2.1, world: world)
        expect(model.lift == beforeRelease, "release preserves an unfinished pickup instead of swapping images")
        expect(view.renderPNG(pose: model.pose, isSettling: true, lift: model.lift) == beforePNG,
               "first landing frame is pixel-identical to the last held silhouette")
        model.tick(now: 2.18, world: world)
        let midLanding = model.lift
        expect(midLanding.shoulder < beforeRelease.shoulder, "landing continuously returns toward sitting")
        let reGrip = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: reGrip, now: 2.18, world: world)
        model.tick(now: 2.19, world: world)
        expect(model.lift == midLanding, "pressing during landing holds the current silhouette")
        model.pointerDragged(to: CGPoint(x: reGrip.x + 20, y: reGrip.y + 10), now: 2.2, world: world)
        expect(model.lift == midLanding, "re-grab starts from the exact partial landing silhouette including lean")
        for i in 1...12 { model.tick(now: 2.2 + Double(i) / 24, world: world) }
        let held = model.lift
        let heldPNG = view.renderPNG(pose: .carried, lift: held)
        model.pointerUp(now: 2.7, world: world)
        expect(view.renderPNG(pose: .sitting, isSettling: true, lift: model.lift) == heldPNG,
               "a fully lifted release also preserves head, body, paws and lean")
        model.tick(now: 2.7 + held.returnDuration + 0.01, world: world)
        expect(!model.isSettling && model.lift.shoulder == 0 && model.lift.paws == 0, "landing finishes without residual articulated motion")

        // Full pickup follows the Gemini landing sequence, while a short drag
        // returns along the partial pickup. Re-grab retains the selected image.
        world = DesktopPetWorld(areas: [area], idleSeconds: 0)
        model.setReleased(true, now: 10, world: world)
        let spriteGrip = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: spriteGrip, now: 10, world: world)
        model.pointerDragged(to: CGPoint(x: spriteGrip.x - 40, y: spriteGrip.y + 100), now: 10.01, world: world)
        model.tick(now: 10.9, world: world)
        expect(model.lift.spriteFrame == DesktopPetLift.carryFrame, "full pickup reaches the generated hanging pose")
        model.pointerUp(now: 10.9, world: world)
        model.tick(now: 11.01, world: world)
        expect(model.lift.spriteFrame > DesktopPetLift.carryFrame && model.lift.spriteFrame < DesktopPetLift.lastFrame,
               "fully lifted drop traverses the generated support and crouch frames")
        let dropImage = model.lift
        model.pointerDown(at: spriteGrip, now: 11.01, world: world)
        model.pointerDragged(to: CGPoint(x: spriteGrip.x + 40, y: spriteGrip.y + 100), now: 11.02, world: world)
        expect(model.lift == dropImage, "re-grab preserves the exact Gemini frame and captured lean")
        for i in 1...24 {
            model.tick(now: 11.02 + Double(i) / 60, world: world)
            expect(model.lift.spriteFrame >= 0 && model.lift.spriteFrame <= DesktopPetLift.lastFrame, "interrupted frame path stays within the atlas")
        }
        model.cancelPointer(now: 11.5)
        model.pointerDown(at: spriteGrip, now: 11.6, world: world)
        model.pointerDragged(to: CGPoint(x: spriteGrip.x - 40, y: spriteGrip.y + 100), now: 11.61, world: world)
        model.tick(now: 11.7, world: world)
        let earlyFrame = model.lift.spriteFrame
        model.pointerUp(now: 11.7, world: world)
        model.tick(now: 11.75, world: world)
        expect(model.lift.spriteFrame < earlyFrame, "short pickup returns along its current path without jumping to landing")
        model.cancelPointer(now: 11.8)

        // A click interrupting a landing waits for the remaining visual return;
        // switching Reduce Motion while that press is held clears stale motion.
        model.pointerDown(at: reGrip, now: 3.2, world: world)
        model.pointerDragged(to: CGPoint(x: reGrip.x + 30, y: reGrip.y + 10), now: 3.25, world: world)
        model.tick(now: 3.65, world: world)
        model.pointerUp(now: 3.65, world: world)
        model.tick(now: 3.7, world: world)
        let clickedLanding = model.lift
        model.pointerDown(at: reGrip, now: 3.7, world: world)
        model.pointerUp(now: 3.72, world: world)
        expect(model.lift == clickedLanding && model.isSettling, "click during landing resumes that silhouette")
        model.tick(now: 4.7, world: world)
        expect(model.pose == .petted && !model.isSettling, "queued click response plays after landing")
        model.pointerDown(at: reGrip, now: 5.2, world: world)
        model.pointerDragged(to: CGPoint(x: reGrip.x - 30, y: reGrip.y + 10), now: 5.25, world: world)
        model.tick(now: 5.65, world: world)
        model.pointerUp(now: 5.65, world: world)
        model.tick(now: 5.7, world: world)
        model.pointerDown(at: reGrip, now: 5.7, world: world)
        world.reduceMotion = true
        model.tick(now: 5.72, world: world)
        world.reduceMotion = false
        model.tick(now: 5.73, world: world)
        expect(model.lift == DesktopPetLift() && !model.isSettling,
               "Reduce Motion toggle while pressing cannot revive a frozen landing")
        model.pointerUp(now: 5.75, world: world)

        // Unchanged drawings keep 50ms dwell; only the repaired segment has
        // a denser sequence of actual source PNGs with explicit timestamps.
        for step in 0...100 {
            let now = Double(step) / 100
            let state = DesktopPetLift.lifting(elapsed: now, lean: 0)
            if step <= 35 || step >= 55 {
                expect(state.spriteFrame == min(15, CGFloat((step <= 35 ? step : step - 10) / 5)),
                       "drawings outside 08→10 keep their original 50ms timing")
            }
        }
        // Explicit expected poses verify every hand-drawn in-between, including
        // its boundary, hold interval, reverse return and renderer selection.
        let segment: [CGFloat] = [7, 7 + 1.0/3, 7 + 2.0/3, 8, 8 + 1.0/3, 8 + 2.0/3, 9]
        let segmentTimes = [0.35, 0.35 + 4.0/60, 0.35 + 5.0/60, 0.45, 0.35 + 8.0/60, 0.35 + 10.0/60, 0.55]
        for index in segment.indices {
            let time = segmentTimes[index]
            let selected = DesktopPetLift.lifting(elapsed: time, lean: 0).spriteFrame
            expect(abs(selected - segment[index]) < 0.000001, "all five genuine drawings have distinct 60Hz slots")
            if index < 6 {
                expect(DesktopPetLift.lifting(elapsed: segmentTimes[index + 1] - 0.00001, lean: 0).spriteFrame == selected,
                       "a new source drawing holds until its next real drawing")
            }
            let reverse = DesktopPetLift.travel(from: 9, to: 7, elapsed: 0.55 - segmentTimes[index])
            expect(abs(reverse - segment[index]) < 0.000001, "reverse traverses the same drawn poses without resynthesis")
            expect(DesktopPetLift.imageIndex(for: selected) == 7 + index, "logical pose selects the exact PNG in the expanded bundle")
            let caught = DesktopPetLift(spriteFrame: selected)
            expect(caught.landing(elapsed: 0).spriteFrame == selected, "release retains every inserted drawing exactly")
            expect(DesktopPetLift.lifting(from: caught, elapsed: 0, lean: 0).spriteFrame == selected,
                   "re-grab retains every inserted drawing exactly")
        }
        expect(DesktopPetLift.pickupDuration == 0.85 && DesktopPetLift.landingDuration == 0.4,
               "pickup remains 850ms and restored landing preserves the approved 400ms duration")
        let fullPose = DesktopPetLift(shoulder: 1, hip: 1, paws: 1, spriteFrame: DesktopPetLift.carryFrame)
        for step in 0...90 {
            let state = fullPose.landing(elapsed: Double(step) / 100)
            expect(state.spriteFrame == min(23, CGFloat(15 + step / 5)),
                   "landing advances one selected drawing per 50ms and retains its last frame")
        }
        expect(abs(fullPose.returnDuration - 0.4) < 0.0000001,
               "the actual restored landing timeline lasts 400ms")
        for rate in [30, 60, 120] {
            var landingModel = DesktopPetModel(seed: 42)
            landingModel.setReleased(true, now: 40, world: world)
            let grip = CGPoint(x: landingModel.frame.midX, y: landingModel.frame.midY)
            landingModel.pointerDown(at: grip, now: 40, world: world)
            landingModel.pointerDragged(to: CGPoint(x: grip.x - 40, y: grip.y + 20), now: 40.01, world: world)
            landingModel.tick(now: 41, world: world)
            landingModel.pointerUp(now: 41, world: world)
            var visitedSources: Set<Int> = []
            for step in 0...(rate * 3 / 2) {
                let elapsed = Double(step) / Double(rate)
                landingModel.tick(now: 41 + elapsed, world: world)
                let source = DesktopPetLift.sourceImageIndex(for: landingModel.lift.spriteFrame)
                visitedSources.insert(source)
                expect(!(27...34).contains(source), "actual landing never replays the rebound tail")
                if elapsed < 0.4 {
                    expect(landingModel.isSettling, "restored landing keeps its approved 400ms duration")
                } else if elapsed > 0.4 {
                    expect(!landingModel.isSettling && source == 35,
                           "after 400ms the original sitting image stays still")
                }
            }
            expect(visitedSources == Set(Array(19...26) + [35]),
                   "30/60/120Hz playback visits only support, crouch and terminal sitting drawings")
        }
        let almostLifted = DesktopPetLift(shoulder: 1, hip: 1, paws: 1, spriteFrame: 14)
        expect(almostLifted.landing(elapsed: 0.32).spriteFrame > 0, "partial return is not cut off")
        expect(almostLifted.landing(elapsed: almostLifted.returnDuration) == DesktopPetLift(),
               "partial pickup returns to its actual first drawing")
        let landed = fullPose.landing(elapsed: fullPose.returnDuration)
        expect(landed.spriteFrame == 23 && landed.shoulder == 0, "full landing ends at the stable sitting timeline position")
        expect(view.renderPNG(pose: .sitting, lift: landed) == view.renderPickupSourcePNG(35),
               "completed landing preserves the exact native terminal source35 pixels and point size")
        for id in CatAppearance.presetIDs {
            let coatView = DesktopPetView(resources: resources, appearance: CatAppearance.makePreset(id)!)
            expect(coatView.renderPNG(pose: .sitting, lift: landed) == coatView.renderPickupSourcePNG(35),
                   "all coat painters preserve the original native resting size after landing: \(id)")
        }
        expect(view.renderPNG(pose: .sitting, lift: landed) == view.renderPNG(pose: .sitting, isSettling: true, lift: landed),
               "finishing landing does not replace the last source drawing")
        expect(view.renderPNG(pose: .carried, lift: fullPose) == view.renderPNG(pose: .carried,
               lift: DesktopPetLift(shoulder: 1, hip: 1, paws: 1, lean: 5, spriteFrame: 15)),
               "direct-original comparison adds no angular sway")
        for (frame, position) in DesktopPetLift.framePositions.enumerated() {
            let png = view.renderPNG(pose: .carried, lift: DesktopPetLift(spriteFrame: position))
            let bitmap = NSBitmapImageRep(data: png)!
            var clearBorder = true
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where x < 10 || y < 10 || x >= bitmap.pixelsWide - 10 || y >= bitmap.pixelsHigh - 10 {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { clearBorder = false }
                }
            }
            expect(clearBorder, "every directly rendered source drawing retains a clear border around all limbs and ears")
            try png.write(to: output.appendingPathComponent(String(format: "direct-source-%02d.png", frame)))
        }
        model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 20, world: world)
        let finalGrip = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: finalGrip, now: 20, world: world)
        model.pointerDragged(to: CGPoint(x: finalGrip.x - 40, y: finalGrip.y + 20), now: 20.01, world: world)
        model.tick(now: 21, world: world)
        model.pointerUp(now: 21, world: world)
        model.tick(now: 21.41, world: world)
        expect(!model.isSettling && model.lift.spriteFrame == 23,
               "the actual model preserves its terminal source drawing after full release")
        let terminalPNG = view.renderPNG(pose: .sitting, lift: model.lift)
        let finalRegrip = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: finalRegrip, now: 21.9, world: world)
        model.pointerDragged(to: CGPoint(x: finalRegrip.x - 40, y: finalRegrip.y + 20), now: 21.91, world: world)
        expect(view.renderPNG(pose: .carried, lift: model.lift) == terminalPNG,
               "picking up again starts from the visible terminal drawing without resetting to source 0")
        model.tick(now: 21.96, world: world)
        expect(model.lift.spriteFrame == 22, "a later pickup reverses continuously from the actual resting drawing from the actual idle drawing")
        for rate in [30, 60, 120] {
            var cadence = DesktopPetModel(seed: 42)
            cadence.setReleased(true, now: 30, world: world)
            let point = CGPoint(x: cadence.frame.midX, y: cadence.frame.midY)
            cadence.pointerDown(at: point, now: 30, world: world)
            cadence.pointerDragged(to: CGPoint(x: point.x - 10, y: point.y + 20), now: 30.01, world: world)
            for i in 1...(rate * 3 / 5) {
                let t = Double(i) / Double(rate)
                cadence.pointerDragged(to: CGPoint(x: point.x - 10 - t * 100, y: point.y + 20), now: 30.01 + t, world: world)
                cadence.tick(now: 30.01 + t, world: world)
            }
            expect(cadence.lift.spriteFrame == 10, "30/60/120Hz pointer reports select the same original drawing at the same wall time")
        }
        func tiltAfterDrag(rate: Int) -> CGFloat {
            var fixture = DesktopPetModel(seed: 42)
            fixture.setReleased(true, now: 20, world: world)
            let point = CGPoint(x: fixture.frame.midX, y: fixture.frame.midY)
            fixture.pointerDown(at: point, now: 20, world: world)
            fixture.pointerDragged(to: CGPoint(x: point.x - 10, y: point.y + 80), now: 20.01, world: world)
            for i in 1...rate {
                let t = Double(i) / Double(rate)
                fixture.pointerDragged(to: CGPoint(x: point.x - 10 - 120 * t, y: point.y + 80), now: 20.01 + t, world: world)
                fixture.tick(now: 20.01 + t, world: world)
            }
            return fixture.carryLean
        }
        expect(abs(tiltAfterDrag(rate: 60) - tiltAfterDrag(rate: 120)) < 0.01,
               "drag inertia is independent of mouse report frequency")
        expect(DesktopPetLift.lifting(elapsed: 2, lean: 0).spriteFrame == DesktopPetLift.carryFrame,
               "completed pickup holds a stable image without cycling")

        for pose in DesktopPetPose.allCases {
            for frame in 0..<24 {
                let phase = Double(frame) / 12
                let image = view.renderPNG(pose: pose, phase: phase, walkDistance: CGFloat(frame) * 3.5)
                expect(image.count > 1400, "each pose renders nonempty")
                try image.write(to: output.appendingPathComponent("\(pose.rawValue)-\(String(format: "%02d", frame)).png"))
            }
        }

        // Export one complete gesture through the same model used by the App.
        // All positions are synthetic fixture coordinates, never user input.
        world = DesktopPetWorld(areas: [area], idleSeconds: 0)
        model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 0, world: world)
        let start = model.origin
        let startGrip = CGPoint(x: model.frame.midX, y: model.frame.midY)
        var frames: [[String: Any]] = []
        for i in 0..<240 {
            let now = Double(i) / 60
            if i == 20 { model.pointerDown(at: startGrip, now: now, world: world) }
            if (23...150).contains(i) {
                let p = Double(i - 23) / 127
                model.pointerDragged(to: CGPoint(x: startGrip.x - 180 * sin(p * .pi / 2),
                                                  y: startGrip.y + 100 * sin(p * .pi * 0.7)), now: now, world: world)
            }
            if i == 180 { model.pointerUp(now: now, world: world) }
            model.tick(now: now, world: world)
            expect(abs(model.carryLean) <= 5 && area.contains(model.frame), "scripted gesture stays bounded")
            view.update(model, reduceMotion: false)
            let image = view.renderPNG(pose: model.pose, phase: model.phase, carryLean: model.carryLean,
                                       isSettling: model.isSettling, lift: model.lift)
            let file = String(format: "pickup-gemini-%03d.png", i)
            try image.write(to: output.appendingPathComponent(file))
            frames.append(["file": file, "pose": model.pose.rawValue, "pressed": model.isPressed,
                           "x": model.origin.x - start.x, "y": model.origin.y - start.y,
                           "phase": model.phase, "lean": model.carryLean, "settling": model.isSettling,
                           "shoulder": model.lift.shoulder, "hip": model.lift.hip, "paws": model.lift.paws,
                           "spriteFrame": model.lift.spriteFrame])
        }
        let data = try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("pickup-gemini-gesture.json"))
        print("Desktop pet interaction: \(checks) checks passed; ten native poses rendered.")
    }
}
