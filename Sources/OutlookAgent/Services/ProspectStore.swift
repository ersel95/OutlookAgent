import Foundation
import SwiftUI
import Observation

/// JSON-backed persistent store for prospects (~/Library/Application Support/OutlookAgent/prospects.json).
@MainActor
@Observable
final class ProspectStore {
    private(set) var prospects: [Prospect] = []

    private let fileURL: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prospects.json")
    }()

    init() {
        loadFromDisk()
    }

    // MARK: - CRUD

    func add(_ p: Prospect) {
        prospects.append(p)
        persist()
    }

    /// Bulk-ingest. Dedup mevcut kayıtların `domain`'i üzerinden yapılır.
    /// Geri dönüş: (eklenen, aktif duplicate, soft-deleted duplicate).
    /// **Soft-deleted** prospect'leri yeniden eklemez — kullanıcı zaten reddetmiş.
    @discardableResult
    func ingest(_ items: [Prospect]) -> (added: Int, dupActive: Int, dupDeleted: Int) {
        var added = 0
        var dupActive = 0
        var dupDeleted = 0
        for item in items {
            if let ex = prospects.first(where: { $0.dedupeKey == item.dedupeKey }) {
                if ex.isDeleted { dupDeleted += 1 } else { dupActive += 1 }
            } else {
                prospects.append(item)
                added += 1
            }
        }
        if added > 0 { persist() }
        return (added, dupActive, dupDeleted)
    }

    func update(_ p: Prospect) {
        guard let idx = prospects.firstIndex(where: { $0.id == p.id }) else { return }
        var copy = p
        copy.updatedAt = Date()
        prospects[idx] = copy
        persist()
    }

    /// Tamamen sil (kalıcı, geri dönüş yok). UI'da onay sonrası kullanılır.
    func hardDelete(_ id: UUID) {
        prospects.removeAll { $0.id == id }
        persist()
    }

    /// Soft delete — kayıt durur, ileride aynı domain'i AI keşfederse yeniden
    /// eklenmez. Restore ile geri alınabilir.
    func softDelete(_ id: UUID, reason: String) {
        guard let i = prospects.firstIndex(where: { $0.id == id }) else { return }
        prospects[i].deletedAt = Date()
        prospects[i].deletionReason = reason
        prospects[i].updatedAt = Date()
        persist()
    }

    func restore(_ id: UUID) {
        guard let i = prospects.firstIndex(where: { $0.id == id }) else { return }
        prospects[i].deletedAt = nil
        prospects[i].deletionReason = nil
        prospects[i].updatedAt = Date()
        persist()
    }

    // MARK: - State transitions

    func setStatus(_ id: UUID, _ status: ProspectStatus) {
        guard let i = prospects.firstIndex(where: { $0.id == id }) else { return }
        prospects[i].status = status
        prospects[i].updatedAt = Date()
        persist()
    }

    func setDedup(_ id: UUID, _ result: DedupResult) {
        guard let i = prospects.firstIndex(where: { $0.id == id }) else { return }
        prospects[i].dedup = result
        prospects[i].queue = result.decision.queue
        prospects[i].status = result.decision.shouldSequence ? .matched : .excluded
        prospects[i].updatedAt = Date()
        persist()
    }

    func setScore(_ id: UUID, _ score: ProspectScore) {
        guard let i = prospects.firstIndex(where: { $0.id == id }) else { return }
        prospects[i].score = score
        if prospects[i].status == .matched {
            prospects[i].status = .scored
        }
        prospects[i].updatedAt = Date()
        persist()
    }

    func setSequence(_ id: UUID, _ steps: [SequenceStep]) {
        guard let i = prospects.firstIndex(where: { $0.id == id }) else { return }
        prospects[i].sequenceSteps = steps
        prospects[i].currentStepIndex = 0
        if prospects[i].status == .scored || prospects[i].status == .matched {
            prospects[i].status = .drafted
        }
        prospects[i].updatedAt = Date()
        persist()
    }

    func updateStep(prospectId: UUID, stepId: UUID, mutate: (inout SequenceStep) -> Void) {
        guard let i = prospects.firstIndex(where: { $0.id == prospectId }),
              let j = prospects[i].sequenceSteps.firstIndex(where: { $0.id == stepId }) else { return }
        mutate(&prospects[i].sequenceSteps[j])
        prospects[i].updatedAt = Date()
        recomputeStatus(at: i)
        persist()
    }

    /// Tüm pending step'leri approved'a çek (batch approve).
    func approveAll(prospectId: UUID) {
        guard let i = prospects.firstIndex(where: { $0.id == prospectId }) else { return }
        for j in prospects[i].sequenceSteps.indices {
            if prospects[i].sequenceSteps[j].status == .drafted {
                prospects[i].sequenceSteps[j].status = .approved
            }
        }
        if prospects[i].status == .drafted {
            prospects[i].status = .approved
        }
        prospects[i].updatedAt = Date()
        persist()
    }

    func setSalesforceLead(prospectId: UUID, leadId: String, url: String?) {
        guard let i = prospects.firstIndex(where: { $0.id == prospectId }) else { return }
        prospects[i].salesforceLeadId = leadId
        prospects[i].salesforceLeadUrl = url
        prospects[i].updatedAt = Date()
        persist()
    }

    func appendSalesforceTask(prospectId: UUID, taskId: String) {
        guard let i = prospects.firstIndex(where: { $0.id == prospectId }) else { return }
        prospects[i].salesforceTaskIds.append(taskId)
        prospects[i].updatedAt = Date()
        persist()
    }

    /// Step'lere göre prospect statüsünü tekrar hesaplar (sending / completed).
    private func recomputeStatus(at i: Int) {
        let steps = prospects[i].sequenceSteps
        guard !steps.isEmpty else { return }
        let allTerminal = steps.allSatisfy {
            $0.status == .sent || $0.status == .skipped || $0.status == .failed || $0.status == .repliedTo
        }
        let anySent = steps.contains { $0.status == .sent }
        let anyReplied = steps.contains { $0.status == .repliedTo }

        if anyReplied {
            prospects[i].status = .replied
        } else if allTerminal {
            prospects[i].status = .completed
        } else if anySent {
            prospects[i].status = .sending
        }

        // Sıradaki step: ilk pending/drafted/approved
        if let nextIdx = steps.firstIndex(where: {
            $0.status == .pending || $0.status == .drafted || $0.status == .approved
        }) {
            prospects[i].currentStepIndex = nextIdx
        } else {
            prospects[i].currentStepIndex = steps.count
        }
    }

    // MARK: - Queries

    func prospect(id: UUID) -> Prospect? {
        prospects.first { $0.id == id }
    }

    func byDomain(_ domain: String) -> Prospect? {
        let key = domain.lowercased()
        return prospects.first { $0.dedupeKey == key }
    }

    var counts: [ProspectStatus: Int] {
        var d: [ProspectStatus: Int] = [:]
        for p in prospects { d[p.status, default: 0] += 1 }
        return d
    }

    var activeCount: Int {
        prospects.filter {
            !$0.isDeleted
            && $0.status != .excluded
            && $0.status != .completed
            && $0.status != .paused
        }.count
    }

    var deletedCount: Int {
        prospects.filter { $0.isDeleted }.count
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let arr = try? dec.decode([Prospect].self, from: data) {
            prospects = arr
        }
    }

    private func persist() {
        let snapshot = prospects
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
