import AppKit

@main
struct PreviewTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }

        // The desktop is a two-dimensional roaming area, including negative
        // monitor origins and a narrow display that permits only vertical travel.
        for roamArea in [CGRect(x: -1800, y: -200, width: 1800, height: 1100),
                         CGRect(x: 0, y: 0, width: 128, height: 728)] {
            var roaming = DesktopPetModel(seed: 42)
            let roamWorld = DesktopPetWorld(areas: [roamArea], idleSeconds: 30)
            roaming.setReleased(true, now: 0, world: roamWorld)
            var corners = Set<Int>(), diagonal = false, vertical = false
            for tick in 0...24000 {
                let before = roaming.origin
                let beforeDistance = roaming.walkDistance
                let beforePose = roaming.pose
                roaming.tick(now: Double(tick) / 4, world: roamWorld)
                expect(roamArea.insetBy(dx: -0.001, dy: -0.001).contains(roaming.frame), "2D roaming stays on its actual monitor")
                let dx = roaming.origin.x - before.x, dy = roaming.origin.y - before.y
                vertical = vertical || abs(dy) > 0.01
                diagonal = diagonal || (abs(dx) > 0.01 && abs(dy) > 0.01)
                if beforePose == .walking && roaming.pose == .walking {
                    expect(abs(roaming.walkDistance - beforeDistance - hypot(dx, dy)) < 0.001,
                           "diagonal and vertical gait use actual two-dimensional travel")
                }
                if !roaming.isTravelling {
                    for corner in 0..<4 {
                        let target = CGPoint(x: (corner & 1) == 0 ? roamArea.minX : roamArea.maxX - DesktopPetModel.size.width,
                                             y: (corner & 2) == 0 ? roamArea.minY : roamArea.maxY - DesktopPetModel.size.height)
                        if hypot(roaming.origin.x - target.x, roaming.origin.y - target.y) < 0.001 { corners.insert(corner) }
                    }
                }
            }
            expect(vertical && (roamArea.width == DesktopPetModel.size.width || diagonal), "roaming includes vertical and diagonal travel")
            expect(corners.count == 4, "uninterrupted roaming visits every corner")
        }

        let area = CGRect(x: 0, y: 0, width: 1000, height: 700)
        var world = DesktopPetWorld(areas: [area], cursor: CGPoint(x: 50, y: 600), idleSeconds: 0)
        var model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 0, world: world)
        let initial = model.origin
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
        let controller = DesktopPetController(resources: resources, automatic: false, world: { world },
                                             clock: { testTime }, pressedButtons: { buttons })
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let key = NSApp.keyWindow, main = NSApp.mainWindow
        controller.setReleased(true)
        expect(!controller.panel.canBecomeKey && !controller.panel.canBecomeMain, "pet panel cannot take keyboard focus")
        expect(controller.panel.styleMask.contains(.nonactivatingPanel), "pet panel is nonactivating")
        let frame = controller.model.frame
        expect(controller.panel.frame.origin == CGPoint(x: frame.minX - 40, y: frame.minY - 64),
               "expanded visual panel preserves the nominal grab coordinate system")
        expect(controller.panel.frame.size == CGSize(width: 208, height: 192), "hanging paws fit inside visual padding")
        controller.updateHitRegion(at: CGPoint(x: controller.panel.frame.minX + 2, y: controller.panel.frame.minY + 2))
        expect(controller.panel.ignoresMouseEvents, "new hanging-body padding remains click-through")
        controller.updateHitRegion(at: CGPoint(x: frame.minX + 1, y: frame.minY + 1))
        expect(controller.panel.ignoresMouseEvents, "transparent padding passes mouse events through")
        controller.updateHitRegion(at: CGPoint(x: frame.minX + 64, y: frame.minY + 65))
        expect(!controller.panel.ignoresMouseEvents, "cat body accepts an intentional click")
        controller.pointerDown(at: CGPoint(x: frame.midX, y: frame.midY))
        testTime = 0.1
        controller.pointerUp()
        expect(controller.model.pose == .petted, "controller forwards completed click")
        expect(NSApp.keyWindow === key && NSApp.mainWindow === main &&
               NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "click callback preserves foreground and typing target")
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
        controller.demonstrate(.walking)
        expect(controller.model.pose == .walking, "walk preview starts with a walking pose, not a sliding sitting pose")
        controller.suspend(true)
        expect(!controller.panel.isVisible && controller.panel.ignoresMouseEvents, "suspended panel is invisible and cannot block clicks")
        controller.suspend(false)
        controller.setReleased(false)
        expect(!controller.panel.isVisible, "recalled preview panel stays hidden")
        controller.dispose()

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
            pulse.suspend(true)
            expect(!pulse.usesDisplaySynchronization && !pulse.panel.isVisible,
                   "suspending the preview stops the screen callback and hides its panel")
            pulse.suspend(false)
            pulse.setReleased(false)
            expect(!pulse.usesDisplaySynchronization, "recall leaves no active display link")
            pulse.dispose()
        }

        let view = DesktopPetView(resources: resources)
        expect(view.loadedPickupFrames == 32, "all direct Gemini source assets load into the native renderer")
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
        model.tick(now: 10.8, world: world)
        expect(model.lift.spriteFrame == DesktopPetLift.carryFrame, "full pickup reaches the generated hanging pose")
        model.pointerUp(now: 10.8, world: world)
        model.tick(now: 10.87, world: world)
        expect(model.lift.spriteFrame > DesktopPetLift.carryFrame && model.lift.spriteFrame < DesktopPetLift.lastFrame,
               "fully lifted drop traverses the generated support and crouch frames")
        let dropImage = model.lift
        model.pointerDown(at: spriteGrip, now: 10.87, world: world)
        model.pointerDragged(to: CGPoint(x: spriteGrip.x + 40, y: spriteGrip.y + 100), now: 10.88, world: world)
        expect(model.lift == dropImage, "re-grab preserves the exact Gemini frame and captured lean")
        for i in 1...24 {
            model.tick(now: 10.88 + Double(i) / 60, world: world)
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

        // The original drawings must have a constant 50ms dwell, independent
        // of motion-report frequency and without skipped source poses.
        for step in 0...100 {
            let now = Double(step) / 100
            let state = DesktopPetLift.lifting(elapsed: now, lean: 0)
            expect(state.spriteFrame == min(15, CGFloat(step / 5)),
                   "pickup shows each source frame for the same 50ms")
        }
        let fullPose = DesktopPetLift(shoulder: 1, hip: 1, paws: 1, spriteFrame: DesktopPetLift.carryFrame)
        for step in 0...90 {
            let state = fullPose.landing(elapsed: Double(step) / 100)
            expect(state.spriteFrame == min(31, CGFloat(15 + step / 5)),
                   "landing advances one original drawing per 50ms and retains its last frame")
        }
        let almostLifted = DesktopPetLift(shoulder: 1, hip: 1, paws: 1, spriteFrame: 14)
        expect(almostLifted.landing(elapsed: 0.32).spriteFrame > 0, "partial return is not cut off")
        expect(almostLifted.landing(elapsed: almostLifted.returnDuration) == DesktopPetLift(),
               "partial pickup returns to its actual first drawing")
        let landed = fullPose.landing(elapsed: fullPose.returnDuration)
        expect(landed.spriteFrame == 31 && landed.shoulder == 0, "full landing keeps the actual terminal Gemini drawing")
        expect(view.renderPNG(pose: .sitting, lift: landed) == view.renderPNG(pose: .sitting, isSettling: true, lift: landed),
               "finishing landing does not replace the last source drawing")
        expect(view.renderPNG(pose: .carried, lift: fullPose) == view.renderPNG(pose: .carried,
               lift: DesktopPetLift(shoulder: 1, hip: 1, paws: 1, lean: 5, spriteFrame: 15)),
               "direct-original comparison adds no angular sway")
        for frame in 0..<32 {
            let png = view.renderPNG(pose: .carried, lift: DesktopPetLift(spriteFrame: CGFloat(frame)))
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
        model.tick(now: 21.81, world: world)
        expect(!model.isSettling && model.lift.spriteFrame == 31,
               "the actual model preserves its terminal source drawing after full release")
        let terminalPNG = view.renderPNG(pose: .sitting, lift: model.lift)
        let finalRegrip = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.pointerDown(at: finalRegrip, now: 21.9, world: world)
        model.pointerDragged(to: CGPoint(x: finalRegrip.x - 40, y: finalRegrip.y + 20), now: 21.91, world: world)
        expect(view.renderPNG(pose: .carried, lift: model.lift) == terminalPNG,
               "picking up again starts from the visible terminal drawing without resetting to source 0")
        model.tick(now: 21.96, world: world)
        expect(model.lift.spriteFrame == 30, "a later pickup reverses one source frame per 50ms from the actual idle drawing")
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
            expect(cadence.lift.spriteFrame == 12, "30/60/120Hz pointer reports select the same original drawing at the same wall time")
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

        // Palm abstraction stays inside the original mascot, joins its loop
        // without a jump, and remains static when reduced motion is requested.
        var previousPalm: CGPoint?
        for sample in 0...320 {
            let pose = DesktopPetGroomingPalm.sample(time: Double(sample) / 100)
            expect(pose.center.x.isFinite && pose.center.y.isFinite && pose.angle.isFinite,
                   "grooming palm positions are finite")
            expect(CGRect(x: 80, y: 130, width: 110, height: 240).contains(pose.center),
                   "palm stays over the cat rather than floating outside its silhouette")
            if let previousPalm {
                expect(hypot(previousPalm.x - pose.center.x, previousPalm.y - pose.center.y) < 8,
                       "grooming palm cannot jump between animation phases")
            }
            previousPalm = pose.center
        }
        let beginPalm = DesktopPetGroomingPalm.sample(time: 0)
        let endPalm = DesktopPetGroomingPalm.sample(time: 3.2)
        expect(beginPalm.center == endPalm.center && beginPalm.activity == endPalm.activity,
               "grooming loop returns to its original paw position")
        expect(DesktopPetGroomingPalm.sample(time: 0, reduceMotion: true).center ==
               DesktopPetGroomingPalm.sample(time: 3, reduceMotion: true).center,
               "reduce motion holds one fixed palm pose")
        for time in [0.95, 1.35, 1.75, 2.15] {
            let contact = DesktopPetGroomingPalm.sample(time: time)
            expect(contact.lick > 0.99 && contact.center.y > 230 && abs(contact.center.x - 184) < 0.01,
                   "each lick reaches a held paw below the muzzle instead of wiping the cheek")
            let retracted = DesktopPetGroomingPalm.sample(time: time + 0.2)
            expect(retracted.lick < 0.001, "tongue retracts between licks")
        }
        for time in [0.0, 0.65, 0.75, 2.35, 2.45, 3.2] {
            expect(DesktopPetGroomingPalm.sample(time: time).lick < 0.001,
                   "tongue stays hidden during paw lift and lowering")
        }
        expect(DesktopPetGroomingPalm.sample(time: 1, reduceMotion: true).lick == 0,
               "reduce motion does not animate or expose the tongue")

        for pair in 0...1 {
            let first = DesktopPetView.pawOffset(distance: 0, pair: pair)
            expect(abs(first.x) < 0.0001 && abs(first.y) < 0.0001,
                   "the first walking frame must retain the original standing paw positions")
        }
        for distance: CGFloat in [1, 3, 6, 9] {
            let foot = DesktopPetView.pawOffset(distance: distance, pair: 0)
            expect(abs(foot.x * 0.28 - distance) < 0.001 && foot.y == 0,
                   "initial planted paw stays on the ground instead of sliding as the body advances")
        }
        expect(DesktopPetView.pawOffset(distance: DesktopPetView.strideDistance * 0.08, pair: 1).y < -10,
               "the other diagonal pair lifts smoothly during the first step")
        for left in [false, true] {
            let a = view.renderPNG(pose: .walking, facingLeft: left, walkDistance: DesktopPetView.strideDistance)
            let b = view.renderPNG(pose: .walking, facingLeft: left, walkDistance: DesktopPetView.strideDistance * 2)
            expect(a == b, "steady walking repeats the same pose after one full stride")
        }

        for pose in DesktopPetPose.allCases {
            for frame in 0..<24 {
                let phase = pose == .grooming ? Double(frame) / 23 * 3.2 : Double(frame) / 12
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
        print("Interaction preview: \(checks) checks passed; ten native poses rendered.")
    }
}
