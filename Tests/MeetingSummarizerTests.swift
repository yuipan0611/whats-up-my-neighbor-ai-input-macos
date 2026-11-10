import Foundation

// MARK: - 離線測試網路攔截協議

private final class OfflineMeetingProtocol: URLProtocol {
    private static let lock = NSLock()
    static var mockModelsJSON: String = ""
    static var mockChatResponseJSON: String = ""
    static var mockStatusCode: Int = 200
    static var capturedRequests: [URLRequest] = []

    static func reset(
        modelsJSON: String = "",
        chatJSON: String = "",
        statusCode: Int = 200
    ) {
        lock.lock()
        defer { lock.unlock() }
        mockModelsJSON = modelsJSON
        mockChatResponseJSON = chatJSON
        mockStatusCode = statusCode
        capturedRequests.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let statusCode = Self.mockStatusCode
        let url = request.url!
        let responseData: Data

        if url.path.hasSuffix("/models") {
            responseData = Data(Self.mockModelsJSON.utf8)
        } else if url.path.hasSuffix("/chat/completions") {
            responseData = Data(Self.mockChatResponseJSON.utf8)
        } else {
            responseData = Data(#"{"error":{"message":"未知 endpoint"}}"#.utf8)
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - 測試斷言輔助函式

private func expect<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}

private func expectTrue(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, message, file: file, line: line)
}

// MARK: - 測試主程式

@main
enum MeetingSummarizerTests {
    static func main() throws {
        testModelParsing()
        testModelSelectionPreferencePriority()
        testModelSelectionFallbackToSecondPreference()
        testModelSelectionFallbackToMaxContextWindow()
        testModelSelectionExcludesNonChatModels()
        testChatRequestAssembly()
        testChatResponseParsingAndFrontmatter()
        testEndToEndOfflineSummaryGeneration()
        testAPIErrorExtraction()
        testMeetingStoreSummaryWritingAndIndependence()
        testSummaryFailureDoesNotAffectTranscript()
        testLatestSummaryURLOrdersTenBeforeNineInSameMinute()
        print("Meeting summarizer tests passed (12 suites)")
    }

    // MARK: - 模型解析與挑選測試

    static func testModelParsing() {
        let json = #"""
        {
          "data": [
            {"id": "whisper-large-v3", "active": true, "context_window": 448},
            {"id": "llama-3.3-70b-versatile", "active": true, "context_window": 131072},
            {"id": "llama-guard-3-8b", "active": true, "context_window": 8192}
          ]
        }
        """#
        let models = try! GroqModelSelector.parseModels(from: Data(json.utf8))
        expect(models.count, 3)
        expect(models[0].isChatModel, false)
        expect(models[1].isChatModel, true)
        expect(models[2].isChatModel, false)
    }

    static func testModelSelectionPreferencePriority() {
        let models = [
            GroqModelInfo(id: "llama-3.3-70b-versatile", contextWindow: 131072, active: true),
            GroqModelInfo(id: "openai/gpt-oss-120b", contextWindow: 131072, active: true),
            GroqModelInfo(id: "llama-3.1-8b-instant", contextWindow: 131072, active: true)
        ]
        // 預設偏好首選為 openai/gpt-oss-120b
        let selected = try! GroqModelSelector.selectModel(from: models)
        expect(selected, "openai/gpt-oss-120b")
    }

    static func testModelSelectionFallbackToSecondPreference() {
        let models = [
            GroqModelInfo(id: "llama-3.3-70b-versatile", contextWindow: 131072, active: true),
            GroqModelInfo(id: "llama-3.1-8b-instant", contextWindow: 131072, active: true)
        ]
        // 首選 openai/gpt-oss-120b 不在清單中時，挑選第二順位 llama-3.3-70b-versatile
        let selected = try! GroqModelSelector.selectModel(from: models)
        expect(selected, "llama-3.3-70b-versatile")
    }

    static func testModelSelectionFallbackToMaxContextWindow() {
        let models = [
            GroqModelInfo(id: "custom-small-chat", contextWindow: 8192, active: true),
            GroqModelInfo(id: "custom-large-chat", contextWindow: 65536, active: true),
            GroqModelInfo(id: "custom-medium-chat", contextWindow: 32768, active: true)
        ]
        // 偏好清單皆不存在時，動態挑選 context_window 最大者 (65536)
        let selected = try! GroqModelSelector.selectModel(from: models)
        expect(selected, "custom-large-chat")
    }

    static func testModelSelectionExcludesNonChatModels() {
        let models = [
            GroqModelInfo(id: "whisper-large-v3", contextWindow: 448, active: true),
            GroqModelInfo(id: "llama-guard-3-8b", contextWindow: 8192, active: true)
        ]
        var failed = false
        do {
            _ = try GroqModelSelector.selectModel(from: models)
        } catch {
            failed = true
        }
        expectTrue(failed, "當清單僅有音訊與守衛模型時應拋出錯誤")
    }

    // MARK: - 提示詞與請求組裝測試

    static func testChatRequestAssembly() {
        let transcript = "[00:01:00] Speaker 1: 我們開會討論 Grokbot。"
        let request = try! MeetingSummarizer.makeChatRequest(
            model: "llama-3.3-70b-versatile",
            transcript: transcript,
            apiKey: "fake-test-key"
        )

        expect(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        expect(request.httpMethod, "POST")
        expect(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-key")
        expect(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        expect(body["model"] as? String, "llama-3.3-70b-versatile")
        expect(body["temperature"] as? Double, 0.1)

        let messages = body["messages"] as! [[String: Any]]
        expect(messages.count, 2)
        expect(messages[0]["role"] as? String, "system")
        let systemPrompt = messages[0]["content"] as! String
        expectTrue(systemPrompt.contains("嚴格防提示詞注入"), "系統提示詞必須包含防注入說明")
        expectTrue(systemPrompt.contains("<transcript>"), "系統提示詞必須說明標籤邊界")
        expectTrue(systemPrompt.contains("未提及"), "系統提示詞必須包含未提及規則")

        expect(messages[1]["role"] as? String, "user")
        let userPrompt = messages[1]["content"] as! String
        expectTrue(userPrompt.contains("<transcript>\n[00:01:00] Speaker 1: 我們開會討論 Grokbot。\n</transcript>"), "使用者提示詞必須包裹原始逐字稿")
    }

    // MARK: - 回應解析與 Frontmatter 測試

    static func testChatResponseParsingAndFrontmatter() {
        let mockContent = """
        ## 摘要
        - [00:01:00] 討論 Grokbot。

        ## 決議
        - 未提及

        ## 待辦
        - 未提及

        ## 未解決問題
        - 未提及
        """
        let chatJSON = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "\(mockContent.replacingOccurrences(of: "\n", with: "\\n"))"
              }
            }
          ]
        }
        """

        let fixedDate = Date(timeIntervalSince1970: 1794333600) // 2026-11-11
        let result = try! MeetingSummarizer.parseChatResponse(
            data: Data(chatJSON.utf8),
            model: "llama-3.3-70b-versatile",
            generatedAt: fixedDate
        )

        expectTrue(result.contains("model: llama-3.3-70b-versatile"), "輸出必須包含 model frontmatter")
        expectTrue(result.contains("generated_at:"), "輸出必須包含 generated_at frontmatter")
        expectTrue(result.contains("## 摘要\n- [00:01:00] 討論 Grokbot。"), "輸出必須保留完整摘要本文")
    }

    // MARK: - 端到端離線整合測試

    static func testEndToEndOfflineSummaryGeneration() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        let modelsJSON = #"""
        {
          "data": [
            {"id": "whisper-large-v3", "active": true, "context_window": 448},
            {"id": "llama-3.3-70b-versatile", "active": true, "context_window": 131072}
          ]
        }
        """#
        let chatResponseJSON = #"""
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "## 摘要\n- [00:00:15] 會議決策。\n\n## 決議\n- 未提及\n\n## 待辦\n- 未提及\n\n## 未解決問題\n- 未提及"
              }
            }
          ]
        }
        """#

        OfflineMeetingProtocol.reset(modelsJSON: modelsJSON, chatJSON: chatResponseJSON)

        let semaphore = DispatchSemaphore(value: 0)
        var outputSummary: String?
        var outputError: Error?

        MeetingSummarizer.generateSummary(
            transcript: "[00:00:15] Speaker 1: 測試逐字稿",
            apiKey: "mock-key",
            session: session
        ) { result in
            switch result {
            case .success(let markdown):
                outputSummary = markdown
            case .failure(let error):
                outputError = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        expectTrue(outputError == nil, "不應發生錯誤")
        guard let summary = outputSummary else {
            fatalError("未取得產出摘要")
        }

        expectTrue(summary.contains("model: llama-3.3-70b-versatile"), "frontmatter 應標明自動選用的模型")
        expectTrue(summary.contains("## 摘要"), "內容應包含摘要區塊")
    }

    // MARK: - 錯誤處理測試

    static func testAPIErrorExtraction() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        let errorJSON = #"{"error":{"message":"Invalid API Key supplied to Groq."}}"#
        OfflineMeetingProtocol.reset(modelsJSON: errorJSON, statusCode: 401)

        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?

        MeetingSummarizer.generateSummary(
            transcript: "測試",
            apiKey: "bad-key",
            session: session
        ) { result in
            switch result {
            case .success:
                break
            case .failure(let err):
                capturedError = err
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let error = capturedError as? VoiceTypeError else {
            fatalError("未捕獲預期之 VoiceTypeError")
        }
        expect(error.errorDescription, "Invalid API Key supplied to Groq.")
    }

    // MARK: - MeetingStore 摘要寫入與獨立性測試

    static func testMeetingStoreSummaryWritingAndIndependence() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(root: tempDir)
        let session = try! store.beginSession(startedAt: Date(), language: "zh-TW", chunkSeconds: 300)
        let originalTranscript = try! String(contentsOf: session.transcriptURL, encoding: .utf8)

        let mockSummary = """
        ---
        model: llama-3.3-70b-versatile
        generated_at: 2026-11-11T02:00:00Z
        ---

        ## 摘要
        - [00:01:00] 測試會議。

        ## 決議
        - 未提及

        ## 待辦
        - 未提及

        ## 未解決問題
        - 未提及
        """

        let writtenURL = try! store.writeSummary(mockSummary, for: session.transcriptURL)
        expect(writtenURL, store.summaryURL(for: session.transcriptURL))
        expectTrue(FileManager.default.fileExists(atPath: writtenURL.path), "summary.md 必須存在")

        let readSummary = try! String(contentsOf: writtenURL, encoding: .utf8)
        expect(readSummary, mockSummary)

        // 核心斷言：transcript.md 必須完全不受寫入 summary 影響
        let transcriptAfter = try! String(contentsOf: session.transcriptURL, encoding: .utf8)
        expect(transcriptAfter, originalTranscript)

        // 查詢驗證
        expect(store.latestSummaryURL(), writtenURL)
    }

    static func testSummaryFailureDoesNotAffectTranscript() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(root: tempDir)
        let session = try! store.beginSession(startedAt: Date(), language: "zh-TW", chunkSeconds: 300)
        let originalTranscript = try! String(contentsOf: session.transcriptURL, encoding: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let mockSession = URLSession(configuration: config)

        OfflineMeetingProtocol.reset(
            modelsJSON: #"{"error":{"message":"Rate limit exceeded."}}"#,
            statusCode: 429
        )

        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?

        MeetingSummarizer.generateSummary(
            transcript: originalTranscript,
            apiKey: "test-key",
            session: mockSession
        ) { result in
            switch result {
            case .success:
                break
            case .failure(let err):
                capturedError = err
            }
            semaphore.signal()
        }

        semaphore.wait()
        expectTrue(capturedError != nil, "摘要失敗應回傳錯誤")

        // 核心斷言：摘要失敗時，transcript.md 絕不能被修改或損壞
        let transcriptAfterFailure = try! String(contentsOf: session.transcriptURL, encoding: .utf8)
        expect(transcriptAfterFailure, originalTranscript)

        // summary.md 不應被建立
        let summaryURL = store.summaryURL(for: session.transcriptURL)
        expectTrue(!FileManager.default.fileExists(atPath: summaryURL.path), "失敗時不應產生 summary.md")
    }

    static func testLatestSummaryURLOrdersTenBeforeNineInSameMinute() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSummarySortTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(root: tempDir, timeZone: TimeZone(identifier: "UTC")!)
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00

        var sessions: [MeetingSession] = []
        for _ in 0..<11 {
            let session = try! store.beginSession(startedAt: fixedDate, language: "zh", chunkSeconds: 300)
            sessions.append(session)
        }
        // sessions[8] 為 -9，sessions[9] 為 -10，sessions[10] 為 -11
        let summaryNine = try! store.writeSummary("## 摘要\n第 9 場會議摘要", for: sessions[8].transcriptURL)
        let summaryTen = try! store.writeSummary("## 摘要\n第 10 場會議摘要", for: sessions[9].transcriptURL)

        // 核心斷言：同一分鐘內 -10 必須排在 -9 前面，不能被字串字典序搞錯
        expect(store.latestSummaryURL(), summaryTen)

        // 若刪除 -10 的摘要，則退回找到 -9
        try! FileManager.default.removeItem(at: summaryTen)
        expect(store.latestSummaryURL(), summaryNine)
    }
}
