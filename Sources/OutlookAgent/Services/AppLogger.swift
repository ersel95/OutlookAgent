import Foundation
import SwiftUI
import Observation
import OSLog

/// Uygulama içi log altyapısı.
///
/// - **Memory ring buffer** son 5000 entry — UI listesi anlık feed.
/// - **Disk JSONL** günlük rotation (`logs/app-YYYY-MM-DD.jsonl`) — geçmiş analiz.
/// - **os.Logger** Console.app + Xcode console — düşük seviyeli izleme.
///
/// Kullanım:
/// ```swift
/// AppLogger.shared.info(.claudeSubprocess, "runClaude başladı", metadata: [
///     "promptSize": .int(prompt.count), "tools": .string(tools.joined(separator: ","))
/// ])
/// AppLogger.shared.error(.claudeSubprocess, "timeout", metadata: ["elapsedSec": .int(elapsed)])
/// ```
///
/// Trace ID: aynı async iş zincirinin (discovery → dedup → score → draft) tüm
/// log'larını gruplamak için `traceId` parametresi geçirilebilir.
@MainActor
@Observable
final class AppLogger {
    static let shared = AppLogger()

    /// Son N entry (UI feed için ring buffer).
    private(set) var entries: [LogEntry] = []
    private let memoryCapacity = 5000

    /// Disk seviyesinde tutulacak min log level. Default `.debug` → her şey yazılır.
    var diskMinLevel: LogLevel = .debug
    /// UI seviyesinde varsayılan görüntü filter min level (kullanıcı UI'da değiştirebilir).
    var uiMinLevel: LogLevel = .debug

    private let osLogger: os.Logger
    private let logDir: URL
    private let dateFormatter: DateFormatter

    private init() {
        self.osLogger = os.Logger(subsystem: "com.ersel.outlookagent", category: "general")

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OutlookAgent/logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logDir = dir

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        self.dateFormatter = f

        // Önceki günün log'larını yükle (son 200 entry — UI'da göstermek için).
        loadRecentFromDisk()

        // App lifecycle başlatma log'u.
        appendInternal(LogEntry(
            level: .info,
            category: .appLifecycle,
            message: "AppLogger başlatıldı",
            metadata: ["logDir": .string(dir.path)]
        ))
    }

    // MARK: - Public API

    func debug(_ category: LogCategory,
               _ message: String,
               metadata: [String: LogValue] = [:],
               traceId: UUID? = nil) {
        log(.debug, category, message, metadata: metadata, traceId: traceId)
    }

    func info(_ category: LogCategory,
              _ message: String,
              metadata: [String: LogValue] = [:],
              traceId: UUID? = nil) {
        log(.info, category, message, metadata: metadata, traceId: traceId)
    }

    func warn(_ category: LogCategory,
              _ message: String,
              metadata: [String: LogValue] = [:],
              traceId: UUID? = nil) {
        log(.warn, category, message, metadata: metadata, traceId: traceId)
    }

    func error(_ category: LogCategory,
               _ message: String,
               metadata: [String: LogValue] = [:],
               traceId: UUID? = nil) {
        log(.error, category, message, metadata: metadata, traceId: traceId)
    }

    /// Trace ID üret (async iş zinciri için).
    nonisolated func newTraceId() -> UUID { UUID() }

    /// Manuel temizle (UI butonu).
    func clearMemoryEntries() {
        entries.removeAll()
    }

    /// Tüm disk log dosyalarını listele (UI'da export için).
    func listDiskLogs() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }
        return files.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Bugünün log dosyası — Finder'da göstermek için.
    var todayLogFileURL: URL {
        logDir.appendingPathComponent("app-\(dateFormatter.string(from: Date())).jsonl")
    }

    // MARK: - Background-safe entry points

    /// Background thread'lerden çağırmak için. MainActor sıçramayı kendisi yapar.
    nonisolated func logFromBackground(_ level: LogLevel,
                                       _ category: LogCategory,
                                       _ message: String,
                                       metadata: [String: LogValue] = [:],
                                       traceId: UUID? = nil) {
        let entry = LogEntry(level: level, category: category, message: message,
                             metadata: metadata, traceId: traceId)
        Task { @MainActor [weak self] in
            self?.appendInternal(entry)
        }
    }

    // MARK: - Core

    private func log(_ level: LogLevel,
                     _ category: LogCategory,
                     _ message: String,
                     metadata: [String: LogValue],
                     traceId: UUID?) {
        let entry = LogEntry(level: level, category: category, message: message,
                             metadata: metadata, traceId: traceId)
        appendInternal(entry)
    }

    private func appendInternal(_ entry: LogEntry) {
        // Memory ring buffer
        entries.append(entry)
        if entries.count > memoryCapacity {
            entries.removeFirst(entries.count - memoryCapacity)
        }

        // os.Logger (Console.app)
        let osMsg = "[\(entry.category.rawValue)] \(entry.message)"
        switch entry.level {
        case .debug: osLogger.debug("\(osMsg, privacy: .public)")
        case .info:  osLogger.info("\(osMsg, privacy: .public)")
        case .warn:  osLogger.warning("\(osMsg, privacy: .public)")
        case .error: osLogger.error("\(osMsg, privacy: .public)")
        }

        // Disk JSONL (level filter)
        if entry.level.severity >= diskMinLevel.severity {
            appendToDisk(entry)
        }
    }

    private func appendToDisk(_ entry: LogEntry) {
        let file = todayLogFileURL
        let snapshot = entry
        Task.detached(priority: .background) {
            let enc = JSONEncoder()
            enc.outputFormatting = []
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(snapshot) else { return }
            var line = data
            line.append(0x0A)  // \n
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                // Yeni dosya
                try? line.write(to: file, options: .atomic)
            }
        }
    }

    private func loadRecentFromDisk() {
        let file = todayLogFileURL
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var loaded: [LogEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let d = line.data(using: .utf8),
               let entry = try? dec.decode(LogEntry.self, from: d) {
                loaded.append(entry)
            }
        }
        // Son 200 entry'i yükle (UI ilk gösterimi için).
        if loaded.count > 200 {
            loaded = Array(loaded.suffix(200))
        }
        self.entries = loaded
    }
}

// MARK: - Convenience helpers for non-isolated callers

extension AppLogger {
    /// Foundation Process / URLSession callback'lerinden kolay log için.
    /// MainActor sıçramayı async yapar — sync caller'ı bloklamaz.
    nonisolated static func bg(_ level: LogLevel,
                               _ category: LogCategory,
                               _ message: String,
                               _ metadata: [String: LogValue] = [:],
                               traceId: UUID? = nil) {
        Task { @MainActor in
            AppLogger.shared.log(level: level, category: category, message: message,
                                 metadata: metadata, traceId: traceId)
        }
    }

    func log(level: LogLevel, category: LogCategory, message: String,
             metadata: [String: LogValue] = [:], traceId: UUID? = nil) {
        self.log(level, category, message, metadata: metadata, traceId: traceId)
    }
}
