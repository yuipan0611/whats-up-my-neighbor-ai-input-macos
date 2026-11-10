import Foundation

/// 取消把手：涵蓋「背景讀檔完成前」這段空窗，與 `GroqDictationTranscriber` 的做法相同。
private final class PendingMeetingRequest: DictationCancellable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?

    func attach(_ task: URLSessionDataTask?) {
        lock.lock()
        self.task = task
        if cancelled { task?.cancel() } else { task?.resume() }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// 會議專用的 Groq 辨識：用 `.verboseWithWords` 拿 segment 時間，其餘沿用
/// `GroqTranscriptionClient`（逾時、模型、temperature 都不改）。
struct MeetingGroqTranscriber: MeetingTranscribing {
    let readAPIKey: () -> String?
    /// 在主執行緒呼叫（詞庫學習資料只能在主執行緒讀）。
    let makePrompt: (LanguageSettings) -> String
    var workQueue: DispatchQueue = .global(qos: .utility)
    /// 測試用：換成帶假 URLProtocol 的 session，不碰真網路。
    var session: URLSession = .shared

    func transcribe(
        url: URL, language: LanguageSettings,
        completion: @escaping (Result<TranscriptionResult, Error>) -> Void
    ) -> DictationCancellable {
        let pending = PendingMeetingRequest()
        guard let apiKey = readAPIKey() else {
            DispatchQueue.main.async {
                completion(.failure(VoiceTypeError.message("無法讀取 Groq API Key，請重新設定金鑰。")))
            }
            return pending
        }
        let prompt = makePrompt(language)
        let code = language.primary.rawValue
        workQueue.async {
            guard !pending.isCancelled else { return }
            let task = GroqTranscriptionClient.transcribe(
                audioURL: url, apiKey: apiKey, language: code,
                prompt: prompt, format: .verboseWithWords, session: session, startImmediately: false
            ) { result in
                DispatchQueue.main.async {
                    guard !pending.isCancelled else { return }
                    completion(result)
                }
            }
            pending.attach(task)
        }
        return pending
    }
}
