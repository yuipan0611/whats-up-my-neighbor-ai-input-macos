import AppKit

/// Edits a value snapshot. The live desktop is updated only by the owner's
/// save callback; closing this window leaves the active appearance alone.
final class CatCustomizationWindowController: NSWindowController, NSWindowDelegate {
    private(set) var draft: CatAppearance
    var onSave: ((CatAppearance, String) throws -> Void)?
    var onExport: ((CatAppearance, String, Data?) throws -> Bool)?
    private let nameField = NSTextField(string: "")
    private let presets = NSPopUpButton()
    private let poses = NSPopUpButton()
    private let parts = NSPopUpButton()
    private let patterns = NSPopUpButton()
    private let partColor = NSColorWell()
    private let patternColor = NSColorWell()
    private let leftEyeToggle = NSButton(checkboxWithTitle: "左眼", target: nil, action: nil)
    private let rightEyeToggle = NSButton(checkboxWithTitle: "右眼", target: nil, action: nil)
    private let leftEyeColor = NSColorWell()
    private let rightEyeColor = NSColorWell()
    private let noseShape = NSPopUpButton()
    private let noseColor = NSColorWell()
    private let freckles = NSButton(checkboxWithTitle: "鼻旁小斑點", target: nil, action: nil)
    private let collarToggle = NSButton(checkboxWithTitle: "項圈", target: nil, action: nil)
    private let collarColor = NSColorWell()
    private let bowToggle = NSButton(checkboxWithTitle: "蝴蝶結", target: nil, action: nil)
    private let bowColor = NSColorWell()
    private let knotColor = NSColorWell()
    private let bowPosition = NSPopUpButton()
    private let facing = NSButton(checkboxWithTitle: "向左", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let preview: DesktopPetView
    private var timer: Timer?
    private var phase: Double = 0

    init(appearance: CatAppearance, name: String = "我的貓咪", resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("DesktopPet")) {
        draft = appearance
        preview = DesktopPetView(resources: resources, appearance: appearance)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "自訂貓咪"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        super.init(window: window)
        window.delegate = self
        nameField.stringValue = name
        buildInterface()
        restoreControls()
        window.center()
    }

    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            timer = Timer(timeInterval: 1 / 24, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        for well in [partColor, patternColor, leftEyeColor, rightEyeColor, noseColor, collarColor, bowColor, knotColor] {
            well.deactivate()
        }
    }

    private func buildInterface() {
        let title = label("讓牠有自己的樣子", 26, 598, 500, 26)
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        label("毛色、左右眼與小配件，都能跟著同一套動作。", 26, 569, 700, 22).textColor = .secondaryLabelColor
        label("名字", 26, 528, 50, 24)
        place(nameField, 76, 530, 220, 24)
        nameField.placeholderString = "替這隻貓取個名字"
        label("底色", 320, 528, 46, 24)
        presets.addItems(withTitles: CatAppearance.presetNames)
        wire(presets, #selector(selectPreset))
        place(presets, 368, 527, 180, 28)

        let stage = NSView(frame: CGRect(x: 26, y: 258, width: 270, height: 250))
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor(srgbRed: 0.965, green: 0.954, blue: 0.928, alpha: 1).cgColor
        stage.layer?.cornerRadius = 16
        preview.frame.origin = CGPoint(x: 31, y: 47)
        stage.addSubview(preview)
        let caption = NSTextField(labelWithString: "動作預覽")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.frame = CGRect(x: 16, y: 16, width: 95, height: 18)
        stage.addSubview(caption)
        window!.contentView!.addSubview(stage)
        poses.addItems(withTitles: DesktopPetPose.allCases.map(\.description))
        wire(poses, #selector(selectPose))
        place(poses, 26, 221, 190, 28)
        wire(facing, #selector(selectPose))
        place(facing, 225, 224, 70, 24)

        label("眼睛", 320, 477, 60, 24)
        wire(leftEyeToggle, #selector(changeFeatures))
        wire(rightEyeToggle, #selector(changeFeatures))
        place(leftEyeToggle, 380, 477, 68, 24)
        place(leftEyeColor, 449, 474, 43, 29)
        place(rightEyeToggle, 518, 477, 68, 24)
        place(rightEyeColor, 587, 474, 43, 29)
        label("左右以正面畫面為準；取消／完成操作照常。", 380, 452, 350, 18).font = .systemFont(ofSize: 11)
        noseShape.addItems(withTitles: ["原本鼻子", "小三角", "圓鼻子", "愛心鼻子"])
        wire(noseShape, #selector(changeFeatures))
        label("鼻子", 320, 411, 60, 24)
        place(noseShape, 380, 410, 126, 28)
        place(noseColor, 518, 410, 43, 29)
        wire(freckles, #selector(changeFeatures))
        place(freckles, 578, 413, 150, 24)
        wire(collarToggle, #selector(changeFeatures))
        place(collarToggle, 320, 365, 110, 24)
        place(collarColor, 449, 362, 43, 29)
        wire(bowToggle, #selector(changeFeatures))
        place(bowToggle, 320, 318, 110, 24)
        place(bowColor, 449, 315, 43, 29)
        label("結心", 513, 318, 50, 24)
        place(knotColor, 567, 315, 43, 29)
        label("位置", 380, 276, 55, 24)
        bowPosition.addItems(withTitles: ["頸前", "左耳", "右耳"])
        wire(bowPosition, #selector(changeFeatures))
        place(bowPosition, 449, 273, 162, 28)

        for (well, name) in [(leftEyeColor, "左眼顏色"), (rightEyeColor, "右眼顏色"),
                             (noseColor, "鼻子顏色"), (collarColor, "項圈顏色"),
                             (bowColor, "蝴蝶結顏色"), (knotColor, "結心顏色")] {
            wire(well, #selector(changeFeatures))
            well.setAccessibilityLabel(name)
        }

        let separator = NSBox()
        separator.boxType = .separator
        place(separator, 26, 200, 708, 1)
        label("部位毛色", 26, 166, 100, 22).font = .systemFont(ofSize: 13, weight: .semibold)
        parts.addItems(withTitles: ["頭臉", "左耳", "右耳", "口鼻", "胸前", "腹部", "身體",
            "左前肢", "右前肢", "左後肢", "右後肢", "左前腳掌", "右前腳掌", "左後腳掌", "右後腳掌", "尾巴"])
        wire(parts, #selector(selectPart))
        place(parts, 26, 128, 145, 28)
        label("底色", 186, 131, 40, 22)
        place(partColor, 230, 127, 43, 29)
        patterns.addItems(withTitles: ["無花紋", "虎斑", "拼色", "三花", "斑塊", "重點色"])
        wire(patterns, #selector(changePart))
        place(patterns, 300, 128, 136, 28)
        label("花紋色", 455, 131, 60, 22)
        place(patternColor, 519, 127, 43, 29)
        wire(partColor, #selector(changePart))
        wire(patternColor, #selector(changePart))
        partColor.setAccessibilityLabel("部位底色")
        patternColor.setAccessibilityLabel("部位花紋色")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = "調整會先顯示在預覽中；儲存後立即套用到桌面。"
        place(status, 26, 72, 708, 39)
        let export = NSButton(title: "匯出貓咪包…", target: self, action: #selector(exportPack))
        export.bezelStyle = .rounded
        place(export, 26, 24, 145, 32)
        let save = NSButton(title: "儲存並套用", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        place(save, 581, 24, 153, 32)
    }

    private func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        view.frame = CGRect(x: x, y: y, width: width, height: height)
        window!.contentView!.addSubview(view)
    }
    @discardableResult private func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        place(label, x, y, width, height)
        return label
    }
    private func wire(_ control: NSControl, _ selector: Selector) {
        control.target = self
        control.action = selector
    }
    private func restoreControls() {
        presets.selectItem(at: CatAppearance.presetIDs.firstIndex(of: draft.preset) ?? 0)
        let f = draft.features
        leftEyeToggle.state = f.eyes.left == nil ? .off : .on
        rightEyeToggle.state = f.eyes.right == nil ? .off : .on
        leftEyeColor.color = Self.color(f.eyes.left ?? "#81AFC2")
        rightEyeColor.color = Self.color(f.eyes.right ?? "#D8AD59")
        noseShape.selectItem(at: CatNoseShape.allCases.firstIndex(of: f.nose.shape) ?? 0)
        noseColor.color = Self.color(f.nose.color)
        freckles.state = f.nose.freckles ? .on : .off
        collarToggle.state = f.collar.enabled ? .on : .off
        collarColor.color = Self.color(f.collar.color)
        bowToggle.state = f.bow.enabled ? .on : .off
        bowColor.color = Self.color(f.bow.color)
        knotColor.color = Self.color(f.bow.knotColor)
        bowPosition.selectItem(at: CatBowPosition.allCases.firstIndex(of: f.bow.position) ?? 0)
        updateEnabledControls()
        selectPart()
    }
    private func updateEnabledControls() {
        leftEyeColor.isEnabled = leftEyeToggle.state == .on
        rightEyeColor.isEnabled = rightEyeToggle.state == .on
        noseColor.isEnabled = noseShape.indexOfSelectedItem != 0 || freckles.state == .on
        collarColor.isEnabled = collarToggle.state == .on
        bowColor.isEnabled = bowToggle.state == .on
        knotColor.isEnabled = bowToggle.state == .on
        bowPosition.isEnabled = bowToggle.state == .on
    }
    @objc private func selectPreset() {
        guard let base = CatAppearance.makePreset(CatAppearance.presetIDs[presets.indexOfSelectedItem]) else { return }
        draft = base.replacingFeatures(draft.features)
        selectPart()
        updatePreview()
    }
    @objc private func selectPart() {
        let style = draft[CatBodyPart.allCases[max(0, parts.indexOfSelectedItem)]]
        partColor.color = Self.color(style.color)
        patternColor.color = Self.color(style.patternColor)
        patterns.selectItem(at: CatPattern.allCases.firstIndex(of: style.pattern) ?? 0)
    }
    @objc private func changePart() {
        var object = draft.jsonObject
        var partValues = object["parts"] as! [String: [String: String]]
        partValues[CatBodyPart.allCases[parts.indexOfSelectedItem].rawValue] = [
            "color": Self.hex(partColor.color), "patternColor": Self.hex(patternColor.color),
            "pattern": CatPattern.allCases[patterns.indexOfSelectedItem].rawValue]
        object["parts"] = partValues
        do { draft = try CatAppearance.parse(object); updatePreview() }
        catch { status.stringValue = "無法套用這組部位設定，請再試一次。" }
    }
    @objc private func changeFeatures() {
        var f = draft.features
        f.eyes.left = leftEyeToggle.state == .on ? Self.hex(leftEyeColor.color) : nil
        f.eyes.right = rightEyeToggle.state == .on ? Self.hex(rightEyeColor.color) : nil
        f.nose.shape = CatNoseShape.allCases[noseShape.indexOfSelectedItem]
        f.nose.color = Self.hex(noseColor.color)
        f.nose.freckles = freckles.state == .on
        f.collar.enabled = collarToggle.state == .on
        f.collar.color = Self.hex(collarColor.color)
        f.bow.enabled = bowToggle.state == .on
        f.bow.color = Self.hex(bowColor.color)
        f.bow.knotColor = Self.hex(knotColor.color)
        f.bow.position = CatBowPosition.allCases[bowPosition.indexOfSelectedItem]
        draft = draft.replacingFeatures(f)
        updateEnabledControls()
        updatePreview()
    }
    private func updatePreview() {
        preview.setAppearance(draft)
        status.stringValue = "預覽已更新；按「儲存並套用」保留這次調整。"
    }
    @objc private func selectPose() {
        phase = 0
        preview.pose = DesktopPetPose.allCases[poses.indexOfSelectedItem]
        preview.facingLeft = facing.state == .on
        preview.needsDisplay = true
    }
    private func tick() {
        guard window?.isVisible == true else { return }
        phase += 1 / 24
        preview.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        preview.phase = phase
        preview.walkDistance = CGFloat(phase * 22)
        if preview.pose == .carried {
            preview.lift.spriteFrame = DesktopPetLift.travel(from: 0, to: 31, elapsed: phase.truncatingRemainder(dividingBy: 3))
        } else { preview.lift = DesktopPetLift() }
        preview.needsDisplay = true
    }
    private func checkedName() throws -> String {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NSError(domain: "CatCustomization", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "請輸入 1–64 字的貓咪名字。"])
        }
        return name
    }
    @objc private func save() {
        do {
            try onSave?(draft, checkedName())
            status.stringValue = "已儲存並套用到桌面；也可以匯出，讓別台電腦使用。"
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func exportPack() {
        do {
            if try onExport?(draft, checkedName(), previewPNG()) == true {
                status.stringValue = "貓咪包已匯出。安裝 App 後雙擊檔案，即可使用這隻貓。"
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func previewPNG() -> Data? {
        guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { return nil }
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
    private static func color(_ hex: String) -> NSColor {
        let n = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((n >> 16) & 255) / 255,
                       green: CGFloat((n >> 8) & 255) / 255,
                       blue: CGFloat(n & 255) / 255, alpha: 1)
    }
    private static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .black
        func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(c.redComponent), channel(c.greenComponent), channel(c.blueComponent))
    }

    #if CAT_CUSTOMIZATION_TESTS
    var testPreview: DesktopPetView { preview }
    func testSave() { save() }
    func testDisableLeftEye() { leftEyeToggle.state = .off; changeFeatures() }
    #endif
}
