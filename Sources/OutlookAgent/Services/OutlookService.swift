import Foundation

enum OutlookError: LocalizedError {
    case scriptMissing(String)
    case scriptFailed(String)
    case parseFailed(String)
    case newOutlookUnsupported
    case outlookNotRunning
    case messageNotFound

    var errorDescription: String? {
        switch self {
        case .scriptMissing(let s): return "AppleScript bulunamadı: \(s)"
        case .scriptFailed(let s):  return "AppleScript hata verdi: \(s)"
        case .parseFailed(let s):   return "Çıktı çözümlenemedi: \(s)"
        case .newOutlookUnsupported:
            return """
            Yeni Outlook görünümü AppleScript'i desteklemiyor.

            Outlook'ta menüden Help → Revert to Legacy Outlook \
            (veya Outlook → New Outlook anahtarını kapat) ile Classic Outlook'a \
            geri dönmen gerekiyor. Klasik görünüm bu uygulamanın çalışması için zorunlu.
            """
        case .outlookNotRunning:
            return "Microsoft Outlook çalışmıyor. Outlook'u açıp tekrar dene."
        case .messageNotFound:
            return "Mail bulunamadı (taşınmış, silinmiş veya senkronize olmamış olabilir)."
        }
    }
}

actor OutlookService {
    static let shared = OutlookService()

    private let rs = Character(UnicodeScalar(30)!)
    private let fs = Character(UnicodeScalar(31)!)

    // MARK: - Public API

    func listInbox(limit: Int = 30,
                   unreadOnly: Bool = false,
                   accountId: String? = nil) async throws -> [EmailSummary] {
        let acctArg = (accountId?.isEmpty == false) ? accountId! : ""
        let raw = try runScript(
            name: "list_inbox",
            args: [String(limit), unreadOnly ? "true" : "false", acctArg]
        )
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "OA_EMPTY_INBOX" {
            // AppleScript signaled inbox is empty/unreachable — likely New Outlook
            throw OutlookError.newOutlookUnsupported
        }
        guard let data = Data(base64Encoded: trimmed),
              let payload = String(data: data, encoding: .utf8) else {
            throw OutlookError.parseFailed("base64 decode failed")
        }
        return parseInboxPayload(payload)
    }

    /// Outlook'un tanımlı tüm hesaplarını döner (exchange + imap + pop).
    /// Sonuç MailAccount.id Outlook'un kendi id'siyle eşleşir.
    func listAccounts() async throws -> [MailAccount] {
        let raw = try runScript(name: "list_accounts", args: [])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard let data = Data(base64Encoded: trimmed),
              let payload = String(data: data, encoding: .utf8) else {
            throw OutlookError.parseFailed("accounts base64 decode failed")
        }
        return Self.parseAccountsPayload(payload, fs: fs, rs: rs)
    }

    nonisolated static func parseAccountsPayload(_ payload: String, fs: Character, rs: Character) -> [MailAccount] {
        let records = payload.split(separator: rs, omittingEmptySubsequences: true)
        var out: [MailAccount] = []
        for rec in records {
            let f = rec.split(separator: fs, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            let typeRaw = f[1].lowercased()
            let type: MailAccount.AccountType
            switch typeRaw {
            case "exchange": type = .exchange
            case "imap":     type = .imap
            case "pop":      type = .pop
            default:         type = .other
            }
            let name = f[2]
            let email = f[3]
            out.append(MailAccount(
                id: f[0],
                displayName: name.isEmpty ? email : name,
                emailAddress: email,
                accountType: type,
                outlookAccountName: name,
                colorHex: nil,
                isEnabled: true,
                isDefault: false,
                lastSeenAt: Date()
            ))
        }
        return out
    }

    func readEmail(id: String) async throws -> EmailFull {
        let raw = try runScript(name: "read_email", args: [id])
        guard let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let payload = String(data: data, encoding: .utf8) else {
            throw OutlookError.parseFailed("base64 decode failed")
        }
        let fields = payload.split(separator: fs, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 11 else {
            throw OutlookError.parseFailed("read_email: beklenen alan sayısı eksik (\(fields.count))")
        }
        let convId: String? = (fields.count >= 12 && !fields[11].isEmpty) ? fields[11] : nil
        let paths = fields.count >= 13 ? Self.parseAttachmentPaths(fields[12]) : [:]
        let acctId: String? = (fields.count >= 14 && !fields[13].isEmpty) ? fields[13] : nil
        let acctName: String? = (fields.count >= 15 && !fields[14].isEmpty) ? fields[14] : nil
        return EmailFull(
            id: fields[0],
            isRead: fields[1].lowercased() == "true",
            date: fields[2],
            fromName: fields[3],
            fromAddress: fields[4],
            toAddresses: fields[5].split(separator: ";").map(String.init).filter { !$0.isEmpty },
            ccAddresses: fields[6].split(separator: ";").map(String.init).filter { !$0.isEmpty },
            subject: BodyFormatter.stripHTMLResidue(fields[7]),
            body: fields[8],   // body EmailBodyParser → BodyFormatter zincirinde strip ediliyor
            hasAttachments: fields[9].lowercased() == "true",
            attachmentNames: fields[10].split(separator: ";").map(String.init).filter { !$0.isEmpty },
            conversationId: convId,
            attachmentPaths: paths,
            accountId: acctId,
            accountName: acctName
        )
    }

    nonisolated static func parseAttachmentPaths(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for entry in raw.components(separatedBy: "||") where !entry.isEmpty {
            let parts = entry.components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            // Anything after the first "::" belongs to the path (paths can contain colons)
            let path = parts[1...].joined(separator: "::")
            if !name.isEmpty, !path.isEmpty {
                out[name] = path
            }
        }
        return out
    }

    func listThread(conversationId: String, subjectKey: String = "") async throws -> [ThreadMessage] {
        let raw = try runScript(name: "list_thread", args: [conversationId, subjectKey])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let payload = String(data: data, encoding: .utf8) else {
            throw OutlookError.parseFailed("thread base64 decode failed")
        }
        let records = payload.split(separator: rs, omittingEmptySubsequences: true)
        var out: [ThreadMessage] = []
        out.reserveCapacity(records.count)
        let df = ISO8601DateFormatter()  // not used — AppleScript's date string is locale; ignore
        _ = df
        for rec in records {
            let f = rec.split(separator: fs, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 12 else { continue }
            let paths = f.count >= 13 ? Self.parseAttachmentPaths(f[12]) : [:]
            let acctId: String? = (f.count >= 14 && !f[13].isEmpty) ? f[13] : nil
            let acctName: String? = (f.count >= 15 && !f[14].isEmpty) ? f[14] : nil
            let msg = ThreadMessage(
                id: f[0],
                folder: f[1],
                date: f[2],
                sortKey: 0,
                fromName: f[3],
                fromAddress: f[4],
                toAddresses: f[5].split(separator: ";").map(String.init).filter { !$0.isEmpty },
                ccAddresses: f[6].split(separator: ";").map(String.init).filter { !$0.isEmpty },
                subject: BodyFormatter.stripHTMLResidue(f[7]),
                body: f[8],
                isRead: f[9].lowercased() == "true",
                hasAttachments: f[10].lowercased() == "true",
                attachmentNames: f[11].split(separator: ";").map(String.init).filter { !$0.isEmpty },
                attachmentPaths: paths,
                accountId: acctId,
                accountName: acctName
            )
            out.append(msg)
        }
        // sort by message id (Outlook ids are increasing) as a stable order proxy
        out.sort { (a, b) in
            (Int(a.id) ?? 0) < (Int(b.id) ?? 0)
        }
        return out
    }

    func deleteEmail(messageId: String) async throws {
        _ = try runScript(name: "delete_email", args: [messageId])
    }

    func createDraftReply(messageId: String, body: String, replyAll: Bool = false) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("outlookagent-\(UUID().uuidString).txt")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try runScript(name: "create_draft",
                          args: [messageId, tmp.path,
                                 replyAll ? "true" : "false",
                                 AgoraContext.userEmail])
    }

    /// Yeni bir outbound email oluşturup direkt gönderir (Classic Outlook AppleScript
    /// `send` action). Reply değil, fresh outgoing — AI SDR sequence step'leri için
    /// kullanılır. Geri dönüş: Outlook message id (boş olabilir).
    func sendEmail(subject: String,
                   body: String,
                   to: [String],
                   cc: [String] = [],
                   fromAccountId: String? = nil) async throws -> String {
        let subjFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("oa-subj-\(UUID().uuidString).txt")
        try subject.write(to: subjFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: subjFile) }

        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("oa-body-\(UUID().uuidString).txt")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let toArg = to.joined(separator: ";")
        let ccArg = cc.joined(separator: ";")
        let fromArg = fromAccountId ?? ""
        let raw = try runScript(name: "send_email",
                                args: [subjFile.path, bodyFile.path, toArg, ccArg, fromArg])
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func markRead(messageId: String, read: Bool = true) async throws {
        _ = try runScript(name: "mark_read", args: [messageId, read ? "true" : "false"])
    }

    // MARK: - Calendar

    /// Fetch calendar events from `startOffsetDays` (negative=past) through `endOffsetDays`.
    /// `0,7` => today + next 7 days (inclusive).
    func listCalendarEvents(startOffsetDays: Int, endOffsetDays: Int) async throws -> [CalendarEvent] {
        let raw = try runScript(
            name: "list_calendar",
            args: [String(startOffsetDays), String(endOffsetDays)]
        )
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "OA_NO_CALENDARS" { return [] }
        guard let data = Data(base64Encoded: trimmed),
              let payload = String(data: data, encoding: .utf8) else {
            throw OutlookError.parseFailed("calendar base64 decode failed")
        }
        return Self.parseCalendarPayload(payload, fs: fs, rs: rs)
    }

    /// Create a new outgoing meeting on the user's default calendar and open it
    /// in Outlook for confirmation. Returns the created event id (best effort).
    func createCalendarEvent(
        subject: String,
        startISO: String,        // "yyyy-MM-dd HH:mm:ss" in local TZ
        endISO: String,
        location: String,
        body: String,
        attendees: [String],
        timeZoneId: String? = nil
    ) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("outlookagent-event-\(UUID().uuidString).txt")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let attendeeArg = attendees.joined(separator: ";")
        let raw = try runScript(name: "create_calendar_event", args: [
            subject, startISO, endISO, location, tmp.path, attendeeArg, timeZoneId ?? ""
        ])
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func parseCalendarPayload(_ payload: String, fs: Character, rs: Character) -> [CalendarEvent] {
        let records = payload.split(separator: rs, omittingEmptySubsequences: true)
        var out: [CalendarEvent] = []
        out.reserveCapacity(records.count)
        for rec in records {
            let f = rec.split(separator: fs, omittingEmptySubsequences: false).map(String.init)
            // 15 base fields + 2 optional account fields
            guard f.count >= 15 else { continue }
            let req = parseAttendeeBlob(f[9])
            let opt = parseAttendeeBlob(f[10])
            let respRaw = f[11].lowercased()
            let resp = CalendarEvent.ResponseStatus(rawValue: respRaw) ?? .none
            let body = f[12]
            let (confUrl, confType) = extractConference(from: body, location: f[6])
            let acctId: String? = (f.count >= 16 && !f[15].isEmpty) ? f[15] : nil
            let acctName: String? = (f.count >= 17 && !f[16].isEmpty) ? f[16] : nil
            let event = CalendarEvent(
                id: f[0],
                calendarName: f[1],
                subject: f[2],
                startRaw: f[3],
                endRaw: f[4],
                isAllDay: f[5].lowercased() == "true",
                location: f[6],
                organizerName: f[7],
                organizerEmail: f[8],
                requiredAttendees: req,
                optionalAttendees: opt,
                ownResponse: resp,
                body: body,
                hasReminder: f[13].lowercased() == "true",
                isRecurring: f[14].lowercased() == "true",
                conferenceUrl: confUrl,
                conferenceType: confType,
                pipelineStage: nil,
                pipelineConfidence: nil,
                primaryDomain: nil,
                accountId: acctId,
                accountName: acctName
            )
            out.append(event)
        }
        // Stable sort by start
        out.sort { (a, b) in
            DateUtil.sortKey(a.startRaw) < DateUtil.sortKey(b.startRaw)
        }
        return out
    }

    private nonisolated static func parseAttendeeBlob(_ raw: String) -> [CalendarEvent.Attendee] {
        var out: [CalendarEvent.Attendee] = []
        for chunk in raw.components(separatedBy: ";;") where !chunk.isEmpty {
            let parts = chunk.components(separatedBy: "||")
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let email = parts[1]
            let resp: CalendarEvent.ResponseStatus = {
                guard parts.count >= 3, !parts[2].isEmpty else { return .none }
                return CalendarEvent.ResponseStatus(rawValue: parts[2].lowercased()) ?? .none
            }()
            if !email.isEmpty {
                out.append(.init(name: name, email: email, response: resp))
            }
        }
        return out
    }

    private nonisolated static func extractConference(from body: String, location: String) -> (String?, CalendarEvent.ConferenceType?) {
        let haystack = body + " " + location
        // Order matters: more specific patterns first
        let patterns: [(String, CalendarEvent.ConferenceType)] = [
            (#"https?://[^\s<>"]*teams\.microsoft\.com/[^\s<>"]+"#, .teams),
            (#"https?://[^\s<>"]*teams\.live\.com/[^\s<>"]+"#,       .teams),
            (#"https?://[^\s<>"]*\.zoom\.us/[^\s<>"]+"#,             .zoom),
            (#"https?://[^\s<>"]*meet\.google\.com/[^\s<>"]+"#,      .meet),
            (#"https?://[^\s<>"]*\.webex\.com/[^\s<>"]+"#,           .webex)
        ]
        for (pat, kind) in patterns {
            if let r = haystack.range(of: pat, options: .regularExpression) {
                return (String(haystack[r]), kind)
            }
        }
        // Generic http link in body — fall back
        if let r = body.range(of: #"https?://[^\s<>"]+"#, options: .regularExpression) {
            return (String(body[r]), .generic)
        }
        return (nil, nil)
    }

    // MARK: - Internals

    private func parseInboxPayload(_ payload: String) -> [EmailSummary] {
        let records = payload.split(separator: rs, omittingEmptySubsequences: true)
        var out: [EmailSummary] = []
        out.reserveCapacity(records.count)
        for rec in records {
            let fields = rec.split(separator: fs, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8 else { continue }
            let acctId: String? = (fields.count >= 9 && !fields[8].isEmpty) ? fields[8] : nil
            let acctName: String? = (fields.count >= 10 && !fields[9].isEmpty) ? fields[9] : nil
            out.append(EmailSummary(
                id: fields[0],
                isRead: fields[1].lowercased() == "true",
                date: fields[2],
                fromName: fields[3],
                fromAddress: fields[4],
                subject: BodyFormatter.stripHTMLResidue(fields[5]),
                preview: BodyFormatter.stripHTMLResidue(fields[6]),
                hasAttachments: fields[7].lowercased() == "true",
                accountId: acctId,
                accountName: acctName
            ))
        }
        return out
    }

    private static let cacheWorkingDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func runScript(name: String, args: [String]) throws -> String {
        // SPM Bundle.module accessor macOS .app Contents/ yapisini bilmedigi icin
        // bundle'i Bundle.main altinda Scripts/ subdirectory'sinden okuyoruz.
        // build.sh AppleScript dosyalarini direkt Contents/Resources/Scripts/'e koyuyor.
        guard let url = Bundle.main.url(forResource: name, withExtension: "applescript", subdirectory: "Scripts")
            ?? Bundle.module.url(forResource: name, withExtension: "applescript") else {
            AppLogger.bg(.error, .appleScript, "script bulunamadı", ["script": .string(name)])
            throw OutlookError.scriptMissing(name)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [url.path] + args
        proc.currentDirectoryURL = Self.cacheWorkingDir
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let startTime = Date()
        AppLogger.bg(.debug, .appleScript, "script başlatılıyor", [
            "script":   .string(name),
            "argCount": .int(args.count)
        ])

        try proc.run()
        proc.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

        if proc.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "?"
            AppLogger.bg(.error, .appleScript, "script hata", [
                "script":     .string(name),
                "exitCode":   .int(Int(proc.terminationStatus)),
                "elapsedMs":  .int(elapsedMs),
                "stderrHead": .string(String(msg.prefix(240)))
            ])
            throw Self.classifyError(scriptName: name, raw: msg)
        }

        AppLogger.bg(.debug, .appleScript, "script bitti", [
            "script":      .string(name),
            "elapsedMs":   .int(elapsedMs),
            "stdoutBytes": .int(outData.count)
        ])
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Translate raw AppleScript / osascript stderr into a typed OutlookError
    /// with a user-friendly message instead of a cryptic locale-specific dump.
    nonisolated private static func classifyError(scriptName: String, raw: String) -> OutlookError {
        let lower = raw.lowercased()

        // "messages 1 thru 0" — empty inbox under New Outlook, no AppleScript access.
        if lower.contains("messages 1 thru 0") || lower.contains("messages 1 through 0") {
            return .newOutlookUnsupported
        }
        // Any reference to invalid index in mail folder traversal hints at the same.
        if scriptName == "list_inbox"
            && (lower.contains("invalid index")
                || lower.contains("geçersiz dizin")
                || lower.contains("-1719")) {
            return .newOutlookUnsupported
        }
        // Outlook not running / can't connect.
        if lower.contains("application isn't running")
            || lower.contains("uygulama çalışmıyor")
            || lower.contains("(-600)") {
            return .outlookNotRunning
        }
        // Specific message id no longer exists.
        if lower.contains("message id")
            && (lower.contains("doesn't exist") || lower.contains("yok")
                || lower.contains("mevcut değil") || lower.contains("(-1728)")) {
            return .messageNotFound
        }
        return .scriptFailed("\(scriptName): \(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
