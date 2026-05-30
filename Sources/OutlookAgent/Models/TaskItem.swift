import Foundation
import SwiftUI

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case todo    = "Yapılacak"
    case doing   = "Devam Ediyor"
    case blocked = "Engelli"
    case done    = "Tamamlandı"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .todo:    return "circle"
        case .doing:   return "play.circle"
        case .blocked: return "exclamationmark.octagon"
        case .done:    return "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .todo:    return .secondary
        case .doing:   return .blue
        case .blocked: return .orange
        case .done:    return .green
        }
    }
    var sortOrder: Int {
        switch self {
        case .doing:   return 0
        case .todo:    return 1
        case .blocked: return 2
        case .done:    return 3
        }
    }
}

enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case urgent = "Acil"
    case high   = "Yüksek"
    case normal = "Normal"
    case low    = "Düşük"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .urgent: return .red
        case .high:   return .orange
        case .normal: return .blue
        case .low:    return .gray
        }
    }
    var sortOrder: Int {
        switch self {
        case .urgent: return 0
        case .high:   return 1
        case .normal: return 2
        case .low:    return 3
        }
    }
}

struct TaskItem: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var notes: String

    var status: TaskStatus
    var priority: TaskPriority

    var dueDate: Date?
    var dueHint: String?

    // Context
    var account: String?         // örn. "Acme Corp" veya domain'den çıkarılan
    var contactEmail: String?
    var contactName: String?
    var category: String?        // TriageCategory.rawValue (string olarak)

    // Source
    var sourceEmailId: String?
    var sourceSubject: String?

    // Timestamps
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    // Free-form
    var tags: [String]

    init(id: UUID = UUID(),
         title: String,
         notes: String = "",
         status: TaskStatus = .todo,
         priority: TaskPriority = .normal,
         dueDate: Date? = nil,
         dueHint: String? = nil,
         account: String? = nil,
         contactEmail: String? = nil,
         contactName: String? = nil,
         category: String? = nil,
         sourceEmailId: String? = nil,
         sourceSubject: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         completedAt: Date? = nil,
         tags: [String] = []) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.dueHint = dueHint
        self.account = account
        self.contactEmail = contactEmail
        self.contactName = contactName
        self.category = category
        self.sourceEmailId = sourceEmailId
        self.sourceSubject = sourceSubject
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.tags = tags
    }

    var isOverdue: Bool {
        guard let d = dueDate, status != .done else { return false }
        return d < Date()
    }

    var dedupeKey: String {
        "\(sourceEmailId ?? "manual")|\(title.lowercased())"
    }
}
