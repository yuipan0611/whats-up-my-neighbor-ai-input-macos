import Foundation

@main
enum AgentPreviewTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreviewPreferencesStore(directory: root)
        precondition(store.loadProvider() == .codex)
        let model = RemoteAgentPreviewModel(preferences: store)
        precondition(!model.canSubmit && !model.isRunning)
        model.startDemo()
        precondition(model.errorMessage != nil && model.task == nil)
        model.selectProvider(.gemini)
        precondition(store.loadProvider() == .gemini)
        model.useExample()
        precondition(model.canSubmit)
        model.startDemo()
        precondition(model.task?.provider == .gemini && model.isRunning && !model.canSubmit)
        let id = model.task?.id
        model.startDemo(); model.selectProvider(.claude)
        precondition(model.task?.id == id && model.provider == .gemini)
        model.cancel()
        precondition(model.task?.status == .cancelled && model.task?.result == nil && model.canSubmit)
        let data = try Data(contentsOf: root.appendingPathComponent("preferences.json"))
        let saved = try JSONSerialization.jsonObject(with: data) as! [String: String]
        precondition(saved == ["provider": "gemini"], "Only provider selection may be persisted")
        try Data("invalid".utf8).write(to: root.appendingPathComponent("preferences.json"))
        precondition(store.loadProvider() == .codex)
        model.prompt = String(repeating: "字", count: 5_001)
        precondition(!model.canSubmit)
        precondition(PreviewPreferencesStore.bundleIdentifier != "tw.panh.FreeVoiceType")
        precondition(PreviewPreferencesStore().directory.lastPathComponent == PreviewPreferencesStore.bundleIdentifier)
        print("Agent preview model tests passed (input, lifecycle, provider and isolated persistence)")
    }
}
