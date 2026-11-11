import Foundation

/// Groq 語言模型資訊模型。
struct GroqModelInfo: Equatable {
    let id: String
    let contextWindow: Int
    let active: Bool

    /// 過濾僅保留純文字對話語言模型（排除語音轉錄 whisper-* 與安全過濾 guard 模型）。
    var isChatModel: Bool {
        active && !id.hasPrefix("whisper-") && !id.contains("guard")
    }
}

/// Groq 語言模型動態查詢與挑選器。
///
/// 依規範：
/// 1. 不寫死單一模型名稱，透過 GET https://api.groq.com/openai/v1/models 動態取得模型列表。
/// 2. 依可配置的偏好清單順序進行匹配。
/// 3. 若偏好清單皆不存在，自動挑選可用對話模型中 `context_window` 最大的一款作為兜底。
enum GroqModelSelector {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/models")!
    static let timeoutInterval: TimeInterval = 30

    /// 預設推薦優先順序（可由外部自訂替換，絕不寫死為單一模型；不包含 preview 模型）
    static let defaultPreferences: [String] = [
        "openai/gpt-oss-120b",
        "llama-3.3-70b-versatile",
        "llama-3.1-8b-instant"
    ]

    /// 從 Groq /models API 回傳的 JSON Data 解析模型清單（純函式）。
    static func parseModels(from data: Data) throws -> [GroqModelInfo] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw VoiceTypeError.message("無法解析 Groq 模型清單回應。")
        }

        return dataArray.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let active = item["active"] as? Bool ?? true
            let contextWindow = item["context_window"] as? Int ?? 0
            return GroqModelInfo(id: id, contextWindow: contextWindow, active: active)
        }
    }

    /// 根據偏好清單與可用模型，動態挑選最適合的模型（純函式）。
    static func selectModel(
        from models: [GroqModelInfo],
        preferredOrder: [String] = defaultPreferences
    ) throws -> String {
        let chatModels = models.filter { $0.isChatModel }
        guard !chatModels.isEmpty else {
            throw VoiceTypeError.message("Groq 未提供任何可用的對話語言模型。")
        }

        let modelMap = Dictionary(uniqueKeysWithValues: chatModels.map { ($0.id, $0) })

        // 1. 依偏好清單依序挑選
        for candidate in preferredOrder {
            if modelMap[candidate] != nil {
                return candidate
            }
        }

        // 2. 若偏好皆無，選擇 context_window 最大者
        if let maxContextModel = chatModels.max(by: { $0.contextWindow < $1.contextWindow }) {
            return maxContextModel.id
        }

        return chatModels[0].id
    }

    /// 發送網路請求獲取可用模型並進行動態挑選。
    @discardableResult
    static func fetchAndSelectModel(
        apiKey: String,
        preferredOrder: [String] = defaultPreferences,
        session: URLSession = .shared,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(MeetingSummarizer.formatNetworkError(error)))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(VoiceTypeError.message("查詢 Groq 模型未取得有效回應。")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(MeetingSummarizer.error(from: data, statusCode: http.statusCode)))
                return
            }
            do {
                let models = try parseModels(from: data)
                let selected = try selectModel(from: models, preferredOrder: preferredOrder)
                completion(.success(selected))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }
}
