import Foundation
import Combine

final class PreviewPreferencesStore {
    static let bundleIdentifier = "tw.panh.NeighborRemoteAgentPreview"
    let directory: URL
    private struct Preferences: Codable { let provider: AgentProvider }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
    }

    func loadProvider() -> AgentProvider {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("preferences.json")),
              data.count <= 2_048,
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else { return .codex }
        return preferences.provider
    }

    func saveProvider(_ provider: AgentProvider) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("preferences.json")
        try JSONEncoder().encode(Preferences(provider: provider)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class RemoteAgentPreviewModel: ObservableObject {
    @Published var prompt = ""
    @Published private(set) var provider: AgentProvider
    @Published private(set) var task: AgentTask?
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var errorMessage: String?
    let coordinator = AgentTaskCoordinator()
    private let preferences: PreviewPreferencesStore
    private let adapterFactory: (AgentProvider) -> ProviderAdapter

    init(preferences: PreviewPreferencesStore = PreviewPreferencesStore(),
         adapterFactory: @escaping (AgentProvider) -> ProviderAdapter = { DemoProviderAdapter(provider: $0) }) {
        self.preferences = preferences
        self.adapterFactory = adapterFactory
        provider = preferences.loadProvider()
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            self.task = self.coordinator.task
            self.events = self.coordinator.events
        }
    }

    var isRunning: Bool { task?.status == .running }
    var canSubmit: Bool {
        !isRunning && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.count <= 5_000
    }

    func selectProvider(_ provider: AgentProvider) {
        guard !isRunning else { return }
        self.provider = provider
        do { try preferences.saveProvider(provider); errorMessage = nil }
        catch { errorMessage = "無法儲存 AI 選擇，本次仍可繼續示範。" }
    }

    func useExample() {
        guard !isRunning else { return }
        prompt = "查詢三個介紹 Linux 遠端桌面的網頁，整理重點與來源，存到備忘錄。"
    }

    func startDemo() {
        guard !isRunning else { return }
        errorMessage = nil
        do { try coordinator.submit(prompt: prompt, using: adapterFactory(provider)) }
        catch { errorMessage = error.localizedDescription }
    }

    func cancel() { coordinator.cancel() }
}
