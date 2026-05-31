import Foundation

enum ClaudeError: LocalizedError {
    case jsonExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .jsonExtractionFailed(let s): return "Yanıt JSON olarak çözümlenemedi: \(s)"
        }
    }
}

/// AI saglayicisi-agnostic high-level facade. Aktif provider AIConfigStore'dan
/// resolve edilir. `final class` — actor DEGIL: complete cagrilari paralel
/// calisabilsin diye. AIConfigStore.shared MainActor; provider lookup'i her
/// cagrida MainActor.run ile yapilir.
final class ClaudeService: @unchecked Sendable {
    static let shared = ClaudeService()

    // MARK: - Public API

    func triage(emails: [EmailSummary]) async throws -> [String: TriageResult] {
        guard !emails.isEmpty else { return [:] }
        let prompt = Self.buildTriagePrompt(emails: emails)
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let arr = json as? [[String: Any]] else {
            throw ClaudeError.jsonExtractionFailed("triage: array bekleniyordu")
        }
        var out: [String: TriageResult] = [:]
        for item in arr {
            guard let id = item["id"] as? String,
                  let catRaw = item["category"] as? String,
                  let priRaw = item["priority"] as? String,
                  let summary = item["summary"] as? String else { continue }
            let category = TriageCategory(rawValueLoose: catRaw) ?? .other
            let priority = TriagePriority(rawValueLoose: priRaw) ?? .normal
            let competitors = (item["competitorMentions"] as? [String]) ?? []
            let dataFlag = (item["dataResidencyFlag"] as? Bool) ?? false
            let needsReply = (item["needsHumanReply"] as? Bool) ?? false
            let nextAction = (item["suggestedNextAction"] as? String) ?? ""
            let health = item["customerHealth"] as? String
            out[id] = TriageResult(
                category: category, priority: priority,
                summary: summary, customerHealth: health,
                competitorMentions: competitors,
                dataResidencyFlag: dataFlag,
                suggestedNextAction: nextAction,
                needsHumanReply: needsReply
            )
        }
        return out
    }

    func generateDraft(for email: EmailFull, userIntent: String?) async throws -> DraftSuggestion {
        let prompt = Self.buildDraftPrompt(email: email, intent: userIntent)
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let dict = json as? [String: Any],
              let body = dict["body"] as? String else {
            throw ClaudeError.jsonExtractionFailed("draft: body alanı yok")
        }
        return DraftSuggestion(
            body: body,
            tone: (dict["tone"] as? String) ?? "professional",
            rationale: (dict["rationale"] as? String) ?? ""
        )
    }

    func extractTasks(from email: EmailFull) async throws -> [TaskItem] {
        let prompt = Self.buildTodoPrompt(email: email)
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let arr = json as? [[String: Any]] else { return [] }
        let domain = email.fromAddress.split(separator: "@").last.map(String.init) ?? ""
        return arr.compactMap { item -> TaskItem? in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let priority: TaskPriority = {
                guard let p = item["priority"] as? String else { return .normal }
                switch p.lowercased() {
                case "urgent","acil":  return .urgent
                case "high","yüksek":  return .high
                case "low","düşük":    return .low
                default:               return .normal
                }
            }()
            return TaskItem(
                title: title,
                notes: (item["notes"] as? String) ?? "",
                status: .todo,
                priority: priority,
                dueHint: item["dueHint"] as? String,
                account: domain.isEmpty ? nil : domain,
                contactEmail: email.fromAddress,
                contactName: email.fromName,
                sourceEmailId: email.id,
                sourceSubject: email.subject
            )
        }
    }

    // MARK: - Calendar-aware methods

    /// Tag each event with a pipeline stage + customer domain.
    func classifyMeetings(_ events: [CalendarEvent]) async throws -> [String: CalendarStore.EventEnrichment] {
        guard !events.isEmpty else { return [:] }
        let prompt = Self.buildMeetingClassifyPrompt(events: events)
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let arr = json as? [[String: Any]] else { return [:] }
        var out: [String: CalendarStore.EventEnrichment] = [:]
        for item in arr {
            guard let id = item["id"] as? String else { continue }
            let stageRaw = (item["stage"] as? String)?.lowercased() ?? "other"
            let stage = CalendarEvent.PipelineStage(rawValue: stageRaw) ?? .other
            let confidence = (item["confidence"] as? Double)
                ?? Double(item["confidence"] as? Int ?? 0)
            let domain = (item["primaryDomain"] as? String)?
                .trimmingCharacters(in: .whitespaces).lowercased()
            out[id] = CalendarStore.EventEnrichment(
                pipelineStage: stage,
                pipelineConfidence: confidence > 0 ? confidence : nil,
                primaryDomain: (domain?.isEmpty == false) ? domain : nil,
                preparationBrief: nil,
                briefGeneratedAt: nil
            )
        }
        return out
    }

    /// Generate a markdown briefing for an upcoming meeting using the recent inbox.
    func preparationBrief(for event: CalendarEvent, recentMails: [EmailSummary]) async throws -> String {
        let prompt = Self.buildPrepPrompt(event: event, mails: recentMails)
        let raw = try await runClaude(prompt: prompt)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract action items from a calendar event (subject + body + attendees).
    func extractMeetingTasks(from event: CalendarEvent) async throws -> [TaskItem] {
        let prompt = Self.buildMeetingTasksPrompt(event: event)
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let arr = json as? [[String: Any]] else { return [] }
        let domain = event.inferredCustomerDomain
        return arr.compactMap { item -> TaskItem? in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let priority: TaskPriority = {
                guard let p = item["priority"] as? String else { return .normal }
                switch p.lowercased() {
                case "urgent","acil":  return .urgent
                case "high","yüksek":  return .high
                case "low","düşük":    return .low
                default:               return .normal
                }
            }()
            return TaskItem(
                title: title,
                notes: (item["notes"] as? String) ?? "Toplantıdan: " + event.subject,
                status: .todo,
                priority: priority,
                dueHint: item["dueHint"] as? String,
                account: domain,
                contactEmail: event.organizerEmail,
                contactName: event.organizerName,
                category: event.pipelineStage?.rawValue,
                sourceEmailId: nil,
                sourceSubject: "Toplantı: " + event.subject
            )
        }
    }

    /// Polite decline body for a meeting reply.
    func declineDraft(for event: CalendarEvent) async throws -> String {
        let prompt = """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki toplantıyı kibarca reddeden kısa bir mail yanıtı yaz. Türkçe \
        veya toplantı dili neyse ona uy. "Saygılarımla, Ersel Tarhan" ile bitir.

        Çıktı: SADECE mail metni — JSON yok, markdown yok.

        Toplantı: \(event.subject)
        Düzenleyen: \(event.organizerName) <\(event.organizerEmail)>
        Tarih: \(event.startRaw) → \(event.endRaw)
        Lokasyon: \(event.location)
        """
        let raw = try await runClaude(prompt: prompt)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Examine a mail thread and propose a calendar invite (subject/time/attendees).
    func extractInviteSuggestion(from email: EmailFull, thread: [ThreadMessage]) async throws -> InviteSuggestion {
        let prompt = Self.buildInvitePrompt(email: email, thread: thread)
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let dict = json as? [String: Any] else {
            throw ClaudeError.jsonExtractionFailed("invite: object bekleniyordu")
        }
        let subject = (dict["subject"] as? String) ?? "Toplantı"
        let startISO = (dict["startISO"] as? String) ?? ""
        let endISO = (dict["endISO"] as? String) ?? ""
        let location = (dict["location"] as? String) ?? ""
        let attendees = (dict["attendees"] as? [String]) ?? []
        let body = (dict["body"] as? String) ?? ""
        let rationale = (dict["rationale"] as? String) ?? ""
        let customerTz = dict["customerTimezone"] as? String
        let customerLocal = dict["customerLocalTime"] as? String
        return InviteSuggestion(
            subject: subject,
            startISO: startISO,
            endISO: endISO,
            location: location,
            attendees: attendees,
            body: body,
            rationale: rationale,
            customerTimezone: customerTz,
            customerLocalTime: customerLocal
        )
    }

    /// Markdown morning brief: today's meetings + recent mail digest.
    func morningBrief(events: [CalendarEvent], recentMails: [EmailSummary]) async throws -> String {
        let prompt = Self.buildMorningBriefPrompt(events: events, mails: recentMails)
        let raw = try await runClaude(prompt: prompt)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Provider dispatch

    /// `tools` parametresi sadece Claude CLI provider tarafından kullanilir
    /// (--allowedTools); diger provider'lar (API, Ollama) ignore eder. Aktif
    /// provider AIConfigStore'dan resolve edilir.
    func runClaude(prompt: String,
                   tools: [String] = [],
                   timeoutSec: TimeInterval = 120,
                   traceId: UUID? = nil) async throws -> String {
        let provider = await Self.resolveProvider()
        let options = AIOptions(tools: tools, timeoutSec: timeoutSec, traceId: traceId)
        return try await provider.complete(prompt: prompt, options: options)
    }

    /// Aktif provider'i ConfigStore'dan resolve eder. MainActor isolation.
    @MainActor
    private static func resolveProvider() -> AIProvider {
        let cfg = AIConfigStore.shared.config
        switch cfg.activeProvider {
        case .claudeCLI:
            return ClaudeCLIProvider(configuredPath: cfg.claudeCLI.binaryPath)
        case .anthropicAPI:
            return AnthropicAPIProvider(
                model: cfg.anthropicAPI.model,
                apiKey: KeychainHelper.get(AISecretKey.anthropicAPIKey) ?? ""
            )
        case .openAI:
            return OpenAIProvider(
                model: cfg.openAI.model,
                baseURL: cfg.openAI.baseURL,
                apiKey: KeychainHelper.get(AISecretKey.openAIAPIKey) ?? ""
            )
        case .ollama:
            return OllamaProvider(model: cfg.ollama.model, baseURL: cfg.ollama.baseURL)
        }
    }


    // MARK: - Prompt Builders

    private static func buildTriagePrompt(emails: [EmailSummary]) -> String {
        let allowedCats = AgoraContext.allowedCategories.joined(separator: "|")
        let allowedPris = AgoraContext.allowedPriorities.joined(separator: "|")
        var blocks: [String] = []
        for e in emails {
            let preview = e.preview.prefix(500)
            blocks.append("""
            ---
            ID: \(e.id)
            Tarih: \(e.date)
            Kimden: \(e.fromName) <\(e.fromAddress)>
            Konu: \(e.subject)
            Önizleme: \(preview)
            """)
        }
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki e-postaları triage et. Her biri için kategori, öncelik, \
        kısa Türkçe özet, müşteri sağlığı sinyali (varsa), rakip mention'ları, veri \
        yerleşimi/uyum bayrağı ve önerilen sonraki adımı çıkar.

        Çıktıyı SADECE geçerli JSON dizisi olarak ver — açıklama, markdown veya \
        kod çiti EKLEME. Şema:

        [
          {
            "id": "<email id>",
            "category": "\(allowedCats)",
            "priority": "\(allowedPris)",
            "summary": "1-2 cümle Türkçe özet",
            "customerHealth": null veya "kısa not",
            "competitorMentions": [string, ...],
            "dataResidencyFlag": true|false,
            "suggestedNextAction": "kısa Türkçe öneri",
            "needsHumanReply": true|false
          },
          ...
        ]

        E-postalar:
        \(blocks.joined(separator: "\n"))
        """
    }

    private static func buildDraftPrompt(email: EmailFull, intent: String?) -> String {
        let bodyTrimmed = String(email.body.prefix(6000))
        let intentLine = (intent?.isEmpty ?? true)
            ? "Niyet belirtilmedi — sen makul bir profesyonel yanıt yaz."
            : "Yanıt için niyet/talimat: \(intent!)"
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki gelen e-postaya bir yanıt taslağı yaz. Türkçe yaz \
        (kullanıcı Türkçe çalışıyor) ya da gelen e-posta İngilizce ise ona göre \
        İngilizce yaz — gelen mailin diline uy. Selam, imza ve kapanış dahil olsun \
        ama "Saygılarımla, Ersel Tarhan / Region Manager — Agora.io" şeklinde \
        bitir. Reklam dili kullanma.

        \(intentLine)

        Çıktıyı SADECE geçerli JSON olarak ver:
        {"body": "<tam yanıt metni>", "tone": "professional|warm|concise", \
        "rationale": "<neden bu yanıtı seçtin, 1 cümle>"}

        Gelen e-posta:
        Tarih: \(email.date)
        Kimden: \(email.fromName) <\(email.fromAddress)>
        Konu: \(email.subject)

        \(bodyTrimmed)
        """
    }

    private static func buildTodoPrompt(email: EmailFull) -> String {
        let bodyTrimmed = String(email.body.prefix(6000))
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki e-postadan Ersel'in yapması gereken eylemleri (action items) \
        çıkar. Sadece doğrudan ona ait, somut iş maddelerini listele — bilgi notları \
        değil. Tarih ipucu varsa "dueHint" alanına yaz (ör. "Bu Cuma", "Mayıs 12").

        Çıktıyı SADECE geçerli JSON dizisi olarak ver:
        [{"title": "kısa Türkçe eylem", "dueHint": null veya "ipucu", \
        "priority": "urgent|high|normal|low" (opsiyonel), "notes": "kısa not" (opsiyonel)}, ...]

        Hiç eylem yoksa boş dizi `[]` döndür.

        E-posta:
        Konu: \(email.subject)
        Kimden: \(email.fromName) <\(email.fromAddress)>

        \(bodyTrimmed)
        """
    }

    // MARK: - Calendar prompt builders

    private static func buildMeetingClassifyPrompt(events: [CalendarEvent]) -> String {
        var blocks: [String] = []
        for e in events.prefix(20) {
            let attendees = e.allAttendees.prefix(8).map { "\($0.name) <\($0.email)>" }.joined(separator: ", ")
            let bodyTrim = String(e.body.prefix(600))
            blocks.append("""
            ---
            ID: \(e.id)
            Konu: \(e.subject)
            Düzenleyen: \(e.organizerName) <\(e.organizerEmail)>
            Tarih: \(e.startRaw) → \(e.endRaw)
            Yineleyen: \(e.isRecurring ? "evet" : "hayır")
            Lokasyon: \(e.location)
            Katılımcılar: \(attendees)
            Notlar: \(bodyTrim)
            """)
        }
        let stages = "prospect|poc|contract|renewal|qbr|churnRisk|internalNote|partner|focus|other"
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki Outlook takvim olaylarını sınıflandır. Her olay için \
        Agora.io pipeline aşaması ve birincil müşteri domain'i (varsa) belirle. \
        Sadece @agora.io katılımcıları varsa "internalNote" kullan; yenileme \
        konuşması için "renewal", QBR için "qbr". Reseller/partner ise "partner". \
        Boş zaman bloku ya da focus hold ise "focus". Kararsızsan "other" döndür.

        Çıktı SADECE JSON dizisi:
        [{"id": "<event id>", "stage": "\(stages)", \
          "primaryDomain": "<acme.com> veya null", "confidence": 0.0-1.0}, ...]

        Olaylar:
        \(blocks.joined(separator: "\n"))
        """
    }

    private static func buildPrepPrompt(event: CalendarEvent, mails: [EmailSummary]) -> String {
        let attendees = event.allAttendees.prefix(15).map {
            "- \($0.name) <\($0.email)> [\($0.response.label)]"
        }.joined(separator: "\n")
        let mailDigest: String
        if mails.isEmpty {
            mailDigest = "(Bu müşteri/domain ile son inbox'ta mail yok.)"
        } else {
            mailDigest = mails.map { m in
                "• \(m.date) | \(m.fromName) <\(m.fromAddress)>\n   Konu: \(m.subject)\n   Önizleme: \(m.preview.prefix(220))"
            }.joined(separator: "\n")
        }
        let bodyTrim = String(event.body.prefix(2000))
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki yaklaşan toplantı için 1 sayfalık Türkçe hazırlık brief'i \
        yaz (Markdown). Bölümler:
        1. **Bağlam** — toplantının amacı, müşteri/iç olduğu, pipeline aşaması
        2. **Son E-postalar** — özet (varsa) ve son 1-2 maille bağlantısı
        3. **Açık Konular** — bilinen sorular, beklenen taleplerden çıkarım
        4. **Risk / Sinyal** — varsa rakip mention, churn sinyali, veri yerleşimi
        5. **Sorulacak Sorular** — Ersel'in toplantıda sorması faydalı 3-5 soru
        6. **Önerilen Eylemler** — toplantı sonrası yapılacaklar (madde madde)

        Tahmin yapma — bilgi yoksa "(yeterli bilgi yok)" yaz. Çıktı saf Markdown, \
        kod çiti yok. Maksimum ~350 kelime.

        ## Toplantı
        Konu: \(event.subject)
        Tarih: \(event.startRaw) → \(event.endRaw)
        Lokasyon: \(event.location)
        Düzenleyen: \(event.organizerName) <\(event.organizerEmail)>
        Pipeline (önceden tespit edilen): \(event.pipelineStage?.label ?? "—")
        Birincil müşteri domain: \(event.inferredCustomerDomain ?? "—")
        Açıklama:
        \(bodyTrim.isEmpty ? "(boş)" : bodyTrim)

        ## Katılımcılar
        \(attendees.isEmpty ? "(yok)" : attendees)

        ## Son E-postalar (ilgili domain)
        \(mailDigest)
        """
    }

    private static func buildMeetingTasksPrompt(event: CalendarEvent) -> String {
        let bodyTrim = String(event.body.prefix(3000))
        let attendees = event.allAttendees.prefix(10).map { "\($0.name) <\($0.email)>" }.joined(separator: ", ")
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki toplantıdan Ersel'in yapması gereken eylemleri çıkar. \
        Toplantının açıklamasında / agenda'sında belirtilen action items'a odaklan; \
        belirsizse boş dizi döndür.

        Çıktı SADECE JSON dizisi:
        [{"title": "kısa Türkçe eylem", "notes": "kısa not", \
          "priority": "urgent|high|normal|low", "dueHint": null veya "ipucu"}, ...]

        Toplantı: \(event.subject)
        Tarih: \(event.startRaw) → \(event.endRaw)
        Düzenleyen: \(event.organizerName) <\(event.organizerEmail)>
        Katılımcılar: \(attendees)

        Açıklama:
        \(bodyTrim.isEmpty ? "(boş)" : bodyTrim)
        """
    }

    private static func buildInvitePrompt(email: EmailFull, thread: [ThreadMessage]) -> String {
        let nowFmt = DateFormatter()
        nowFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        nowFmt.locale = Locale(identifier: "en_US_POSIX")
        nowFmt.timeZone = .current
        let now = nowFmt.string(from: Date())
        let userTZ = TimeZone.current.identifier

        var threadText = ""
        let lastMsgs = Array(thread.suffix(3))
        for m in lastMsgs {
            threadText += "\n— \(m.fromName) <\(m.fromAddress)> [\(m.date)]:\n\(String(m.body.prefix(700)))\n"
        }
        if threadText.isEmpty {
            threadText = "\n— \(email.fromName) <\(email.fromAddress)> [\(email.date)]:\n\(String(email.body.prefix(2000)))\n"
        }

        let recipientsHint: String = {
            var seen = Set<String>([AgoraContext.userEmail.lowercased()])
            var out: [String] = []
            for cand in [email.fromAddress] + email.toAddresses + email.ccAddresses {
                let lc = cand.lowercased()
                if lc.isEmpty || seen.contains(lc) { continue }
                seen.insert(lc); out.append(cand)
            }
            return out.joined(separator: ", ")
        }()

        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki mail konuşmasından bir toplantı daveti öner. Mailde \
        açıkça önerilen tarih/saat varsa onu kullan; yoksa "yarın 15:00–15:30" \
        gibi makul bir varsayılan kullan. Süreyi belirsizse 30 dk yap.

        Şu anki zaman (kullanıcının TZ'inde): \(now)
        Kullanıcının timezone'ı: \(userTZ)

        Karşı tarafın domain'inden tahmini timezone'u çıkar (.com.tr/Türkiye, \
        .uk/Londra, .de/Berlin, .sg/Singapore, .cn/Şangay, .in/Hindistan vb). \
        Yine de davetin başlangıç/bitiş zamanı KULLANICININ LOKAL ZAMANINDA olmalı.

        Çıktı SADECE JSON:
        {
          "subject": "Toplantı başlığı",
          "startISO": "yyyy-MM-dd HH:mm:ss",     // local TZ (\(userTZ))
          "endISO":   "yyyy-MM-dd HH:mm:ss",
          "location": "Teams / Zoom linki YOKSA boş",
          "attendees": ["a@b.com", ...],         // kullanıcıyı (\(AgoraContext.userEmail)) DAHİL ETME
          "body": "Davet açıklaması — Türkçe, 2-3 cümle agenda + son thread özeti",
          "rationale": "Bu zamanı neden seçtin (1 cümle)",
          "customerTimezone": "Europe/London veya null",
          "customerLocalTime": "İnsan-okur format ör. 'Pzt 16:00 BST' veya null"
        }

        Başlangıç adayı katılımcılar: \(recipientsHint)

        Konu: \(email.subject)
        Son mesajlar:
        \(threadText)
        """
    }

    private static func buildMorningBriefPrompt(events: [CalendarEvent], mails: [EmailSummary]) -> String {
        let evtBlock: String
        if events.isEmpty {
            evtBlock = "(Bugün takvimde toplantı yok.)"
        } else {
            evtBlock = events.map { e in
                "- \(e.startRaw)–\(e.endRaw) | \(e.subject) | \(e.allAttendees.prefix(4).map { $0.email }.joined(separator: ", "))"
            }.joined(separator: "\n")
        }
        let mailBlock: String
        if mails.isEmpty {
            mailBlock = "(Inbox boş.)"
        } else {
            mailBlock = mails.map { m in
                "• \(m.date) | \(m.fromName): \(m.subject) — \(String(m.preview.prefix(200)))"
            }.joined(separator: "\n")
        }
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Ersel için 1 sayfalık günün başlangıcı brief'i yaz (Markdown, Türkçe). \
        Bölümler:
        - **Bugünün Toplantıları** (saat sırasıyla, her biri için 1 satır + odak)
        - **Inbox Özeti** (kaç mail, hangi konularda toplanıyor — 5-7 madde)
        - **Bugünkü Öncelikler** (3 madde — toplantılardan ve mailden ortaya çıkan)
        - **Riskler / Hatırlatmalar** (varsa)

        Saf Markdown çıktısı, kod çiti yok. Maksimum ~250 kelime.

        ## Bugünün Toplantıları
        \(evtBlock)

        ## Son Mailler (top 20)
        \(mailBlock)
        """
    }

    // MARK: - JSON Extraction (tolerates code fences)

    static func extractJSON(_ raw: String) throws -> Any {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json ... ``` or ``` ... ``` fences
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let closing = text.range(of: "```", options: .backwards) {
                text = String(text[..<closing.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Find first { or [ then last matching bracket
        guard let firstBracket = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            throw ClaudeError.jsonExtractionFailed("JSON başlangıcı yok")
        }
        let openChar = text[firstBracket]
        let closeChar: Character = (openChar == "{") ? "}" : "]"
        guard let lastBracket = text.lastIndex(of: closeChar) else {
            throw ClaudeError.jsonExtractionFailed("JSON kapanışı yok")
        }
        let slice = String(text[firstBracket...lastBracket])
        guard let data = slice.data(using: .utf8) else {
            throw ClaudeError.jsonExtractionFailed("utf8 dönüşümü başarısız")
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - Loose enum decoding helpers
extension TriageCategory {
    init?(rawValueLoose: String) {
        let lower = rawValueLoose.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for c in TriageCategory.allCases {
            if String(describing: c).lowercased() == lower { self = c; return }
        }
        switch lower {
        case "internal", "internal_note": self = .internalNote
        case "churn", "churn_risk":       self = .churnRisk
        default: return nil
        }
    }
}
extension TriagePriority {
    init?(rawValueLoose: String) {
        let lower = rawValueLoose.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in TriagePriority.allCases {
            if String(describing: p).lowercased() == lower { self = p; return }
        }
        return nil
    }
}

/// Async-safe Data buffer — pipe readabilityHandler'dan gelen chunk'ları
/// thread-safe biriktirir.
actor SubprocessDataCollector {
    private(set) var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
}

/// Async-safe Bool flag — timeout watchdog için.
actor SubprocessFlag {
    private(set) var value = false
    func set() { value = true }
}
