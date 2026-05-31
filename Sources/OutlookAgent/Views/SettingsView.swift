import SwiftUI

/// macOS native Settings scene (App.swift'te `Settings { SettingsView() }` ile
/// bind'lenir → ⌘, kısayolu). Provider seçimi + provider'a özel form.
struct SettingsView: View {
    @ObservedObject private var store = AIConfigStore.shared
    @State private var draft: AIConfig = AIConfigStore.shared.config
    @State private var anthropicKey: String = KeychainHelper.get(AISecretKey.anthropicAPIKey) ?? ""
    @State private var openAIKey: String = KeychainHelper.get(AISecretKey.openAIAPIKey) ?? ""

    @State private var testStatus: TestStatus = .idle
    enum TestStatus: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    var body: some View {
        TabView {
            aiProviderTab
                .tabItem { Label("AI Provider", systemImage: "brain") }
        }
        .frame(width: 560, height: 480)
    }

    private var aiProviderTab: some View {
        Form {
            Section("Aktif Saglayici") {
                Picker("Saglayici", selection: $draft.activeProvider) {
                    ForEach(AIProviderKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                providerSpecificForm
            } header: {
                Text(draft.activeProvider.displayName)
            }

            Section {
                HStack {
                    Button("Baglanti testi") {
                        Task { await testConnection() }
                    }
                    .disabled(testStatus == .running)

                    Spacer()

                    testStatusLabel
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Geri Al") {
                        draft = store.config
                        anthropicKey = KeychainHelper.get(AISecretKey.anthropicAPIKey) ?? ""
                        openAIKey = KeychainHelper.get(AISecretKey.openAIAPIKey) ?? ""
                    }
                    Button("Kaydet") {
                        saveAll()
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var providerSpecificForm: some View {
        switch draft.activeProvider {
        case .claudeCLI:
            TextField("Binary path (opsiyonel)", text: $draft.claudeCLI.binaryPath,
                      prompt: Text("/opt/homebrew/bin/claude (bos birakirsan auto-detect)"))
            Text("Claude Max abonesi veya `claude login` ile auth'lu kullanicilar API key gerektirmez. Bos brakirsan standart Homebrew/system path'leri taranir.")
                .font(.caption).foregroundStyle(.secondary)

        case .anthropicAPI:
            SecureField("API key", text: $anthropicKey,
                        prompt: Text("sk-ant-..."))
            TextField("Model", text: $draft.anthropicAPI.model)
            Text("console.anthropic.com → Settings → API Keys. Onerilen: claude-opus-4-7 (en yetenekli) veya claude-sonnet-4-6 (hizli).")
                .font(.caption).foregroundStyle(.secondary)

        case .openAI:
            SecureField("API key", text: $openAIKey,
                        prompt: Text("sk-..."))
            TextField("Model", text: $draft.openAI.model,
                      prompt: Text("gpt-4o, gpt-5"))
            TextField("Base URL", text: $draft.openAI.baseURL,
                      prompt: Text("https://api.openai.com/v1"))
            Text("OpenAI-compatible servisler (Azure OpenAI, Groq, OpenRouter) icin baseURL'i degistirebilirsin.")
                .font(.caption).foregroundStyle(.secondary)

        case .ollama:
            TextField("Model", text: $draft.ollama.model,
                      prompt: Text("llama3.1, qwen2.5, mistral"))
            TextField("Base URL", text: $draft.ollama.baseURL,
                      prompt: Text("http://localhost:11434"))
            Text("Lokal Ollama gerekir (`brew install ollama` + `ollama serve`). Model'i once `ollama pull <model>` ile indir.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var testStatusLabel: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(3)
        }
    }

    private func saveAll() {
        // API key'leri Keychain'e yaz (bos string ise sil → kullanıcı temizleyebilsin)
        if anthropicKey.isEmpty {
            KeychainHelper.delete(AISecretKey.anthropicAPIKey)
        } else {
            try? KeychainHelper.set(anthropicKey, for: AISecretKey.anthropicAPIKey)
        }
        if openAIKey.isEmpty {
            KeychainHelper.delete(AISecretKey.openAIAPIKey)
        } else {
            try? KeychainHelper.set(openAIKey, for: AISecretKey.openAIAPIKey)
        }
        store.save(draft)
    }

    private func testConnection() async {
        await MainActor.run { testStatus = .running }
        // Test icin gecici provider olustur (henuz Save edilmemis olabilir)
        let provider: AIProvider
        switch draft.activeProvider {
        case .claudeCLI:
            provider = ClaudeCLIProvider(configuredPath: draft.claudeCLI.binaryPath)
        case .anthropicAPI:
            provider = AnthropicAPIProvider(model: draft.anthropicAPI.model, apiKey: anthropicKey)
        case .openAI:
            provider = OpenAIProvider(model: draft.openAI.model,
                                      baseURL: draft.openAI.baseURL,
                                      apiKey: openAIKey)
        case .ollama:
            provider = OllamaProvider(model: draft.ollama.model, baseURL: draft.ollama.baseURL)
        }

        do {
            let start = Date()
            _ = try await provider.complete(
                prompt: "Reply with the single word: pong",
                options: AIOptions(timeoutSec: 30, preferJSON: false)
            )
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await MainActor.run { testStatus = .success("Basarili (\(ms)ms)") }
        } catch {
            await MainActor.run { testStatus = .failure(error.localizedDescription) }
        }
    }
}
