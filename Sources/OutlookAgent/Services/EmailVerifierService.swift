import Foundation

enum EmailVerifierError: LocalizedError {
    case mxLookupFailed(String)
    case noMXRecords
    case patternGuessFailed(String)

    var errorDescription: String? {
        switch self {
        case .mxLookupFailed(let s):       return "MX lookup hatası: \(s)"
        case .noMXRecords:                 return "Domain mail kabul etmiyor (MX kaydı yok)."
        case .patternGuessFailed(let s):   return "Pattern guess hatası: \(s)"
        }
    }
}

/// Email candidate üretir + DNS MX sanity check.
/// SMTP probe Türkiye consumer ISP'lerinde port 25 outbound bloklu olduğu
/// için yapılmıyor; verify-before-send mümkün değil. Yerine: önceden öğrenilmiş
/// pattern cache'i + Claude WebFetch tabanlı pattern guess + bounce-handler.
actor EmailVerifierService {
    static let shared = EmailVerifierService()

    private let digURL: URL? = {
        let candidates = ["/usr/bin/dig", "/opt/homebrew/bin/dig"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }()

    /// Sonuç: (.alive, .deadDomain, .deadWebsite, .unknown).
    /// AI discovery'den dönen prospect'lerin gerçekten ayakta olup olmadığını
    /// doğrular — eski/kapanmış startup'ları filtrelemek için kritik.
    enum DomainHealth: String {
        case alive          // DNS var + HTTPS 2xx/3xx
        case deadDomain     // DNS yok (NXDOMAIN / SERVFAIL / A record boş)
        case deadWebsite    // DNS var ama HTTPS connection refused / timeout / 4xx-5xx
        case unknown        // dig yok ya da network problem (false-positive avoid)
    }

    /// Hem DNS A record hem HTTPS HEAD kontrolü yapar. Eski/kapanmış domain'leri
    /// (vidyodan.com / clickmelive.com vakası) yakalamak için discovery sonrası
    /// her prospect'e uygulanır. ~100ms-3sn arası.
    func checkDomainHealth(_ domain: String) async -> DomainHealth {
        let dom = domain.lowercased()
        // 1. Cloudflare 1.1.1.1 DNS — ev/corporate DNS'den geçen filterleri atla.
        if let dig = digURL {
            let proc = Process()
            proc.executableURL = dig
            proc.arguments = ["+short", "@1.1.1.1", "+time=3", "+tries=2", "A", dom]
            let stdout = Pipe()
            proc.standardOutput = stdout
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if out.isEmpty {
                    return .deadDomain
                }
            } catch {
                return .unknown
            }
        }

        // 2. HTTPS HEAD — DNS var ama site cevap veriyor mu?
        guard let url = URL(string: "https://\(dom)") else { return .unknown }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 6
        req.setValue("Mozilla/5.0 OutlookAgent", forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if (200..<400).contains(http.statusCode) {
                    return .alive
                } else if http.statusCode >= 500 {
                    return .deadWebsite
                } else {
                    // 4xx — bazı siteler HEAD'i 403/405 verir ama canlı.
                    // Quick fallback: GET ile dene.
                    var getReq = URLRequest(url: url)
                    getReq.timeoutInterval = 6
                    getReq.setValue("Mozilla/5.0 OutlookAgent", forHTTPHeaderField: "User-Agent")
                    let (_, getResp) = (try? await URLSession.shared.data(for: getReq)) ?? (Data(), resp)
                    if let h2 = getResp as? HTTPURLResponse, (200..<400).contains(h2.statusCode) {
                        return .alive
                    }
                    return .deadWebsite
                }
            }
            return .unknown
        } catch {
            return .deadWebsite
        }
    }

    /// Domain mail kabul ediyor mu? Yoksa prospect "no-mail" badge alır.
    /// `dig +short MX <domain>` subprocess. Boş dönüş → MX yok.
    func hasMXRecord(_ domain: String) async throws -> Bool {
        guard let dig = digURL else {
            // dig yoksa fallback: çoğu domain mail kabul ediyor varsayalım, send'e izin ver.
            return true
        }
        let proc = Process()
        proc.executableURL = dig
        proc.arguments = ["+short", "+time=3", "+tries=2", "MX", domain.lowercased()]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            throw EmailVerifierError.mxLookupFailed(error.localizedDescription)
        }
        proc.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !output.isEmpty
    }

    /// Bir prospect için en uygun email candidate'i üret.
    /// 1) Cache'de domain için verified/noBounce pattern varsa onu kullan.
    /// 2) Yoksa Claude'a sor (WebFetch ile şirket sitesinde public email örnekleri ara,
    ///    failed template'leri dışla, en olası template'i öner).
    /// 3) Template'i prospect'in firstName/lastName ile birleştir, döndür.
    /// Geri dönüş: (email, kullanılan template, kaynak: cache | guess).
    func emailCandidate(for prospect: Prospect,
                        cache: EmailPatternCache) async throws -> (email: String, template: String, source: String) {
        let domain = prospect.domain.lowercased()
        let firstName = prospect.contact.firstName
        let lastName = prospect.contact.lastName
        guard !firstName.isEmpty else {
            throw EmailVerifierError.patternGuessFailed("Birincil kontağın adı boş — pattern üretilemez.")
        }

        // 1) Cache hit?
        if let learned = await cache.bestPattern(for: domain),
           let email = EmailPatternCache.apply(
               template: learned.template,
               firstName: firstName, lastName: lastName,
               domain: domain
           ) {
            return (email, learned.template, "cache (\(learned.confidence.rawValue))")
        }

        // 2) Claude'dan guess al.
        let failedTemplates = await cache.failedTemplates(for: domain)
        let template = try await guessTemplateViaClaude(
            domain: domain,
            companyName: prospect.companyName,
            failedTemplates: failedTemplates
        )

        guard let email = EmailPatternCache.apply(
            template: template, firstName: firstName, lastName: lastName, domain: domain
        ) else {
            throw EmailVerifierError.patternGuessFailed("Template uygulanamadı.")
        }
        return (email, template, "guess")
    }

    /// Claude WebSearch + WebFetch ile şirket sitesinde public email örneklerini
    /// bulur ve en olası template'i çıkarır. Failed template'leri prompt'ta
    /// dışlamak için açıkça söyler.
    private func guessTemplateViaClaude(domain: String,
                                        companyName: String,
                                        failedTemplates: [String]) async throws -> String {
        let banList: String = {
            guard !failedTemplates.isEmpty else { return "(yok)" }
            return failedTemplates.map { "`\($0)`" }.joined(separator: ", ")
        }()
        let templates = EmailPatternCache.candidateTemplates.map { "`\($0)`" }.joined(separator: ", ")

        let prompt = """
        \(AgoraContext.systemPrompt)

        GÖREV: \(companyName) (\(domain)) şirketinin email pattern'ini tahmin et.

        Yöntem:
        1. WebFetch ile şu URL'leri dene: https://\(domain), https://\(domain)/contact,
           https://\(domain)/about, https://\(domain)/iletisim, https://\(domain)/team.
        2. Sayfada görünen public email adreslerini bul (info@, contact@, hr@, press@, vb.).
        3. WebSearch ile "\(domain) email" ya da "site:\(domain) @\(domain)" ara — public email örnekleri bul.
        4. Bu örneklerden hangi template'in kullanıldığını çıkar.

        İzinli template'ler: \(templates)
        DENEME — bu template'ler bu domain için zaten başarısız: \(banList)

        Hiç örnek bulamazsan TR baseline'ını kullan: `{first}.{last}` (en yaygın TR pattern, ~%45).

        Çıktı SADECE JSON: {"template": "<template>", "rationale": "<1 cümle gerekçe>", "samplesFound": ["info@\(domain)", ...]}
        """
        let raw = try await ClaudeService.shared.runClaude(
            prompt: prompt, tools: ["WebSearch", "WebFetch"]
        )
        let json = try ClaudeService.extractJSON(raw)
        guard let dict = json as? [String: Any],
              let template = dict["template"] as? String,
              !template.isEmpty else {
            throw EmailVerifierError.patternGuessFailed("Claude template döndürmedi.")
        }
        // Failed olanları yine de döndürdüyse (modelin uymadığı durum), default'a düş.
        if failedTemplates.contains(template) {
            return EmailPatternCache.candidateTemplates.first(where: { !failedTemplates.contains($0) })
                ?? "{first}.{last}"
        }
        return template
    }
}
