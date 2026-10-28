import SwiftUI

/// Title bar plus the remote screen; status appears only while connecting or after a failure.
struct VPSDesktopView: View {
    @ObservedObject var panel: VPSDesktopPanel
    @ObservedObject var connection: VPSDesktopConnection
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("VPS 電腦").font(.system(size: 13, weight: .semibold))
                Spacer()
                if panel.catInside && !panel.collapsed {
                    Button("叫牠回家") { panel.returnCat?() }.accessibilityLabel("叫貓咪回本機")
                }
                if connection.connected && !panel.collapsed {
                    Button(connection.controlling ? "結束接手" : "接手操作") { connection.toggleControl() }
                        .accessibilityLabel(connection.controlling ? "結束接手" : "接手操作")
                    Button("中斷") { connection.confirmDisconnect = true }.accessibilityLabel("中斷 VPS 連線")
                }
                Button { panel.toggle?() } label: { Image(systemName: panel.collapsed ? "chevron.down" : "chevron.up").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel(panel.collapsed ? "展開 VPS 面板" : "收合 VPS 面板")
            }.font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
            .padding(.leading, 80).padding(.trailing, 14).frame(height: 48)
            if !panel.collapsed {
                Divider().opacity(0.45)
                ZStack {
                    VPSDesktopSurface(connection: connection)
                    if connection.loading {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(connection.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0xFAF8F9))
                    } else if !connection.connected && !connection.awaitingCredentials {
                        VStack(spacing: 12) {
                            Text(connection.status).font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("重新連線") { connection.connect() }.buttonStyle(.borderedProminent)
                                .accessibilityLabel("重新連線")
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0xFAF8F9))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()

            }
        }.background(Color.white).preferredColorScheme(.light).ignoresSafeArea()
        .alert("確定中斷 VPS 連線？", isPresented: $connection.confirmDisconnect) {
            Button("繼續連線", role: .cancel) {}
            Button("中斷連線", role: .destructive) { connection.disconnect() }
        } message: {
            Text("只是想暫時收起視窗，請使用右上角收合按鈕，連線會保留。")
        }
    }
}

final class VPSDesktopPanel: ObservableObject {
    @Published var collapsed = false
    @Published var catInside = false
    @Published var dropHovered = false
    var toggle: (() -> Void)?
    var returnCat: (() -> Void)?
}

private extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
