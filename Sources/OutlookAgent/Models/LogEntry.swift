import Foundation
import SwiftUI

enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case debug, info, warn, error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debug: return "Debug"
        case .info:  return "Info"
        case .warn:  return "Warn"
        case .error: return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .debug: return "ladybug"
        case .info:  return "info.circle"
        case .warn:  return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .debug: return Color(white: 0.55)
        case .info:  return .blue
        case .warn:  return .orange
        case .error: return .red
        }
    }

    var severity: Int {
        switch self {
        case .debug: return 0
        case .info:  return 1
        case .warn:  return 2
        case .error: return 3
        }
    }
}

enum LogCategory: String, Codable, CaseIterable, Identifiable {
    case claudeSubprocess   // claude -p subprocess
    case appleScript        // Outlook AppleScript (list_inbox, send_email, vb.)
    case salesforce         // SF REST API (query / createRecord)
    case prospectPipeline   // dedup → score → draft → send state transitions
    case emailGuess         // pattern guess + DNS MX
    case bounceDetection    // postmaster mail tespit
    case appStoreDiscovery  // iTunes Lookup API
    case inboxTriage        // background triage
    case calendarClassify   // background calendar pipeline tag
    case uiAction           // user-initiated event
    case appLifecycle       // launch / refresh / state load

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeSubprocess:  return "Claude CLI"
        case .appleScript:       return "AppleScript"
        case .salesforce:        return "Salesforce"
        case .prospectPipeline:  return "Prospect Pipeline"
        case .emailGuess:        return "Email Guess"
        case .bounceDetection:   return "Bounce Detect"
        case .appStoreDiscovery: return "App Store"
        case .inboxTriage:       return "Inbox Triage"
        case .calendarClassify:  return "Calendar Classify"
        case .uiAction:          return "UI Action"
        case .appLifecycle:      return "App Lifecycle"
        }
    }

    var systemImage: String {
        switch self {
        case .claudeSubprocess:  return "brain"
        case .appleScript:       return "applescript"
        case .salesforce:        return "cloud"
        case .prospectPipeline:  return "scope"
        case .emailGuess:        return "envelope.badge"
        case .bounceDetection:   return "arrow.uturn.left"
        case .appStoreDiscovery: return "iphone"
        case .inboxTriage:       return "tray.full"
        case .calendarClassify:  return "calendar.badge.checkmark"
        case .uiAction:          return "hand.tap"
        case .appLifecycle:      return "power"
        }
    }
}

/// Tek bir log kaydı.
struct LogEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var timestamp: Date
    var level: LogLevel
    var category: LogCategory
    var message: String
    /// Yapısal alan: subprocess duration_ms, prompt size, http status vs.
    /// JSONEncodable primitive'ler (String / Int / Double / Bool).
    var metadata: [String: LogValue]

    /// Aynı async iş zincirinin (örn discovery → dedup → score → draft) tüm
    /// log'larını gruplamak için isteğe bağlı correlation id.
    var traceId: UUID?

    init(level: LogLevel,
         category: LogCategory,
         message: String,
         metadata: [String: LogValue] = [:],
         traceId: UUID? = nil,
         timestamp: Date = Date()) {
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
        self.traceId = traceId
        self.timestamp = timestamp
    }
}

/// Codable-friendly heterogeneous value (metadata için).
enum LogValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(_ v: String) { self = .string(v) }
    init(_ v: Int)    { self = .int(v) }
    init(_ v: Double) { self = .double(v) }
    init(_ v: Bool)   { self = .bool(v) }

    var display: String {
        switch self {
        case .string(let s): return s
        case .int(let i):    return String(i)
        case .double(let d): return String(format: "%.2f", d)
        case .bool(let b):   return b ? "true" : "false"
        }
    }

    // Codable: single value container (otomatik Codable yetersiz)
    enum CodingKeys: String, CodingKey { case kind, value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v): try c.encode("s", forKey: .kind); try c.encode(v, forKey: .value)
        case .int(let v):    try c.encode("i", forKey: .kind); try c.encode(v, forKey: .value)
        case .double(let v): try c.encode("d", forKey: .kind); try c.encode(v, forKey: .value)
        case .bool(let v):   try c.encode("b", forKey: .kind); try c.encode(v, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "s": self = .string(try c.decode(String.self, forKey: .value))
        case "i": self = .int(try c.decode(Int.self, forKey: .value))
        case "d": self = .double(try c.decode(Double.self, forKey: .value))
        case "b": self = .bool(try c.decode(Bool.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown kind \(kind)"
            )
        }
    }
}
