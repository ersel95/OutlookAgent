import Foundation

/// OpenAI Chat Completions API (/v1/chat/completions). baseURL override edilebilir
/// — OpenAI-compatible diger servisler (Azure OpenAI, Groq, OpenRouter) icin de
/// kullanilabilir. preferJSON=true ise response_format=json_object set edilir.
final class OpenAIProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind = .openAI

    private let model: String
    private let baseURL: String
    private let apiKey: String

    init(model: String, baseURL: String, apiKey: String) {
        self.model = model
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
    }

    func complete(prompt: String, options: AIOptions) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.configMissing("OpenAI API key (Settings → OpenAI)")
        }
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AIProviderError.configMissing("Gecersiz baseURL: \(baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = options.timeoutSec

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt],
            ],
        ]
        if options.preferJSON {
            body["response_format"] = ["type": "json_object"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startTime = Date()
        AppLogger.bg(.info, .claudeSubprocess, "openai API cagrisi", [
            "model":      .string(model),
            "promptSize": .int(prompt.count),
        ], traceId: options.traceId)

        let (data, response) = try await URLSession.shared.data(for: req)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.responseParseError("HTTPURLResponse degil")
        }

        if http.statusCode != 200 {
            let preview = String(data: data, encoding: .utf8)?.prefix(240) ?? "?"
            AppLogger.bg(.error, .claudeSubprocess, "openai HTTP \(http.statusCode)", [
                "elapsedMs":  .int(elapsedMs),
                "bodyHead":   .string(String(preview)),
            ], traceId: options.traceId)
            throw AIProviderError.httpStatus(http.statusCode, String(preview))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw AIProviderError.emptyResult
        }

        AppLogger.bg(.info, .claudeSubprocess, "openai basarili", [
            "elapsedMs":   .int(elapsedMs),
            "resultBytes": .int(content.count),
        ], traceId: options.traceId)

        return content
    }
}
