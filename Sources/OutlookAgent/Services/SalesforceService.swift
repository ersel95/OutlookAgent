import Foundation

enum SalesforceError: LocalizedError {
    case binaryMissing
    case authFailed(String)
    case httpError(Int, String)
    case parseFailed(String)
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:        return "sf CLI bulunamadı (PATH'te değil)."
        case .authFailed(let s):    return "Salesforce auth alınamadı: \(s)"
        case .httpError(let c, let s): return "Salesforce HTTP \(c): \(s)"
        case .parseFailed(let s):   return "Salesforce yanıtı çözümlenemedi: \(s)"
        case .createFailed(let s):  return "Salesforce kaydı oluşturulamadı: \(s)"
        }
    }
}

/// REST API üzerinden Salesforce ile konuşur. Auth token'ı `sf` CLI'dan alır
/// (subprocess), sonra direkt `URLSession` ile query/insert yapar.
/// Token cache 50 dakika tutulur — sf CLI 2 saatlik refresh token'ı arka planda
/// yeniler, biz expire'a yaklaşmadan refresh ederiz.
actor SalesforceService {
    static let shared = SalesforceService()

    private let alias = "agora"
    private let apiVersion = "v60.0"
    private let cacheTTL: TimeInterval = 50 * 60   // 50 dk

    private struct Auth {
        let accessToken: String
        let instanceUrl: String
        let userId: String
        let username: String
        let fetchedAt: Date
    }

    private var cachedAuth: Auth?

    private let sfBinaryURL: URL? = {
        let candidates = [
            "/opt/homebrew/bin/sf",
            "/usr/local/bin/sf",
            "/usr/bin/sf"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }()

    // MARK: - Public API

    /// Tek seferde 4 paralel SOQL query'siyle bir prospect'in dedup durumunu çıkarır.
    func dedupCheck(domain: String, email: String) async throws -> DedupResult {
        let dom = domain.lowercased().trimmingCharacters(in: .whitespaces)
        let emailLc = email.lowercased().trimmingCharacters(in: .whitespaces)
        let websiteLike = Self.escapeSOQL("%\(dom)%")
        let emailLike   = Self.escapeSOQL("%@\(dom)")
        let exactEmail  = Self.escapeSOQL(emailLc)

        let wonOppQ = """
        SELECT Id, Name, AccountId, Account.Name, StageName, CloseDate \
        FROM Opportunity \
        WHERE Account.Website LIKE '\(websiteLike)' AND IsWon = true \
        ORDER BY CloseDate DESC LIMIT 3
        """
        let openOppQ = """
        SELECT Id, Name, AccountId, Account.Name, StageName, OwnerId, Owner.Name \
        FROM Opportunity \
        WHERE Account.Website LIKE '\(websiteLike)' AND IsClosed = false \
        ORDER BY CreatedDate DESC LIMIT 3
        """
        let closedLostQ = """
        SELECT Id, Name, AccountId, Account.Name, StageName, CloseDate \
        FROM Opportunity \
        WHERE Account.Website LIKE '\(websiteLike)' AND IsClosed = true AND IsWon = false \
        ORDER BY CloseDate DESC LIMIT 3
        """
        let leadQ = """
        SELECT Id, FirstName, LastName, Email, Status, Company, OwnerId, Owner.Name \
        FROM Lead \
        WHERE Email = '\(exactEmail)' OR Email LIKE '\(emailLike)' \
        ORDER BY CreatedDate DESC LIMIT 10
        """

        async let wonOppRecords    = query(wonOppQ)
        async let openOppRecords   = query(openOppQ)
        async let closedLostRecords = query(closedLostQ)
        async let leadRecords       = query(leadQ)

        let won  = try await wonOppRecords
        let open = try await openOppRecords
        let lost = try await closedLostRecords
        let leads = try await leadRecords

        let now = Date()

        // 1. Open Opportunity → atla
        if let opp = open.first {
            return DedupResult(
                decision: .skippedOpenOpportunity,
                accountId: opp["AccountId"] as? String,
                accountName: (opp["Account"] as? [String: Any])?["Name"] as? String,
                opportunityId: opp["Id"] as? String,
                opportunityName: opp["Name"] as? String,
                opportunityStage: opp["StageName"] as? String,
                checkedAt: now
            )
        }

        // 2. Won Opp = aktif müşteri → atla
        if let opp = won.first {
            return DedupResult(
                decision: .skippedActiveAccount,
                accountId: opp["AccountId"] as? String,
                accountName: (opp["Account"] as? [String: Any])?["Name"] as? String,
                opportunityId: opp["Id"] as? String,
                opportunityName: opp["Name"] as? String,
                opportunityStage: opp["StageName"] as? String,
                opportunityCloseDate: opp["CloseDate"] as? String,
                checkedAt: now
            )
        }

        // 3. Closed Lost → winBack
        if let opp = lost.first {
            return DedupResult(
                decision: .closedLost,
                accountId: opp["AccountId"] as? String,
                accountName: (opp["Account"] as? [String: Any])?["Name"] as? String,
                opportunityId: opp["Id"] as? String,
                opportunityName: opp["Name"] as? String,
                opportunityStage: opp["StageName"] as? String,
                opportunityCloseDate: opp["CloseDate"] as? String,
                checkedAt: now
            )
        }

        // 4. Open Lead (DQ olmayan) → openLeadOtherRep
        let openLead = leads.first { l in
            let s = (l["Status"] as? String ?? "").lowercased()
            return !s.contains("disqualif")
                && !s.contains("junk")
                && !s.contains("converted")
                && !s.contains("unqualified")
        }
        if let l = openLead {
            return DedupResult(
                decision: .openLeadOtherRep,
                leadId: l["Id"] as? String,
                leadOwner: (l["Owner"] as? [String: Any])?["Name"] as? String,
                leadStatus: l["Status"] as? String,
                checkedAt: now
            )
        }

        // 5. DQ Lead → disqualifiedLead
        let dqLead = leads.first { l in
            let s = (l["Status"] as? String ?? "").lowercased()
            return s.contains("disqualif") || s.contains("junk") || s.contains("unqualified")
        }
        if let l = dqLead {
            return DedupResult(
                decision: .disqualifiedLead,
                leadId: l["Id"] as? String,
                leadOwner: (l["Owner"] as? [String: Any])?["Name"] as? String,
                leadStatus: l["Status"] as? String,
                disqualifyReason: l["Status"] as? String,
                checkedAt: now
            )
        }

        // 6. Hiçbir kayıt yok
        return DedupResult(decision: .freshNoRecord, checkedAt: now)
    }

    /// Lead INSERT — minimum gerekli field'larla başlar; FLS ya da validation rule
    /// hatasında kullanıcıya net hata mesajıyla döner.
    /// Geri dönüş: (LeadId, Lightning UI URL)
    func createLead(_ p: Prospect) async throws -> (id: String, url: String) {
        var fields: [String: Any] = [
            "FirstName": p.contact.firstName,
            "LastName":  p.contact.lastName.isEmpty ? "(Unknown)" : p.contact.lastName,
            "Company":   p.companyName,
            "Email":     p.contact.email,
            "LeadSource": "Outbound — AI SDR",
            "Description": "Auto-imported by OutlookAgent (\(p.sourceTag)). " +
                          "ICP score: \(scoreText(p.score)). " +
                          (p.dedup.flatMap { "Dedup: \($0.decision.label)." } ?? "")
        ]
        if !p.contact.title.isEmpty       { fields["Title"]    = p.contact.title }
        if let w = p.website, !w.isEmpty  { fields["Website"]  = w }
        if let c = p.country, !c.isEmpty  { fields["Country"]  = c }
        if let i = p.industry, !i.isEmpty { fields["Industry"] = i }
        if let phone = p.contact.phone, !phone.isEmpty { fields["Phone"] = phone }

        let id = try await createRecord(object: "Lead", fields: fields)
        let auth = try await getAuth()
        let url = "\(auth.instanceUrl)/lightning/r/Lead/\(id)/view"
        return (id, url)
    }

    /// Domain bazında Account / Lead'den Crunchbase + Agora-spesifik enrichment
    /// alanlarını çeker. Account yoksa Lead'den bakar, hiçbir yerde yoksa nil.
    /// Çıktı: insan-okur key→value dictionary (prompt'a doğrudan injekte için).
    func enrichAccount(domain: String) async throws -> [String: String]? {
        let websiteLike = Self.escapeSOQL("%\(domain.lowercased())%")
        let emailLike   = Self.escapeSOQL("%@\(domain.lowercased())")

        // Account üzerindeki Crunchbase + Agora field'ları.
        let accSoql = """
        SELECT Id, Name, Website, Industry, NumberOfEmployees, Type, \
        crunchbase__Latest_Round_Funding_Type__c, crunchbase__Number_of_Employees_Crunchbase__c, \
        crunchbase__Revenue_Range_USD__c, crunchbase__Unicorn_Status__c, \
        crunchbase__Probability_Tier__c, crunchbase__Last_Funding_At__c, \
        crunchbase__Total_Funding_USD__c, \
        Already_using_an_Agora_SDK__c, Competitor_RTC_SDK_Providers_Involved__c, \
        Use_Case__c, Vertical__c, Region__c, MAU__c, Estimated_DAU__c \
        FROM Account WHERE Website LIKE '\(websiteLike)' LIMIT 1
        """
        let leadSoql = """
        SELECT Id, FirstName, LastName, Title, Email, Company, LeadSource, Status, \
        crunchbase__Latest_Round_Funding_Type__c, crunchbase__Number_of_Employees_Crunchbase__c, \
        Already_using_an_Agora_SDK__c, Use_Case__c, Vertical__c \
        FROM Lead WHERE Email LIKE '\(emailLike)' LIMIT 1
        """

        // İlk Account, varsa onu döndür.
        do {
            let accs = try await query(accSoql)
            if let acc = accs.first {
                return Self.formatEnrichment(record: acc, source: "Account")
            }
        } catch {
            // Field-level security bazı org'larda eksik field'ları reddedebilir;
            // o durumda sessizce Lead'e düş.
        }
        do {
            let leads = try await query(leadSoql)
            if let l = leads.first {
                return Self.formatEnrichment(record: l, source: "Lead")
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func formatEnrichment(record: [String: Any], source: String) -> [String: String] {
        var out: [String: String] = ["source": source]

        let interesting: [(String, String)] = [
            ("Vertical__c",                                       "Vertical (SF)"),
            ("Use_Case__c",                                       "Use Case (SF)"),
            ("Region__c",                                         "Region (SF)"),
            ("Industry",                                          "Industry"),
            ("Type",                                              "Account Type"),
            ("Status",                                            "Lead Status"),
            ("crunchbase__Latest_Round_Funding_Type__c",          "Last Funding Round"),
            ("crunchbase__Last_Funding_At__c",                    "Last Funding Date"),
            ("crunchbase__Total_Funding_USD__c",                  "Total Funding USD"),
            ("crunchbase__Revenue_Range_USD__c",                  "Revenue Range USD"),
            ("crunchbase__Number_of_Employees_Crunchbase__c",     "Employees (Crunchbase)"),
            ("crunchbase__Unicorn_Status__c",                     "Unicorn Status"),
            ("crunchbase__Probability_Tier__c",                   "Probability Tier"),
            ("Already_using_an_Agora_SDK__c",                     "Already using Agora SDK?"),
            ("Competitor_RTC_SDK_Providers_Involved__c",          "Competitor RTC SDK"),
            ("MAU__c",                                            "MAU"),
            ("Estimated_DAU__c",                                  "DAU (estimate)"),
            ("NumberOfEmployees",                                 "Employees"),
            ("Title",                                             "Lead Title"),
            ("LeadSource",                                        "Lead Source")
        ]
        for (key, label) in interesting {
            if let v = record[key] as? String, !v.isEmpty {
                out[label] = v
            } else if let v = record[key] as? Bool {
                out[label] = v ? "evet" : "hayır"
            } else if let v = record[key] as? Double {
                out[label] = String(Int(v))
            } else if let v = record[key] as? Int {
                out[label] = String(v)
            }
        }
        return out
    }

    /// Sequence step gönderildikten sonra Lead'e Activity (Task) ekler.
    func logTask(prospectLeadId: String,
                 subject: String,
                 description: String,
                 channel: SequenceChannel) async throws -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        let today = f.string(from: Date())

        let typeStr: String = {
            switch channel {
            case .email:            return "Email"
            case .linkedinConnect:  return "LinkedIn — Connect"
            case .linkedinMessage:  return "LinkedIn — Message"
            case .linkedinInMail:   return "LinkedIn — InMail"
            }
        }()

        let fields: [String: Any] = [
            "Subject":      "[OutlookAgent] \(typeStr): \(subject)",
            "WhoId":        prospectLeadId,
            "Status":       "Completed",
            "ActivityDate": today,
            "Description":  description
        ]
        return try await createRecord(object: "Task", fields: fields)
    }

    // MARK: - Lower-level

    /// Run a SOQL SELECT and return the records as an array of dictionaries.
    func query(_ soql: String) async throws -> [[String: Any]] {
        let auth = try await getAuth()
        var comps = URLComponents(string: "\(auth.instanceUrl)/services/data/\(apiVersion)/query")!
        comps.queryItems = [URLQueryItem(name: "q", value: soql)]
        guard let url = comps.url else {
            throw SalesforceError.parseFailed("URL kurulamadı")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let startTime = Date()
        let soqlPreview = String(soql.replacingOccurrences(of: "\n", with: " ").prefix(180))
        AppLogger.bg(.debug, .salesforce, "SOQL query başlatılıyor", [
            "soqlHead": .string(soqlPreview)
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

        if http?.statusCode == 401 {
            AppLogger.bg(.warn, .salesforce, "SOQL 401 — token refresh", [
                "elapsedMs": .int(elapsedMs)
            ])
            _ = try await getAuth(forceRefresh: true)
            return try await query(soql)
        }
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            AppLogger.bg(.error, .salesforce, "SOQL HTTP hata", [
                "status":    .int(http?.statusCode ?? -1),
                "elapsedMs": .int(elapsedMs),
                "bodyHead":  .string(String(msg.prefix(240)))
            ])
            throw SalesforceError.httpError(http?.statusCode ?? -1, msg)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = obj["records"] as? [[String: Any]] else {
            AppLogger.bg(.error, .salesforce, "SOQL parse fail", [
                "elapsedMs": .int(elapsedMs)
            ])
            throw SalesforceError.parseFailed("records alanı yok")
        }
        AppLogger.bg(.info, .salesforce, "SOQL başarılı", [
            "elapsedMs":   .int(elapsedMs),
            "recordCount": .int(records.count),
            "totalSize":   .int(obj["totalSize"] as? Int ?? records.count)
        ])
        return records
    }

    /// Generic REST POST to /services/data/<v>/sobjects/<Object>/.
    /// Returns the new record's Id.
    func createRecord(object: String, fields: [String: Any]) async throws -> String {
        let auth = try await getAuth()
        let url = URL(string: "\(auth.instanceUrl)/services/data/\(apiVersion)/sobjects/\(object)/")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: fields)

        let startTime = Date()
        AppLogger.bg(.info, .salesforce, "createRecord başlatılıyor", [
            "object":     .string(object),
            "fieldCount": .int(fields.count)
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

        if http?.statusCode == 401 {
            AppLogger.bg(.warn, .salesforce, "createRecord 401 — token refresh", [
                "object": .string(object), "elapsedMs": .int(elapsedMs)
            ])
            _ = try await getAuth(forceRefresh: true)
            return try await createRecord(object: object, fields: fields)
        }
        guard let code = http?.statusCode else {
            AppLogger.bg(.error, .salesforce, "createRecord HTTP response yok",
                         ["object": .string(object)])
            throw SalesforceError.parseFailed("HTTP response yok")
        }
        if code == 201 {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String else {
                AppLogger.bg(.error, .salesforce, "createRecord response id eksik",
                             ["object": .string(object), "elapsedMs": .int(elapsedMs)])
                throw SalesforceError.parseFailed("create response: id yok")
            }
            AppLogger.bg(.info, .salesforce, "createRecord başarılı", [
                "object":    .string(object),
                "id":        .string(id),
                "elapsedMs": .int(elapsedMs)
            ])
            return id
        } else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            AppLogger.bg(.error, .salesforce, "createRecord HTTP hata", [
                "object":    .string(object),
                "status":    .int(code),
                "elapsedMs": .int(elapsedMs),
                "bodyHead":  .string(String(body.prefix(360)))
            ])
            throw SalesforceError.createFailed("\(object) HTTP \(code): \(body)")
        }
    }

    // MARK: - Auth

    private func getAuth(forceRefresh: Bool = false) async throws -> Auth {
        if !forceRefresh,
           let a = cachedAuth,
           Date().timeIntervalSince(a.fetchedAt) < cacheTTL {
            return a
        }
        guard let bin = sfBinaryURL else { throw SalesforceError.binaryMissing }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["org", "display", "user", "--target-org", alias, "--json"]
        proc.currentDirectoryURL = Self.cacheWorkingDir
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        if proc.terminationStatus != 0 {
            let m = String(data: errData, encoding: .utf8) ?? "?"
            throw SalesforceError.authFailed(m)
        }
        guard let obj = try JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let token = result["accessToken"] as? String,
              let instance = result["instanceUrl"] as? String else {
            throw SalesforceError.authFailed("sf org display user JSON parse hatası")
        }
        let userId = (result["id"] as? String) ?? ""
        let username = (result["username"] as? String) ?? ""
        let auth = Auth(
            accessToken: token,
            instanceUrl: instance.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            userId: userId,
            username: username,
            fetchedAt: Date()
        )
        cachedAuth = auth
        return auth
    }

    // MARK: - Helpers

    private static let cacheWorkingDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private nonisolated static func escapeSOQL(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'",  with: "\\'")
    }

    private nonisolated func scoreText(_ s: ProspectScore?) -> String {
        guard let s = s else { return "—" }
        return String(format: "ICP %.0f%% / Revenue %.0f%%",
                      s.icpFit * 100, s.revenueFit * 100)
    }
}
