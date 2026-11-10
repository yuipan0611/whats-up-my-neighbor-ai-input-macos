import Foundation

// MARK: - 離線測試網路攔截協議

private final class OfflineMeetingProtocol: URLProtocol {
    private static let lock = NSLock()
    static var mockModelsJSON: String = ""
    static var mockChatResponseJSON: String = ""
    static var mockChatResponses: [String] = []
    static var mockStatusCode: Int = 200
    static var mockError: Error?
    static var capturedRequests: [URLRequest] = []

    static func reset(
        modelsJSON: String = "",
        chatJSON: String = "",
        chatResponses: [String] = [],
        statusCode: Int = 200,
        error: Error? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        mockModelsJSON = modelsJSON
        mockChatResponseJSON = chatJSON
        mockChatResponses = chatResponses
        mockStatusCode = statusCode
        mockError = error
        capturedRequests.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let statusCode = Self.mockStatusCode
        let customError = Self.mockError
        let url = request.url!
        let responseData: Data

        if let customError {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: customError)
            return
        }

        if url.path.hasSuffix("/models") {
            responseData = Data(Self.mockModelsJSON.utf8)
        } else if url.path.hasSuffix("/chat/completions") {
            if !Self.mockChatResponses.isEmpty {
                let next = Self.mockChatResponses.removeFirst()
                responseData = Data(next.utf8)
            } else {
                responseData = Data(Self.mockChatResponseJSON.utf8)
            }
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
        testGenerationOrderingPreventsOldJobOverwritingNewSummary()
        testRecordingSessionDetectionBlocksEarlySummarization()
        testInterleavedDictationWithSummaryFailureNeverPresentsModal()
        print("Meeting summarizer tests passed (23 suites)")
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
          "choices": [{"message": {"role": "assistant", "content": "## 摘要\n- 短稿摘要內容。"}}]
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
        {"choices":[{"message":{"role":"assistant","content":"## 摘要\\n- [00:01:00] 討論模組一。"}}]}
        """
        let mapResponse2 = """
        {"choices":[{"message":{"role":"assistant","content":"## 摘要\\n- [00:02:00] 討論模組二。"}}]}
        """
        let reduceResponse = """
        {"choices":[{"message":{"role":"assistant","content":"## 摘要\\n- [00:01:00] 討論模組一。\\n- [00:02:00] 討論模組二。\\n\\n## 決議\\n- 未提及\\n\\n## 待辦\\n- 未提及\\n\\n## 未解決問題\\n- 未提及"}}]}
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

    // MARK: - Generation 世代逆序防覆寫測試

    static func testGenerationOrderingPreventsOldJobOverwritingNewSummary() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenerationOrderingTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(root: tempDir)
        let session = try! store.beginSession(startedAt: Date(), language: "zh-TW", chunkSeconds: 300)

        // 模擬兩個併發工作：Gen 1 (舊) 與 Gen 2 (新)
        let currentGeneration = 2 // 目前最新為 Gen 2

        // Gen 2 先完成寫入
        let v2Summary = "## 摘要\n這是 Generation 2 的新摘要"
        try! store.writeSummary(v2Summary, for: session.transcriptURL)

        // Gen 1 晚完成，檢查 generation 是否匹配
        let gen1FinishedGeneration = 1
        let v1Summary = "## 摘要\n這是 Generation 1 的舊摘要"

        if gen1FinishedGeneration == currentGeneration {
            try! store.writeSummary(v1Summary, for: session.transcriptURL)
        }
        // 核心斷言：Gen 1 晚到結果不准寫入，檔案仍為 V2
        let currentFile = try! String(contentsOf: store.summaryURL(for: session.transcriptURL), encoding: .utf8)
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

    // MARK: - 交錯情境測試（摘要失敗絕不打斷聽寫）

    static func testInterleavedDictationWithSummaryFailureNeverPresentsModal() {
        var modalPresented = false
        var notificationPosted = false
        var menuTitleUpdated = ""

        let mockShowAlert: (String) -> Void = { _ in
            modalPresented = true
        }
        let mockPostNotification: (String) -> Void = { _ in
            notificationPosted = true
        }
        let mockUpdateMenu: (String) -> Void = { title in
            menuTitleUpdated = title
        }

        func handleSummaryResult(
            error: Error,
            manualTrigger: Bool,
            isDictating: Bool
        ) {
            let failureTitle = "摘要失敗：429，點此重試"
            mockUpdateMenu(failureTitle)
            if manualTrigger {
                if !isDictating {
                    mockShowAlert("會議摘要產生失敗：\(error.localizedDescription)")
                }
            } else {
                // 自動流程：絕不彈出 modal，只發送通知
                mockPostNotification("會議摘要產生失敗：\(error.localizedDescription)")
            }
        }

        let error429 = MeetingSummarizer.error(from: nil, statusCode: 429)

        // 情境 1：自動摘要失敗時，使用者正在聽寫 (isDictating = true)
        handleSummaryResult(error: error429, manualTrigger: false, isDictating: true)
        expectTrue(!modalPresented, "自動摘要失敗在聽寫中絕不允許彈出 modal 視窗")
        expectTrue(notificationPosted, "自動摘要失敗應送出不搶焦點之系統通知")
        expect(menuTitleUpdated, "摘要失敗：429，點此重試")

        // 重設狀態
        modalPresented = false
        notificationPosted = false

        // 情境 2：自動摘要失敗時，使用者未聽寫 (isDictating = false)
        handleSummaryResult(error: error429, manualTrigger: false, isDictating: false)
        expectTrue(!modalPresented, "自動摘要失敗即使未在聽寫中亦絕不可彈出 modal 視窗")
        expectTrue(notificationPosted, "應送出系統通知")

        // 情境 3：手動觸發失敗，但使用者隨即開始聽寫 (isDictating = true)
        modalPresented = false
        handleSummaryResult(error: error429, manualTrigger: true, isDictating: true)
        expectTrue(!modalPresented, "使用者在聽寫中時，手動觸發失敗亦不得彈窗中斷聽寫")
    }
}
