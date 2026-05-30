import Foundation
import SwiftUI
import Observation

/// Domain bazlı email pattern öğrenme cache'i.
/// "trendyol.com → {first}.{last} işe yaradı (3 başarılı, 0 bounce)" gibi bilgiyi
/// kalıcı tutar. Her bounce/replied event'i cache'i günceller; bir sonraki prospect
/// aynı domain'e ait olduğunda direkt öğrenilmiş pattern kullanılır.
@MainActor
@Observable
final class EmailPatternCache {
    /// Pattern template'ler — `{first}` ve `{last}` ASCII-normalize ad/soyad ile değişir.
    nonisolated static let candidateTemplates: [String] = [
        "{first}.{last}",         // ahmet.yilmaz   — TR'de en yaygın (~%45)
        "{first}",                // ahmet
        "{first}{last}",          // ahmetyilmaz
        "{firstinitial}{last}",   // ayilmaz
        "{first}_{last}",         // ahmet_yilmaz
        "{first}-{last}",         // ahmet-yilmaz
        "{firstinitial}.{last}",  // a.yilmaz
        "{first}.{lastinitial}",  // ahmet.y
        "{last}.{first}",         // yilmaz.ahmet
        "{last}{firstinitial}"    // yilmaza
    ]

    enum Confidence: String, Codable {
        case verified         // reply geldi — pattern kesin doğru
        case noBounce         // 24+ saat bounce yok — muhtemelen doğru
        case guessed          // henüz denenmedi
        case failed           // hard bounce geldi
    }

    struct PatternRecord: Codable, Hashable {
        var template: String
        var confidence: Confidence
        var lastUpdated: Date
        var workingSamples: [String]    // bounce yapmadığı bilinen email'ler
        var failedSamples: [String]     // hard bounce yapan email'ler
    }

    /// Domain → şu ana kadar denenmiş pattern'ler (birden fazla olabilir).
    private(set) var entries: [String: [PatternRecord]] = [:]

    private let fileURL: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("email_patterns.json")
    }()

    init() {
        loadFromDisk()
    }

    // MARK: - Lookup

    /// En iyi pattern: önce verified, sonra noBounce, sonra guessed.
    /// Failed pattern'leri ASLA döndürme.
    func bestPattern(for domain: String) -> PatternRecord? {
        let key = domain.lowercased()
        let recs = entries[key] ?? []
        // failed olmayanları priority'ye göre sırala
        return recs
            .filter { $0.confidence != .failed }
            .min { lhs, rhs in
                let order: [Confidence: Int] = [.verified: 0, .noBounce: 1, .guessed: 2, .failed: 99]
                return (order[lhs.confidence] ?? 50) < (order[rhs.confidence] ?? 50)
            }
    }

    /// Bu domain için failed olarak işaretlenmiş template'ler (Claude'a "bunları deneme" diye geçilir).
    func failedTemplates(for domain: String) -> [String] {
        let key = domain.lowercased()
        return (entries[key] ?? [])
            .filter { $0.confidence == .failed }
            .map { $0.template }
    }

    // MARK: - Mutations

    /// Bir prospect'e atanan pattern (henüz denenmemiş) — guessed olarak kaydet.
    func recordGuess(domain: String, template: String, sample: String) {
        let key = domain.lowercased()
        var recs = entries[key] ?? []
        if let idx = recs.firstIndex(where: { $0.template == template }) {
            // Mevcut kaydı override etme; sadece sample ekle.
            if !recs[idx].workingSamples.contains(sample),
               !recs[idx].failedSamples.contains(sample) {
                recs[idx].workingSamples.append(sample)
                recs[idx].lastUpdated = Date()
            }
        } else {
            recs.append(PatternRecord(
                template: template,
                confidence: .guessed,
                lastUpdated: Date(),
                workingSamples: [sample],
                failedSamples: []
            ))
        }
        entries[key] = recs
        persist()
    }

    /// Hard bounce geldi → bu pattern'i failed işaretle.
    func recordFailure(domain: String, template: String, sample: String) {
        let key = domain.lowercased()
        var recs = entries[key] ?? []
        if let idx = recs.firstIndex(where: { $0.template == template }) {
            recs[idx].confidence = .failed
            recs[idx].lastUpdated = Date()
            if !recs[idx].failedSamples.contains(sample) {
                recs[idx].failedSamples.append(sample)
            }
            recs[idx].workingSamples.removeAll { $0 == sample }
        } else {
            recs.append(PatternRecord(
                template: template,
                confidence: .failed,
                lastUpdated: Date(),
                workingSamples: [],
                failedSamples: [sample]
            ))
        }
        entries[key] = recs
        persist()
    }

    /// 24+ saat bounce yok → pattern muhtemelen doğru. (Cron-tabanlı promote V2.)
    func promoteToNoBounce(domain: String, template: String) {
        let key = domain.lowercased()
        guard var recs = entries[key],
              let idx = recs.firstIndex(where: { $0.template == template }) else { return }
        if recs[idx].confidence == .guessed {
            recs[idx].confidence = .noBounce
            recs[idx].lastUpdated = Date()
            entries[key] = recs
            persist()
        }
    }

    /// Reply geldi → pattern kesin doğru.
    func promoteToVerified(domain: String, template: String, sample: String) {
        let key = domain.lowercased()
        var recs = entries[key] ?? []
        if let idx = recs.firstIndex(where: { $0.template == template }) {
            recs[idx].confidence = .verified
            recs[idx].lastUpdated = Date()
            if !recs[idx].workingSamples.contains(sample) {
                recs[idx].workingSamples.append(sample)
            }
            entries[key] = recs
        } else {
            recs.append(PatternRecord(
                template: template,
                confidence: .verified,
                lastUpdated: Date(),
                workingSamples: [sample],
                failedSamples: []
            ))
            entries[key] = recs
        }
        persist()
    }

    // MARK: - Apply (template → email)

    /// Template'i (örn `{first}.{last}`) gerçek isim ve domain'e uygula.
    /// TR karakterleri ASCII'ye normalize eder (ş→s, ı→i, ç→c, ü→u, ö→o, ğ→g).
    /// Pure helper — actor isolation gerekmez.
    nonisolated static func apply(template: String, firstName: String, lastName: String, domain: String) -> String? {
        let f = firstName.asciiSlug
        let l = lastName.asciiSlug
        guard !f.isEmpty else { return nil }
        let fi = String(f.prefix(1))
        let li = l.isEmpty ? "" : String(l.prefix(1))
        let local = template
            .replacingOccurrences(of: "{first}",         with: f)
            .replacingOccurrences(of: "{last}",          with: l)
            .replacingOccurrences(of: "{firstinitial}",  with: fi)
            .replacingOccurrences(of: "{lastinitial}",   with: li)
        return "\(local)@\(domain.lowercased())"
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = entries
        let url = fileURL
        Task.detached(priority: .background) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([String: [PatternRecord]].self, from: data) {
            entries = decoded
        }
    }
}

// MARK: - String ASCII slug helper

extension String {
    /// Türkçe + diğer Latin diakritiklerini ASCII'ye dönüştürür (lowercase + alfanumerik dışı temizlenir).
    /// "Ahmet Şahin" → "ahmetsahin", "Çağrı İğneci" → "cagriigneci".
    var asciiSlug: String {
        var s = self.lowercased()
        let trMap: [Character: Character] = [
            "ş":"s","ı":"i","İ":"i","ç":"c","ü":"u","ö":"o","ğ":"g"
        ]
        var rebuilt = ""
        for ch in s {
            rebuilt.append(trMap[ch] ?? ch)
        }
        s = rebuilt
        // Diacritic strip (e.g. é, ñ, ä → e, n, a)
        s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        // Sadece a-z 0-9 -
        s = s.unicodeScalars.compactMap { sc -> String? in
            let v = sc.value
            if (v >= 0x30 && v <= 0x39) || (v >= 0x61 && v <= 0x7A) || sc == "-" {
                return String(sc)
            }
            return nil
        }.joined()
        return s
    }
}
