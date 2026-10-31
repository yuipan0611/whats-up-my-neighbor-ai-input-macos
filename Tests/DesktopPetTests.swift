import AppKit

@main
struct DesktopPetTests {
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
        let folder = DesktopPetPerch(id: "fixture-folder", frame: CGRect(x: 430, y: 180, width: 70, height: 70))
        var world = DesktopPetWorld(areas: [area], perches: [folder], cursor: CGPoint(x: 30, y: 600), idleSeconds: 30)
        var model = DesktopPetModel(seed: 42)
        model.tick(now: 0, world: world)
        expect(!model.visible && !model.released, "off by default")
        model.setReleased(true, now: 0, world: world)
        var poses = Set<DesktopPetPose>()
        var perched = false, moving = false
        var travelDirections = Set<Bool>()
        for step in 0...4000 {
            let previous = model.origin
            let previousDistance = model.walkDistance
            let previousPose = model.pose
            model.tick(now: Double(step) / 4, world: world)
            expect(area.insetBy(dx: -0.01, dy: -0.01).contains(model.frame), "entire pet stays on its display")
            poses.insert(model.pose)
            moving = moving || model.isTravelling
            let dx = model.origin.x - previous.x
            if model.pose == .walking && abs(dx) > 0.01 {
                expect(model.facingLeft == (dx < 0), "walking faces its actual horizontal travel")
                travelDirections.insert(model.facingLeft)
                if previousPose == .walking {
                    expect(abs(model.walkDistance - previousDistance - hypot(dx, model.origin.y - previous.y)) < 0.001,
                           "gait distance follows actual movement including acceleration")
                }
            }
            if model.perchID == folder.id {
                perched = true
                expect(abs(model.frame.minY + DesktopPetModel.feetInset - folder.frame.maxY) < 0.01,
                       "feet contact the actual folder's top edge")
            }
        }
        expect(poses == Set(DesktopPetPose.allCases.filter { $0 != .petted && $0 != .carried }), "idle cycle reaches all eight poses including approved paw licking")
        expect(perched && moving, "walks to a folder as well as the screen edge")
        expect(travelDirections == [true, false], "fixture exercises leftward and rightward travel")

        // Removed/moved/occluded folder IDs must never strand the pet in mid-air.
        model = DesktopPetModel(seed: 42)
        model.setReleased(true, now: 0, world: world)
        var now: Double = 0
        while model.perchID == nil && now < 20 { now += 0.25; model.tick(now: now, world: world) }
        expect(model.perchID != nil, "fixture reaches perch")
        world.perches = []
        now += 0.25; model.tick(now: now, world: world)
        expect(model.perchID == nil && model.origin.y == area.minY, "lost perch returns to edge")
        world.idleSeconds = 0
        model.tick(now: now + 0.25, world: world)
        let quiet = model.origin
        for step in 1...20 { model.tick(now: now + Double(step), world: world) }
        expect(model.pose == .sitting && model.origin == quiet && !model.isTravelling, "active typing keeps it still")
        world.cursor = CGPoint(x: model.frame.midX, y: model.frame.midY)
        model.tick(now: now + 21, world: world)
        expect(model.visible, "remains available for intentional clicks near the pointer")
        world.cursor = CGPoint(x: 10, y: 650)
        world.idleSeconds = 90; world.reduceMotion = true
        for step in 22...50 { model.tick(now: now + Double(step), world: world) }
        expect(model.visible && model.pose == .sleeping && model.origin == quiet && model.phase == 0,
               "Reduce Motion disables walking and breathing")
        world.hidden = true
        model.tick(now: now + 51, world: world)
        expect(!model.visible, "busy/full-screen/locked world hides pet")
        world.hidden = false; world.reduceMotion = false
        model.tick(now: now + 5000, world: world)
        expect(model.visible && !model.isTravelling && model.pose == .sitting, "wake skips elapsed animations")
        model.setReleased(false, now: now + 5001, world: world)
        model.tick(now: now + 6000, world: world)
        expect(!model.visible && !model.isTravelling, "recall stays recalled")
        world.areas = [CGRect(x: -1440, y: -300, width: 1440, height: 900)]
        world.cursor = CGPoint(x: -200, y: 400)
        model.setReleased(true, now: 0, world: world)
        for step in 1...400 { model.tick(now: Double(step) / 4, world: world) }
        expect(world.areas[0].contains(model.frame), "negative-origin monitor supported")
        world.areas = [CGRect(x: 0, y: 0, width: 800, height: 600)]
        model.tick(now: 101, world: world)
        expect(world.areas[0].contains(model.frame), "display removal clamps to remaining screen")
        world.areas = [.zero]
        model.tick(now: 102, world: world)
        expect(!model.visible, "invalid display hides safely")
        expect(DesktopPetModel.appKitFrame(topLeft: CGRect(x: -100, y: 10, width: 60, height: 70), primaryScreenTop: 900)
               == CGRect(x: -100, y: 820, width: 60, height: 70), "AX top-left conversion")

        // Native window fixture: no API, recording, keyboard or user's files.
        world = DesktopPetWorld(areas: [area], cursor: CGPoint(x: 10, y: 600), idleSeconds: 0)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let key = NSApp.keyWindow, main = NSApp.mainWindow
        var applicationHidden = true, unhides = 0
        let presentation = DesktopPetController.Presentation(isAppHidden: { applicationHidden },
            unhideWithoutActivation: { applicationHidden = false; unhides += 1 })
        let controller = DesktopPetController(resources: resources, world: { world }, presentation: presentation)
        var busy = false
        controller.isBusy = { busy }
        controller.refresh()
        expect(unhides == 0, "recalled startup never unhides the app")
        controller.setReleased(true)
        expect(unhides == 1 && !applicationHidden, "hidden login launch reveals the released pet")
        expect(controller.testPanel.isVisible && controller.testTimerActive, "released native window runs")
        expect(controller.testPanel.ignoresMouseEvents, "clicks pass through")
        expect(!controller.testPanel.canBecomeKey && !controller.testPanel.canBecomeMain, "cannot take keyboard focus")
        expect(controller.testPanel.styleMask.contains(.nonactivatingPanel), "nonactivating panel")
        expect(NSApp.keyWindow === key && NSApp.mainWindow === main &&
               NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "presentation preserves typing target")
        busy = true; controller.refresh()
        expect(!controller.testPanel.isVisible, "recording/modal/selection takes priority")
        applicationHidden = true; controller.refresh()
        expect(unhides == 1, "busy UI never unhides the app for the pet")
        busy = false; controller.refresh()
        expect(controller.testPanel.isVisible, "idle restores released pet")
        expect(unhides == 2 && !applicationHidden, "released pet recovers from hidden app state")
        controller.testSuspend(true)
        expect(!controller.testPanel.isVisible && !controller.testTimerActive, "sleep/lock stops animation timer")
        applicationHidden = true; controller.refresh()
        expect(unhides == 2, "sleep/lock never unhides the app")
        controller.testSuspend(false)
        expect(controller.testPanel.isVisible, "wake restores a released pet")
        controller.setReleased(false)
        applicationHidden = true; controller.refresh()
        let beforeWake = unhides
        controller.testSuspend(true); controller.testSuspend(false)
        expect(!controller.testPanel.isVisible && !controller.testTimerActive, "recall has no timer, including after wake")
        expect(unhides == beforeWake && applicationHidden, "recalled wake preserves the hidden app")
        controller.dispose()
        controller.setReleased(true)
        expect(!controller.testPanel.isVisible && !controller.testTimerActive, "disposed window cannot restart")

        let view = DesktopPetView(resources: resources)
        // Ground contact is a spatial contract, including the model's eased
        // acceleration: planted paws must not drift as the panel moves.
        for left in [false, true] {
            let initial = DesktopPetView.pawOffset(distance: 0, pair: 0)
            for distance: CGFloat in [1, 3, 6, 9, 12] {
                let foot = DesktopPetView.pawOffset(distance: distance, pair: 0)
                let panelX = left ? -distance : distance
                let worldX = panelX + (left ? foot.x : -foot.x) * 0.28
                expect(abs(worldX - (left ? initial.x : -initial.x) * 0.28) < 0.001 && foot.y == 0,
                       "planted paw stays fixed on the desktop while the body advances")
            }
        }
        let lifted = DesktopPetView.pawOffset(distance: DesktopPetView.strideDistance * 0.5, pair: 0)
        expect(lifted.y <= -27, "swing lifts a paw visibly above the ground")
        let landed = DesktopPetView.pawOffset(distance: DesktopPetView.strideDistance * 0.7, pair: 0)
        expect(landed.y == 0 && abs(landed.x + 43) < 0.001, "swing returns to a planted leading paw")
        let partner = DesktopPetView.pawOffset(distance: DesktopPetView.strideDistance, pair: 1)
        expect(partner.y <= -27, "diagonal pairs alternate stance and swing")
        for pair in 0...1 {
            let first = DesktopPetView.pawOffset(distance: 0, pair: pair)
            expect(abs(first.x) < 0.001 && abs(first.y) < 0.001, "first step starts at neutral standing paws")
        }
        expect(view.loadedAssets.isSuperset(of: ["groom-head", "groom-body", "walk-foot-0", "walk-foot-1", "walk-foot-2", "walk-foot-3"]),
               "approved palm and original individual paws are bundled")
        var lastPalm: CGPoint?
        for i in 0...320 {
            let palm = DesktopPetGroomingPalm.sample(time: Double(i) / 100)
            expect(palm.center.x.isFinite && palm.center.y.isFinite && palm.lick.isFinite,
                   "paw licking remains finite through the complete cycle")
            if let lastPalm {
                expect(hypot(lastPalm.x - palm.center.x, lastPalm.y - palm.center.y) < 8,
                       "paw does not jump between lift, licking and lowering")
            }
            lastPalm = palm.center
        }
        for t in [0.95, 1.35, 1.75, 2.15] {
            let palm = DesktopPetGroomingPalm.sample(time: t)
            expect(palm.lick > 0.99 && palm.center.y > 230, "four licks touch a held paw below the muzzle")
            expect(DesktopPetGroomingPalm.sample(time: t + 0.2).lick < 0.001, "tongue retracts between licks")
        }
        expect(DesktopPetGroomingPalm.sample(time: 0).center == DesktopPetGroomingPalm.sample(time: 3.2).center,
               "grooming returns to the grounded paw position")
        expect(DesktopPetGroomingPalm.sample(time: 1, reduceMotion: true).lick == 0,
               "reduced motion hides the tongue and holds the palm still")
        let lickingPixels = NSBitmapImageRep(data: view.renderPNG(pose: .grooming, phase: 0.95))!
        var tonguePixels: [CGPoint] = []
        for y in 0..<lickingPixels.pixelsHigh {
            for x in 0..<lickingPixels.pixelsWide {
                let color = lickingPixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.alphaComponent > 0.8 && color.redComponent > 0.7 &&
                    color.greenComponent > 0.3 && color.greenComponent < 0.65 &&
                    color.blueComponent > 0.35 && color.blueComponent < 0.7 {
                    tonguePixels.append(CGPoint(x: x, y: y))
                }
            }
        }
        expect(tonguePixels.count > 2, "short tongue is visible in the actual native render")
        if let minX = tonguePixels.map(\.x).min(), let maxX = tonguePixels.map(\.x).max(),
           let minY = tonguePixels.map(\.y).min(), let maxY = tonguePixels.map(\.y).max() {
            expect(maxX - minX >= maxY - minY, "approved tongue stays broad and short rather than long and thin")
        }
        expect(view.loadedAssets.contains("sit") && view.loadedAssets.contains("walk") && view.loadedAssets.contains("reply"), "original artwork bundled")
        expect(view.loadedAssets.contains("walk-body") && view.loadedAssets.contains("walk-paws") &&
               view.loadedAssets.contains("walk-front-face"), "original directional walking components bundled")
        for pose in DesktopPetPose.allCases {
            let data = view.renderPNG(pose: pose, phase: pose == .yawning ? 1.6 : 0.55)
            expect(data.count > 1500, "native pose renders nonempty")
            try data.write(to: output.appendingPathComponent(pose.rawValue + ".png"))
            if pose != .walking {
                expect(data == view.renderPNG(pose: pose, phase: pose == .yawning ? 1.6 : 0.55, facingLeft: true),
                       "resting face never reflects its eyes after a leftward walk: \(pose)")
            }
        }
        func bitmap(_ data: Data) -> NSBitmapImageRep { NSBitmapImageRep(data: data)! }
        func color(_ bitmap: NSBitmapImageRep, artX: CGFloat, artY: CGFloat) -> NSColor {
            let px = (48 + artX * 0.28) / 208 * CGFloat(bitmap.pixelsWide)
            let py = (128 - 2 - 367 * 0.28 + artY * 0.28) / 192 * CGFloat(bitmap.pixelsHigh)
            return bitmap.colorAt(x: Int(px), y: Int(py))!.usingColorSpace(.deviceRGB)!
        }
        func isInk(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> Bool {
            let pixel = color(bitmap, artX: x, artY: y)
            return pixel.alphaComponent > 0.8 && pixel.redComponent > 0.8
        }
        func renderedEyeCenters(_ pixels: NSBitmapImageRep, left: Bool) -> [CGPoint] {
            let width = pixels.pixelsWide, height = pixels.pixelsHigh
            var mask = [Bool](repeating: false, count: width * height)
            for y in 0..<height {
                let artY = (CGFloat(y) * 192 / CGFloat(height) - (128 - 2 - 367 * 0.28)) / 0.28
                guard artY > 125 && artY < 180 else { continue }
                for x in 0..<width {
                    let artX = (CGFloat(x) * 208 / CGFloat(width) - 48) / 0.28
                    guard left ? (60...310).contains(artX) : (100...350).contains(artX) else { continue }
                    let pixel = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    mask[y * width + x] = pixel.alphaComponent > 0.5 && pixel.redComponent > 0.6
                }
            }
            var centers: [CGPoint] = []
            for seed in mask.indices where mask[seed] {
                var queue = [seed], next = 0
                mask[seed] = false
                var minX = seed % width, maxX = minX, minY = seed / width, maxY = minY
                while next < queue.count {
                    let point = queue[next], x = point % width, y = point / width
                    next += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    for dy in -1...1 {
                        for dx in -1...1 where (dx != 0 || dy != 0) &&
                            x + dx >= 0 && x + dx < width && y + dy >= 0 && y + dy < height {
                            let neighbor = (y + dy) * width + x + dx
                            if mask[neighbor] { mask[neighbor] = false; queue.append(neighbor) }
                        }
                    }
                }
                if queue.count > 2 { centers.append(CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(minY + maxY) / 2)) }
            }
            return centers.sorted { $0.x < $1.x }
        }
        for left in [false, true] {
            let data = view.renderPNG(pose: .walking, facingLeft: left)
            let frame = bitmap(data)
            // The front-facing head sits over the leading shoulders; body
            // direction is verified independently by the rear tail below.
            var mass: CGFloat = 0, xMass: CGFloat = 0
            for y in 50..<200 {
                for x in 20..<380 {
                    let pixel = color(frame, artX: CGFloat(x), artY: CGFloat(y))
                    if pixel.alphaComponent > 0.8 && pixel.redComponent < 0.2 {
                        mass += 1; xMass += CGFloat(x)
                    }
                }
            }
            expect(mass > 1000 && (left ? xMass / mass < 195 : xMass / mass > 205),
                   "front-facing head stays over the leading shoulders")
            let offset: CGFloat = left ? 0 : 40
            expect(isInk(frame, 286 + offset, 145) && !isInk(frame, 247 + offset, 145) &&
                   isInk(frame, 259 + offset, 174), "original check rises to the right in either direction")
            expect(isInk(frame, 80 + offset, 147) && isInk(frame, 108 + offset, 147),
                   "original X remains left of check")
            expect(isInk(frame, 181 + offset, 187) && isInk(frame, 171 + offset, 194) &&
                   isInk(frame, 190 + offset, 194) && !isInk(frame, 34 + offset, 198),
                   "original omega stays centered within the original round head")
            func leadingEdge(at y: CGFloat) -> Int {
                let xs = (0..<400).filter { x in
                    let pixel = color(frame, artX: CGFloat(x), artY: y)
                    return pixel.alphaComponent > 0.8 && pixel.redComponent < 0.2
                }
                return left ? xs.first! : xs.last!
            }
            expect(left ? leadingEdge(at: 195) >= leadingEdge(at: 165) : leadingEdge(at: 195) <= leadingEdge(at: 165),
                   "lower cheek curves inward rather than adding a protruding muzzle")
            try data.write(to: output.appendingPathComponent(left ? "walk-left.png" : "walk-right.png"))
            let step = view.renderPNG(pose: .walking, phase: 0.18, facingLeft: left, walkDistance: 12.6)
            expect(data != step, "walking paws articulate in both directions")
            let timeOnly = view.renderPNG(pose: .walking, phase: 5, facingLeft: left)
            if data != timeOnly {
                try data.write(to: output.appendingPathComponent("time-before.png"))
                try timeOnly.write(to: output.appendingPathComponent("time-after.png"))
            }
            expect(data == timeOnly,
                   "elapsed time alone cannot slide paws when the cat has not moved")
            try step.write(to: output.appendingPathComponent(left ? "walk-left-step.png" : "walk-right-step.png"))
        }
        let framesDirectory = output.appendingPathComponent("walking-cycle")
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        var cycleFrames: [Data] = []
        for left in [true, false] {
            for index in 0..<16 {
                let distance = DesktopPetView.strideDistance * CGFloat(index) / 16
                let data = view.renderPNG(pose: .walking, facingLeft: left, walkDistance: distance)
                let pixels = bitmap(data), width = pixels.pixelsWide, height = pixels.pixelsHigh
                let tail = color(pixels, artX: left ? 384 : 16, artY: 150)
                let ahead = color(pixels, artX: left ? 16 : 384, artY: 150)
                expect(tail.alphaComponent > 0.8 && tail.redComponent < 0.2 && ahead.alphaComponent < 0.2,
                       "tail trails the actual walking direction through every gait frame")
                let eyes = renderedEyeCenters(pixels, left: left)
                expect(eyes.count == 2 && abs(eyes[0].y - eyes[1].y) <= 1,
                       "walking eyes share one rendered horizontal line in frame \(left)/\(index): \(eyes)")
                expect(eyes.count == 2 && abs(eyes[1].x - eyes[0].x - 172.5 * 0.28 * CGFloat(width) / 208) <= 1,
                       "walking eye spacing stays consistent in either direction")
                var solid = [Bool](repeating: false, count: width * height)
                var clips = false
                for y in 0..<height {
                    for x in 0..<width where pixels.colorAt(x: x, y: y)!.alphaComponent > 0.5 {
                        solid[y * width + x] = true
                        clips = clips || x == 0 || y == 0 || x == width - 1 || y == height - 1
                    }
                }
                var components = 0
                for seed in solid.indices where solid[seed] {
                    var queue = [seed], next = 0
                    solid[seed] = false
                    while next < queue.count {
                        let point = queue[next], x = point % width, y = point / width
                        next += 1
                        for neighbor in [x > 0 ? point - 1 : -1, x + 1 < width ? point + 1 : -1,
                                         y > 0 ? point - width : -1, y + 1 < height ? point + width : -1]
                            where neighbor >= 0 && solid[neighbor] {
                            solid[neighbor] = false; queue.append(neighbor)
                        }
                    }
                    if queue.count > 8 { components += 1 }
                }
                expect(components == 1, "walking frame \(left)/\(index) has no detached paws, face or tail")
                expect(!clips, "walking frame \(left)/\(index) fits the panel without cropping")
                try data.write(to: framesDirectory.appendingPathComponent("\(left ? "left" : "right")-\(index).png"))
                if index % 2 == 0 { cycleFrames.append(data) }
            }
        }
        let cycleSheet = NSImage(size: CGSize(width: 640, height: 704), flipped: true) { _ in
            NSColor(srgbRed: 0.90, green: 0.91, blue: 0.89, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 640, height: 704).fill()
            for (index, data) in cycleFrames.enumerated() {
                let x = (index % 4) * 160, y = (index / 4) * 176
                NSImage(data: data)!.draw(in: CGRect(x: x, y: y, width: 160, height: 160),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                ("\(index < 8 ? "← 向左" : "向右 →")  \(index % 8 + 1)/8" as NSString)
                    .draw(at: CGPoint(x: x + 30, y: y + 156), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            }
            return true
        }
        try NSBitmapImageRep(data: cycleSheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("walking-composition.png"))
        let directions: [(String, DesktopPetPose, Bool, Double)] = [
            ("向左走 ←", .walking, true, 0), ("向左邁步 ←", .walking, true, 0.18),
            ("向右走 →", .walking, false, 0), ("向右邁步 →", .walking, false, 0.18),
            ("走完向前看", .sitting, true, 0), ("趴下休息", .loafing, true, 0)]
        let directionSheet = NSImage(size: CGSize(width: 768, height: 190), flipped: true) { _ in
            NSColor(srgbRed: 0.90, green: 0.91, blue: 0.89, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 768, height: 190).fill()
            for (index, item) in directions.enumerated() {
                let data = view.renderPNG(pose: item.1, phase: item.3, facingLeft: item.2, walkDistance: CGFloat(item.3 * 70))
                NSImage(data: data)!.draw(in: CGRect(x: index * 128, y: 10, width: 128, height: 128),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                (item.0 as NSString).draw(at: CGPoint(x: index * 128 + 20, y: 155), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            }
            return true
        }
        try NSBitmapImageRep(data: directionSheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("directions.png"))
        let sheet = NSImage(size: CGSize(width: 896, height: 210), flipped: true) { _ in
            NSColor(srgbRed: 0.90, green: 0.91, blue: 0.89, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 896, height: 210).fill()
            for (index, pose) in DesktopPetPose.allCases.enumerated() {
                let data = view.renderPNG(pose: pose, phase: pose == .yawning ? 1.6 : 0.55)
                NSImage(data: data)!.draw(in: CGRect(x: index * 128, y: 20, width: 128, height: 128),
                                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                (pose.description as NSString).draw(at: CGPoint(x: index * 128 + 20, y: 166), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)])
            }
            return true
        }
        let bitmap = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("poses.png"))
        print("Desktop pet: \(checks) checks passed; native pose renders saved.")
    }
}
