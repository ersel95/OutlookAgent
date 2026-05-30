import Foundation

enum AppStoreDiscoveryError: LocalizedError {
    case httpError(Int, String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let c, let s): return "App Store HTTP \(c): \(s)"
        case .parseFailed(let s):      return "App Store yanıtı çözümlenemedi: \(s)"
        }
    }
}

/// iTunes Lookup API — Apple'ın public, no-auth endpoint'i.
/// Apptopia'nın yaptığı SDK detection'ı yapamaz ama mobile-first şirketleri
/// (live-commerce, social, faith tech) bulmak için bedava ve hızlı bir kanal.
actor AppStoreDiscoveryService {
    static let shared = AppStoreDiscoveryService()

    private let baseURL = "https://itunes.apple.com/search"
    private let apiVersion = "v1"

    /// `query` örnekler: "live commerce", "live shopping", "social audio",
    /// "video call", "live streaming", "tarot canlı yayın", vb.
    /// `country` ISO 3166-1 alpha-2 (lowercase) — TR pazarı için "tr".
    /// `limit` max 200 (Apple kısıtı).
    func search(query: String, country: String = "tr", limit: Int = 25) async throws -> [Prospect] {
        var comps = URLComponents(string: baseURL)!
        comps.queryItems = [
            URLQueryItem(name: "term",    value: query),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "media",   value: "software"),
            URLQueryItem(name: "entity",  value: "software,iPadSoftware"),
            URLQueryItem(name: "limit",   value: String(min(limit, 200)))
        ]
        guard let url = comps.url else {
            throw AppStoreDiscoveryError.parseFailed("URL kurulamadı")
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            throw AppStoreDiscoveryError.httpError(http?.statusCode ?? -1, msg)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            throw AppStoreDiscoveryError.parseFailed("results alanı yok")
        }

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        let safeQuery = query.lowercased().replacingOccurrences(of: " ", with: "-")
        let tag = "appstore-\(country.lowercased())-\(safeQuery)-\(f.string(from: Date()))"

        // Geliştirici şirketi başına dedup — aynı şirketin 5 app'i varsa tek prospect olsun.
        var seen = Set<String>()
        var out: [Prospect] = []

        for item in results {
            guard let sellerName = item["sellerName"] as? String, !sellerName.isEmpty else { continue }
            guard let domain = Self.extractDomain(from: item) else { continue }
            let key = domain.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)

            let appName    = (item["trackName"] as? String) ?? ""
            let bundleId   = (item["bundleId"] as? String) ?? ""
            let appUrl     = (item["trackViewUrl"] as? String) ?? ""
            let primaryGenre = (item["primaryGenreName"] as? String) ?? ""
            let appDesc    = (item["description"] as? String) ?? ""
            let releaseDate = (item["releaseDate"] as? String) ?? ""
            let version    = (item["version"] as? String) ?? ""
            let userCount  = item["userRatingCount"] as? Int ?? 0
            let rating     = item["averageUserRating"] as? Double ?? 0

            let descShort = String(appDesc.prefix(280))
            let notes = """
            App Store keşfi (\(country.uppercased()) market):
            • App: \(appName) (\(bundleId)) — \(primaryGenre)
            • Version \(version) — release: \(releaseDate)
            • \(userCount) rating, ortalama \(String(format: "%.1f", rating))
            • App URL: \(appUrl)
            """

            let p = Prospect(
                companyName: sellerName,
                domain: domain.lowercased(),
                website: (item["sellerUrl"] as? String) ?? "https://\(domain)",
                country: country.uppercased() == "TR" ? "Türkiye" : country.uppercased(),
                industry: Self.mapGenreToVertical(primaryGenre),
                employeeRange: nil,
                fundingStage: nil,
                lastFundingDate: nil,
                lastFundingAmount: nil,
                crunchbaseUrl: nil,
                description: descShort,
                contact: ProspectContact(
                    firstName: "", lastName: "", title: "", email: "",
                    linkedinUrl: nil, phone: nil
                ),
                sourceTag: tag,
                notes: notes
            )
            out.append(p)
        }
        return out
    }

    /// `sellerUrl` varsa o domain. Yoksa `bundleId`'den ters çevir
    /// (com.acme.app → acme.com — bunu `acme.com` heuristic olarak çıkarır).
    private static func extractDomain(from item: [String: Any]) -> String? {
        if let urlStr = item["sellerUrl"] as? String,
           let url = URL(string: urlStr),
           let host = url.host?.lowercased() {
            // www. prefix temizle
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        // Fallback: bundleId reversal
        if let bundleId = item["bundleId"] as? String, !bundleId.isEmpty {
            let parts = bundleId.lowercased().split(separator: ".")
            if parts.count >= 2 {
                // ["com","acme","app"] → "acme.com"
                let tld = parts[0]
                let main = parts[1]
                return "\(main).\(tld)"
            }
        }
        return nil
    }

    /// App Store genre → Agora-relevant vertical mapping.
    private static func mapGenreToVertical(_ genre: String) -> String? {
        let g = genre.lowercased()
        switch g {
        case let s where s.contains("social"):           return "Social"
        case let s where s.contains("shopping"),
             let s where s.contains("commerce"):         return "Live-Commerce"
        case let s where s.contains("education"):        return "EdTech"
        case let s where s.contains("medical"),
             let s where s.contains("health"):           return "Healthcare"
        case let s where s.contains("entertainment"),
             let s where s.contains("video"):            return "Media & Entertainment"
        case let s where s.contains("game"):             return "Gaming"
        case let s where s.contains("business"),
             let s where s.contains("productiv"):        return "Future of Work"
        case let s where s.contains("lifestyle"):        return "Lifestyle"
        default:                                          return genre.isEmpty ? nil : genre
        }
    }
}
