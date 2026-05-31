import Foundation

/// One logical message extracted from a raw email body.
/// A single physical Outlook message often contains the full quoted history
/// (replies stacked inside one body). We split on Outlook block separators
/// ("________________________________________" + From/Sent/To/Subject headers),
/// "On <date>, <name> wrote:" intros, and Turkish "<name> şunları yazdı (...):" intros.
struct EmailSegment: Identifiable, Hashable {
    let id: UUID
    var author: String?
    var authorEmail: String?
    var dateRaw: String?
    var body: String
    var depth: Int                 // 0 = outermost (the message itself), N = deepest quote
    var sourceMessageId: String?   // physical Outlook message this segment was extracted from
    var sourceFolder: String?      // "inbox", "sent items", ...
    var attachmentNames: [String]  // attached only to depth==0 segment of a physical message
    var attachmentPaths: [String: String] = [:]   // filename → local cached path

    init(id: UUID = UUID(),
         author: String?,
         authorEmail: String?,
         dateRaw: String?,
         body: String,
         depth: Int,
         sourceMessageId: String?,
         sourceFolder: String?,
         attachmentNames: [String] = []) {
        self.id = id
        self.author = author
        self.authorEmail = authorEmail
        self.dateRaw = dateRaw
        self.body = body
        self.depth = depth
        self.sourceMessageId = sourceMessageId
        self.sourceFolder = sourceFolder
        self.attachmentNames = attachmentNames
    }

    var displayName: String {
        if let n = author, !n.isEmpty { return n }
        if let e = authorEmail, !e.isEmpty { return e }
        return "?"
    }

    var participantKey: String {
        let e = (authorEmail ?? "").lowercased()
        let n = (author ?? "").lowercased()
        return e.isEmpty ? n : e
    }

    var isOutgoing: Bool {
        if let e = authorEmail?.lowercased(), !e.isEmpty {
            return e == AgoraContext.userEmail.lowercased()
        }
        if let folder = sourceFolder {
            let f = folder.lowercased()
            if f.contains("sent") || f.contains("drafts") { return true }
        }
        return false
    }

    /// Used to dedupe across physical messages (same content quoted in multiple places).
    var dedupeKey: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+",
                                  with: " ",
                                  options: .regularExpression)
            .lowercased()
        return participantKey + "|" + String(trimmed.prefix(120))
    }
}

enum EmailBodyParser {
    static func parse(
        _ rawBody: String,
        defaultAuthor: String?,
        defaultEmail: String?,
        sourceMessageId: String?,
        sourceFolder: String?
    ) -> [EmailSegment] {
        // HTML/CSS residue (örn. Outlook'un plain-text render'ı sızdırdığı
        // `<font-size:14px;...>` veya `<blank>` placeholder'ları) segment
        // bölmeden önce temizlenir — AI prompt ve dedupeKey de bu temiz hâlden
        // beslenir.
        let stripped = BodyFormatter.stripHTMLResidue(rawBody)
        let normalized = stripped.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var segments: [EmailSegment] = []
        var depth = 0
        var curAuthor = defaultAuthor
        var curEmail = defaultEmail
        var curDate: String? = nil
        var curBody: [String] = []

        func flush() {
            let bodyStr = curBody.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !bodyStr.isEmpty {
                segments.append(EmailSegment(
                    author: curAuthor,
                    authorEmail: curEmail,
                    dateRaw: curDate,
                    body: bodyStr,
                    depth: depth,
                    sourceMessageId: sourceMessageId,
                    sourceFolder: sourceFolder
                ))
            }
            curBody = []
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Outlook block separator, "-----Original Message-----",
            // OR an implicit "From: ... \n Date/Sent: ..." header block (no underscore).
            let isExplicit = isUnderscoreSeparator(trimmed) || isOriginalMessageMarker(trimmed)
            let isImplicitFromBlock = !isExplicit && isImplicitHeaderStart(lines: lines, at: i)

            if isExplicit || isImplicitFromBlock {
                flush()
                depth += 1
                curAuthor = nil; curEmail = nil; curDate = nil
                if isExplicit {
                    i += 1   // consume the underscore line
                }
                // (For implicit start we leave i where it is — header line itself starts the block)

                while i < lines.count {
                    let hl = lines[i].trimmingCharacters(in: .whitespaces)
                    if hl.isEmpty {
                        i += 1
                        break
                    }
                    if let (n, e) = parseFromHeader(hl) {
                        curAuthor = n; curEmail = e
                    } else if let d = parseDateHeader(hl) {
                        curDate = d
                    } else if isSkippableHeader(hl) {
                        // skip
                    } else {
                        curBody.append(lines[i])
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }

            // Inline wrote-intro: "On ..., X <e@x> wrote:" / "X <e@x> şunları yazdı (...):"
            if isWroteIntro(trimmed),
               let parsed = parseWroteIntro(trimmed) {
                flush()
                depth += 1
                curAuthor = parsed.name
                curEmail = parsed.email
                curDate = parsed.date
                i += 1
                continue
            }

            curBody.append(raw)
            i += 1
        }
        flush()

        return segments
    }

    // MARK: - Pattern helpers

    private static func isUnderscoreSeparator(_ s: String) -> Bool {
        guard s.count >= 15 else { return false }
        return s.allSatisfy { $0 == "_" }
    }

    private static func isOriginalMessageMarker(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.contains("original message") else { return false }
        return lower.contains("---") || lower.contains("___")
    }

    private static let fromHeaderRegex = try! NSRegularExpression(
        pattern: #"^(?:From|Kimden|De|Von|Da):\s*(.+)$"#, options: [.caseInsensitive])
    private static let dateHeaderRegex = try! NSRegularExpression(
        pattern: #"^(?:Sent|Date|Tarih|Gönderildi|Gönderme tarihi|Envoyé|Enviado|Gesendet|Inviato):\s*(.+)$"#,
        options: [.caseInsensitive])
    private static let nameAddrRegex = try! NSRegularExpression(
        pattern: #"^([^<]+?)\s*<\s*([^>\s]+@[^>\s]+)\s*>\s*$"#, options: [])
    private static let anyEmailRegex = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])

    private static func isSkippableHeader(_ s: String) -> Bool {
        let lower = s.lowercased()
        let skipPrefixes = [
            "to:", "kime:", "à:", "para:", "an:", "a:",
            "cc:", "bilgi:",
            "bcc:", "gizli:",
            "subject:", "konu:", "objet:", "asunto:", "betreff:", "oggetto:",
            "importance:", "önem:", "priorité:",
            "reply-to:", "yanıt:"
        ]
        for p in skipPrefixes where lower.hasPrefix(p) { return true }
        return false
    }

    /// Heuristic: is this line the start of an implicit header block (From: + Date/Subject within the next few lines)?
    private static func isImplicitHeaderStart(lines: [String], at i: Int) -> Bool {
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        let fromTokens = ["from:", "kimden:", "de:", "von:", "da:"]
        guard fromTokens.contains(where: { lower.hasPrefix($0) }) else { return false }
        // Need parseable name<email> on the From: line itself
        guard parseFromHeader(line) != nil else { return false }
        // Look at the next 1..4 lines for a Date/Sent/Subject sibling header
        let lookAhead = min(i + 5, lines.count)
        var siblingsFound = 0
        if i + 1 < lookAhead {
            for j in (i+1)..<lookAhead {
                let n = lines[j].trimmingCharacters(in: .whitespaces).lowercased()
                if n.isEmpty { break }
                let dateTokens = ["sent:", "date:", "tarih:", "gönderildi:",
                                  "envoyé:", "enviado:", "gesendet:"]
                let subjTokens = ["subject:", "konu:", "objet:", "asunto:", "betreff:"]
                if dateTokens.contains(where: { n.hasPrefix($0) }) ||
                   subjTokens.contains(where: { n.hasPrefix($0) }) {
                    siblingsFound += 1
                }
            }
        }
        return siblingsFound >= 1
    }

    private static func parseFromHeader(_ s: String) -> (String, String)? {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = fromHeaderRegex.firstMatch(in: s, range: r),
              let g = Range(m.range(at: 1), in: s) else { return nil }
        let value = String(s[g]).trimmingCharacters(in: .whitespaces)

        // Strategy: pick the first email address, treat everything before it as
        // the display name, strip "<", ">" and "mailto:" leftovers (Outlook for
        // Mac duplicates "<email> <mailto:email>" in plain-text bodies).
        let valueR = NSRange(value.startIndex..., in: value)
        if let em = anyEmailRegex.firstMatch(in: value, range: valueR),
           let emRange = Range(em.range, in: value) {
            let email = String(value[emRange])
            var name = String(value[..<emRange.lowerBound])
            name = name.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            name = name.replacingOccurrences(of: "<", with: "")
            name = name.replacingOccurrences(of: ">", with: "")
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, email)
        }
        // No email at all — fall back to the raw value as name.
        return (value, "")
    }

    private static func parseDateHeader(_ s: String) -> String? {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = dateHeaderRegex.firstMatch(in: s, range: r),
              let g = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[g]).trimmingCharacters(in: .whitespaces)
    }

    /// Quick filter: line might be a wrote-intro?
    private static func isWroteIntro(_ s: String) -> Bool {
        guard s.count >= 12, s.count <= 300 else { return false }
        // Trim a trailing space before ":" — common in French ("a écrit :")
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower.hasSuffix(":") else { return false }
        let mentions = lower.contains("wrote")
                     || lower.contains("şunları yazdı")
                     || lower.contains("sunlari yazdi")
                     || lower.contains("a écrit")
                     || lower.contains("a ecrit")
                     || lower.contains("escribió")
                     || lower.contains("escribio")
                     || lower.contains("schrieb")
                     || lower.contains("ha scritto")
        return mentions && (s.contains("@") || s.contains("("))
    }

    private static let wroteIntroRegex = try! NSRegularExpression(
        // Captures:
        // 1) optional preceding "On <stuff>," / "Le <stuff>," date hint
        // 2) name (before <email>)
        // 3) email
        // 4) optional parenthetical date "(30 Nis 2026 17:13)"
        pattern: #"^(?:(?:On|Le|El|Am|Il)\s+(.+?),\s+)?([^<]+?)\s*<\s*([^>\s]+@[^>\s]+)\s*>\s*(?:şunları\s+yazdı|sunlari\s+yazdi|wrote|a\s+écrit|a\s+ecrit|escribió|escribio|schrieb|ha\s+scritto)\s*(?:\((.+?)\))?\s*:?\s*$"#,
        options: [.caseInsensitive])

    private static func parseWroteIntro(_ s: String) -> (name: String, email: String, date: String?)? {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = wroteIntroRegex.firstMatch(in: s, range: r) else { return nil }

        let leadingDate = Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? ""
        let name = Range(m.range(at: 2), in: s)
            .map { String(s[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        let email = Range(m.range(at: 3), in: s).map { String(s[$0]) } ?? ""
        let parenDate = Range(m.range(at: 4), in: s)
            .map { String(s[$0]).trimmingCharacters(in: .whitespaces) } ?? ""

        let date: String? = {
            let combined = !parenDate.isEmpty ? parenDate : leadingDate
            return combined.isEmpty ? nil : combined
        }()
        return (name, email, date)
    }
}
