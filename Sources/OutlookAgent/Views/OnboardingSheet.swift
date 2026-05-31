import SwiftUI

/// Ilk launch'ta (veya aktif provider misconfigured ise) gosterilen modal sheet.
/// Provider sec, minimum bilgi gir, Continue. "Skip"le sonra Settings'ten yapilabilir.
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AIConfigStore.shared

    @State private var pickedProvider: AIProviderKind = .claudeCLI
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var baseURL: String = ""
    @State private var claudeBinary: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("OutlookAgent'a Hosgeldin")
                    .font(.title2).fontWeight(.semibold)
                Text("AI ozellikleri (mail triage, taslak yanit, takvim oneri) icin bir saglayici sec.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Picker("AI Saglayici", selection: $pickedProvider) {
                ForEach(AIProviderKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: pickedProvider) { _, newKind in
                seedDefaults(for: newKind)
            }

            Divider()

            providerFields

            Spacer(minLength: 0)

            HStack {
                Button("Daha sonra") {
                    saveAndDismiss(skipped: true)
                }

                Spacer()

                Button("Devam") {
                    saveAndDismiss(skipped: false)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 360)
        .onAppear { seedDefaults(for: pickedProvider) }
    }

    @ViewBuilder
    private var providerFields: some View {
        switch pickedProvider {
        case .claudeCLI:
            VStack(alignment: .leading, spacing: 8) {
                Text("`claude` CLI gerekir. Yukle:")
                    .font(.subheadline)
                Text("brew install --cask claude-code && claude login")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)

                TextField("Binary path (opsiyonel, bos = auto-detect)", text: $claudeBinary)
                    .font(.callout)
                Text("Claude Max abone veya `claude login` ile auth'lu kullanicilar API key gerektirmez.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .anthropicAPI:
            SecureField("API key (sk-ant-...)", text: $apiKey)
            TextField("Model", text: $model)
            Text("Key: console.anthropic.com → Settings → API Keys")
                .font(.caption).foregroundStyle(.secondary)

        case .openAI:
            SecureField("API key (sk-...)", text: $apiKey)
            TextField("Model", text: $model)
            TextField("Base URL", text: $baseURL)
            Text("Key: platform.openai.com → API Keys")
                .font(.caption).foregroundStyle(.secondary)

        case .ollama:
            TextField("Model", text: $model, prompt: Text("llama3.1, qwen2.5"))
            TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:11434"))
            Text("Lokal Ollama gerekir: `brew install ollama && ollama serve` + `ollama pull <model>`")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func seedDefaults(for kind: AIProviderKind) {
        switch kind {
        case .claudeCLI:
            claudeBinary = store.config.claudeCLI.binaryPath
        case .anthropicAPI:
            apiKey = KeychainHelper.get(AISecretKey.anthropicAPIKey) ?? ""
            model  = store.config.anthropicAPI.model
        case .openAI:
            apiKey  = KeychainHelper.get(AISecretKey.openAIAPIKey) ?? ""
            model   = store.config.openAI.model
            baseURL = store.config.openAI.baseURL
        case .ollama:
            model   = store.config.ollama.model
            baseURL = store.config.ollama.baseURL
        }
    }

    private func saveAndDismiss(skipped: Bool) {
        var cfg = store.config
        cfg.activeProvider = pickedProvider
        switch pickedProvider {
        case .claudeCLI:
            cfg.claudeCLI.binaryPath = claudeBinary
        case .anthropicAPI:
            cfg.anthropicAPI.model = model
            if !apiKey.isEmpty {
                try? KeychainHelper.set(apiKey, for: AISecretKey.anthropicAPIKey)
            }
        case .openAI:
            cfg.openAI.model   = model
            cfg.openAI.baseURL = baseURL
            if !apiKey.isEmpty {
                try? KeychainHelper.set(apiKey, for: AISecretKey.openAIAPIKey)
            }
        case .ollama:
            cfg.ollama.model   = model
            cfg.ollama.baseURL = baseURL
        }
        store.save(cfg)
        dismiss()
    }
}
