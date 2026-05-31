import Foundation

/// Lokal Ollama server (/api/generate). API key gerektirmez. baseURL default
/// http://localhost:11434. Model adi (llama3.1, qwen2.5, mistral, vb.) Settings'ten
/// secilir. preferJSON=true ise format=json hint'i gonderilir.
final class OllamaProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind = .ollama

    private let model: String
    private let baseURL: String

    init(model: String, baseURL: String) {
        self.model = model
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func complete(prompt: String, options: AIOptions) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw AIProviderError.configMissing("Gecersiz baseURL: \(baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = options.timeoutSec

        var body: [String: Any] = [
            "model":  model,
            "prompt": prompt,
            "stream": false,
        ]
        if options.preferJSON {
            body["format"] = "json"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startTime = Date()
        AppLogger.bg(.info, .claudeSubprocess, "ollama API cagrisi", [
            "model":      .string(model),
            "baseURL":    .string(baseURL),
            "promptSize": .int(prompt.count),
        ], traceId: options.traceId)

        let (data, response) = try await URLSession.shared.data(for: req)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.responseParseError("HTTPURLResponse degil")
        }

        if http.statusCode != 200 {
            let preview = String(data: data, encoding: .utf8)?.prefix(240) ?? "?"
            AppLogger.bg(.error, .claudeSubprocess, "ollama HTTP \(http.statusCode)", [
                "elapsedMs": .int(elapsedMs),
                "bodyHead":  .string(String(preview)),
            ], traceId: options.traceId)
            throw AIProviderError.httpStatus(http.statusCode, String(preview))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String, !response.isEmpty else {
            throw AIProviderError.emptyResult
        }

        AppLogger.bg(.info, .claudeSubprocess, "ollama basarili", [
            "elapsedMs":   .int(elapsedMs),
            "resultBytes": .int(response.count),
        ], traceId: options.traceId)

        return response
    }
}
