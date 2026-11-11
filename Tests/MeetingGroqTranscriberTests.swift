import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

/// 假的 Groq 伺服器：在背景執行緒回應，可擋住回應直到測試放行。不碰真網路、不需要任何 Key。
private final class FakeGroq: URLProtocol {
    static let lock = NSLock()
    static var holdResponse: DispatchSemaphore?
    static var onResponded: DispatchSemaphore?
    static var requests: [(headers: [String: String], body: Data)] = []
    static var stopCount = 0
    static var requestSeen = DispatchSemaphore(value: 0)
    private var stopped = false

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        holdResponse = nil
        onResponded = nil
        requests = []
        stopCount = 0
        requestSeen = DispatchSemaphore(value: 0)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.requests.append((request.allHTTPHeaderFields ?? [:], body))
        let hold = Self.holdResponse
        Self.lock.unlock()
        Self.requestSeen.signal()
        DispatchQueue.global().async { [self] in
            hold?.wait()
            guard !stopped else { return }
            let json = """
            {"text":"大家好 Grokbot","language":"zh","duration":4.0,
             "segments":[{"id":0,"start":0.0,"end":2.0,"text":" 大家好","avg_logprob":-0.1,"no_speech_prob":0.01},
                         {"id":1,"start":2.5,"end":4.0,"text":" Grokbot","avg_logprob":-0.2,"no_speech_prob":0.02}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
            Self.onResponded?.signal()
        }
    }

    override func stopLoading() {
        stopped = true
        Self.lock.lock(); Self.stopCount += 1; Self.lock.unlock()
    }
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeGroq.self]
    return URLSession(configuration: configuration)
}

private func makeAudio() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingGroqTests-\(UUID().uuidString).m4a")
    try! Data([1, 2, 3, 4]).write(to: url)
    return url
}

private func makeTranscriber(key: String? = "fake-test-key") -> MeetingGroqTranscriber {
    MeetingGroqTranscriber(readAPIKey: { key }, makePrompt: { _ in "詞庫提示：Grokbot、yui" },
                           session: makeSession())
}

private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

private func spin(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

@main
enum MeetingGroqTranscriberTests {
    static func main() {
        testCompletionReturnsToMainThreadWithParsedSegments()
        testMissingKeyFailsAsynchronouslyOnMain()
        testCancelWhileRequestInFlightDropsCallback()
        testCancelAfterBackgroundCompletionDropsCallback()
        testCancelBeforeBackgroundWorkStartsSendsNothing()
        testAllBossVocabularyTermsFitMeetingPrompt()
        print("Meeting Groq transcriber tests passed (6 scenarios, fake HTTP, no real key)")
    }

    // 老闆的 5 個常用詞（含最長的 DeepseekHarness）都要進得了會議的 prompt，且不超過 200 bytes。
    // 對照組：聽寫的中文說明（138 bytes）放同樣 5 個詞會被擠掉至少一個——這就是實測發現的問題。
    static func testAllBossVocabularyTermsFitMeetingPrompt() {
        let suite = "MeetingPrompt-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacVocabularyStore(defaults: defaults)
        let terms = ["Grokbot", "yui", "Stack", "claudecode", "DeepseekHarness"]
        for term in terms { _ = try? store.add(term: term) }
        expect(store.entries.count == 5, "5 terms stored")

        let meeting = store.buildPrompt(baseInstruction: MeetingGroqTranscriber.basePrompt(for: .traditionalChinese))
        expect(meeting.includedEntryIDs.count == 5, "all 5 terms included, got \(meeting.includedEntryIDs.count)")
        for term in terms { expect(meeting.text.contains(term), "\(term) in meeting prompt") }
        expect(meeting.text.utf8.count <= MacVocabularyStore.maximumPromptUTF8ByteCount, "within 200 bytes")

        let dictation = store.buildPrompt(baseInstruction: LanguageOption.traditionalChinese.transcriptionPrompt)
        expect(dictation.includedEntryIDs.count < 5, "control: dictation base still drops a term")
        expect(LanguageOption.traditionalChinese.transcriptionPrompt.utf8.count == 138, "dictation prompt untouched")
    }

    // 背景完成後必須回到 main；請求內容要是 verbose_json＋詞庫 prompt。
    static func testCompletionReturnsToMainThreadWithParsedSegments() {
        FakeGroq.reset()
        let audio = makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        var outcome: Result<TranscriptionResult, Error>?
        var onMain: Bool?
        var callbackCount = 0
        _ = makeTranscriber().transcribe(url: audio, language: .default) { result in
            onMain = Thread.isMainThread
            callbackCount += 1
            outcome = result
        }
        expect(outcome == nil, "completion is never synchronous")
        spin(until: { outcome != nil })
        guard case .success(let value)? = outcome else { expect(false, "expected success, got \(String(describing: outcome))"); return }
        expect(onMain == true, "completion must be delivered on the main thread")
        expect(value.segments.count == 2 && value.segments[1].start == 2.5 && value.segments[1].text == " Grokbot", "segments parsed")
        spin(for: 0.2)
        expect(callbackCount == 1, "exactly one callback")
        FakeGroq.lock.lock(); defer { FakeGroq.lock.unlock() }
        expect(FakeGroq.requests.count == 1, "one request")
        let request = FakeGroq.requests[0]
        let body = String(decoding: request.body, as: UTF8.self)
        expect(request.headers["Authorization"] == "Bearer fake-test-key", "bearer header from injected key")
        expect(body.contains("verbose_json"), "asks for verbose_json")
        expect(body.contains("timestamp_granularities[]") && body.contains("segment") && body.contains("word"), "segment + word granularity")
        expect(body.contains("詞庫提示：Grokbot、yui"), "vocabulary prompt sent")
        expect(body.contains("name=\"language\"\r\n\r\nzh"), "language code")
    }

    static func testMissingKeyFailsAsynchronouslyOnMain() {
        FakeGroq.reset()
        let audio = makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        var outcome: Result<TranscriptionResult, Error>?
        var onMain: Bool?
        _ = makeTranscriber(key: nil).transcribe(url: audio, language: .default) { result in
            onMain = Thread.isMainThread
            outcome = result
        }
        expect(outcome == nil, "failure is not delivered synchronously")
        spin(until: { outcome != nil })
        guard case .failure? = outcome else { expect(false, "expected failure"); return }
        expect(onMain == true, "failure delivered on main")
        FakeGroq.lock.lock(); defer { FakeGroq.lock.unlock() }
        expect(FakeGroq.requests.isEmpty, "no request without a key")
    }

    // 請求送出、回應被擋住時 cancel：URLSession 停止載入，回呼永遠不會來。
    static func testCancelWhileRequestInFlightDropsCallback() {
        FakeGroq.reset()
        let hold = DispatchSemaphore(value: 0)
        FakeGroq.holdResponse = hold
        let audio = makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        var callbacks = 0
        let token = makeTranscriber().transcribe(url: audio, language: .default) { _ in callbacks += 1 }
        let seen = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { FakeGroq.requestSeen.wait(); seen.signal() }
        spin(until: { seen.wait(timeout: .now()) == .success })
        token.cancel()
        hold.signal()
        spin(for: 0.5)
        expect(callbacks == 0, "no callback after cancel while in flight")
        FakeGroq.lock.lock(); defer { FakeGroq.lock.unlock() }
        expect(FakeGroq.stopCount >= 1, "url loading was stopped")
    }

    // 最刁鑽的情況：背景已經拿到成功回應，但 main 還沒來得及收；此時 cancel 必須讓回呼被丟掉。
    // main 在等待期間不跑 run loop，所以「回到 main」的那一步一定排在 cancel 之後。
    static func testCancelAfterBackgroundCompletionDropsCallback() {
        FakeGroq.reset()
        let responded = DispatchSemaphore(value: 0)
        FakeGroq.onResponded = responded
        let audio = makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        var callbacks = 0
        let token = makeTranscriber().transcribe(url: audio, language: .default) { _ in callbacks += 1 }
        expect(responded.wait(timeout: .now() + 5) == .success, "fake server responded")
        Thread.sleep(forTimeInterval: 0.2) // 讓 URLSession 的回呼在背景排好 main.async
        expect(callbacks == 0, "main has not run yet")
        token.cancel()
        spin(for: 0.5)
        expect(callbacks == 0, "result that finished in the background is dropped after cancel")
    }

    // 背景讀檔／送出之前就 cancel：連請求都不該送。
    static func testCancelBeforeBackgroundWorkStartsSendsNothing() {
        FakeGroq.reset()
        let audio = makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let gate = DispatchQueue(label: "MeetingGroqTests.gate")
        let release = DispatchSemaphore(value: 0)
        gate.async { release.wait() } // 先把工作佇列卡住
        var transcriber = makeTranscriber()
        transcriber.workQueue = gate
        var callbacks = 0
        let token = transcriber.transcribe(url: audio, language: .default) { _ in callbacks += 1 }
        token.cancel()
        release.signal()
        spin(for: 0.5)
        expect(callbacks == 0, "no callback")
        FakeGroq.lock.lock(); defer { FakeGroq.lock.unlock() }
        expect(FakeGroq.requests.isEmpty, "no request was sent")
    }
}
