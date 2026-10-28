import AppKit

/// Transparent hit surface over the existing VNC viewer. Only the painted cat
/// receives mouse events, so the rest of the remote desktop stays usable.
final class VPSCatHostView: NSView {
    let artwork: DesktopPetView
    var acceptsCatInput = false {
        didSet { isHidden = !acceptsCatInput }
    }
    var followsRemoteDrag = false {
        didSet { artwork.alphaValue = followsRemoteDrag ? 0.001 : 1 }
    }

    init(resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("DesktopPet"), appearance: CatAppearance) {
        artwork = DesktopPetView(resources: resources, appearance: appearance)
        super.init(frame: CGRect(origin: .zero, size: DesktopPetView.panelSize))
        wantsLayer = true
        artwork.frame = bounds
        artwork.autoresizingMask = [.width, .height]
        addSubview(artwork)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsCatInput else { return nil }
        let local = artwork.convert(point, from: superview)
        return artwork.containsCat(local) ? artwork : nil
    }
}

/// Keep the cat outside NSHostingView's managed child hierarchy so SwiftUI/WKWebView
/// cannot paint over it after a remote frame arrives.
final class VPSDesktopContentView: NSView {
    let desktop: NSView
    let cat: VPSCatHostView

    init(desktop: NSView, cat: VPSCatHostView) {
        self.desktop = desktop
        self.cat = cat
        super.init(frame: .zero)
        wantsLayer = true
        desktop.autoresizingMask = [.width, .height]
        cat.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        addSubview(desktop)
        addSubview(cat, positioned: .above, relativeTo: desktop)
        cat.layer?.zPosition = 1
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        desktop.frame = bounds
        cat.frame = CGRect(x: max(0, (bounds.width - DesktopPetView.panelSize.width) / 2),
                           y: 8, width: DesktopPetView.panelSize.width, height: DesktopPetView.panelSize.height)
    }
}
