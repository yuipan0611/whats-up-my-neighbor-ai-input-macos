import CoreGraphics

/// Screen-coordinate hit region for the existing VPS window's desktop area.
struct VPSCatTransferZone {
    static func accepts(_ point: CGPoint, window: CGRect, connected: Bool,
                        collapsed: Bool, visible: Bool) -> Bool {
        guard connected, !collapsed, visible, window.width >= 220, window.height >= 120 else { return false }
        return VPSCatDropHintGeometry.screenRect(VPSCatDropHintGeometry.entry, window: window).contains(point)
    }

    static func hasExited(_ point: CGPoint, window: CGRect) -> Bool {
        !window.contains(point)
    }
}
