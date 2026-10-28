import AppKit
import ApplicationServices
import QuartzCore

@available(macOS 14.0, *)
private final class DesktopPetDisplayPulse: NSObject {
    weak var owner: DesktopPetController?
    private var link: CADisplayLink?
    init(owner: DesktopPetController, view: NSView) {
        self.owner = owner
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) { owner?.refresh() }
    func stop() { link?.invalidate(); link = nil }
    deinit { link?.invalidate() }
}

private final class DesktopPetPanel: NSPanel {
    // 核心設計規範（焦點不侵入原則）：
    // 桌面貓咪純粹為陪伴與視覺元件，絕對不能剝奪使用者的工作輸入焦點。
    // 即使使用者點擊、撫摸或拖拽貓咪，當前正在輸入的編輯器或視窗永遠不會失去焦點。
    // 容易誤用之處：切勿為了接收鍵盤事件而將其改為 true，否則每次碰觸貓咪都會打斷使用者的工作。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns only the optional desktop companion. Recording and greeting keep their
/// existing windows and take priority; this controller never posts input events.
final class DesktopPetController {
    struct Presentation {
        var isAppHidden: () -> Bool
        var unhideWithoutActivation: () -> Void
        static var system: Self {
            Self(isAppHidden: { NSApp.isHidden }, unhideWithoutActivation: { NSApp.unhideWithoutActivation() })
        }
    }
    var onReleasedChange: ((Bool) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragReleased: ((CGPoint) -> Void)?
    var onDragCancelled: (() -> Void)?
    var onRemoteHostedChange: ((Bool) -> Void)?
    var onRemoteFrame: ((DesktopPetModel, Bool, CatAppearance) -> Void)?
    var isBusy: () -> Bool = { NSApp.modalWindow != nil }
    private(set) var model = DesktopPetModel()
    private(set) var appearance: CatAppearance
    private(set) var remoteHosted = false
    private var homeOrigin: CGPoint?
    private var pressOrigin: CGPoint?
    private let panel: DesktopPetPanel
    private let artwork: DesktopPetView
    private let reader = DesktopPetDesktopReader()
    private var snapshot = DesktopPetDesktopReader.Snapshot()
    private var nextRefresh: TimeInterval = 0
    private var timer: Timer?
    private var displayPulse: AnyObject?
    private var globalMouse: Any?
    private var localMouse: Any?
    private var deliveringPointer = false
    private let clock: () -> TimeInterval
    private let pressedButtons: () -> Int
    private var interval: TimeInterval = 0
    private var suspended = Set<String>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var disposed = false
    private let automaticallyTicks: Bool
    private let presentation: Presentation
    private var injectedWorld: (() -> DesktopPetWorld)?

    init(resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("DesktopPet"),
         appearance: CatAppearance = .original,
         automaticallyTicks: Bool = true, world: (() -> DesktopPetWorld)? = nil,
         presentation: Presentation = .system,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pressedButtons: @escaping () -> Int = { NSEvent.pressedMouseButtons }) {
        precondition(Thread.isMainThread)
        self.automaticallyTicks = automaticallyTicks
        self.presentation = presentation
        self.clock = clock
        self.pressedButtons = pressedButtons
        self.appearance = appearance
        injectedWorld = world
        artwork = DesktopPetView(resources: resources, appearance: appearance)
        panel = DesktopPetPanel(contentRect: CGRect(origin: .zero, size: DesktopPetView.panelSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.contentView = artwork
        panel.title = "小黑貓桌面夥伴"
        artwork.onPointerDown = { [weak self] point in self?.pointerDown(at: point) }
        artwork.onPointerDragged = { [weak self] point in self?.pointerDragged(to: point) }
        artwork.onPointerUp = { [weak self] in self?.pointerUp() }
        artwork.onAccessibilityPress = { [weak self] in self?.pet() }
        if automaticallyTicks {
            if world == nil,
               (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
                suspended.insert("lock")
            }
            observeEnvironment()
        }
    }

    var isReleased: Bool { model.released }

    /// An explicit coat choice also brings a recalled pet onto the desktop.
    func show(appearance: CatAppearance) {
        guard !disposed else { return }
        self.appearance = appearance
        artwork.setAppearance(appearance)
        if model.released { refresh() }
        else { setReleased(true) }
    }

    func setReleased(_ value: Bool) {
        guard !disposed else { return }
        let now = clock()
        if !value && remoteHosted {
            remoteHosted = false
            onRemoteHostedChange?(false)
        }
        let cancelledDrag = !value && model.isDragging
        model.setReleased(value, now: now, world: world(now: now))
        if cancelledDrag { onDragCancelled?() }
        if !value { reader.cancel(); snapshot = .init() }
        refresh(now: now)
        onReleasedChange?(value)
    }

    func pointerDown(at point: CGPoint) {
        guard !disposed else { return }
        pressOrigin = model.origin
        deliveringPointer = true
        defer { deliveringPointer = false }
        let now = clock()
        model.pointerDown(at: point, now: now, world: world(now: now))
        refresh(now: now)
    }

    func pointerDragged(to point: CGPoint) {
        guard !disposed else { return }
        deliveringPointer = true
        defer { deliveringPointer = false }
        let now = clock()
        let wasDragging = model.isDragging
        model.pointerDragged(to: point, now: now, world: world(now: now))
        if !wasDragging && model.isDragging { panel.orderFrontRegardless() }
        refresh(now: now)
        if model.isDragging { onDragMoved?(point) }
    }

    func pointerUp(at point: CGPoint? = nil) {
        guard !disposed else { return }
        let now = clock()
        let wasDragging = model.isDragging
        let environment = world(now: now)
        model.pointerUp(now: now, world: environment)
        if wasDragging {
            if environment.hidden { onDragCancelled?() }
            else { onDragReleased?(point ?? environment.cursor) }
        }
        refresh(now: now)
    }

    /// The VPS draws this same model while its desktop panel is hidden.
    @discardableResult func parkInVPS(preservingHome: Bool = false) -> Bool {
        guard !disposed, model.released, !remoteHosted else { return false }
        if !preservingHome { homeOrigin = pressOrigin ?? model.origin }
        let now = clock()
        if let homeOrigin { model.relocateForTransfer(to: homeOrigin, now: now, world: world(now: now)) }
        remoteHosted = true
        onRemoteHostedChange?(true)
        refresh(now: now)
        return true
    }

    func beginVPSDrag(at point: CGPoint, from screenRect: CGRect) {
        guard remoteHosted, !disposed else { return }
        let now = clock()
        remoteHosted = false
        onRemoteHostedChange?(false)
        model.relocateForTransfer(to: CGPoint(x: screenRect.minX - DesktopPetView.panelOffset.x,
                                               y: screenRect.minY - DesktopPetView.panelOffset.y),
                                  now: now, world: world(now: now))
        refresh(now: now)
        pointerDown(at: point)
    }

    func returnFromVPS() {
        guard remoteHosted, !disposed else { return }
        let now = clock()
        remoteHosted = false
        model.arriveFromTransfer(at: homeOrigin ?? model.origin, now: now, world: world(now: now))
        onRemoteHostedChange?(false)
        refresh(now: now)
    }

    func cancelVPSDrag() {
        guard !remoteHosted, model.isPressed, !disposed else { return }
        model.cancelPointer(now: clock())
        _ = parkInVPS(preservingHome: true)
    }

    func pet() {
        pointerDown(at: CGPoint(x: model.frame.midX, y: model.frame.midY))
        pointerUp()
    }

    func refresh(now suppliedNow: TimeInterval? = nil) {
        precondition(Thread.isMainThread)
        guard !disposed else { return }
        let now = suppliedNow ?? clock()
        let environment = world(now: now)
        let wasDragging = model.isDragging
        if remoteHosted {
            var parkedWorld = environment
            parkedWorld.idleSeconds = 0
            parkedWorld.perches = []
            model.tick(now: now, world: parkedWorld)
            panel.ignoresMouseEvents = true
            if panel.isVisible { panel.orderOut(nil) }
            if #available(macOS 14.0, *) { (displayPulse as? DesktopPetDisplayPulse)?.stop(); displayPulse = nil }
            onRemoteFrame?(model, parkedWorld.reduceMotion, appearance)
            schedule(every: model.isSettling ? 1 / 60 : 1)
            return
        }
        // 遺失 mouseUp 事件的自我修復：
        // 在浮動視窗中，若使用者在螢幕外或快速拖拽時釋放滑鼠，AppKit 的 mouseUp 有微小機率被系統遺失。
        // 若系統實體滑鼠左鍵已釋放（bit 0 為 0），但模型仍處於 isPressed，
        // 立即主動合成 pointerUp，使貓咪平穩著地，避免永久卡在抓起懸空狀態。
        if !deliveringPointer, model.isPressed, pressedButtons() & 1 == 0, !environment.hidden {
            // The display link can observe button-up before AppKit delivers mouseUp.
            // Finish the controller-level release too, including a pending VPS drop.
            // pointerUp clears the pressed state before callbacks; a late event is inert.
            pointerUp(at: environment.cursor)
            return
        }
        model.tick(now: now, world: environment)
        if wasDragging && !model.isDragging { onDragCancelled?() }
        if model.visible {
            // The login agent uses open -gj. Match the recording HUD's
            // nonactivating presentation instead of leaving a hidden app's
            // animation running without an on-screen window.
            if presentation.isAppHidden() { presentation.unhideWithoutActivation() }
            artwork.update(model, reduceMotion: environment.reduceMotion)
            panel.setFrameOrigin(CGPoint(x: model.origin.x + DesktopPetView.panelOffset.x,
                                         y: model.origin.y + DesktopPetView.panelOffset.y))
            if !panel.isVisible { panel.orderFrontRegardless() }
            updateHitRegion(at: environment.cursor)
        } else {
            panel.ignoresMouseEvents = true
            if panel.isVisible { panel.orderOut(nil) }
        }
        if #available(macOS 14.0, *), automaticallyTicks {
            let animating = model.visible && suspended.isEmpty && !environment.reduceMotion &&
                (model.isDragging || model.isSettling) &&
                !(model.isDragging && model.lift.spriteFrame == DesktopPetLift.carryFrame)
            if animating {
                timer?.invalidate(); timer = nil; interval = 0
                if displayPulse == nil { displayPulse = DesktopPetDisplayPulse(owner: self, view: artwork) }
                return
            }
            (displayPulse as? DesktopPetDisplayPulse)?.stop(); displayPulse = nil
        }
        let delay: TimeInterval
        if !model.released || !suspended.isEmpty { delay = 0 }
        else if !model.visible { delay = 1 }
        else if !environment.reduceMotion && (model.isDragging || model.isSettling) {
            delay = model.isDragging && model.lift.spriteFrame == DesktopPetLift.carryFrame ? 1 / 30 : 1 / 60
        }
        else if model.isPressed { delay = 1 / 30 }
        else if model.pose == .petted { delay = 1 / 12 }
        else if environment.reduceMotion || environment.idleSeconds < 12 { delay = 1 }
        else if model.pose == .grooming { delay = 1 / 25 }
        else { delay = model.pose == .walking || model.pose == .yawning ? 1 / 12 : 1 / 4 }
        schedule(every: delay)
    }

    /// Observe pointer position only to let transparent padding pass through.
    /// Hover never moves the cat, changes its pose, or consumes a desktop event.
    func updateHitRegion(at point: CGPoint) {
        // 動態滑鼠穿透與命中測試：
        // 1. 面板為固定矩形且周圍有大量透明留白；預設 ignoresMouseEvents = true，點擊完全穿透至底層桌面。
        // 2. 只有當游標移動到非透明實體像素上方時（artwork.containsCat），才將 ignoresMouseEvents 設為 false。
        // 3. 特殊邊界條件：
        //    - model.isPressed（拖拽中）：必須保持 false，避免游標快速甩動暫時脫離圖案時遺失 drag 與 mouseUp。
        //    - isBusy()（錄音中、選單開啟或 Modal 存在）：必須強制設為 true，全面讓出滑鼠事件，避免干擾核心操作。
        guard model.visible, !remoteHosted, !disposed, suspended.isEmpty, !isBusy() else {
            panel.ignoresMouseEvents = true; return
        }
        if model.isPressed { panel.ignoresMouseEvents = false; return }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        panel.ignoresMouseEvents = !artwork.containsCat(local)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        if #available(macOS 14.0, *) { (displayPulse as? DesktopPetDisplayPulse)?.stop() }
        displayPulse = nil
        timer?.invalidate(); timer = nil
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        globalMouse = nil; localMouse = nil
        model.cancelPointer(now: clock())
        reader.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        panel.orderOut(nil)
        panel.close()
        onReleasedChange = nil
        onDragMoved = nil; onDragReleased = nil; onDragCancelled = nil
        onRemoteHostedChange = nil; onRemoteFrame = nil
        isBusy = { true }
    }

    private func world(now: TimeInterval) -> DesktopPetWorld {
        if var result = injectedWorld?() {
            result.hidden = result.hidden || !suspended.isEmpty || isBusy()
            return result
        }
        let screens = NSScreen.screens
        if model.released, suspended.isEmpty, now >= nextRefresh {
            nextRefresh = now + 2
            reader.refresh(screens: screens.map(\.frame), primaryTop: screens.first?.frame.maxY ?? 0) { [weak self] value in
                guard let self, self.model.released, !self.disposed else { return }
                self.snapshot = value
            }
        }
        return DesktopPetWorld(areas: screens.map(\.visibleFrame), perches: snapshot.perches,
                               cursor: NSEvent.mouseLocation,
                               idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!),
                               hidden: !suspended.isEmpty || snapshot.fullScreen || isBusy(),
                               reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func schedule(every delay: TimeInterval) {
        guard automaticallyTicks else { return }
        if delay == interval, timer != nil { return }
        timer?.invalidate(); timer = nil; interval = delay
        guard delay > 0 else { return }
        let timer = Timer(timeInterval: delay, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = delay * 0.15
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observeEnvironment() {
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.updateHitRegion(at: NSEvent.mouseLocation)
        }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateHitRegion(at: NSEvent.mouseLocation)
            return event
        }
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
            observers.append((center, token))
        }
        for (pause, resume, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        ] {
            observe(workspace, pause) { [weak self] in self?.suspended.insert(reason); self?.refresh() }
            observe(workspace, resume) { [weak self] in self?.suspended.remove(reason); self?.nextRefresh = 0; self?.refresh() }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.snapshot = .init(); self?.nextRefresh = 0; self?.refresh()
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.refresh() }
        // Lock notifications complement workspace session switching: both stop
        // the timer, and neither changes the system's sleep/energy settings.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.suspended.insert("lock"); self?.refresh()
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.suspended.remove("lock"); self?.nextRefresh = 0; self?.refresh()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.snapshot = .init(); self?.nextRefresh = 0; self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        for (center, token) in observers { center.removeObserver(token) }
    }

    #if DESKTOP_PET_TESTS
    var testPanel: NSPanel { panel }
    var testTimerActive: Bool { timer != nil }
    var usesDisplaySynchronization: Bool { displayPulse != nil }
    var testArtwork: DesktopPetView { artwork }
    func testSuspend(_ value: Bool) {
        if value { suspended.insert("test") } else { suspended.remove("test") }
        refresh()
    }
    #endif
}
