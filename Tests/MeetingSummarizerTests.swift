import Foundation

// MARK: - 離線測試網路攔截協議

private final class OfflineMeetingProtocol: URLProtocol {
    private static let lock = NSLock()
    static var mockModelsJSON: String = ""
    static var mockChatResponseJSON: String = ""
    static var mockChatResponses: [String] = []
    static var mockStatusCode: Int = 200
    static var mockStatusCodes: [Int] = []
    static var mockHeaderFields: [String: String] = ["Content-Type": "application/json"]
    static var mockHeaderFieldsSequence: [[String: String]] = []
    static var mockError: Error?
    static var capturedRequests: [URLRequest] = []

    static func reset(
        modelsJSON: String = "",
        chatJSON: String = "",
        chatResponses: [String] = [],
        statusCode: Int = 200,
        statusCodes: [Int] = [],
        headerFields: [String: String] = ["Content-Type": "application/json"],
        headerFieldsSequence: [[String: String]] = [],
        error: Error? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        mockModelsJSON = modelsJSON
        mockChatResponseJSON = chatJSON
        mockChatResponses = chatResponses
        mockStatusCode = statusCode
        mockStatusCodes = statusCodes
        mockHeaderFields = headerFields
        mockHeaderFieldsSequence = headerFieldsSequence
        mockError = error
        capturedRequests.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let statusCode: Int
        let headerFields: [String: String]
        let customError = Self.mockError
        let url = request.url!
        let responseData: Data

        if let customError {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: customError)
            return
        }

        if url.path.hasSuffix("/models") {
            statusCode = Self.mockStatusCode
            headerFields = Self.mockHeaderFields
            responseData = Data(Self.mockModelsJSON.utf8)
        } else if url.path.hasSuffix("/chat/completions") {
            statusCode = !Self.mockStatusCodes.isEmpty ? Self.mockStatusCodes.removeFirst() : Self.mockStatusCode
            headerFields = !Self.mockHeaderFieldsSequence.isEmpty ? Self.mockHeaderFieldsSequence.removeFirst() : Self.mockHeaderFields
            if !Self.mockChatResponses.isEmpty {
                let next = Self.mockChatResponses.removeFirst()
                responseData = Data(next.utf8)
            } else {
                responseData = Data(Self.mockChatResponseJSON.utf8)
            }
        } else {
            statusCode = 404
            headerFields = ["Content-Type": "application/json"]
            responseData = Data(#"{"error":{"message":"未知 endpoint"}}"#.utf8)
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - 測試斷言輔助函式

private func extractBody(from request: URLRequest) -> Data? {
    if let data = request.httpBody { return data }
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
    return nil
}

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
        testCategorizedErrorMessages()
        testFrontmatterStrippingAndFailedChunksDetection()
        testChunkingDoesNotCutLinesInHalf()
        testShortTranscriptSingleRequest()
        testLongTranscriptMapReduceRequests()
        testMeetingStoreSummaryWritingAndIndependence()
        testSummaryFailureDoesNotAffectTranscript()
        testLatestSummaryURLOrdersTenBeforeNineInSameMinute()
        testWhitespaceResponseRejectionAndPreservesPriorSummary()
        testOverlongSingleLineRejection()
        testJobCancellationAbortsPendingTasksAndDropsLateCallbacks()
        testMeetingSummaryJobConcurrentAccessNoDataRace()
        testTrackerShutdownCancelsAllJobs()
        testGenerationOrderingPreventsOldJobOverwritingNewSummary()
        testRecordingSessionDetectionBlocksEarlySummarization()
        testInterleavedDictationWithSummaryFailureNeverPresentsModal()
        testReduceDepthLimitExceededFailsCleanly()
        testDiarizedSystemPromptIncludesWarningAndTodoSpeakerDirective()
        testDiarizationStateGateForManualAndAutomaticSummary()
        testEndToEndDiarizedTranscriptUsesDiarizedPrompt()
        testGptOssModelParameters()
        testFinishReasonValidationAndPreservesPriorSummary()
        testRateLimitHeaderParsing()
        testRateLimit429RetrySuccess()
        testRateLimit429RetryCancellation()
        testChunkThresholdReducedTo3500()
        testSystemPromptConstraints()
        print("Meeting summarizer tests passed (36 suites)")
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
              },
              "finish_reason": "stop"
            }
          ]
        }
        """

        let fixedDate = Date(timeIntervalSince1970: 1794333600) // 2026-11-11
        let result = try! MeetingSummarizer.parseChatResponse(
            data: Data(chatJSON.utf8),
            model: "llama-3.3-70b-versatile",
            isPartial: false,
            generatedAt: fixedDate
        )

        expectTrue(result.contains("model: llama-3.3-70b-versatile"), "輸出必須包含 model frontmatter")
        expectTrue(result.contains("generated_at:"), "輸出必須包含 generated_at frontmatter")
        expectTrue(!result.contains("partial: true"), "完整會議摘要不應有 partial frontmatter")
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
              },
              "finish_reason": "stop"
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

    // MARK: - 錯誤處理測試（401/403/413/429/逾時）

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
        expectTrue(error.errorDescription?.contains("更換有效的 API Key") == true, "401 應明確提示更換 Key")
    }

    static func testCategorizedErrorMessages() {
        // 403 測試：提示更換 Key
        let err403 = MeetingSummarizer.error(from: nil, statusCode: 403)
        expectTrue(err403.errorDescription?.contains("更換有效的 API Key") == true, "403 應提示更換 Key")

        // 413 測試：獨立說明超出大小限制
        let err413 = MeetingSummarizer.error(from: nil, statusCode: 413)
        expectTrue(err413.errorDescription?.contains("413") == true, "413 應包含 413 狀態碼")
        expectTrue(err413.errorDescription?.contains("超出單次請求大小限制") == true, "413 應提示超出單次大小限制")

        // 429 測試：精確提示手動重試
        let err429 = MeetingSummarizer.error(from: nil, statusCode: 429)
        expect(err429.errorDescription, "Groq 額度或速率限制，請稍後用『為最近一次會議產生摘要』重試")

        // 逾時測試：獨立清晰之訊息
        let timeoutNS = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let timeoutError = MeetingSummarizer.formatNetworkError(timeoutNS)
        expect(timeoutError.errorDescription, "會議摘要請求逾時，請檢查網路連線或稍後重試。")
    }

    // MARK: - Frontmatter 去除與 failed_chunks 檢測測試（限定 Header 掃描）

    static func testFrontmatterStrippingAndFailedChunksDetection() {
        let transcriptWithFailedChunks = """
        ---
        started: 2026-11-10T19:30:00Z
        ended: 2026-11-10T19:40:00Z
        status: completed
        language: zh
        chunks: 10
        failed_chunks: 2
        chunk_seconds: 300
        ---

        # 會議記錄 2026-11-10 19:30

        [00:00:10] Speaker 1: 我們討論一下進度。
        [00:00:30] Speaker 2: 好。
        """

        expectTrue(MeetingSummarizer.hasFailedChunks(in: transcriptWithFailedChunks), "應偵測出 failed_chunks > 0")

        let stripped = MeetingSummarizer.stripFrontmatter(from: transcriptWithFailedChunks)
        expectTrue(!stripped.contains("failed_chunks: 2"), "正文應去除 frontmatter 區塊")
        expectTrue(stripped.contains("[00:00:10] Speaker 1: 我們討論一下進度。"), "正文內容應完整保留")

        // 驗證 formatFinalSummary 帶 partial 標記
        let summaryResult = try! MeetingSummarizer.formatFinalSummary(
            content: "## 摘要\n- [00:00:10] 討論進度。",
            model: "openai/gpt-oss-120b",
            isPartial: true
        )
        expectTrue(summaryResult.contains("partial: true"), "summary frontmatter 應包含 partial: true")
        expectTrue(summaryResult.contains("部分段落辨識失敗，摘要可能不完整"), "摘要開頭應包含警示提醒")

        // 驗證無失敗段落時不帶 partial
        let cleanTranscript = """
        ---
        started: 2026-11-10T19:30:00Z
        chunks: 10
        failed_chunks: 0
        ---

        [00:00:10] Speaker 1: 全部成功。
        """
        expectTrue(!MeetingSummarizer.hasFailedChunks(in: cleanTranscript), "failed_chunks 為 0 時不應判定為 partial")

        // 核心驗證：若正文包含 failed_chunks: 5，但 header 為 failed_chunks: 0，絕不被誤判為 partial
        let bodyWithMention = """
        ---
        started: 2026-11-10T19:30:00Z
        failed_chunks: 0
        ---

        [00:00:10] Speaker 1: 我們剛才討論 failed_chunks: 5 的問題。
        """
        expectTrue(!MeetingSummarizer.hasFailedChunks(in: bodyWithMention), "正文出現關鍵字不應被誤判為 partial（限定 header 掃描）")
    }

    // MARK: - 長會議分段切塊測試（絕不切半任何一行）

    static func testChunkingDoesNotCutLinesInHalf() {
        // 構造超過 12,000 字元的長會議逐字稿
        var originalLines: [String] = []
        for i in 1...200 {
            let line = String(format: "[%02d:%02d:00] Speaker %d: 這是第 %d 行會議發言，討論關於 Grokbot、yui 以及 claudecode 的整合架構與詳細規劃細節。",
                              i / 60, i % 60, (i % 3) + 1, i)
            originalLines.append(line)
        }
        let fullTranscript = originalLines.joined(separator: "\n")
        expectTrue(fullTranscript.count > MeetingSummarizer.maxChunkCharacterCount, "長逐字稿字元數應超過門檻")

        let chunks = try! MeetingSummarizer.splitTranscriptIntoChunks(fullTranscript, maxChunkSize: MeetingSummarizer.maxChunkCharacterCount)
        expectTrue(chunks.count > 1, "長逐字稿必須被切分成多個 chunk")

        // 驗證：每一行的完整性，絕不能把任何一行切成兩半
        var extractedLines: [String] = []
        for (idx, chunk) in chunks.enumerated() {
            let chunkLines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
            for line in chunkLines {
                extractedLines.append(line)
                expectTrue(originalLines.contains(line), "第 \(idx + 1) 個 chunk 中的行必須存在於原始發言中，絕不能被切半：\(line)")
            }
        }
        expect(extractedLines.count, originalLines.count)
        expect(extractedLines, originalLines)
    }

    // MARK: - 短稿 1 次請求 vs 長稿 N+1 次請求

    static func testShortTranscriptSingleRequest() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        let modelsJSON = #"""
        {
          "data": [{"id": "llama-3.3-70b-versatile", "active": true, "context_window": 131072}]
        }
        """#
        let chatResponseJSON = #"""
        {
          "choices": [{"message": {"role": "assistant", "content": "## 摘要\n- 短稿摘要內容。"}, "finish_reason": "stop"}]
        }
        """#

        OfflineMeetingProtocol.reset(modelsJSON: modelsJSON, chatJSON: chatResponseJSON)

        let shortTranscript = "[00:01:00] Speaker 1: 短會議測試。"
        let semaphore = DispatchSemaphore(value: 0)
        var resultSummary: String?

        MeetingSummarizer.generateSummary(
            transcript: shortTranscript,
            apiKey: "mock-key",
            session: session
        ) { result in
            if case .success(let md) = result { resultSummary = md }
            semaphore.signal()
        }

        semaphore.wait()
        expectTrue(resultSummary != nil, "應取得短稿摘要")

        // 驗證 chat completions 請求次數剛好為 1 次
        let chatRequests = OfflineMeetingProtocol.capturedRequests.filter { $0.url?.path.hasSuffix("/chat/completions") == true }
        expect(chatRequests.count, 1)
    }

    static func testLongTranscriptMapReduceRequests() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        let modelsJSON = #"""
        {
          "data": [{"id": "llama-3.3-70b-versatile", "active": true, "context_window": 131072}]
        }
        """#

        // 構造剛好切分成 2 個 chunk 的長逐字稿（以 80 字元作為門檻模擬測試切塊）
        let mockChunkThreshold = 80
        let line1 = "[00:01:00] Speaker 1: 第一個區塊的詳細討論內容，包含 Stack 與 claudecode 的初步設計流程與各模組職責。"
        let line2 = "[00:02:00] Speaker 2: 第二個區塊的詳細討論內容，包含 DeepseekHarness 的效能對比圖表與繁體中文自定義詞庫導入。"
        let longTranscript = "\(line1)\n\(line2)"

        let chunks = try! MeetingSummarizer.splitTranscriptIntoChunks(longTranscript, maxChunkSize: mockChunkThreshold)
        expect(chunks.count, 2)

        // 準備 N (2) 個 map 回應與 1 個 reduce 回應
        let mapResponse1 = """
        {"choices":[{"message":{"role":"assistant","content":"## 摘要\\n- [00:01:00] 討論模組一。"},"finish_reason":"stop"}]}
        """
        let mapResponse2 = """
        {"choices":[{"message":{"role":"assistant","content":"## 摘要\\n- [00:02:00] 討論模組二。"},"finish_reason":"stop"}]}
        """
        let reduceResponse = """
        {"choices":[{"message":{"role":"assistant","content":"## 摘要\\n- [00:01:00] 討論模組一。\\n- [00:02:00] 討論模組二。\\n\\n## 決議\\n- 未提及\\n\\n## 待辦\\n- 未提及\\n\\n## 未解決問題\\n- 未提及"},"finish_reason":"stop"}]}
        """

        OfflineMeetingProtocol.reset(
            modelsJSON: modelsJSON,
            chatResponses: [mapResponse1, mapResponse2, reduceResponse]
        )

        let semaphore = DispatchSemaphore(value: 0)
        var finalResult: String?

        // 執行 Map-Reduce
        MeetingSummarizer.executeMapReduce(
            chunks: chunks,
            model: "llama-3.3-70b-versatile",
            apiKey: "mock-key",
            session: session
        ) { result in
            if case .success(let md) = result { finalResult = md }
            semaphore.signal()
        }

        semaphore.wait()
        guard let output = finalResult else {
            fatalError("未取得 Map-Reduce 結果")
        }

        expectTrue(output.contains("討論模組一。"), "最終摘要應包含第一段重點")
        expectTrue(output.contains("討論模組二。"), "最終摘要應包含第二段重點")

        // 核心驗證：長稿 N 個 chunk 必須剛好發送 N + 1 次請求（2 次 map + 1 次 reduce = 3 次）
        let chatRequests = OfflineMeetingProtocol.capturedRequests.filter { $0.url?.path.hasSuffix("/chat/completions") == true }
        expect(chatRequests.count, 3)

        // 驗證第 3 次請求（Reduce）的 payload 含有 <partial_summaries>
        guard let reduceBodyData = extractBody(from: chatRequests[2]) else {
            fatalError("無法自 URLRequest 讀取 httpBody")
        }
        let reduceBodyJSON = try! JSONSerialization.jsonObject(with: reduceBodyData) as! [String: Any]
        let reduceMessages = reduceBodyJSON["messages"] as! [[String: Any]]
        let reduceUserContent = reduceMessages[1]["content"] as! String
        expectTrue(reduceUserContent.contains("<partial_summaries>"), "Reduce 請求必須包含 <partial_summaries>")
        expectTrue(reduceUserContent.contains("=== 第 1 段摘要 ==="), "Reduce 請求必須註明段落標記")
        expectTrue(reduceUserContent.contains("=== 第 2 段摘要 ==="), "Reduce 請求必須註明段落標記")
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

        _ = MeetingSummarizer.generateSummary(
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

    // MARK: - 空白回應防覆寫回歸測試

    static func testWhitespaceResponseRejectionAndPreservesPriorSummary() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhitespaceSummaryTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(root: tempDir)
        let session = try! store.beginSession(startedAt: Date(), language: "zh-TW", chunkSeconds: 300)
        try! store.writeSummary("PRIOR_GOOD_SUMMARY", for: session.transcriptURL)

        let whitespaceData = Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8)
        var rejected = false
        do {
            _ = try MeetingSummarizer.parseChatResponse(data: whitespaceData, model: "test-model")
        } catch {
            rejected = true
        }
        expectTrue(rejected, "空白 API content 必須被拒絕拋出錯誤")

        // 核心斷言：原本的好摘要必須完好保留，絕不被覆寫
        let preservedSummary = try! String(contentsOf: store.summaryURL(for: session.transcriptURL), encoding: .utf8)
        expect(preservedSummary, "PRIOR_GOOD_SUMMARY")
    }

    // MARK: - 超長單行防範測試

    static func testOverlongSingleLineRejection() {
        let longLine = "[00:00:00] Speaker 1: " + String(repeating: "測", count: 15_000)
        var rejected = false
        var capturedMessage = ""
        do {
            _ = try MeetingSummarizer.splitTranscriptIntoChunks(longLine)
        } catch {
            rejected = true
            capturedMessage = error.localizedDescription
        }
        expectTrue(rejected, "單行超過 12,000 字元必須拒絕")
        expectTrue(capturedMessage.contains("逐字稿單行過長，暫不支援。"), "錯誤訊息應提示單行過長")
    }

    // MARK: - MeetingSummaryJob 生命週期與取消測試

    static func testJobCancellationAbortsPendingTasksAndDropsLateCallbacks() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        // 模擬卡住的 HTTP（不給予回應資料）
        OfflineMeetingProtocol.reset(modelsJSON: "", chatJSON: "")

        let job = MeetingSummaryJob(transcriptURL: URL(fileURLWithPath: "/test"), generation: 1)
        var callbackCalled = false

        _ = MeetingSummarizer.generateSummary(
            transcript: "[00:01:00] Speaker 1: 會議內容。",
            apiKey: "mock-key",
            session: session,
            job: job
        ) { _ in
            callbackCalled = true
        }

        // 立即取消工作（如同 App 關閉或工作重啟）
        job.cancel()
        expectTrue(job.isCancelled, "job 應標記為已取消")

        // 等待些許時間驗證晚到回呼是否被丟棄
        Thread.sleep(forTimeInterval: 0.1)
        expectTrue(!callbackCalled, "已取消之 job 絕不可觸發 completion 回呼")
    }

    // MARK: - MeetingSummaryJob 多線程併發存取安全測試（ThreadSanitizer 驗證）

    static func testMeetingSummaryJobConcurrentAccessNoDataRace() {
        let job = MeetingSummaryJob()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent.job", attributes: .concurrent)

        for _ in 0..<50 {
            group.enter()
            queue.async {
                _ = job.isCancelled
                _ = job.currentTask
                group.leave()
            }
        }

        for _ in 0..<10 {
            group.enter()
            queue.async {
                job.attachTask(nil)
                group.leave()
            }
        }

        group.enter()
        queue.async {
            job.cancel()
            group.leave()
        }

        group.wait()
        expectTrue(job.isCancelled, "job 最終應為已取消")
    }

    // MARK: - Tracker 關閉時取消所有工作測試

    static func testTrackerShutdownCancelsAllJobs() {
        let tracker = MeetingSummaryTracker()
        let url1 = URL(fileURLWithPath: "/test1")
        let url2 = URL(fileURLWithPath: "/test2")

        let job1 = tracker.registerJob(for: url1)
        let job2 = tracker.registerJob(for: url2)
        expectTrue(tracker.isBusy, "有 active jobs 時 tracker 應為 busy")

        tracker.cancelAll()
        expectTrue(job1.isCancelled, "cancelAll 應取消 job1")
        expectTrue(job2.isCancelled, "cancelAll 應取消 job2")
        expectTrue(!tracker.isBusy, "cancelAll 後 tracker 不應為 busy")
    }

    // MARK: - Generation 世代逆序防覆寫測試（直接測試 Production 型別 MeetingSummaryTracker）

    static func testGenerationOrderingPreventsOldJobOverwritingNewSummary() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenerationOrderingTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(root: tempDir)
        let session = try! store.beginSession(startedAt: Date(), language: "zh-TW", chunkSeconds: 300)
        let transcriptURL = session.transcriptURL

        // 使用 Production 實際之 MeetingSummaryTracker
        let tracker = MeetingSummaryTracker()

        // 模擬兩次摘要請求：Job 1 (舊) 與 Job 2 (新)
        let job1 = tracker.registerJob(for: transcriptURL)
        expect(job1.generation, 1)

        let job2 = tracker.registerJob(for: transcriptURL)
        expect(job2.generation, 2)
        expectTrue(job1.isCancelled, "註冊新工作時應自動取消舊工作")

        // 模擬 Job 2 先完成並通過驗證寫入
        let v2Summary = "## 摘要\n這是 Generation 2 的新摘要"
        let job2Valid = tracker.validateAndComplete(job: job2)
        expectTrue(job2Valid, "最新世代 Job 2 應驗證通過")
        try! store.writeSummary(v2Summary, for: transcriptURL)

        // 模擬 Job 1 晚到完成
        let v1Summary = "## 摘要\n這是 Generation 1 的舊摘要"
        let job1Valid = tracker.validateAndComplete(job: job1)
        expectTrue(!job1Valid, "已取消或非最新世代之 Job 1 絕不可驗證通過")

        if job1Valid {
            try! store.writeSummary(v1Summary, for: transcriptURL)
        }

        // 核心斷言：Job 1 晚到結果絕不准寫入，檔案仍為 V2
        let currentFile = try! String(contentsOf: store.summaryURL(for: transcriptURL), encoding: .utf8)
        expect(currentFile, v2Summary)
    }

    // MARK: - 錄音中狀態檢測測試（防錄音中提早摘要）

    static func testRecordingSessionDetectionBlocksEarlySummarization() {
        let activeTranscript = """
        ---
        started: 2026-11-11T02:00:00Z
        ended: in-progress
        status: recording
        chunks: 1
        failed_chunks: 0
        ---

        [00:00:10] Speaker 1: 正在錄音中...
        """
        expectTrue(MeetingSummarizer.isRecordingSession(transcript: activeTranscript), "錄音中的逐字稿應被判定為 recording")

        let completedTranscript = """
        ---
        started: 2026-11-11T02:00:00Z
        ended: 2026-11-11T02:10:00Z
        status: completed
        chunks: 2
        failed_chunks: 0
        ---

        [00:00:10] Speaker 1: 已結束。
        """
        expectTrue(!MeetingSummarizer.isRecordingSession(transcript: completedTranscript), "已完成的會議不應判定為 recording")
    }

    // MARK: - 交錯情境測試（直接測試 Production 型別 MeetingSummaryPresentationPolicy）

    static func testInterleavedDictationWithSummaryFailureNeverPresentsModal() {
        let error429 = MeetingSummarizer.error(from: nil, statusCode: 429)

        // 情境 1：自動摘要失敗時，使用者正在聽寫 (isDictating = true)
        let d1 = MeetingSummaryPresentationPolicy.decidePresentation(
            isSuccess: false,
            manualTrigger: false,
            isDictating: true,
            error: error429
        )
        expectTrue(!d1.shouldShowAlert, "自動摘要失敗在聽寫中絕不允許彈出 modal 視窗")
        expectTrue(d1.shouldPostNotification, "自動摘要失敗應送出不搶焦點之系統通知")
        expectTrue(!d1.shouldOpenFileViewer, "失敗絕不可打開 Finder")
        expect(d1.menuTitle, "摘要失敗：429，點此重試")

        // 情境 2：自動摘要失敗時，使用者未聽寫 (isDictating = false)
        let d2 = MeetingSummaryPresentationPolicy.decidePresentation(
            isSuccess: false,
            manualTrigger: false,
            isDictating: false,
            error: error429
        )
        expectTrue(!d2.shouldShowAlert, "自動摘要失敗即使未在聽寫中亦絕不可彈出 modal 視窗")
        expectTrue(d2.shouldPostNotification, "應送出系統通知")
        expect(d2.menuTitle, "摘要失敗：429，點此重試")

        // 情境 3：手動觸發失敗，但使用者隨即開始聽寫 (isDictating = true)
        let d3 = MeetingSummaryPresentationPolicy.decidePresentation(
            isSuccess: false,
            manualTrigger: true,
            isDictating: true,
            error: error429
        )
        expectTrue(!d3.shouldShowAlert, "使用者在聽寫中時，手動觸發失敗亦不得彈窗中斷聽寫")
        expectTrue(!d3.shouldPostNotification, "手動觸發不在聽寫中彈窗，由選單標題提示")
        expect(d3.menuTitle, "摘要失敗：429，點此重試")

        // 情境 4：手動觸發成功且未在聽寫
        let d4 = MeetingSummaryPresentationPolicy.decidePresentation(
            isSuccess: true,
            manualTrigger: true,
            isDictating: false
        )
        expectTrue(!d4.shouldShowAlert, "成功時不應彈出 alert")
        expectTrue(d4.shouldOpenFileViewer, "手動觸發成功應開啟 Finder 選取檔案")
        expectTrue(!d4.shouldPostNotification, "手動觸發成功不重複發送系統通知")
        expect(d4.menuTitle, "為最近一次會議產生摘要")

        // 情境 5：自動摘要成功
        let d5 = MeetingSummaryPresentationPolicy.decidePresentation(
            isSuccess: true,
            manualTrigger: false,
            isDictating: false
        )
        expectTrue(!d5.shouldShowAlert, "成功時不應彈出 alert")
        expectTrue(!d5.shouldOpenFileViewer, "自動摘要成功絕不可自動開啟 Finder 搶焦點")
        expectTrue(d5.shouldPostNotification, "自動摘要成功應發出系統通知")
        expect(d5.menuTitle, "為最近一次會議產生摘要")
    }

    // MARK: - Reduce 深度上限與收斂保證測試

    static func testReduceDepthLimitExceededFailsCleanly() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        let summaries = [
            "## 摘要\n- 第一段重點",
            "## 摘要\n- 第二段重點"
        ]

        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?

        // 模擬已達深度上限 (currentDepth: 3 >= maxReduceDepth: 3)
        MeetingSummarizer.reduceSummaries(
            summaries: summaries,
            model: "llama-3.3-70b-versatile",
            apiKey: "mock-key",
            session: session,
            currentDepth: 3
        ) { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard let error = capturedError else {
            fatalError("超限 depth 應觸發錯誤")
        }
        expectTrue(error.localizedDescription.contains("會議分段摘要彙整層數超過上限（最多 3 層）"), "錯誤訊息應提示層數超過上限")
    }

    // MARK: - Diarization 說話者辨識配合測試

    static func testDiarizedSystemPromptIncludesWarningAndTodoSpeakerDirective() {
        let defaultPrompt = MeetingSummarizer.systemPrompt(diarized: false)
        expectTrue(!defaultPrompt.contains("說話者標籤由自動辨識產生，可能不準"), "未辨識說話者時不應包含警告")
        expectTrue(defaultPrompt == MeetingSummarizer.systemPrompt, "預設 systemPrompt 屬性必須完全向後相容")

        let diarizedPrompt = MeetingSummarizer.systemPrompt(diarized: true)
        expectTrue(diarizedPrompt.contains("說話者標籤由自動辨識產生，可能不準；不要從說話內容推斷說話者是誰。"), "diarized: true 必須包含辨識警告")
        expectTrue(diarizedPrompt.contains("待辦事項的負責人欄位請直接原樣使用逐字稿中的說話者標籤（如 Speaker 1、Speaker 2）。"), "diarized: true 必須包含待辦 Speaker 標籤指示")

        let defaultReducePrompt = MeetingSummarizer.reduceSystemPrompt(diarized: false)
        expectTrue(!defaultReducePrompt.contains("說話者標籤由自動辨識產生，可能不準"), "未辨識說話者時 Reduce 不應包含警告")
        expectTrue(defaultReducePrompt == MeetingSummarizer.reduceSystemPrompt, "預設 reduceSystemPrompt 屬性必須完全向後相容")

        let diarizedReducePrompt = MeetingSummarizer.reduceSystemPrompt(diarized: true)
        expectTrue(diarizedReducePrompt.contains("說話者標籤由自動辨識產生，可能不準；不要從說話內容推斷說話者是誰。"), "diarized: true Reduce 必須包含辨識警告")
        expectTrue(diarizedReducePrompt.contains("待辦事項的負責人欄位請直接原樣使用分段摘要中的說話者標籤（如 Speaker 1、Speaker 2）。"), "diarized: true Reduce 必須包含待辦 Speaker 標籤指示")
    }

    static func testDiarizationStateGateForManualAndAutomaticSummary() {
        // 驗證終態判定：除了 pending/running 之外都是終態
        expectTrue(!MeetingDiarizationState.pending.isTerminal, "pending 不是終態")
        expectTrue(!MeetingDiarizationState.running.isTerminal, "running 不是終態")
        expectTrue(MeetingDiarizationState.done.isTerminal, "done 是終態")
        expectTrue(MeetingDiarizationState.failed.isTerminal, "failed 是終態")
        expectTrue(MeetingDiarizationState.skipped.isTerminal, "skipped 是終態")
        expectTrue(MeetingDiarizationState.cancelled.isTerminal, "cancelled 是終態")
        expectTrue(MeetingDiarizationState.interrupted.isTerminal, "interrupted 是終態")
        expectTrue(MeetingDiarizationState.notApplicable.isTerminal, "notApplicable 是終態")

        // 驗證 isDiarizedDone
        let doneTranscript = """
        ---
        status: finished
        diarization: done
        ---
        [00:00:01] (Speaker 1) 會議開始
        """
        expectTrue(MeetingSummarizer.isDiarizedDone(transcript: doneTranscript), "diarization: done 應回傳 true")

        let failedTranscript = """
        ---
        status: finished
        diarization: failed
        ---
        [00:00:01] (Speaker 1) 會議開始
        """
        expectTrue(!MeetingSummarizer.isDiarizedDone(transcript: failedTranscript), "diarization: failed 應回傳 false")

        let interruptedTranscript = """
        ---
        status: finished
        diarization: interrupted
        ---
        [00:00:01] 會議開始
        """
        expectTrue(!MeetingSummarizer.isDiarizedDone(transcript: interruptedTranscript), "diarization: interrupted 應回傳 false")

        let legacyTranscript = """
        ---
        status: finished
        ---
        [00:00:01] 會議開始
        """
        expectTrue(!MeetingSummarizer.isDiarizedDone(transcript: legacyTranscript), "無 diarization 欄位應回傳 false")

        let noFrontmatterTranscript = "[00:00:01] 會議開始"
        expectTrue(!MeetingSummarizer.isDiarizedDone(transcript: noFrontmatterTranscript), "無 frontmatter 應回傳 false")
    }

    static func testEndToEndDiarizedTranscriptUsesDiarizedPrompt() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        let modelsJSON = #"""
        {
          "data": [
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
              },
              "finish_reason": "stop"
            }
          ]
        }
        """#

        OfflineMeetingProtocol.reset(modelsJSON: modelsJSON, chatJSON: chatResponseJSON)

        let diarizedTranscript = """
        ---
        status: finished
        diarization: done
        ---
        [00:00:01] (Speaker 1) 各位早安，我們今天討論專案進度。
        [00:00:15] (Speaker 2) 我負責前端，預計週三完成。
        """

        let semaphore = DispatchSemaphore(value: 0)
        var capturedSummary: String?
        var capturedError: Error?

        MeetingSummarizer.generateSummary(
            transcript: diarizedTranscript,
            apiKey: "mock-api-key",
            session: session
        ) { result in
            switch result {
            case .success(let summary):
                capturedSummary = summary
            case .failure(let error):
                capturedError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let error = capturedError {
            fatalError("產生摘要不應失敗：\(error)")
        }
        guard let summary = capturedSummary else {
            fatalError("應取得摘要內容")
        }
        expectTrue(summary.contains("## 摘要"), "產生的 Markdown 應包含摘要區塊")

        // 檢驗送出給 Groq API 的實際 system prompt 包含說話者辨識警告指示
        let chatRequests = OfflineMeetingProtocol.capturedRequests.filter { $0.url?.path.hasSuffix("/chat/completions") == true }
        guard let lastRequest = chatRequests.last,
              let body = extractBody(from: lastRequest),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]],
              let systemMessage = messages.first(where: { ($0["role"] as? String) == "system" }),
              let systemContent = systemMessage["content"] as? String else {
            fatalError("未攔截到有效的 Chat Request 系統提示詞")
        }

        expectTrue(systemContent.contains("說話者標籤由自動辨識產生，可能不準；不要從說話內容推斷說話者是誰。"), "diarization: done 的逐字稿送出之系統提示詞必須包含警告指示")
        expectTrue(systemContent.contains("待辦事項的負責人欄位請直接原樣使用逐字稿中的說話者標籤"), "diarization: done 的逐字稿送出之系統提示詞必須包含待辦 Speaker 標籤指示")

        // 測試非 done（例如 legacy）逐字稿不包含該提示詞
        let legacyTranscript = """
        ---
        status: finished
        ---
        [00:00:01] 各位早安，我們今天討論專案進度。
        """
        OfflineMeetingProtocol.reset(modelsJSON: modelsJSON, chatJSON: chatResponseJSON)
        let semaphore2 = DispatchSemaphore(value: 0)
        MeetingSummarizer.generateSummary(
            transcript: legacyTranscript,
            apiKey: "mock-api-key",
            session: session
        ) { _ in
            semaphore2.signal()
        }
        semaphore2.wait()

        let legacyChatRequests = OfflineMeetingProtocol.capturedRequests.filter { $0.url?.path.hasSuffix("/chat/completions") == true }
        guard let legacyRequest = legacyChatRequests.last,
              let legacyBody = extractBody(from: legacyRequest),
              let legacyJson = try? JSONSerialization.jsonObject(with: legacyBody) as? [String: Any],
              let legacyMessages = legacyJson["messages"] as? [[String: Any]],
              let legacySystemMsg = legacyMessages.first(where: { ($0["role"] as? String) == "system" }),
              let legacySystemContent = legacySystemMsg["content"] as? String else {
            fatalError("未攔截到有效的 Legacy Chat Request 系統提示詞")
        }

        expectTrue(!legacySystemContent.contains("說話者標籤由自動辨識產生，可能不準"), "未帶 diarization: done 的逐字稿不得包含說話者辨識警告")
    }

    // MARK: - P1 / P2 實測修復驗證測試

    /// 驗證 gpt-oss 系列模型在 Request Body 包含 reasoning_effort: "low" 與 max_completion_tokens: 3500
    static func testGptOssModelParameters() {
        // 情境 1：openai/gpt-oss-120b
        let ossData = try! MeetingSummarizer.makeRequestBody(
            model: "openai/gpt-oss-120b",
            system: "sys",
            user: "usr"
        )
        let ossJson = try! JSONSerialization.jsonObject(with: ossData) as! [String: Any]
        expect(ossJson["model"] as? String, "openai/gpt-oss-120b")
        expect(ossJson["reasoning_effort"] as? String, "low")
        expect(ossJson["max_completion_tokens"] as? Int, 3500)

        // 情境 2：一般模型如 llama-3.3-70b-versatile 不應帶有上述推理參數
        let llamaData = try! MeetingSummarizer.makeRequestBody(
            model: "llama-3.3-70b-versatile",
            system: "sys",
            user: "usr"
        )
        let llamaJson = try! JSONSerialization.jsonObject(with: llamaData) as! [String: Any]
        expect(llamaJson["model"] as? String, "llama-3.3-70b-versatile")
        expectTrue(llamaJson["reasoning_effort"] == nil, "非 gpt-oss 模型不應包含 reasoning_effort")
        expectTrue(llamaJson["max_completion_tokens"] == nil, "非 gpt-oss 模型不應包含 max_completion_tokens")
    }

    /// 驗證 finish_reason 非 "stop"（如 "length"、缺漏、null、型別錯誤）嚴格報錯並拒絕覆寫既有摘要
    static func testFinishReasonValidationAndPreservesPriorSummary() {
        // 情境 1：parseChatContent 遇到 finish_reason == "length" 拋出錯誤
        let lengthJSON = #"""
        {
          "choices": [
            {
              "message": {"role": "assistant", "content": "## 摘要\n- [00:01:00] 殘缺的內容"},
              "finish_reason": "length"
            }
          ]
        }
        """#
        var threwLength = false
        do {
            _ = try MeetingSummarizer.parseChatContent(data: Data(lengthJSON.utf8))
        } catch {
            threwLength = true
            expectTrue(error.localizedDescription.contains("finish_reason: length"), "應包含 finish_reason: length 提示")
        }
        expectTrue(threwLength, "finish_reason=length 應拋出錯誤")

        // 情境 2：finish_reason 缺漏、null 或型別錯誤
        let missingReasonJSON = #"{"choices":[{"message":{"content":"TRUNCATED_REPLACEMENT"}}]}"#
        let nullReasonJSON = #"{"choices":[{"finish_reason":null,"message":{"content":"TRUNCATED_REPLACEMENT"}}]}"#
        let wrongTypeReasonJSON = #"{"choices":[{"finish_reason":123,"message":{"content":"TRUNCATED_REPLACEMENT"}}]}"#

        for (label, json) in [("missing", missingReasonJSON), ("null", nullReasonJSON), ("wrong type", wrongTypeReasonJSON)] {
            var threw = false
            do {
                _ = try MeetingSummarizer.parseChatContent(data: Data(json.utf8))
            } catch {
                threw = true
                expectTrue(error.localizedDescription.contains("finish_reason"), "應提示 finish_reason 錯誤（\(label)）")
            }
            expectTrue(threw, "finish_reason 為 \(label) 時必須拋出錯誤")
        }

        // 情境 3：parseChatContent 遇到 finish_reason == "stop" 正常通過
        let stopJSON = #"""
        {
          "choices": [
            {
              "message": {"role": "assistant", "content": "## 摘要\n- [00:01:00] 完整的內容"},
              "finish_reason": "stop"
            }
          ]
        }
        """#
        let content = try! MeetingSummarizer.parseChatContent(data: Data(stopJSON.utf8))
        expect(content, "## 摘要\n- [00:01:00] 完整的內容")

        // 情境 4：端到端生成遇到 finish_reason 缺漏（或 non-stop）時失敗，既有 summary.md 完好保留不被覆寫
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(root: tempDir)
        let transcriptURL = tempDir.appendingPathComponent("2026-11-12-140000.md")
        try! "--- status: stopped ---\n[00:00:10] Alice: 討論測試。".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let priorSummary = "---\nmodel: old-model\ngenerated_at: 2026-11-12T13:00:00Z\n---\n\n## 摘要\n- 舊的珍貴摘要"
        let summaryURL = try! store.writeSummary(priorSummary, for: transcriptURL)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        OfflineMeetingProtocol.reset(
            modelsJSON: #"{"data":[{"id":"openai/gpt-oss-120b","active":true,"context_window":131072}]}"#,
            chatJSON: missingReasonJSON,
            statusCode: 200
        )

        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?
        MeetingSummarizer.generateSummary(
            transcript: "[00:00:10] Alice: 討論測試。",
            apiKey: "mock-key",
            session: session
        ) { result in
            if case .failure(let err) = result {
                capturedError = err
            }
            semaphore.signal()
        }
        semaphore.wait()

        expectTrue(capturedError != nil, "finish_reason 缺漏端到端生成應回報失敗")
        let summaryOnDisk = try! String(contentsOf: summaryURL, encoding: .utf8)
        expect(summaryOnDisk, priorSummary)
    }

    /// 驗證 HTTP 429 速率限制標頭解析（Retry-After 優先級、剩餘額度挑選、保守取大、複合時間字串）
    static func testRateLimitHeaderParsing() {
        let groqBase = URL(string: "https://api.groq.com")!

        // 1. Retry-After 優先於其他所有標頭
        let respPriority = HTTPURLResponse(
            url: groqBase,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Retry-After": "4.5",
                "x-ratelimit-reset-tokens": "60s",
                "x-ratelimit-reset-requests": "30s"
            ]
        )
        expect(MeetingSummarizer.parseRateLimitWaitInterval(from: respPriority), 4.5)

        // 2. 雙 header：remaining-tokens == 0，挑選 reset-tokens
        let respTokensZero = HTTPURLResponse(
            url: groqBase,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "x-ratelimit-remaining-tokens": "0",
                "x-ratelimit-reset-tokens": "45s",
                "x-ratelimit-remaining-requests": "100",
                "x-ratelimit-reset-requests": "2s"
            ]
        )
        expect(MeetingSummarizer.parseRateLimitWaitInterval(from: respTokensZero), 45.0)

        // 3. 雙 header：remaining-requests == 0，挑選 reset-requests
        let respReqsZero = HTTPURLResponse(
            url: groqBase,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "x-ratelimit-remaining-tokens": "5000",
                "x-ratelimit-reset-tokens": "2s",
                "x-ratelimit-remaining-requests": "0",
                "x-ratelimit-reset-requests": "30s"
            ]
        )
        expect(MeetingSummarizer.parseRateLimitWaitInterval(from: respReqsZero), 30.0)

        // 4. 雙 header：無法判斷 remaining 或兩者皆 0 時，取較大值（保守等待，避免 1s 覆蓋 60s）
        for i in 0..<20 {
            let respBoth = HTTPURLResponse(
                url: groqBase,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "x-ratelimit-reset-tokens": "60s",
                    "x-ratelimit-reset-requests": "1s",
                    "x-noise": "\(i)"
                ]
            )
            expect(MeetingSummarizer.parseRateLimitWaitInterval(from: respBoth), 60.0)
        }

        // 5. 複合時間字串解析（Groq 官方規格支援 h, m, s, ms）
        expect(MeetingSummarizer.parseTimeString("1m2.5s"), 62.5)
        expect(MeetingSummarizer.parseTimeString("2m59.56s"), 179.56)
        expect(MeetingSummarizer.parseTimeString("4m19.2s"), 259.2)
        expect(MeetingSummarizer.parseTimeString("36.45s"), 36.45)
        expect(MeetingSummarizer.parseTimeString("500ms"), 0.5)
        expect(MeetingSummarizer.parseTimeString("60s"), 60.0)
        expect(MeetingSummarizer.parseTimeString("1h"), 3600.0)
        expect(MeetingSummarizer.parseTimeString("1h2m3s"), 3723.0)
        expect(MeetingSummarizer.parseTimeString("12"), 12.0)
        expect(MeetingSummarizer.parseTimeString("12.5"), 12.5)
        expectTrue(MeetingSummarizer.parseTimeString("invalid") == nil, "無效字串應為 nil")
        expectTrue(MeetingSummarizer.parseTimeString("10s extra") == nil, "夾帶額外文字應為 nil")

        // 6. 無相關標頭回傳 nil
        let respNone = HTTPURLResponse(
            url: groqBase,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )
        expectTrue(MeetingSummarizer.parseRateLimitWaitInterval(from: respNone) == nil, "無標頭時應回傳 nil")
    }

    /// 驗證收到 429 帶 Retry-After 時，進入等待、通知選單狀態，並在重試後成功
    static func testRateLimit429RetrySuccess() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        let chatSuccessJSON = #"""
        {
          "choices": [
            {
              "message": {"role": "assistant", "content": "## 摘要\n- 重試後成功"},
              "finish_reason": "stop"
            }
          ]
        }
        """#

        // 第一次 429（Retry-After: 3 秒），第二次 200 成功
        OfflineMeetingProtocol.reset(
            modelsJSON: #"{"data":[{"id":"openai/gpt-oss-120b","active":true,"context_window":131072}]}"#,
            chatResponses: [
                #"{"error":{"message":"Rate limit reached"}}"#,
                chatSuccessJSON
            ],
            statusCodes: [429, 200],
            headerFieldsSequence: [
                ["Content-Type": "application/json", "Retry-After": "3"],
                ["Content-Type": "application/json"]
            ]
        )

        var statusUpdates: [String] = []
        var scheduledDelays: [TimeInterval] = []

        // 注入自訂立即執行的 DelayScheduler，記錄排程延遲
        let immediateScheduler: MeetingSummarizer.DelayScheduler = { delay, block in
            scheduledDelays.append(delay)
            let item = DispatchWorkItem(block: block)
            DispatchQueue.global().async(execute: item)
            return item
        }

        let semaphore = DispatchSemaphore(value: 0)
        var capturedResult: Result<String, Error>?
        MeetingSummarizer.generateSummary(
            transcript: "[00:00:10] Bob: 討論測試。",
            apiKey: "mock-key",
            session: session,
            delayScheduler: immediateScheduler,
            statusHandler: { status in
                statusUpdates.append(status)
            }
        ) { result in
            capturedResult = result
            semaphore.signal()
        }
        semaphore.wait()

        guard let result = capturedResult, case .success(let markdown) = result else {
            fatalError("429 重試後應成功")
        }
        expectTrue(markdown.contains("重試後成功"), "Markdown 應包含重試後內容")
        expectTrue(scheduledDelays.contains(3.0), "應排程 3 秒之延遲")
        expectTrue(statusUpdates.contains("等待 Groq 額度，約 3 秒"), "應通知選單『等待 Groq 額度，約 3 秒』")
        expectTrue(statusUpdates.contains("正在產生會議摘要…"), "重試發出時應更新選單為『正在產生會議摘要…』")
    }

    /// 驗證 429 等待期間工作被取消時，等待立即中止，不再發送第二次請求
    static func testRateLimit429RetryCancellation() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineMeetingProtocol.self]
        let session = URLSession(configuration: config)

        // 第一次請求返回 429
        OfflineMeetingProtocol.reset(
            modelsJSON: #"{"data":[{"id":"openai/gpt-oss-120b","active":true,"context_window":131072}]}"#,
            statusCodes: [429],
            headerFieldsSequence: [["Content-Type": "application/json", "Retry-After": "10"]]
        )

        let tracker = MeetingSummaryTracker()
        let testURL = URL(fileURLWithPath: "/tmp/fake-transcript.md")
        let job = tracker.registerJob(for: testURL)

        var didExecuteWorkItem = false
        // 模擬排程器：不立即執行，等待呼叫
        let manualScheduler: MeetingSummarizer.DelayScheduler = { delay, block in
            let item = DispatchWorkItem {
                didExecuteWorkItem = true
                block()
            }
            return item
        }

        let semaphore = DispatchSemaphore(value: 0)
        MeetingSummarizer.generateSummary(
            transcript: "[00:00:10] Bob: 討論測試。",
            apiKey: "mock-key",
            session: session,
            job: job,
            delayScheduler: manualScheduler
        ) { _ in
            semaphore.signal()
        }

        // 等待 models 取得並發出第一次 chat 收到 429
        let deadline = Date().addingTimeInterval(2.0)
        while job.pendingWorkItem == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        expectTrue(job.pendingWorkItem != nil, "應已有 pendingWorkItem")
        expectTrue(!job.pendingWorkItem!.isCancelled, "尚未取消前 workItem 應有效")

        // 呼叫 cancel()（例如 App 退出或被新工作覆蓋）
        job.cancel()

        expectTrue(job.isCancelled, "job 應標記為已取消")
        expectTrue(job.pendingWorkItem == nil, "cancel 後 pendingWorkItem 應被清理")
        expectTrue(!didExecuteWorkItem, "已取消的等待項目絕不可被執行")
    }

    /// 驗證長會議分段門檻已調降為 3,500 字元
    static func testChunkThresholdReducedTo3500() {
        expect(MeetingSummarizer.maxChunkCharacterCount, 3500)

        // 3,000 字元逐字稿：單一 chunk
        let shortText = String(repeating: "測試語句與技術名詞討論。\n", count: 230)
        expectTrue(shortText.count > 2500 && shortText.count <= 3500, "長度應在 3500 以內")
        let shortChunks = try! MeetingSummarizer.splitTranscriptIntoChunks(shortText)
        expect(shortChunks.count, 1)

        // 4,000 字元逐字稿：應切分為多個 chunks
        let longText = String(repeating: "測試語句與技術名詞討論。\n", count: 300)
        expectTrue(longText.count > 3500, "長度應超過 3500")
        let longChunks = try! MeetingSummarizer.splitTranscriptIntoChunks(longText)
        expectTrue(longChunks.count > 1, "超過 3500 字元應分段")
    }

    /// 驗證提示詞中嚴格約束期限照原文不補年份，且待辦事項不重複進決議
    static func testSystemPromptConstraints() {
        let prompt = MeetingSummarizer.systemPrompt
        expectTrue(prompt.contains("待辦事項之期限必須嚴格照逐字稿原文填寫"), "應約束期限照逐字稿原文")
        expectTrue(prompt.contains("禁止補上年份"), "應明確禁止補上年份")
        expectTrue(prompt.contains("待辦工作事項請勿重複列入決議區塊"), "應約束待辦事項勿重複列入決議")

        let reducePrompt = MeetingSummarizer.reduceSystemPrompt
        expectTrue(reducePrompt.contains("待辦事項之期限必須嚴格照分段摘要原文填寫"), "Reduce 階段應約束期限照原文")
        expectTrue(reducePrompt.contains("嚴禁自行補上年份"), "Reduce 階段應嚴禁補年份")
        expectTrue(reducePrompt.contains("待辦工作事項請勿重複列入決議區塊"), "Reduce 階段應約束待辦事項勿重複列入決議")
    }
}
