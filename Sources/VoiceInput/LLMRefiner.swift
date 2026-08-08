import Foundation

/// 设置窗口的“测试连接”使用此客户端；正式转录润色由 Python 内核执行。
/// 两端读取同一份 JSON 配置与 Keychain 条目，因此测试结果能代表实际运行配置。
final class LLMRefiner {
    static let shared = LLMRefiner()
    private var currentTask: URLSessionDataTask?

    var isConfigured: Bool {
        guard let key = KeychainStore.readAPIKey() else { return false }
        return !key.isEmpty
    }

    func refine(
        _ text: String,
        settings: AppSettings = SettingsStore.shared.load(),
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let apiKey = KeychainStore.readAPIKey(), !apiKey.isEmpty else {
            completion(.failure(RefinerError.missingAPIKey))
            return
        }
        let baseURL = settings.llmAPIBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            completion(.failure(RefinerError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let body: [String: Any] = [
            "model": settings.llmModel,
            "messages": [
                ["role": "system", "content": settings.llmPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.3,
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        currentTask = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                DispatchQueue.main.async {
                    completion(.failure(RefinerError.httpStatus(http.statusCode)))
                }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            DispatchQueue.main.async {
                completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    enum RefinerError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "API key is not configured."
            case .invalidURL: return "Invalid API base URL."
            case .invalidResponse: return "The LLM API returned an invalid response."
            case .httpStatus(let code): return "The LLM API returned HTTP \(code)."
            }
        }
    }
}
