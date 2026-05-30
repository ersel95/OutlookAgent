import Foundation
import SwiftUI
import Observation

/// Persistent store for TaskItem. JSON-backed in
/// ~/Library/Application Support/OutlookAgent/tasks.json
@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [TaskItem] = []

    private let fileURL: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }()

    init() {
        loadFromDisk()
    }

    // MARK: - CRUD

    func add(_ task: TaskItem) {
        tasks.append(task)
        persist()
    }

    func update(_ task: TaskItem) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var t = task
        t.updatedAt = Date()
        tasks[idx] = t
        persist()
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    func setStatus(_ id: UUID, _ status: TaskStatus) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = status
        tasks[idx].updatedAt = Date()
        if status == .done {
            tasks[idx].completedAt = Date()
        } else if tasks[idx].completedAt != nil {
            tasks[idx].completedAt = nil
        }
        persist()
    }

    func setPriority(_ id: UUID, _ priority: TaskPriority) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].priority = priority
        tasks[idx].updatedAt = Date()
        persist()
    }

    /// Bulk-ingest AI-extracted items, deduping on (sourceEmailId | title).
    func ingest(_ items: [TaskItem]) -> Int {
        let existing = Set(tasks.map { $0.dedupeKey })
        var added = 0
        for item in items {
            if !existing.contains(item.dedupeKey) {
                tasks.append(item)
                added += 1
            }
        }
        if added > 0 { persist() }
        return added
    }

    // MARK: - Queries

    func tasks(for emailId: String) -> [TaskItem] {
        tasks.filter { $0.sourceEmailId == emailId }
    }

    var pendingCount: Int {
        tasks.filter { $0.status != .done }.count
    }

    var accounts: [String] {
        Array(Set(tasks.compactMap { $0.account?.isEmpty == false ? $0.account : nil })).sorted()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let arr = try? dec.decode([TaskItem].self, from: data) {
            tasks = arr
        }
    }

    private func persist() {
        let snapshot = tasks
        let url = fileURL
        Task.detached(priority: .background) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
