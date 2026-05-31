import Foundation
import SwiftUI

/// Bir Outlook (Classic) hesabını temsil eder. ID Outlook'un kendi `id` property'sinden
/// gelir; üretici farklı (exchange / imap / pop) — uygulama içinde tek liste hâlinde
/// görünür. `displayName` ve `colorHex` kullanıcı override'ları, `lastSeenAt` Outlook'tan
/// son keşif zamanı (silinmiş hesabı UI'da soluk göstermek için).
struct MailAccount: Identifiable, Codable, Hashable {
    let id: String
    var displayName: String
    var emailAddress: String
    var accountType: AccountType
    /// Outlook AppleScript dictionary'sinde hesabı isimle arıyoruz —
    /// `name of acct` ile döner; kullanıcı `displayName` ile bunu değiştirebilse
    /// de AppleScript çağrılarında hep bu kullanılır.
    var outlookAccountName: String
    var colorHex: String?
    var isEnabled: Bool = true
    var isDefault: Bool = false
    /// Outlook'tan son keşif anı; nil ise hiç görülmedi (manuel eklenmiş olabilir).
    var lastSeenAt: Date?

    enum AccountType: String, Codable, CaseIterable {
        case exchange
        case imap
        case pop
        case other

        var displayName: String {
            switch self {
            case .exchange: return "Exchange"
            case .imap:     return "IMAP"
            case .pop:      return "POP"
            case .other:    return "Diğer"
            }
        }
    }

    /// Hesabın AppleScript bağlamında "stale" olup olmadığı — son 7 günde görülmedi
    /// ise Settings UI'sinde soluk gösterilir.
    var isStale: Bool {
        guard let lastSeenAt else { return true }
        return Date().timeIntervalSince(lastSeenAt) > 7 * 24 * 60 * 60
    }

    /// SwiftUI Color (`colorHex` parsed veya türetilmiş fallback).
    var color: Color {
        if let hex = colorHex, let c = Color(hex: hex) { return c }
        // Stable fallback: hash → predefined palette
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red, .mint, .cyan]
        let hash = abs(id.hashValue)
        return palette[hash % palette.count]
    }
}

// MARK: - Color hex helper

extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6, let v = UInt32(trimmed, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// "#RRGGBB" formatı; alpha düşürülür.
    var hexString: String? {
        #if canImport(AppKit)
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        return nil
        #endif
    }
}
