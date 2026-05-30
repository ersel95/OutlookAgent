import Foundation

/// Parses AppleScript-emitted ISO-like dates ("yyyy-MM-dd HH:mm:ss") and
/// formats them for display in Turkish locale.
enum DateUtil {
    private static let isoIn: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let trDisplay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = .current
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isoIn.date(from: s)
    }

    /// Smart, compact display:
    ///   today              -> "16:23"
    ///   < 7 days           -> "Pzt 16:23"
    ///   same year          -> "5 May 16:23"
    ///   else               -> "5 May 2026 16:23"
    static func display(_ raw: String) -> String {
        guard let d = parse(raw) else { return raw }
        let cal = Calendar(identifier: .gregorian)
        if cal.isDateInToday(d) {
            trDisplay.dateFormat = "HH:mm"
            return trDisplay.string(from: d)
        }
        let dayDelta = cal.dateComponents([.day], from: cal.startOfDay(for: d),
                                          to: cal.startOfDay(for: Date())).day ?? 99
        if (0..<7).contains(dayDelta) {
            trDisplay.dateFormat = "EEE HH:mm"
            return trDisplay.string(from: d).capitalized
        }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            trDisplay.dateFormat = "d MMM HH:mm"
            return trDisplay.string(from: d)
        }
        trDisplay.dateFormat = "d MMM yyyy HH:mm"
        return trDisplay.string(from: d)
    }

    /// Long form for thread bubbles
    static func fullDisplay(_ raw: String) -> String {
        guard let d = parse(raw) else { return raw }
        trDisplay.dateFormat = "d MMM yyyy HH:mm"
        return trDisplay.string(from: d)
    }

    static func sortKey(_ raw: String) -> Date {
        parse(raw) ?? .distantPast
    }
}

