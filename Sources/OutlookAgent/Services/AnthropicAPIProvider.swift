import Foundation

/// Anthropic /v1/messages API'sini HTTPS uzerinden cagirir. API key Keychain'de.
/// Default model claude-opus-4-7; Settings'ten degistirilebilir.
final class AnthropicAPIProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind = .anthropicAPI

    private let model: String
    private let apiKey: String
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(model: String, apiKey: String) {
        self.model = model
        self.apiKey = apiKey
    }

    func complete(prompt: String, options: AIOptions) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.configMissing("Anthropic API key (Settings → Anthropic)")
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = options.timeoutSec

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                ["role": "user", "content": prompt],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startTime = Date()
        AppLogger.bg(.info, .claudeSubprocess, "anthropic API cagrisi", [
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
            AppLogger.bg(.error, .claudeSubprocess, "anthropic HTTP \(http.statusCode)", [
                "elapsedMs":  .int(elapsedMs),
                "bodyHead":   .string(String(preview)),
            ], traceId: options.traceId)
            throw AIProviderError.httpStatus(http.statusCode, String(preview))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String, !text.isEmpty else {
            throw AIProviderError.emptyResult
        }

        AppLogger.bg(.info, .claudeSubprocess, "anthropic basarili", [
            "elapsedMs":   .int(elapsedMs),
            "resultBytes": .int(text.count),
        ], traceId: options.traceId)

        return text
    }
}
