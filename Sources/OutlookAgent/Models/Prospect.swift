import Foundation
import SwiftUI

// MARK: - Pipeline state

enum ProspectStatus: String, Codable, CaseIterable, Identifiable {
    case discovered      // CSV / manual ingest, dedup pending
    case matched         // SF dedup tamam, kuyruğa atandı
    case excluded        // SF tarafından atla kararı (active account / open opp)
    case scored          // ICP + revenue skoru hesaplandı
    case drafted         // sequence taslakları hazır, onay bekliyor
    case approved        // Ersel onayladı, ilk send'e hazır
    case sending         // sequence aktif, ortada bir step gönderildi
    case completed       // tüm sequence step'leri sent/skipped
    case replied         // reply detect edildi (V1)
    case paused          // OOO / unsubscribe / manuel pause (V1)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .discovered: return "Keşfedildi"
        case .matched:    return "Eşleşti"
        case .excluded:   return "Atlandı"
        case .scored:     return "Skorlandı"
        case .drafted:    return "Taslak Hazır"
        case .approved:   return "Onaylandı"
        case .sending:    return "Gönderiliyor"
        case .completed:  return "Tamamlandı"
        case .replied:    return "Cevap Geldi"
        case .paused:     return "Duraklatıldı"
        }
    }

    var systemImage: String {
        switch self {
        case .discovered: return "circle.dashed"
        case .matched:    return "link.circle"
        case .excluded:   return "xmark.octagon"
        case .scored:     return "chart.bar.xaxis"
        case .drafted:    return "doc.text"
        case .approved:   return "checkmark.circle"
        case .sending:    return "paperplane"
        case .completed:  return "checkmark.seal.fill"
        case .replied:    return "bubble.left.fill"
        case .paused:     return "pause.circle"
        }
    }

    var color: Color {
        switch self {
        case .discovered: return .secondary
        case .matched:    return .blue
        case .excluded:   return Color(white: 0.55)
        case .scored:     return .indigo
        case .drafted:    return .purple
        case .approved:   return .teal
        case .sending:    return .orange
        case .completed:  return .green
        case .replied:    return .mint
        case .paused:     return .yellow
        }
    }

    var sortOrder: Int {
        switch self {
        case .replied:    return 0
        case .sending:    return 1
        case .approved:   return 2
        case .drafted:    return 3
        case .scored:     return 4
        case .paused:     return 5
        case .matched:    return 6
        case .discovered: return 7
        case .completed:  return 8
        case .excluded:   return 9
        }
    }
}

// "main" — taze prospect / DQ Lead / Open Lead başka rep'te.
// "winBack" — Closed Lost Opportunity'si var, farklı angle ile gidilir.
enum ProspectQueue: String, Codable, CaseIterable, Identifiable {
    case main, winBack

    var id: String { rawValue }
    var label: String {
        switch self {
        case .main:    return "Ana Kuyruk"
        case .winBack: return "Win-Back"
        }
    }
    var color: Color { self == .winBack ? .orange : .blue }
}

// MARK: - Salesforce dedup

enum DedupDecision: String, Codable {
    case freshNoRecord            // hiç Account/Lead/Opp yok → main
    case disqualifiedLead         // DQ Lead var → main, eski sebebi prompt'a aktar
    case closedLost               // Closed Lost Opp var → winBack
    case openLeadOtherRep         // Open Lead başka rep'te → main (paralel)
    case skippedActiveAccount     // mevcut müşteri → atla
    case skippedOpenOpportunity   // Open Opp var → atla

    var label: String {
        switch self {
        case .freshNoRecord:           return "Yeni"
        case .disqualifiedLead:        return "DQ Lead (yeniden)"
        case .closedLost:              return "Win-Back adayı"
        case .openLeadOtherRep:        return "Açık Lead (paralel)"
        case .skippedActiveAccount:    return "Aktif Müşteri (atla)"
        case .skippedOpenOpportunity:  return "Açık Fırsat (atla)"
        }
    }

    var shouldSequence: Bool {
        switch self {
        case .freshNoRecord, .disqualifiedLead, .closedLost, .openLeadOtherRep:
            return true
        case .skippedActiveAccount, .skippedOpenOpportunity:
            return false
        }
    }

    var queue: ProspectQueue {
        self == .closedLost ? .winBack : .main
    }
}

struct DedupResult: Codable, Hashable {
    var decision: DedupDecision
    // Eşleşen SF kayıtları (bilgilendirme amaçlı)
    var accountId: String?
    var accountName: String?
    var leadId: String?
    var leadOwner: String?
    var leadStatus: String?
    var disqualifyReason: String?      // Lead status DQ ise eski rep'in sebebi (varsa)
    var opportunityId: String?
    var opportunityName: String?
    var opportunityStage: String?
    var opportunityCloseDate: String?
    var checkedAt: Date
}

// MARK: - AI scoring

struct ProspectScore: Codable, Hashable {
    var icpFit: Double          // 0.0–1.0 — kazanma kolaylığı (vertical, funding stage, geography fit)
    var revenueFit: Double      // 0.0–1.0 — deal size potansiyeli ($50K–$200K bandı sweet spot)
    var rationale: String       // 1-2 cümle Türkçe gerekçe
    var matchedSignals: [String] // ["Social vertical", "Series A", "Twilio kullanıyor"], vb.
    var concerns: [String]      // ["Series B (anti-pattern)", "France HQ"]
    var scoredAt: Date

    /// 0–5 yıldız görseli için.
    var stars: Int {
        let total = (icpFit + revenueFit) / 2
        return max(0, min(5, Int((total * 5).rounded())))
    }

    /// Combined score (default eşit ağırlık).
    var combined: Double {
        (icpFit + revenueFit) / 2
    }
}

// MARK: - Sequence

enum SequenceChannel: String, Codable, CaseIterable, Identifiable {
    case email
    case linkedinConnect       // bağlantı isteği (300 char limit, kısa)
    case linkedinMessage       // bağlandıktan sonra DM
    case linkedinInMail        // Sales Nav InMail (300 char subject + 1900 char body)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .email:            return "Email"
        case .linkedinConnect:  return "LinkedIn Bağlantı"
        case .linkedinMessage:  return "LinkedIn Mesaj"
        case .linkedinInMail:   return "Sales Nav InMail"
        }
    }

    var isAutoSend: Bool {
        // Email otomatik atılır (ToS güvenli). LinkedIn manuel — ToS gereği.
        self == .email
    }

    var systemImage: String {
        switch self {
        case .email:            return "envelope"
        case .linkedinConnect:  return "person.crop.circle.badge.plus"
        case .linkedinMessage:  return "bubble.left"
        case .linkedinInMail:   return "tray.and.arrow.up"
        }
    }

    var color: Color {
        switch self {
        case .email:            return .blue
        case .linkedinConnect:  return Color(red: 0.0, green: 0.47, blue: 0.71)
        case .linkedinMessage:  return Color(red: 0.0, green: 0.55, blue: 0.85)
        case .linkedinInMail:   return Color(red: 0.05, green: 0.3, blue: 0.55)
        }
    }
}

enum SequenceStepStatus: String, Codable {
    case pending      // henüz draft yok (Claude'a gidecek)
    case drafted      // AI taslak yazdı
    case approved     // Ersel onayladı
    case sent         // email auto-sent ya da LinkedIn metni clipboard'a kopyalandı
    case skipped      // kullanıcı atla dedi
    case failed       // send hatası
    case repliedTo    // V1: reply geldi, sequence pause (bu step üzerinde)

    var label: String {
        switch self {
        case .pending:    return "Bekliyor"
        case .drafted:    return "Taslak"
        case .approved:   return "Onaylı"
        case .sent:       return "Gönderildi"
        case .skipped:    return "Atlandı"
        case .failed:     return "Başarısız"
        case .repliedTo:  return "Cevap Geldi"
        }
    }

    var color: Color {
        switch self {
        case .pending:    return .secondary
        case .drafted:    return .purple
        case .approved:   return .teal
        case .sent:       return .green
        case .skipped:    return Color(white: 0.55)
        case .failed:     return .red
        case .repliedTo:  return .mint
        }
    }
}

struct SequenceStep: Identifiable, Codable, Hashable {
    var id: UUID
    var index: Int                 // 0-based sıra
    var dayOffset: Int             // 0 = ilk temas günü
    var channel: SequenceChannel

    // İçerik
    var subject: String?           // sadece email & inMail
    var body: String               // email gövdesi ya da LinkedIn metni
    var rationale: String?         // AI'ın bu step'i seçme nedeni

    var status: SequenceStepStatus
    var sentAt: Date?
    var scheduledFor: Date?        // approve sonrası hesaplanır
    var failureReason: String?

    // V1 — reply detection
    var replyDetectedAt: Date?
    var replySummary: String?

    // Outlook ile bağlantı (email atıldıktan sonra geri linkleyebilmek için)
    var outlookMessageId: String?

    init(id: UUID = UUID(),
         index: Int,
         dayOffset: Int,
         channel: SequenceChannel,
         subject: String? = nil,
         body: String = "",
         rationale: String? = nil,
         status: SequenceStepStatus = .pending,
         sentAt: Date? = nil,
         scheduledFor: Date? = nil,
         failureReason: String? = nil,
         replyDetectedAt: Date? = nil,
         replySummary: String? = nil,
         outlookMessageId: String? = nil) {
        self.id = id
        self.index = index
        self.dayOffset = dayOffset
        self.channel = channel
        self.subject = subject
        self.body = body
        self.rationale = rationale
        self.status = status
        self.sentAt = sentAt
        self.scheduledFor = scheduledFor
        self.failureReason = failureReason
        self.replyDetectedAt = replyDetectedAt
        self.replySummary = replySummary
        self.outlookMessageId = outlookMessageId
    }
}

// MARK: - Contact

struct ProspectContact: Codable, Hashable {
    var firstName: String
    var lastName: String
    var title: String
    var email: String
    var linkedinUrl: String?
    var phone: String?

    var fullName: String {
        let combined = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? email : combined
    }

    var displayLine: String {
        let n = fullName
        return title.isEmpty ? n : "\(n) — \(title)"
    }
}

// MARK: - Prospect

struct Prospect: Identifiable, Codable, Hashable {
    var id: UUID
    var status: ProspectStatus
    var queue: ProspectQueue

    // Şirket
    var companyName: String
    var domain: String                  // dedup'ın temel anahtarı (lowercased)
    var website: String?
    var country: String?
    var industry: String?               // Agora vertical (Social, FoW, Live-Commerce, vb.)
    var employeeRange: String?          // "11-50", "51-200", vb.
    var fundingStage: String?           // "Seed", "Series A", vb.
    var lastFundingDate: String?
    var lastFundingAmount: String?
    var crunchbaseUrl: String?
    var description: String?

    // Birincil kontak
    var contact: ProspectContact

    // Pipeline durumu
    var dedup: DedupResult?
    var score: ProspectScore?
    var sequenceSteps: [SequenceStep]
    var currentStepIndex: Int           // bir sonraki gönderilecek step'in index'i

    // Salesforce sync
    var salesforceLeadId: String?
    var salesforceLeadUrl: String?
    var salesforceTaskIds: [String]

    // Source / metadata
    var sourceTag: String               // "crunchbase-csv-2026-05-09", "manual", vb.
    var importedAt: Date
    var updatedAt: Date

    // Soft delete — dedup ingest aynı domain'i yeniden eklerken silinmiş kayıtları
    // atlar (kullanıcı zaten reddetmiş — gürültüye getirme).
    var deletedAt: Date?
    var deletionReason: String?

    // Notlar
    var notes: String
    var tags: [String]

    init(id: UUID = UUID(),
         status: ProspectStatus = .discovered,
         queue: ProspectQueue = .main,
         companyName: String,
         domain: String,
         website: String? = nil,
         country: String? = nil,
         industry: String? = nil,
         employeeRange: String? = nil,
         fundingStage: String? = nil,
         lastFundingDate: String? = nil,
         lastFundingAmount: String? = nil,
         crunchbaseUrl: String? = nil,
         description: String? = nil,
         contact: ProspectContact,
         dedup: DedupResult? = nil,
         score: ProspectScore? = nil,
         sequenceSteps: [SequenceStep] = [],
         currentStepIndex: Int = 0,
         salesforceLeadId: String? = nil,
         salesforceLeadUrl: String? = nil,
         salesforceTaskIds: [String] = [],
         sourceTag: String = "manual",
         importedAt: Date = Date(),
         updatedAt: Date = Date(),
         deletedAt: Date? = nil,
         deletionReason: String? = nil,
         notes: String = "",
         tags: [String] = []) {
        self.id = id
        self.status = status
        self.queue = queue
        self.companyName = companyName
        self.domain = domain.lowercased()
        self.website = website
        self.country = country
        self.industry = industry
        self.employeeRange = employeeRange
        self.fundingStage = fundingStage
        self.lastFundingDate = lastFundingDate
        self.lastFundingAmount = lastFundingAmount
        self.crunchbaseUrl = crunchbaseUrl
        self.description = description
        self.contact = contact
        self.dedup = dedup
        self.score = score
        self.sequenceSteps = sequenceSteps
        self.currentStepIndex = currentStepIndex
        self.salesforceLeadId = salesforceLeadId
        self.salesforceLeadUrl = salesforceLeadUrl
        self.salesforceTaskIds = salesforceTaskIds
        self.sourceTag = sourceTag
        self.importedAt = importedAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deletionReason = deletionReason
        self.notes = notes
        self.tags = tags
    }

    var isDeleted: Bool { deletedAt != nil }

    // Türkiye-first sıralama için ipucu (`country` boşsa domain TLD'sinden bakar).
    var isTurkey: Bool {
        let c = (country ?? "").lowercased()
        if c.contains("türkiye") || c == "tr" || c == "turkey" { return true }
        let d = domain.lowercased()
        return d.hasSuffix(".tr") || d.hasSuffix(".com.tr")
    }

    var nextStep: SequenceStep? {
        guard currentStepIndex < sequenceSteps.count else { return nil }
        return sequenceSteps[currentStepIndex]
    }

    var dedupeKey: String { domain.lowercased() }
}
