import Foundation

/// Tum AI saglayicilarinin uygulayacagi sade interface. Prompt in → text out.
/// JSON cikti garantisi her provider'in kendi mekanizmasi (CLI raw text,
/// Anthropic/OpenAI response_format, Ollama format=json) ile saglanir.
protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    func complete(prompt: String, options: AIOptions) async throws -> String
}

enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case claudeCLI       = "claude_cli"
    case anthropicAPI    = "anthropic_api"
    case openAI          = "openai"
    case ollama          = "ollama"

    var displayName: String {
        switch self {
        case .claudeCLI:    return "Claude CLI (lokal subprocess)"
        case .anthropicAPI: return "Anthropic API"
        case .openAI:       return "OpenAI"
        case .ollama:       return "Ollama (lokal)"
        }
    }
}

/// Provider'a ait per-call ayarlar. tools sadece Claude CLI tarafindan
/// kullanilir (--allowedTools); diger providerlar ignore eder.
struct AIOptions: Sendable {
    var tools: [String] = []
    var timeoutSec: TimeInterval = 120
    var traceId: UUID? = nil
    /// JSON cikti istegi: OpenAI response_format / Ollama format=json.
    /// Claude CLI ve Anthropic API plain text doner (extractJSON helper'i
    /// code-fence ile JSON cikarir).
    var preferJSON: Bool = true
}

enum AIProviderError: LocalizedError {
    case binaryMissing(String)
    case configMissing(String)
    case httpStatus(Int, String)
    case nonZeroExit(String)
    case emptyResult
    case timeout(TimeInterval)
    case responseParseError(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let p):     return "Binary bulunamadi: \(p)"
        case .configMissing(let f):     return "Konfigurasyon eksik: \(f)"
        case .httpStatus(let s, let m): return "HTTP \(s): \(m)"
        case .nonZeroExit(let m):       return "Subprocess hata: \(m)"
        case .emptyResult:              return "Bos sonuc dondu."
        case .timeout(let s):           return "Timeout: \(Int(s))sn asildi."
        case .responseParseError(let s): return "Yanit parse edilemedi: \(s)"
        }
    }
}
