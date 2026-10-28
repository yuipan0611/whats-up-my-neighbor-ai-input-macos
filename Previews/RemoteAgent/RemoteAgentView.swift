import SwiftUI
import AppKit

private enum PreviewPalette {
    static let secondary = Color(nsColor: NSColor(name: "PreviewSecondary") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(calibratedWhite: dark ? 0.74 : 0.36, alpha: 1)
    })
    static let error = Color(nsColor: NSColor(name: "PreviewError") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(calibratedRed: 1, green: 0.58, blue: 0.55, alpha: 1)
                    : NSColor(calibratedRed: 0.72, green: 0.12, blue: 0.10, alpha: 1)
    })
}

// THESIS: A native work panel makes demonstration versus remote work unmistakable.
// OWN-WORLD: Existing black cat, system type, semantic macOS surfaces and controls.
// STORY: Write a task, choose a provider label, run locally, inspect or cancel.
// FIRST VIEWPORT: Environment rail beside a task composer and chronological progress.
// FORM: Precisely scoped extension of the existing native product; no new visual world.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
struct RemoteAgentView: View {
    @ObservedObject var model: RemoteAgentPreviewModel
    @ObservedObject var handoff: RemoteDesktopHandoffModel

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView { sidebar.frame(minHeight: proxy.size.height) }
            }
            .frame(width: 220)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    composer
                    taskProgress
                    result
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                if let icon = Bundle.main.image(forResource: "AppIcon") {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("What's up").font(.headline)
                    Text("my neighbor").font(.subheadline)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("執行環境").font(.headline)
                Label("本機示範", systemImage: "desktopcomputer").fontWeight(.medium)
                Label("Linux VPS", systemImage: "server.rack").foregroundStyle(PreviewPalette.secondary)
                Text("等待 SSH 連線資料")
                    .font(.callout).foregroundStyle(PreviewPalette.secondary)
                    .padding(.leading, 23)
            }
            takeControl
            VStack(alignment: .leading, spacing: 10) {
                Text("選擇 AI").font(.headline)
                Picker("選擇 AI", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden().disabled(model.isRunning)
                .accessibilityLabel("示範 AI 標籤，三家皆待遠端驗證")
                Text("Codex、Gemini、Claude\n皆待遠端登入與功能驗證。")
                    .font(.callout).foregroundStyle(PreviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 9) {
                Label("獨立預覽", systemImage: "shield.lefthalf.filled").font(.headline)
                Text("任務示範只在本機執行，\n不呼叫 AI、不操作桌面。\n「接手控制」只在按下時\n才連線並開啟螢幕共享。")
                    .font(.callout).foregroundStyle(PreviewPalette.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var takeControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("接手控制").font(.headline)
            Picker("接手目標", selection: $handoff.targetKind) {
                ForEach(RemoteDesktopTargetKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden().disabled(handoff.isActive)
            .accessibilityLabel("接手目標")
            if handoff.targetKind == .linuxVPS {
                TextField("SSH 主機別名", text: $handoff.hostAlias)
                    .textFieldStyle(.roundedBorder).disabled(handoff.isActive)
                    .onSubmit { handoff.start() }
                    .accessibilityLabel("SSH 主機別名，需為 ssh_config 既有別名")
            }
            if handoff.isActive {
                Button("結束接手") { handoff.stop() }
                    .disabled(!handoff.canStop)
            } else {
                Button("接手控制") { handoff.start() }
                    .disabled(!handoff.canStart)
                    .help("確認 VNC 伺服器有回應後，用「螢幕共享」開啟遠端桌面")
            }
            if let status = handoff.statusText {
                HStack(alignment: .top, spacing: 6) {
                    if handoff.isWorking { ProgressView().controlSize(.small) }
                    Text(status).font(.callout).foregroundStyle(PreviewPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let failure = handoff.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(PreviewPalette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("需先在遠端啟動 VNC 伺服器，設定見 docs/remote-desktop/SETUP.md。")
                .font(.caption).foregroundStyle(PreviewPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("遠端分身").font(.system(size: 26, weight: .semibold))
                Spacer()
                Label("示範模式", systemImage: "info.circle")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }
            Text("先試著交辦一件事")
                .font(.title3.weight(.medium))
            Text("這裡先示範任務流程；接上 VPS 後，才能執行真正的遠端工作。")
                .foregroundStyle(PreviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("任務內容").font(.headline)
                Spacer()
                Button("填入範例") { model.useExample() }.disabled(model.isRunning)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.prompt)
                    .font(.body).padding(5).frame(height: 92)
                    .disabled(model.isRunning)
                    .accessibilityLabel("任務內容")
                if model.prompt.isEmpty {
                    Text("例如：查詢三個網頁，整理重點與來源，存到備忘錄。")
                        .foregroundStyle(PreviewPalette.secondary).padding(10)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack(spacing: 12) {
                Button("執行示範") { model.startDemo() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSubmit)
                    .help("⌘ Return 執行本機示範")
                if model.isRunning {
                    Button("取消示範") { model.cancel() }.keyboardShortcut(.cancelAction)
                }
                Spacer(minLength: 0)
                Text("\(model.prompt.count) / 5,000 字")
                    .font(.caption).foregroundStyle(model.prompt.count > 5_000 ? PreviewPalette.error : PreviewPalette.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(PreviewPalette.error).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var taskProgress: some View {
        if let task = model.task {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack {
                    Text(statusTitle(task)).font(.headline)
                    Spacer()
                    Text(task.provider.displayName).font(.callout).foregroundStyle(PreviewPalette.secondary)
                }
                if task.status == .running || task.status == .completed {
                    ProgressView(value: task.progress).accessibilityLabel("示範進度")
                }
                ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: event.kind == .completed ? "checkmark.circle" : "circle.fill")
                            .font(event.kind == .completed ? .body : .system(size: 6))
                            .frame(width: 16, height: 17).foregroundStyle(PreviewPalette.secondary)
                            .accessibilityHidden(true)
                        Text(event.message).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if task.status == .cancelled {
                    Text("示範已停止。你可以修改內容，再執行一次。")
                        .foregroundStyle(PreviewPalette.secondary)
                }
                if let failure = task.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PreviewPalette.error).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.bottom, 5)
                Label("任務會在這裡展開", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Text("輸入內容或填入範例，看看進度、取消與結果如何呈現。")
                    .foregroundStyle(PreviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var result: some View {
        if let text = model.task?.result, model.task?.status == .completed {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Text("示範結果").font(.headline)
                Text(text).textSelection(.enabled).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusTitle(_ task: AgentTask) -> String {
        switch task.status {
        case .running: return "正在執行本機示範"
        case .completed: return "示範流程完成"
        case .cancelled: return "已取消示範"
        case .failed: return "示範未完成"
        }
    }
}
