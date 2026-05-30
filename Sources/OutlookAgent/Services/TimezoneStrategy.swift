import Foundation
import SwiftUI

/// Resolves the three timezones the Region Manager cares about for any event:
/// 1. The user's local TZ
/// 2. The customer's likely TZ (from attendee domains / TLD heuristics)
/// 3. Agora HQ (Santa Clara, US Pacific)
enum TimezoneStrategy {
    struct Zone: Hashable {
        let id: String       // unique label
        let label: String    // "Sen", "Müşteri", "HQ"
        let tz: TimeZone
        let flag: String
        let color: Color
    }

    /// Common Region Manager–facing zones, kept as identifiers for picker menus.
    static let commonZones: [String] = [
        "Europe/Istanbul",
        "Europe/London",
        "Europe/Berlin",
        "Europe/Paris",
        "Europe/Amsterdam",
        "Europe/Madrid",
        "Europe/Stockholm",
        "Europe/Athens",
        "America/Los_Angeles",
        "America/New_York",
        "America/Chicago",
        "America/Sao_Paulo",
        "Asia/Tokyo",
        "Asia/Shanghai",
        "Asia/Hong_Kong",
        "Asia/Singapore",
        "Asia/Kolkata",
        "Asia/Dubai",
        "Asia/Riyadh",
        "Australia/Sydney"
    ]

    /// Returns the canonical (user, customer, HQ) trio.
    static func zones(for event: CalendarEvent) -> [Zone] {
        var out: [Zone] = []
        let userTz = TimeZone.current
        out.append(Zone(
            id: "user",
            label: "Sen",
            tz: userTz,
            flag: flag(forTz: userTz),
            color: .blue
        ))
        if let dom = event.inferredCustomerDomain,
           let tzId = timezoneId(for: dom),
           let custTz = TimeZone(identifier: tzId),
           custTz.identifier != userTz.identifier {
            out.append(Zone(
                id: "customer",
                label: "Müşteri",
                tz: custTz,
                flag: flag(forTz: custTz),
                color: .purple
            ))
        }
        let hqId = "America/Los_Angeles"
        if let hqTz = TimeZone(identifier: hqId), hqTz.identifier != userTz.identifier {
            out.append(Zone(
                id: "hq",
                label: "HQ",
                tz: hqTz,
                flag: "🇺🇸",
                color: .green
            ))
        }
        return out
    }

    /// Map a domain to the most likely IANA timezone id.
    /// Honors explicit cctld → region; falls back to nil (unknown).
    static func timezoneId(for domain: String) -> String? {
        let lower = domain.lowercased()
        // Known company → tz overrides
        if let custom = customerOverrides[lower] { return custom }

        // Generic TLDs first — `.com` etc. don't tell us anything.
        let parts = lower.split(separator: ".")
        guard let tld = parts.last.map(String.init) else { return nil }
        if let mapped = tldMap[tld] { return mapped }

        // Fallback: try second-level for "company.com.tr" style
        if parts.count >= 2 {
            let pair = parts.suffix(2).joined(separator: ".")
            if let mapped = tldMap[pair] { return mapped }
        }
        return nil
    }

    /// Hand-curated overrides for major customer / partner domains.
    /// Intentionally narrow — better to return nil than wrong.
    static let customerOverrides: [String: String] = [
        "agora.io":     "America/Los_Angeles",
        "twilio.com":   "America/Los_Angeles",
        "vonage.com":   "America/Los_Angeles",
        "daily.co":     "America/Los_Angeles",
        "livekit.io":   "America/Los_Angeles",
        "zegocloud.com":"Asia/Hong_Kong",
        "tencent.com":  "Asia/Shanghai",
        "100ms.live":   "Asia/Kolkata",
        "sinch.com":    "Europe/Stockholm",
        "stream-io.com":"Europe/Amsterdam",
        "stream.io":    "Europe/Amsterdam",
        "dolby.com":    "America/Los_Angeles",
        "dolby.io":     "America/Los_Angeles"
    ]

    /// ccTLD → IANA timezone (best central guess; not perfect for big countries).
    private static let tldMap: [String: String] = [
        "tr":      "Europe/Istanbul",
        "com.tr":  "Europe/Istanbul",
        "uk":      "Europe/London",
        "co.uk":   "Europe/London",
        "ie":      "Europe/Dublin",
        "de":      "Europe/Berlin",
        "fr":      "Europe/Paris",
        "es":      "Europe/Madrid",
        "it":      "Europe/Rome",
        "nl":      "Europe/Amsterdam",
        "be":      "Europe/Brussels",
        "ch":      "Europe/Zurich",
        "at":      "Europe/Vienna",
        "se":      "Europe/Stockholm",
        "no":      "Europe/Oslo",
        "fi":      "Europe/Helsinki",
        "dk":      "Europe/Copenhagen",
        "pl":      "Europe/Warsaw",
        "cz":      "Europe/Prague",
        "gr":      "Europe/Athens",
        "ro":      "Europe/Bucharest",
        "ru":      "Europe/Moscow",
        "ua":      "Europe/Kyiv",
        "us":      "America/New_York",
        "ca":      "America/Toronto",
        "br":      "America/Sao_Paulo",
        "mx":      "America/Mexico_City",
        "ar":      "America/Argentina/Buenos_Aires",
        "cl":      "America/Santiago",
        "co":      "America/Bogota",
        "jp":      "Asia/Tokyo",
        "kr":      "Asia/Seoul",
        "cn":      "Asia/Shanghai",
        "com.cn":  "Asia/Shanghai",
        "hk":      "Asia/Hong_Kong",
        "tw":      "Asia/Taipei",
        "sg":      "Asia/Singapore",
        "com.sg":  "Asia/Singapore",
        "in":      "Asia/Kolkata",
        "co.in":   "Asia/Kolkata",
        "id":      "Asia/Jakarta",
        "co.id":   "Asia/Jakarta",
        "ph":      "Asia/Manila",
        "th":      "Asia/Bangkok",
        "vn":      "Asia/Ho_Chi_Minh",
        "my":      "Asia/Kuala_Lumpur",
        "com.my":  "Asia/Kuala_Lumpur",
        "ae":      "Asia/Dubai",
        "sa":      "Asia/Riyadh",
        "il":      "Asia/Jerusalem",
        "co.il":   "Asia/Jerusalem",
        "za":      "Africa/Johannesburg",
        "co.za":   "Africa/Johannesburg",
        "ng":      "Africa/Lagos",
        "ke":      "Africa/Nairobi",
        "eg":      "Africa/Cairo",
        "au":      "Australia/Sydney",
        "com.au":  "Australia/Sydney",
        "nz":      "Pacific/Auckland"
    ]

    /// Best-effort flag emoji for a timezone (uses the abbreviation country).
    static func flag(forTz tz: TimeZone) -> String {
        // IANA identifier → continent/city; pick a flag from the city heuristically.
        let mapping: [String: String] = [
            "Europe/Istanbul":      "🇹🇷",
            "Europe/London":        "🇬🇧",
            "Europe/Dublin":        "🇮🇪",
            "Europe/Berlin":        "🇩🇪",
            "Europe/Paris":         "🇫🇷",
            "Europe/Madrid":        "🇪🇸",
            "Europe/Rome":          "🇮🇹",
            "Europe/Amsterdam":     "🇳🇱",
            "Europe/Brussels":      "🇧🇪",
            "Europe/Zurich":        "🇨🇭",
            "Europe/Vienna":        "🇦🇹",
            "Europe/Stockholm":     "🇸🇪",
            "Europe/Oslo":          "🇳🇴",
            "Europe/Helsinki":      "🇫🇮",
            "Europe/Copenhagen":    "🇩🇰",
            "Europe/Warsaw":        "🇵🇱",
            "Europe/Prague":        "🇨🇿",
            "Europe/Athens":        "🇬🇷",
            "Europe/Bucharest":     "🇷🇴",
            "Europe/Moscow":        "🇷🇺",
            "Europe/Kyiv":          "🇺🇦",
            "America/Los_Angeles":  "🇺🇸",
            "America/New_York":     "🇺🇸",
            "America/Chicago":      "🇺🇸",
            "America/Toronto":      "🇨🇦",
            "America/Sao_Paulo":    "🇧🇷",
            "America/Mexico_City":  "🇲🇽",
            "America/Argentina/Buenos_Aires": "🇦🇷",
            "America/Santiago":     "🇨🇱",
            "America/Bogota":       "🇨🇴",
            "Asia/Tokyo":           "🇯🇵",
            "Asia/Seoul":           "🇰🇷",
            "Asia/Shanghai":        "🇨🇳",
            "Asia/Hong_Kong":       "🇭🇰",
            "Asia/Taipei":          "🇹🇼",
            "Asia/Singapore":       "🇸🇬",
            "Asia/Kolkata":         "🇮🇳",
            "Asia/Jakarta":         "🇮🇩",
            "Asia/Manila":          "🇵🇭",
            "Asia/Bangkok":         "🇹🇭",
            "Asia/Ho_Chi_Minh":     "🇻🇳",
            "Asia/Kuala_Lumpur":    "🇲🇾",
            "Asia/Dubai":           "🇦🇪",
            "Asia/Riyadh":          "🇸🇦",
            "Asia/Jerusalem":       "🇮🇱",
            "Africa/Johannesburg":  "🇿🇦",
            "Africa/Lagos":         "🇳🇬",
            "Africa/Nairobi":       "🇰🇪",
            "Africa/Cairo":         "🇪🇬",
            "Australia/Sydney":     "🇦🇺",
            "Pacific/Auckland":     "🇳🇿"
        ]
        return mapping[tz.identifier] ?? "🌐"
    }
}
