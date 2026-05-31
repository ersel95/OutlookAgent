import Foundation

struct EmailSummary: Identifiable, Hashable, Codable {
    let id: String
    var isRead: Bool
    var date: String
    var fromName: String
    var fromAddress: String
    var subject: String
    var preview: String
    var hasAttachments: Bool
    /// Outlook account id (string). Multi-account inbox iterate edildiğinde
    /// her mail hangi hesabın inbox'ından geldiyse onu taşır.
    var accountId: String? = nil
    var accountName: String? = nil

    var displaySender: String {
        fromName.isEmpty ? fromAddress : fromName
    }
}

struct EmailFull: Identifiable, Hashable, Codable {
    let id: String
    var isRead: Bool
    var date: String
    var fromName: String
    var fromAddress: String
    var toAddresses: [String]
    var ccAddresses: [String]
    var subject: String
    var body: String
    var hasAttachments: Bool
    var attachmentNames: [String]
    var conversationId: String?
    var attachmentPaths: [String: String] = [:]   // filename → cached local path
    var accountId: String? = nil
    var accountName: String? = nil
}

/// Single message inside a conversation thread.
struct ThreadMessage: Identifiable, Hashable, Codable {
    let id: String                  // Outlook message id
    var folder: String              // "inbox" | "sent items" | "drafts" | "other"
    var date: String                // raw AppleScript date
    var sortKey: TimeInterval       // parsed for ordering
    var fromName: String
    var fromAddress: String
    var toAddresses: [String]
    var ccAddresses: [String]
    var subject: String
    var body: String
    var isRead: Bool
    var hasAttachments: Bool
    var attachmentNames: [String]
    var attachmentPaths: [String: String] = [:]   // filename → cached local path (image attachments)
    var accountId: String? = nil
    var accountName: String? = nil

    /// Treat as "outgoing" (your message) when folder is sent or you authored it.
    var isOutgoing: Bool {
        folder.lowercased().contains("sent") ||
        folder.lowercased().contains("drafts") ||
        fromAddress.caseInsensitiveCompare(AgoraContext.userEmail) == .orderedSame
    }

    var displaySender: String {
        fromName.isEmpty ? fromAddress : fromName
    }
}

struct EmailThread: Identifiable, Hashable {
    let id: String                  // conversation id
    var subject: String
    var messages: [ThreadMessage]   // chronological (oldest first)

    /// Unique participants across the whole thread, by lowercased address.
    var participants: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in messages {
            let addr = m.fromAddress.lowercased()
            if !addr.isEmpty, !seen.contains(addr) {
                seen.insert(addr); out.append(m.fromAddress)
            }
        }
        return out
    }
}
