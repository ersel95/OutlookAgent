import Foundation
import SwiftUI

enum TriageCategory: String, Codable, CaseIterable {
    case prospect       = "Prospect / Yeni Lead"
    case poc            = "POC / Teknik Değerlendirme"
    case contract       = "Sözleşme / Ticari"
    case renewal        = "Renewal / Yenileme"
    case churnRisk      = "Churn Riski"
    case technical      = "Teknik Destek Sorusu"
    case partner        = "Partner / Reseller / ISV"
    case internalNote   = "Şirket İçi"
    case calendar       = "Takvim / Toplantı"
    case marketing      = "Pazarlama / Bülten"
    case spam           = "Önemsiz / Otomatik"
    case other          = "Diğer"

    var color: Color {
        switch self {
        case .prospect:     return .blue
        case .poc:          return .indigo
        case .contract:     return .purple
        case .renewal:      return .green
        case .churnRisk:    return .red
        case .technical:    return .teal
        case .partner:      return .cyan
        case .internalNote: return .gray
        case .calendar:     return .orange
        case .marketing:    return .yellow
        case .spam:         return Color(white: 0.6)
        case .other:        return .secondary
        }
    }
}

enum TriagePriority: String, Codable, CaseIterable {
    case urgent  = "Acil"
    case high    = "Yüksek"
    case normal  = "Normal"
    case low     = "Düşük"

    var color: Color {
        switch self {
        case .urgent: return .red
        case .high:   return .orange
        case .normal: return .blue
        case .low:    return .gray
        }
    }
}

struct TriageResult: Codable, Hashable {
    var category: TriageCategory
    var priority: TriagePriority
    var summary: String              // 1-2 cümle Türkçe özet
    var customerHealth: String?      // ör: "POC 3 hafta öncesi başladı, gecikme sinyali"
    var competitorMentions: [String] // ["Twilio", "Daily"] gibi
    var dataResidencyFlag: Bool      // GDPR/Çin/Hindistan veri yerleşimi konusu var mı
    var suggestedNextAction: String  // örn "DevRel'e ilet, SDK quota artışı talep ediyor"
    var needsHumanReply: Bool
}

struct DraftSuggestion: Codable, Hashable {
    var body: String
    var tone: String   // "professional", "concise", "warm"
    var rationale: String
}
