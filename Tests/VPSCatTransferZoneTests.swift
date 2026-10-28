import CoreGraphics

@main enum VPSCatTransferZoneTests {
    static func main() {
        let window = CGRect(x: 600, y: 200, width: 450, height: 330)
        let inside = CGPoint(x: 650, y: 350)
        precondition(VPSCatTransferZone.accepts(inside, window: window, connected: true, collapsed: false, visible: true))
        precondition(!VPSCatTransferZone.accepts(inside, window: window, connected: false, collapsed: false, visible: true))
        precondition(!VPSCatTransferZone.accepts(inside, window: window, connected: true, collapsed: true, visible: true))
        precondition(!VPSCatTransferZone.accepts(inside, window: window, connected: true, collapsed: false, visible: false))
        precondition(!VPSCatTransferZone.accepts(CGPoint(x: 800, y: 510), window: window, connected: true, collapsed: false, visible: true))
        precondition(!VPSCatTransferZone.hasExited(CGPoint(x: 800, y: 250), window: window))
        precondition(VPSCatTransferZone.hasExited(CGPoint(x: 400, y: 250), window: window))
        let nearEdge = CGPoint(x: window.minX - 5, y: window.midY)
        precondition(VPSCatTransferZone.accepts(nearEdge, window: window, connected: true, collapsed: false, visible: true))
        precondition(!VPSCatTransferZone.accepts(CGPoint(x: window.minX - 70, y: window.midY), window: window, connected: true, collapsed: false, visible: true))
        precondition(!VPSCatTransferZone.accepts(CGPoint(x: window.maxX - 20, y: window.midY), window: window, connected: true, collapsed: false, visible: true))
        print("VPS cat transfer zone tests passed.")
    }
}
