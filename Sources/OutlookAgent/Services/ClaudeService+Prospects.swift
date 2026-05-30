import Foundation

// MARK: - AI SDR (Prospects) — scoring + sequence drafting

extension ClaudeService {

    /// V0 7-step multi-channel sequence template. AI draft'ları bu iskelet üstüne
    /// içerik üretir. dayOffset = ilk temas (Day 0) sonrası gün sayısı.
    struct SequenceStepSpec {
        let index: Int
        let dayOffset: Int
        let channel: SequenceChannel
        let intent: String         // "intro", "vertical case study", "tech angle", "break-up", vb.
    }

    static let mainSequenceTemplate: [SequenceStepSpec] = [
        .init(index: 0, dayOffset: 0,  channel: .email,             intent: "kısa intro — neden Agora, kişiye özel hook (recent funding / stack / kişisel rol)"),
        .init(index: 1, dayOffset: 2,  channel: .linkedinConnect,   intent: "LinkedIn bağlantı isteği (≤300 char, no pitch — sadece ortak nokta)"),
        .init(index: 2, dayOffset: 5,  channel: .email,             intent: "vertical case study — Agora'nın bu vertical'da kazandırdığı somut sonuç"),
        .init(index: 3, dayOffset: 7,  channel: .linkedinMessage,   intent: "LinkedIn mesaj — soft follow-up, kısa (bağlantı kabul edildiyse)"),
        .init(index: 4, dayOffset: 10, channel: .email,             intent: "tech-spesifik açı — latency / scale / rakip switch avantajı"),
        .init(index: 5, dayOffset: 14, channel: .linkedinInMail,    intent: "Sales Nav InMail — tek mesajda full case + 15 dk demo CTA"),
        .init(index: 6, dayOffset: 18, channel: .email,             intent: "break-up — kibar son temas, gelecekte hatırlatma için kapı aralık")
    ]

    static let winBackSequenceTemplate: [SequenceStepSpec] = [
        .init(index: 0, dayOffset: 0,  channel: .email,             intent: "win-back intro — geçen kayıp opp'tan bu yana neyin değiştiği (Agora'da yeni feature / fiyat / case)"),
        .init(index: 1, dayOffset: 3,  channel: .linkedinConnect,   intent: "LinkedIn bağlantı — soft, eski konuşmayı hatırlat"),
        .init(index: 2, dayOffset: 7,  channel: .email,             intent: "spesifik teknik / ticari avantaj — eski itirazı naturally karşıla"),
        .init(index: 3, dayOffset: 12, channel: .linkedinInMail,    intent: "InMail — re-evaluation araştırma temalı, 15 dk konuşma CTA"),
        .init(index: 4, dayOffset: 18, channel: .email,             intent: "break-up — \"yine de yapmadık\" diyebilecekleri kibar kapanış")
    ]

    // MARK: - Auto-discovery (Claude WebSearch)

    /// Verilen Avrupa pazarında (default Türkiye) Agora ICP'ye uyan şirketleri
    /// Claude WebSearch ile gerçek-zamanlı keşfeder. Sonuç toplu Prospect listesi —
    /// kullanıcı UI'da önce review eder, sonra ingest.
    /// Her arama için 8-15 saniye + WebSearch quota harcaması olur.
    func discoverProspects(vertical: String,
                           country: String = "Türkiye",
                           count: Int = 10) async throws -> [Prospect] {
        let prompt = Self.buildDiscoveryPrompt(vertical: vertical, country: country, count: count)
        // Anthropic 30-40 tool turn × 5-15 sn yapabiliyor — 360 sn watchdog (gerçek
        // test 281 sn'de bitti). Discovery için en uzun süre veren çağrı.
        let raw = try await runClaude(
            prompt: prompt, tools: ["WebSearch", "WebFetch"], timeoutSec: 360
        )
        let json = try Self.extractJSON(raw)
        guard let arr = json as? [[String: Any]] else {
            throw ClaudeError.jsonExtractionFailed("discovery: array bekleniyordu")
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        let safeVertical = vertical.lowercased().replacingOccurrences(of: " ", with: "-")
        let tag = "auto-\(country.lowercased())-\(safeVertical)-\(f.string(from: Date()))"

        return arr.compactMap { item -> Prospect? in
            guard let name = item["companyName"] as? String, !name.isEmpty,
                  let domain = item["domain"] as? String, !domain.isEmpty else { return nil }
            let contactDict = (item["contact"] as? [String: Any]) ?? [:]
            let contact = ProspectContact(
                firstName:    (contactDict["firstName"] as? String) ?? "",
                lastName:     (contactDict["lastName"] as? String) ?? "",
                title:        (contactDict["title"] as? String) ?? "",
                email:        (contactDict["email"] as? String) ?? "",
                linkedinUrl:  contactDict["linkedinUrl"] as? String,
                phone:        contactDict["phone"] as? String
            )
            return Prospect(
                companyName: name,
                domain: domain.lowercased(),
                website: item["website"] as? String,
                country: (item["country"] as? String) ?? country,
                industry: item["industry"] as? String,
                employeeRange: item["employeeRange"] as? String,
                fundingStage: item["fundingStage"] as? String,
                lastFundingDate: item["lastFundingDate"] as? String,
                lastFundingAmount: item["lastFundingAmount"] as? String,
                crunchbaseUrl: item["crunchbaseUrl"] as? String,
                description: item["description"] as? String,
                contact: contact,
                sourceTag: tag,
                notes: (item["notes"] as? String) ?? ""
            )
        }
    }

    /// Mevcut bir prospect'i web search + web fetch ile zenginleştirir. Boş
    /// alanları doldurur, mevcut alanları override etmez. Public email / kontak
    /// bulursa contact bilgisini günceller.
    func enrichProspectFromWeb(_ p: Prospect) async throws -> Prospect {
        let prompt = Self.buildEnrichmentPrompt(prospect: p)
        let raw = try await runClaude(prompt: prompt, tools: ["WebSearch", "WebFetch"])
        let json = try Self.extractJSON(raw)
        guard let dict = json as? [String: Any] else {
            throw ClaudeError.jsonExtractionFailed("enrichment: object bekleniyordu")
        }
        var merged = p
        // Boş alanları doldur — non-empty alanları KORU.
        if (merged.country?.isEmpty ?? true), let v = dict["country"] as? String, !v.isEmpty {
            merged.country = v
        }
        if (merged.industry?.isEmpty ?? true), let v = dict["industry"] as? String, !v.isEmpty {
            merged.industry = v
        }
        if (merged.employeeRange?.isEmpty ?? true), let v = dict["employeeRange"] as? String, !v.isEmpty {
            merged.employeeRange = v
        }
        if (merged.fundingStage?.isEmpty ?? true), let v = dict["fundingStage"] as? String, !v.isEmpty {
            merged.fundingStage = v
        }
        if (merged.lastFundingDate?.isEmpty ?? true), let v = dict["lastFundingDate"] as? String, !v.isEmpty {
            merged.lastFundingDate = v
        }
        if (merged.lastFundingAmount?.isEmpty ?? true), let v = dict["lastFundingAmount"] as? String, !v.isEmpty {
            merged.lastFundingAmount = v
        }
        if (merged.crunchbaseUrl?.isEmpty ?? true), let v = dict["crunchbaseUrl"] as? String, !v.isEmpty {
            merged.crunchbaseUrl = v
        }
        if (merged.description?.isEmpty ?? true), let v = dict["description"] as? String, !v.isEmpty {
            merged.description = v
        }
        if (merged.website?.isEmpty ?? true), let v = dict["website"] as? String, !v.isEmpty {
            merged.website = v
        }
        if let extraNotes = dict["notes"] as? String, !extraNotes.isEmpty {
            if merged.notes.isEmpty {
                merged.notes = extraNotes
            } else if !merged.notes.contains(extraNotes) {
                merged.notes += "\n— Web zenginleştirme:\n" + extraNotes
            }
        }
        // Kontak: boşsa yeni bilgi varsa override; doluysa sadece linkedinUrl/phone'u doldur.
        if let cd = dict["contact"] as? [String: Any] {
            if merged.contact.firstName.isEmpty, let v = cd["firstName"] as? String { merged.contact.firstName = v }
            if merged.contact.lastName.isEmpty, let v = cd["lastName"] as? String { merged.contact.lastName = v }
            if merged.contact.title.isEmpty, let v = cd["title"] as? String { merged.contact.title = v }
            if merged.contact.email.isEmpty, let v = cd["email"] as? String { merged.contact.email = v }
            if (merged.contact.linkedinUrl?.isEmpty ?? true), let v = cd["linkedinUrl"] as? String, !v.isEmpty {
                merged.contact.linkedinUrl = v
            }
            if (merged.contact.phone?.isEmpty ?? true), let v = cd["phone"] as? String, !v.isEmpty {
                merged.contact.phone = v
            }
        }
        return merged
    }

    private static func buildEnrichmentPrompt(prospect p: Prospect) -> String {
        return """
        \(AgoraContext.systemPrompt)

        \(AgoraContext.icpProfile)

        GÖREV: Aşağıdaki prospect'i WebSearch + WebFetch ile zenginleştir. \
        Şirketin kendi web sitesini, LinkedIn şirket sayfasını, Crunchbase \
        profilini ve son haberleri tara. Public bilgileri çek — UYDURMA.

        Özellikle şu eksikleri doldurmaya çalış:
        - employee count / range
        - funding stage + son round (date + amount)
        - description (Agora-relevant: canlı yayın / video call / audio rooms / live commerce vb.)
        - rakip RTC SDK izleri (notes alanına yaz)
        - public iletişim email'i (info@ / contact@ / press@ — \(p.domain) gibi domain'lerde)
        - birincil teknik kontak (CEO / CTO / VP Engineering / Head of Eng) ve LinkedIn URL'si

        Mevcut bilgi (override etme — yalnızca eksikleri doldur):
        Şirket: \(p.companyName)
        Domain: \(p.domain)
        Website: \(p.website ?? "—")
        Ülke: \(p.country ?? "—")
        Vertical: \(p.industry ?? "—")
        Çalışan: \(p.employeeRange ?? "—")
        Funding: \(p.fundingStage ?? "—") (\(p.lastFundingDate ?? "—") / \(p.lastFundingAmount ?? "—"))
        Crunchbase: \(p.crunchbaseUrl ?? "—")
        Açıklama: \(p.description ?? "—")
        Notlar: \(p.notes.isEmpty ? "—" : p.notes)
        Birincil kontak: \(p.contact.fullName) — \(p.contact.title) — \(p.contact.email)
        LinkedIn: \(p.contact.linkedinUrl ?? "—")

        Çıktı SADECE JSON — `parseProspectFromText` ile aynı şema:
        {
          "country": null, "industry": null, "employeeRange": null,
          "fundingStage": null, "lastFundingDate": null, "lastFundingAmount": null,
          "crunchbaseUrl": null, "description": null, "website": null,
          "notes": "yeni bulduğun ek bilgiler",
          "contact": {
            "firstName": "...", "lastName": "...", "title": "...",
            "email": "...", "linkedinUrl": "...", "phone": null
          }
        }

        Bilmediğin alanı null bırak. UYDURMA.
        """
    }

    private static func buildDiscoveryPrompt(vertical: String, country: String, count: Int) -> String {
        // Kompakt prompt — sistem prompt + ICP profile YOK (büyük prompt subprocess'i
        // yavaşlatıyor). Kritik kısıtlar inline.
        return """
        Agora.io B2B SDR. RTC SDK satıyoruz (canlı yayın, video, audio, signaling).

        GÖREV: \(country) pazarında "\(vertical)" sektöründe \(count) gerçek startup keşfet. \
        WebSearch + WebFetch ile araştır. UYDURMA — gerçek bulamazsan az döndür.

        Kaynaklar: Crunchbase, LinkedIn şirket sayfaları, webrazzi.com, startups.watch, \
        sektör haberleri, App Store. Önce 1-2 web search yap, sonra spesifik şirket sayfalarını fetch et.

        ICP filtresi:
        - HEDEF: Seed/Series A funding, $50K-$200K ARR potansiyeli, rakip RTC SDK kullanan \
          (Twilio/ZEGOCLOUD/Daily/LiveKit/Vonage) ya da hiç RTC kullanmayan
        - ATLA: Series B startup, France HQ, Telehealth, Enterprise Collaboration, mevcut Agora müşterisi

        Çıktı SADECE JSON array (markdown / açıklama YOK):
        [{
          "companyName":"...",
          "domain":"acme.com (protokolsüz)",
          "website":"https://...",
          "country":"\(country)",
          "industry":"Live-Commerce / Social / FoW / Faith Tech / Live Streaming / Media",
          "employeeRange":"11-50 / 51-200 / 201-500 / 500+ veya null",
          "fundingStage":"Seed / Series A / Series B / Series C / Bootstrapped veya null",
          "lastFundingDate":"YYYY-MM veya null",
          "lastFundingAmount":"$5M veya null",
          "crunchbaseUrl":"... veya null",
          "description":"1 cümle TR — ne yaptıkları + RTC kullanımı",
          "notes":"rakip SDK / mobile app / son haber / ek kontak adı",
          "contact":{
            "firstName":"CEO/CTO/Head of Eng (varsa)",
            "lastName":"...",
            "title":"...",
            "email":"public iletişim varsa (info@/contact@), UYDURMA, yoksa boş",
            "linkedinUrl":"... veya null",
            "phone":null
          }
        }]
        """
    }

    // MARK: - Text → Prospect (paste-and-parse)

    /// Ersel'in paste ettiği serbest metni (Crunchbase profili, LinkedIn About,
    /// Apptopia listing, manuel notlar) yapılandırılmış Prospect'e çevirir.
    /// Eksik alanları null/empty olarak döner — uydurma yapma talimatı prompt'ta.
    func parseProspectFromText(_ raw: String, sourceTag: String) async throws -> Prospect {
        let prompt = Self.buildParsePrompt(text: raw)
        let result = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(result)
        guard let dict = json as? [String: Any] else {
            throw ClaudeError.jsonExtractionFailed("parse: object bekleniyordu")
        }
        let companyName = (dict["companyName"] as? String) ?? ""
        let domain = (dict["domain"] as? String) ?? ""
        guard !companyName.isEmpty, !domain.isEmpty else {
            throw ClaudeError.jsonExtractionFailed(
                "parse: companyName veya domain boş — metni daha fazla bilgiyle paste et"
            )
        }
        let contactDict = (dict["contact"] as? [String: Any]) ?? [:]
        let contact = ProspectContact(
            firstName:    (contactDict["firstName"] as? String) ?? "",
            lastName:     (contactDict["lastName"] as? String) ?? "",
            title:        (contactDict["title"] as? String) ?? "",
            email:        (contactDict["email"] as? String) ?? "",
            linkedinUrl:  contactDict["linkedinUrl"] as? String,
            phone:        contactDict["phone"] as? String
        )
        return Prospect(
            companyName: companyName,
            domain: domain,
            website: dict["website"] as? String,
            country: dict["country"] as? String,
            industry: dict["industry"] as? String,
            employeeRange: dict["employeeRange"] as? String,
            fundingStage: dict["fundingStage"] as? String,
            lastFundingDate: dict["lastFundingDate"] as? String,
            lastFundingAmount: dict["lastFundingAmount"] as? String,
            crunchbaseUrl: dict["crunchbaseUrl"] as? String,
            description: dict["description"] as? String,
            contact: contact,
            sourceTag: sourceTag,
            notes: (dict["notes"] as? String) ?? ""
        )
    }

    private static func buildParsePrompt(text: String) -> String {
        let trimmed = String(text.prefix(8000))
        return """
        \(AgoraContext.systemPrompt)

        GÖREV: Aşağıdaki serbest metinden bir B2B prospect şirketinin yapılandırılmış \
        bilgilerini çıkar. Metin Crunchbase profili, LinkedIn About, Apptopia listing \
        ya da manuel notlar olabilir. Eksik bilgi varsa o alanı null bırak — UYDURMA.

        Çıktı SADECE JSON:
        {
          "companyName": "tam şirket adı",
          "domain": "ana domain (acme.com — protokol yok)",
          "website": "https://... veya null",
          "country": "ülke adı (TR ise 'Türkiye') veya null",
          "industry": "vertical / sektör tek satırda — Agora terminolojisini tercih et: " +
                      "Social, Future of Work, Live-Commerce, EdTech, Healthcare, Gaming, " +
                      "Faith Tech, Media & Entertainment, Telehealth, ya da serbest",
          "employeeRange": "11-50 / 51-200 / 201-500 / 500+ vb. veya null",
          "fundingStage": "Seed / Series A / Series B / Series C / Bootstrapped / Public veya null",
          "lastFundingDate": "YYYY-MM veya YYYY veya null",
          "lastFundingAmount": "$5M / $20M veya null",
          "crunchbaseUrl": "varsa veya null",
          "description": "1-2 cümle Türkçe ne yaptıkları özet",
          "notes": "metinde geçen ama yukarıdaki alanlara sığmayan kritik notlar (rakip SDK, " +
                   "use-case, ek kontak isimleri vb.)",
          "contact": {
            "firstName": "...",
            "lastName": "...",
            "title": "...",
            "email": "...",
            "linkedinUrl": "varsa veya null",
            "phone": "varsa veya null"
          }
        }

        Metinde birincil kontak yoksa contact'ın tüm alanları boş string olabilir; \
        ama email mutlaka domain'le tutarlı olmalı (yapay üretme — yoksa boş bırak).

        ## Metin
        \(trimmed)
        """
    }

    // MARK: - Scoring

    func scoreProspect(_ p: Prospect,
                       dedup: DedupResult?,
                       enrichment: [String: String]? = nil) async throws -> ProspectScore {
        let prompt = Self.buildScorePrompt(prospect: p, dedup: dedup, enrichment: enrichment)
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let dict = json as? [String: Any] else {
            throw ClaudeError.jsonExtractionFailed("score: object bekleniyordu")
        }
        let icp = (dict["icpFit"] as? Double) ?? Double(dict["icpFit"] as? Int ?? 0)
        let rev = (dict["revenueFit"] as? Double) ?? Double(dict["revenueFit"] as? Int ?? 0)
        return ProspectScore(
            icpFit: max(0, min(1, icp)),
            revenueFit: max(0, min(1, rev)),
            rationale: (dict["rationale"] as? String) ?? "",
            matchedSignals: (dict["matchedSignals"] as? [String]) ?? [],
            concerns: (dict["concerns"] as? [String]) ?? [],
            scoredAt: Date()
        )
    }

    // MARK: - Sequence drafting

    func draftProspectSequence(_ p: Prospect,
                               dedup: DedupResult?,
                               score: ProspectScore?,
                               queue: ProspectQueue,
                               availableSlots: [DateInterval] = [],
                               customerTimezone: String? = nil,
                               enrichment: [String: String]? = nil) async throws -> [SequenceStep] {
        let template = (queue == .winBack) ? Self.winBackSequenceTemplate : Self.mainSequenceTemplate
        let prompt = Self.buildSequencePrompt(
            prospect: p, dedup: dedup, score: score, queue: queue, template: template,
            availableSlots: availableSlots, customerTimezone: customerTimezone,
            enrichment: enrichment
        )
        let raw = try await runClaude(prompt: prompt)
        let json = try Self.extractJSON(raw)
        guard let arr = json as? [[String: Any]] else {
            throw ClaudeError.jsonExtractionFailed("sequence: array bekleniyordu")
        }

        // Çıktıyı template'le birleştir — template ground truth, AI sadece içerik üretir.
        var steps: [SequenceStep] = []
        for spec in template {
            let match = arr.first { ($0["index"] as? Int) == spec.index }
            let subj = match?["subject"] as? String
            let body = (match?["body"] as? String) ?? ""
            let rationale = match?["rationale"] as? String
            steps.append(SequenceStep(
                index: spec.index,
                dayOffset: spec.dayOffset,
                channel: spec.channel,
                subject: spec.channel == .linkedinConnect || spec.channel == .linkedinMessage ? nil : subj,
                body: body,
                rationale: rationale,
                status: body.isEmpty ? .pending : .drafted
            ))
        }
        return steps
    }

    // MARK: - Prompt builders

    private static func buildScorePrompt(prospect p: Prospect,
                                         dedup: DedupResult?,
                                         enrichment: [String: String]?) -> String {
        let dedupNote: String = {
            guard let d = dedup else { return "(dedup yapılmadı)" }
            switch d.decision {
            case .freshNoRecord:           return "Salesforce'ta hiç kayıt yok — taze prospect."
            case .disqualifiedLead:        return "Eski DQ Lead var (sebep: \(d.disqualifyReason ?? "—")). Yeni angle gerekecek."
            case .closedLost:              return "Closed Lost Opp var (\(d.opportunityName ?? "—"), \(d.opportunityCloseDate ?? "—")) — win-back kuyruğu."
            case .openLeadOtherRep:        return "Açık Lead başka rep'te (\(d.leadOwner ?? "—")) — paralel approach."
            case .skippedActiveAccount,
                 .skippedOpenOpportunity:  return "Skip kararı verilmiş — skor irrelevant."
            }
        }()

        return """
        \(AgoraContext.systemPrompt)

        \(AgoraContext.icpProfile)

        GÖREV: Aşağıdaki prospect şirketi için iki ayrı skor üret:
        1. **icpFit** (0.0–1.0): ICP V1 pattern'leriyle uyum — yüksek WR vertical mı, \
           sweet-spot funding stage mi, Avrupa/TR HQ mi, rakip switch / cold adopter mi.
        2. **revenueFit** (0.0–1.0): $50K–$200K ARR bandı için olası — şirket büyüklüğü, \
           funding seviyesi, vertical-spesifik kullanım hacmi.

        Anti-ICP eşleşmesi (Series B, France, Telehealth) icpFit'i düşürür.
        Eksik bilgi varsa düşük confidence ile düşük skor ver — uydurma.

        Çıktı SADECE JSON:
        {
          "icpFit": 0.0-1.0,
          "revenueFit": 0.0-1.0,
          "rationale": "1-2 cümle Türkçe gerekçe",
          "matchedSignals": ["yeşil sinyal 1", "yeşil sinyal 2", ...],
          "concerns": ["kırmızı sinyal 1", ...]
        }

        ## Prospect
        Şirket: \(p.companyName)
        Domain: \(p.domain)
        Ülke: \(p.country ?? "—")
        Vertical / Industry: \(p.industry ?? "—")
        Çalışan: \(p.employeeRange ?? "—")
        Funding: \(p.fundingStage ?? "—") (son round: \(p.lastFundingDate ?? "—"), tutar: \(p.lastFundingAmount ?? "—"))
        Açıklama: \(p.description ?? "—")

        ## Birincil kontak
        \(p.contact.fullName) — \(p.contact.title)
        Email: \(p.contact.email)

        ## Salesforce dedup notu
        \(dedupNote)

        \(enrichmentSection(enrichment))
        """
    }

    private static func enrichmentSection(_ enrichment: [String: String]?) -> String {
        guard let e = enrichment, !e.isEmpty else { return "" }
        let source = e["source"] ?? "SF"
        let lines = e
            .filter { $0.key != "source" }
            .sorted { $0.key < $1.key }
            .map { "• \($0.key): \($0.value)" }
        return """

        ## Salesforce / Crunchbase enrichment (\(source))
        \(lines.joined(separator: "\n"))

        Bu alanları skor + draft içeriğinde KULLAN — özellikle "Already using Agora SDK?",
        "Competitor RTC SDK", "Vertical (SF)", "Last Funding Round" değerleri varsa.
        """
    }

    private static func buildSequencePrompt(prospect p: Prospect,
                                            dedup: DedupResult?,
                                            score: ProspectScore?,
                                            queue: ProspectQueue,
                                            template: [SequenceStepSpec],
                                            availableSlots: [DateInterval],
                                            customerTimezone: String?,
                                            enrichment: [String: String]?) -> String {
        let queueLabel = queue.label
        let scoreNote: String = {
            guard let s = score else { return "(skor yok)" }
            return String(format: "ICP %.0f%% / Revenue %.0f%%. %@",
                          s.icpFit * 100, s.revenueFit * 100, s.rationale)
        }()
        let dedupNote: String = {
            guard let d = dedup else { return "" }
            switch d.decision {
            case .disqualifiedLead:
                return "ÖNEMLİ: Bu prospect daha önce Disqualified Lead'di (eski sebep: \(d.disqualifyReason ?? "—")). " +
                       "Aynı pitch'i tekrarlama — yeni angle (örn: o zamandan bu yana firmanın değişmiş durumu, " +
                       "Agora'nın yeni feature'ı, farklı kontak rolü) ile yaklaş."
            case .closedLost:
                return "ÖNEMLİ: Geçmiş Closed Lost Opp var (\(d.opportunityName ?? "—"), \(d.opportunityCloseDate ?? "—")). " +
                       "Win-back angle: \"o zamandan bu yana neyin değiştiği\" — yeni feature, fiyat reform, vertical-spesifik case."
            case .openLeadOtherRep:
                return "Bu prospect zaten başka rep'in (\(d.leadOwner ?? "—")) açık Lead'i. " +
                       "Paralel approach yapıyoruz — territorial ya da role-based ayrım göstererek başla."
            default:
                return ""
            }
        }()

        let langHint: String = {
            if p.isTurkey { return "Türkçe yaz — kişi büyük olasılıkla TR'li." }
            // Avrupa'da TR dışı → İngilizce default
            return "İngilizce yaz — Avrupa B2B."
        }()

        var stepBlocks: [String] = []
        for s in template {
            let chTag: String
            let constraints: String
            switch s.channel {
            case .email:
                chTag = "Email"
                constraints = "subject (≤80 char), body 80–180 kelime, plain-text, 'Saygılarımla, Ersel Tarhan / Region Manager — Agora.io' ile bitir."
            case .linkedinConnect:
                chTag = "LinkedIn Connect Request"
                constraints = "≤300 character TOPLAM, hiç pitch yok — sadece ortak nokta ya da kişiye özel takdir. subject yok."
            case .linkedinMessage:
                chTag = "LinkedIn Message"
                constraints = "100–250 character, soft follow-up, demo / tech reference. subject yok."
            case .linkedinInMail:
                chTag = "Sales Nav InMail"
                constraints = "subject (≤200 char), body 100–250 kelime, somut case + 15 dk demo CTA. Plain-text."
            }
            stepBlocks.append("""
            Step \(s.index) — Day \(s.dayOffset) — \(chTag)
              Niyet: \(s.intent)
              Format kuralı: \(constraints)
            """)
        }

        return """
        \(AgoraContext.systemPrompt)

        \(AgoraContext.icpProfile)

        GÖREV: Aşağıdaki prospect için \(template.count)-step \(queueLabel.lowercased()) \
        sequence draft yaz. Her step için yukarıdaki şablonun niyetine + format kuralına \
        sıkı sıkıya uy. Dil: \(langHint)

        Hyper-personalization şart: her step'te en az 1 spesifik referans kullan \
        (recent funding, kullanılan rakip SDK, kişinin LinkedIn rolü, şirketin son haberi \
        ya da vertical-spesifik case). Jenerik "Agora is great" yazma. Eğer veride bu \
        referansları üretemiyorsan, body'i o step için kısa tut ve hangi datanın eksik \
        olduğunu rationale'a yaz.

        Çıktı SADECE JSON dizisi (her item bir step için, sırayla):
        [
          {
            "index": 0,
            "subject": "..." veya null,
            "body": "<step içeriği — plain text, satır sonları korunur>",
            "rationale": "1 cümle: bu step'i neden bu şekilde yazdın"
          },
          ...
        ]

        ## Prospect
        Şirket: \(p.companyName)
        Domain: \(p.domain)
        Ülke: \(p.country ?? "—")
        Vertical: \(p.industry ?? "—")
        Çalışan: \(p.employeeRange ?? "—")
        Funding: \(p.fundingStage ?? "—") (son round: \(p.lastFundingDate ?? "—") / \(p.lastFundingAmount ?? "—"))
        Crunchbase: \(p.crunchbaseUrl ?? "—")
        Açıklama: \(p.description ?? "—")
        Notlar: \(p.notes.isEmpty ? "—" : p.notes)

        ## Birincil kontak
        İsim: \(p.contact.fullName)
        Title: \(p.contact.title)
        Email: \(p.contact.email)
        LinkedIn: \(p.contact.linkedinUrl ?? "—")

        ## Skor
        \(scoreNote)

        ## Salesforce dedup
        \(dedupNote.isEmpty ? "—" : dedupNote)

        ## Sequence şablonu (\(template.count) step)
        \(stepBlocks.joined(separator: "\n\n"))

        \(enrichmentSection(enrichment))

        \(slotsSection(availableSlots, customerTimezone: customerTimezone))
        """
    }

    /// Müsait slot listesini Ersel'in TZ'i + (varsa) müşteri TZ'i ile formatlar.
    /// İlk email step'inin sonunda CTA olarak kullanılması için AI'a verilir.
    private static func slotsSection(_ slots: [DateInterval], customerTimezone: String?) -> String {
        guard !slots.isEmpty else { return "" }
        let userFmt = DateFormatter()
        userFmt.dateFormat = "EEE d MMM HH:mm"
        userFmt.locale = Locale(identifier: "tr_TR")
        userFmt.timeZone = .current
        let custTz = customerTimezone.flatMap { TimeZone(identifier: $0) }
        let custFmt: DateFormatter? = custTz.map { tz in
            let f = DateFormatter()
            f.dateFormat = "EEE d MMM HH:mm zzz"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            return f
        }
        let lines: [String] = slots.prefix(6).map { slot in
            let start = slot.start
            let end = slot.end
            let startStr = userFmt.string(from: start)
            let endStr = DateFormatter.timeOnly.string(from: end)
            var line = "• \(startStr)–\(endStr) (Ersel)"
            if let f = custFmt {
                line += " / \(f.string(from: start)) (Müşteri)"
            }
            return line
        }
        return """

        ## Ersel'in müsait slot'ları (önümüzdeki 5 iş günü)
        \(lines.joined(separator: "\n"))

        İlk email step'inin sonuna kısa bir "önereceğim slot'lar:" CTA bölümü EKLE \
        (sadece 2-3 slot, müşteri TZ'sinde formatla — Ersel'in TZ'sini ek bilgi olarak ver).
        """
    }
}

private extension DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = .current
        return f
    }()
}
