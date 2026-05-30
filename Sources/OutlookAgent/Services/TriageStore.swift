import Foundation
import SwiftUI
import Observation

/// Disk-backed cache for AI triage results. Keyed by Outlook message id.
/// Stored at ~/Library/Application Support/OutlookAgent/triage.json
@MainActor
@Observable
final class TriageStore {
    private(set) var map: [String: TriageResult] = [:]

    private let fileURL: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("triage.json")
    }()

    init() { loadFromDisk() }

    subscript(id: String) -> TriageResult? {
        get { map[id] }
    }

    func has(_ id: String) -> Bool { map[id] != nil }

    func merge(_ newResults: [String: TriageResult]) {
        guard !newResults.isEmpty else { return }
        map.merge(newResults) { _, new in new }
        persist()
    }

    func remove(_ id: String) {
        guard map[id] != nil else { return }
        map.removeValue(forKey: id)
        persist()
    }

    func clear() {
        map = [:]
        persist()
    }

    /// Filter inbox to only those mails not yet triaged.
    func untriaged(_ inbox: [EmailSummary]) -> [EmailSummary] {
        inbox.filter { map[$0.id] == nil }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let dict = try? JSONDecoder().decode([String: TriageResult].self, from: data) {
            map = dict
        }
    }

    private func persist() {
        let snapshot = map
        let url = fileURL
        Task.detached(priority: .background) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            guard let data = try? enc.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
