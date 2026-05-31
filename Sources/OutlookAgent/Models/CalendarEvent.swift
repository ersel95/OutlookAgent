import Foundation
import SwiftUI

/// One Outlook calendar event, normalised across all linked Outlook calendars.
struct CalendarEvent: Identifiable, Codable, Hashable {
    let id: String                   // Outlook event id
    var calendarName: String         // hosting calendar (e.g. "Calendar", "Takvim")
    var subject: String
    var startRaw: String             // "yyyy-MM-dd HH:mm:ss" local TZ (as Outlook returns)
    var endRaw: String
    var isAllDay: Bool
    var location: String
    var organizerName: String
    var organizerEmail: String
    var requiredAttendees: [Attendee]
    var optionalAttendees: [Attendee]
    var ownResponse: ResponseStatus
    var body: String
    var hasReminder: Bool
    var isRecurring: Bool

    // Derived (computed once at fetch time)
    var conferenceUrl: String?
    var conferenceType: ConferenceType?

    // Pipeline + prep tagging filled by AI / heuristics later
    var pipelineStage: PipelineStage?
    var pipelineConfidence: Double?
    var primaryDomain: String?       // e.g. "acme.com" — main customer domain among attendees

    // Owning Outlook account (best-effort; bazı calendar'lar account ile
    // direkt ilişkilendirilemez — o durumda nil).
    var accountId: String? = nil
    var accountName: String? = nil

    struct Attendee: Codable, Hashable, Identifiable {
        var name: String
        var email: String
        var response: ResponseStatus
        var id: String { email.lowercased() }
        var displayName: String { name.isEmpty ? email : name }
    }

    enum ResponseStatus: String, Codable, CaseIterable {
        case none, tentative, accepted, declined, responded, organizer

        var label: String {
            switch self {
            case .none:       return "Yanıtsız"
            case .tentative:  return "Belki"
            case .accepted:   return "Kabul"
            case .declined:   return "Red"
            case .responded:  return "Yanıtladı"
            case .organizer:  return "Düzenleyen"
            }
        }
        var color: Color {
            switch self {
            case .accepted:   return .green
            case .declined:   return .red
            case .tentative:  return .orange
            case .responded:  return .blue
            case .organizer:  return .purple
            case .none:       return .secondary
            }
        }
    }

    enum ConferenceType: String, Codable {
        case teams, zoom, meet, webex, generic

        var label: String {
            switch self {
            case .teams:   return "Teams"
            case .zoom:    return "Zoom"
            case .meet:    return "Google Meet"
            case .webex:   return "Webex"
            case .generic: return "Çevrimiçi"
            }
        }
        var color: Color {
            switch self {
            case .teams:   return Color(red: 0.36, green: 0.40, blue: 0.85)
            case .zoom:    return Color(red: 0.20, green: 0.55, blue: 0.95)
            case .meet:    return Color(red: 0.20, green: 0.70, blue: 0.40)
            case .webex:   return Color(red: 0.95, green: 0.55, blue: 0.20)
            case .generic: return .secondary
            }
        }
    }

    enum PipelineStage: String, Codable, CaseIterable {
        case prospect, poc, contract, renewal, qbr, churnRisk, internalNote, partner, focus, other

        var label: String {
            switch self {
            case .prospect:     return "Prospect"
            case .poc:          return "POC"
            case .contract:     return "Sözleşme"
            case .renewal:      return "Renewal"
            case .qbr:          return "QBR"
            case .churnRisk:    return "Churn Risk"
            case .internalNote: return "İç Toplantı"
            case .partner:      return "Partner"
            case .focus:        return "Focus / Hold"
            case .other:        return "Diğer"
            }
        }
        var color: Color {
            switch self {
            case .prospect:     return .blue
            case .poc:          return .indigo
            case .contract:     return .purple
            case .renewal:      return .green
            case .qbr:          return .mint
            case .churnRisk:    return .red
            case .internalNote: return .gray
            case .partner:      return .cyan
            case .focus:        return Color(white: 0.4)
            case .other:        return .secondary
            }
        }
    }

    // MARK: - Derived

    var startDate: Date? { DateUtil.parse(startRaw) }
    var endDate:   Date? { DateUtil.parse(endRaw) }

    /// Duration in minutes; 0 if dates unparsable.
    var durationMinutes: Int {
        guard let s = startDate, let e = endDate else { return 0 }
        return max(0, Int(e.timeIntervalSince(s) / 60.0))
    }

    /// Combined attendee list (required first), excluding the organizer.
    var allAttendees: [Attendee] {
        let req = requiredAttendees
        let opt = optionalAttendees
        var seen = Set<String>()
        var out: [Attendee] = []
        for a in req + opt {
            let k = a.email.lowercased()
            if k.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(a)
        }
        return out
    }

    /// External attendees (not @agora.io, not the user himself).
    var externalAttendees: [Attendee] {
        allAttendees.filter { a in
            let lower = a.email.lowercased()
            return !lower.isEmpty
                && !lower.hasSuffix("@agora.io")
                && lower != AgoraContext.userEmail.lowercased()
        }
    }

    /// "Internal" if every attendee (and organizer) belongs to @agora.io.
    var isInternal: Bool {
        externalAttendees.isEmpty && organizerEmail.lowercased().hasSuffix("@agora.io")
    }

    var isPast: Bool {
        guard let e = endDate else { return false }
        return e < Date()
    }

    /// Most-frequent external email domain (for pipeline/customer mapping).
    var inferredCustomerDomain: String? {
        if let p = primaryDomain, !p.isEmpty { return p }
        var counts: [String: Int] = [:]
        for a in externalAttendees {
            if let d = a.email.split(separator: "@").last.map(String.init)?.lowercased() {
                counts[d, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}

/// Time conflict between two events (for the agenda view).
struct EventConflict: Hashable {
    let aId: String
    let bId: String
}
