import Foundation

/// Disk'te `~/Library/Application Support/OutlookAgent/config.json`'da tutulur.
/// API key'ler burada degil — Keychain'de (KeychainHelper).
struct AIConfig: Codable, Equatable, Sendable {
    var activeProvider: AIProviderKind

    /// Her provider icin opsiyonel ozel ayarlar. Active olmayanlar da burada
    /// kalir — user provider degistirip geri donerse ayarlar kaybolmaz.
    var claudeCLI: ClaudeCLIConfig
    var anthropicAPI: AnthropicAPIConfig
    var openAI: OpenAIConfig
    var ollama: OllamaConfig

    static let `default` = AIConfig(
        activeProvider: .claudeCLI,
        claudeCLI: .default,
        anthropicAPI: .default,
        openAI: .default,
        ollama: .default
    )

    struct ClaudeCLIConfig: Codable, Equatable, Sendable {
        /// Opsiyonel: explicit binary path. Bos ise standart lokasyonlar taranır.
        var binaryPath: String
        static let `default` = ClaudeCLIConfig(binaryPath: "")
    }

    struct AnthropicAPIConfig: Codable, Equatable, Sendable {
        var model: String
        /// API key Keychain'de — KeychainHelper.get("anthropic_api_key")
        static let `default` = AnthropicAPIConfig(model: "claude-opus-4-7")
    }

    struct OpenAIConfig: Codable, Equatable, Sendable {
        var model: String
        var baseURL: String  // default https://api.openai.com/v1
        static let `default` = OpenAIConfig(model: "gpt-4o", baseURL: "https://api.openai.com/v1")
    }

    struct OllamaConfig: Codable, Equatable, Sendable {
        var model: String
        var baseURL: String  // default http://localhost:11434
        static let `default` = OllamaConfig(model: "llama3.1", baseURL: "http://localhost:11434")
    }
}

/// Keychain key sabitleri — tek noktada tut.
enum AISecretKey {
    static let anthropicAPIKey = "anthropic_api_key"
    static let openAIAPIKey    = "openai_api_key"
}

/// Config dosyasını disk'ten yukleyen ve diske yazan store.
/// Process boyunca cache'lenir; Settings UI degisiklikleri saveAndPublish() ile
/// disk + memory'e atomic yazılır.
@MainActor
final class AIConfigStore: ObservableObject {
    static let shared = AIConfigStore()

    @Published private(set) var config: AIConfig

    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AIConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = .default
            try? Self.write(config: .default, to: fileURL)
        }
    }

    func save(_ new: AIConfig) {
        self.config = new
        try? Self.write(config: new, to: fileURL)
    }

    private static func write(config: AIConfig, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(config)
        try data.write(to: url, options: .atomic)
    }

    /// Active provider yapılandırması "minimum viable" mi? Onboarding kontrolu.
    var isActiveProviderConfigured: Bool {
        switch config.activeProvider {
        case .claudeCLI:
            // Binary path bos ise standart lokasyonlar taranir; varlık check
            // ClaudeCLIProvider içinde yapılır. Burada her zaman valid kabul.
            return true
        case .anthropicAPI:
            return KeychainHelper.get(AISecretKey.anthropicAPIKey)?.isEmpty == false
        case .openAI:
            return KeychainHelper.get(AISecretKey.openAIAPIKey)?.isEmpty == false
        case .ollama:
            return !config.ollama.baseURL.isEmpty
        }
    }
}
