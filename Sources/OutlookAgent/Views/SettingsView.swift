import SwiftUI

/// macOS native Settings scene (App.swift'te `Settings { SettingsView() }` ile
/// bind'lenir → ⌘, kısayolu). İki tab: Accounts (multi-account yönetimi) + AI Provider.
struct SettingsView: View {
    @Environment(AppViewModel.self) private var vm
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
            AccountsTab()
                .tabItem { Label("Hesaplar", systemImage: "person.crop.circle") }

            aiProviderTab
                .tabItem { Label("AI Provider", systemImage: "brain") }
        }
        .frame(width: 620, height: 520)
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

// MARK: - Accounts Tab

private struct AccountsTab: View {
    @Environment(AppViewModel.self) private var vm
    @State private var addAccountInfoShown: Bool = false
    @State private var removeCandidate: MailAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            Divider()

            accountList
        }
        .alert("“\(removeCandidate?.displayName ?? "")” listeden silinsin mi?",
               isPresented: Binding(
                get: { removeCandidate != nil },
                set: { if !$0 { removeCandidate = nil } }
               )) {
            Button("İptal", role: .cancel) { removeCandidate = nil }
            Button("Sil", role: .destructive) {
                if let acc = removeCandidate {
                    vm.accountStore.remove(acc.id)
                }
                removeCandidate = nil
            }
        } message: {
            Text("Bu sadece OutlookAgent içindeki kaydı siler. Outlook'taki hesabı silmez. Outlook'ta hâlâ tanımlıysa bir sonraki “Outlook'tan Yenile” adımında geri eklenecektir.")
        }
        .sheet(isPresented: $addAccountInfoShown) {
            AddAccountInstructionsSheet(isPresented: $addAccountInfoShown)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mail Hesapları")
                    .font(.title2.weight(.semibold))
                Spacer()
                if vm.isLoadingAccounts {
                    ProgressView().scaleEffect(0.6)
                }
                Button {
                    Task { await vm.refreshAccounts() }
                } label: {
                    Label("Outlook'tan Yenile", systemImage: "arrow.clockwise")
                }
                .help("Outlook AppleScript'i üzerinden tanımlı hesapları yeniden tara")

                Button {
                    AccountStore.openOutlookForAccountManagement()
                    addAccountInfoShown = true
                } label: {
                    Label("Hesap Ekle", systemImage: "plus")
                }
                .help("Outlook'u ön plana getir ve yeni hesap ekleme adımlarını göster")
            }

            Text("Outlook for Mac (Classic) yeni hesap eklemeyi AppleScript üstünden desteklemiyor; “Hesap Ekle” Outlook'u öne getirir ve adımları gösterir. Eklediğin hesap “Outlook'tan Yenile” ile listede belirir.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accountList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if vm.accountStore.accounts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Henüz hesap keşfedilmedi")
                            .font(.headline)
                        Text("Outlook çalışıyor ve hesaplar tanımlı mı kontrol et, sonra “Outlook'tan Yenile” adımına bas.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(vm.accountStore.accounts) { acc in
                        AccountRow(account: acc, onRemove: { removeCandidate = acc })
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }
}

// MARK: - Row

private struct AccountRow: View {
    let account: MailAccount
    let onRemove: () -> Void

    @Environment(AppViewModel.self) private var vm
    @State private var displayNameDraft: String = ""
    @State private var colorPickerShown: Bool = false

    private var binding: MailAccount {
        vm.accountStore.account(id: account.id) ?? account
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Color swatch + indicator
            ZStack {
                Circle()
                    .fill(account.color)
                    .frame(width: 30, height: 30)
                Text(initials(for: account))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .opacity(account.isStale ? 0.5 : 1.0)
            .overlay(alignment: .bottomTrailing) {
                if account.isDefault {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .background(Circle().fill(Color(NSColor.controlBackgroundColor)).frame(width: 14, height: 14))
                        .offset(x: 4, y: 4)
                }
            }
            .onTapGesture { colorPickerShown.toggle() }
            .popover(isPresented: $colorPickerShown) {
                ColorSwatchPicker(
                    selectedHex: account.colorHex,
                    onPick: { hex in
                        vm.accountStore.setColor(account.id, hex: hex)
                        colorPickerShown = false
                    }
                )
                .padding(10)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                TextField("Görünen ad", text: Binding(
                    get: { displayNameDraft.isEmpty ? account.displayName : displayNameDraft },
                    set: { displayNameDraft = $0 }
                ), onCommit: {
                    let trimmed = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != account.displayName {
                        vm.accountStore.setDisplayName(account.id, trimmed)
                    }
                    displayNameDraft = ""
                })
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))

                HStack(spacing: 6) {
                    Text(account.emailAddress.isEmpty ? "(adres yok)" : account.emailAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(account.accountType.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                    if account.isStale {
                        Text("Outlook'ta yok")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // Default toggle
            Button {
                vm.accountStore.setDefault(account.id)
            } label: {
                if account.isDefault {
                    Label("Varsayılan", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                } else {
                    Label("Varsayılan yap", systemImage: "seal")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(account.isDefault || !account.isEnabled)
            .help("Yeni outbound mailler bu hesaptan gönderilir")

            // Enabled toggle
            Toggle(isOn: Binding(
                get: { account.isEnabled },
                set: { vm.accountStore.setEnabled(account.id, $0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .help(account.isEnabled ? "Bu hesap aktif" : "Bu hesap devre dışı (Inbox/Calendar'da gösterilmez)")

            // Remove
            Menu {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Listeden Sil", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .opacity(account.isEnabled ? 1.0 : 0.55)
    }

    private func initials(for acc: MailAccount) -> String {
        let source = acc.displayName.isEmpty ? acc.emailAddress : acc.displayName
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        if !letters.isEmpty { return letters.uppercased() }
        return String(source.prefix(2)).uppercased()
    }
}

// MARK: - Color picker swatch

private struct ColorSwatchPicker: View {
    let selectedHex: String?
    let onPick: (String?) -> Void

    private let palette: [(String, Color)] = [
        ("#3B82F6", .blue),
        ("#8B5CF6", .purple),
        ("#EC4899", .pink),
        ("#F97316", .orange),
        ("#14B8A6", .teal),
        ("#22C55E", .green),
        ("#6366F1", .indigo),
        ("#EF4444", .red),
        ("#10B981", .mint),
        ("#06B6D4", .cyan)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Renk").font(.caption.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 5), spacing: 6) {
                ForEach(palette, id: \.0) { hex, color in
                    Circle()
                        .fill(color)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(selectedHex == hex ? 0.8 : 0.0), lineWidth: 2)
                        )
                        .onTapGesture { onPick(hex) }
                }
            }
            Button("Otomatik (renk seçilmedi)") { onPick(nil) }
                .font(.caption)
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Add Account instructions

private struct AddAccountInstructionsSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Outlook'ta Hesap Ekle")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Text("OutlookAgent Outlook AppleScript'i üzerinden hesap eklemeyi yapamıyor (Outlook bu komutu desteklemiyor). Outlook az önce ön plana getirildi — sonraki adımları orada tamamla:")
                .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                step(1, "Üst menü: **Outlook → Settings… → Accounts** (veya **Tools → Accounts…**)")
                step(2, "Sol alt **+** → istenen hesap türünü seç (Exchange / IMAP / Microsoft 365)")
                step(3, "Adımları tamamla — Outlook hesabı senkronize etmeye başlasın")
                step(4, "Buraya dön ve **“Outlook'tan Yenile”** butonuna bas")
            }
            .padding(.vertical, 4)

            HStack {
                Spacer()
                Button("Tamam") { isPresented = false }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(.init(text))
                .font(.callout)
        }
    }
}
