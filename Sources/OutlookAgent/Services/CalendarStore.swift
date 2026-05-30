import Foundation
import SwiftUI
import Observation

/// In-memory + disk-cached calendar store. Persists the most recent fetch
/// at ~/Library/Application Support/OutlookAgent/calendar.json so the UI
/// has something to show before the AppleScript bridge replies.
@MainActor
@Observable
final class CalendarStore {
    private(set) var events: [CalendarEvent] = []
    /// Pipeline / domain enrichment results, keyed by event id.
    /// Cached separately so we don't re-call Claude every refresh.
    private(set) var enrichment: [String: EventEnrichment] = [:]
    /// Manual "focus / hold" placeholders (created via 'Focus block koy').
    /// Persisted so they survive relaunches; rendered alongside Outlook events.
    private(set) var focusBlocks: [FocusBlock] = []

    var lastFetchedAt: Date?

    private let eventsURL: URL
    private let enrichmentURL: URL
    private let focusURL: URL

    struct EventEnrichment: Codable, Hashable {
        var pipelineStage: CalendarEvent.PipelineStage?
        var pipelineConfidence: Double?
        var primaryDomain: String?
        var preparationBrief: String?      // "Hazırlık asistanı" output
        var briefGeneratedAt: Date?
    }

    struct FocusBlock: Identifiable, Codable, Hashable {
        let id: String
        var subject: String
        var startRaw: String
        var endRaw: String
        var notes: String

        var startDate: Date? { DateUtil.parse(startRaw) }
        var endDate: Date?   { DateUtil.parse(endRaw) }
    }

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.eventsURL     = dir.appendingPathComponent("calendar.json")
        self.enrichmentURL = dir.appendingPathComponent("calendar_enrichment.json")
        self.focusURL      = dir.appendingPathComponent("calendar_focus.json")
        loadFromDisk()
    }

    // MARK: - Replace / Merge

    /// Replace the in-memory event set; preserves enrichment overlay.
    func replaceEvents(_ fresh: [CalendarEvent]) {
        var merged = fresh
        // Apply cached enrichment so view sees pipeline tags immediately.
        for i in merged.indices {
            if let e = enrichment[merged[i].id] {
                merged[i].pipelineStage = e.pipelineStage
                merged[i].pipelineConfidence = e.pipelineConfidence
                merged[i].primaryDomain = e.primaryDomain
            }
        }
        self.events = merged
        self.lastFetchedAt = Date()
        persistEvents()
    }

    func setEnrichment(_ enr: EventEnrichment, for id: String) {
        enrichment[id] = enr
        if let i = events.firstIndex(where: { $0.id == id }) {
            events[i].pipelineStage = enr.pipelineStage
            events[i].pipelineConfidence = enr.pipelineConfidence
            events[i].primaryDomain = enr.primaryDomain
        }
        persistEnrichment()
    }

    func updateBrief(_ text: String, for id: String) {
        var enr = enrichment[id] ?? EventEnrichment()
        enr.preparationBrief = text
        enr.briefGeneratedAt = Date()
        enrichment[id] = enr
        persistEnrichment()
    }

    // MARK: - Focus blocks

    func addFocusBlock(_ block: FocusBlock) {
        focusBlocks.append(block)
        persistFocus()
    }

    func removeFocusBlock(id: String) {
        focusBlocks.removeAll { $0.id == id }
        persistFocus()
    }

    // MARK: - Queries

    func event(id: String) -> CalendarEvent? {
        events.first { $0.id == id }
    }

    /// Combined feed: outlook events + focus blocks (as synthetic events).
    var combinedFeed: [CalendarEvent] {
        let synthetic: [CalendarEvent] = focusBlocks.map { fb in
            CalendarEvent(
                id: "focus:" + fb.id,
                calendarName: "Focus / Hold",
                subject: fb.subject,
                startRaw: fb.startRaw,
                endRaw: fb.endRaw,
                isAllDay: false,
                location: "",
                organizerName: AgoraContext.userName,
                organizerEmail: AgoraContext.userEmail,
                requiredAttendees: [],
                optionalAttendees: [],
                ownResponse: .organizer,
                body: fb.notes,
                hasReminder: false,
                isRecurring: false,
                conferenceUrl: nil,
                conferenceType: nil,
                pipelineStage: .focus,
                pipelineConfidence: 1.0,
                primaryDomain: nil
            )
        }
        return (events + synthetic).sorted { (a, b) in
            DateUtil.sortKey(a.startRaw) < DateUtil.sortKey(b.startRaw)
        }
    }

    /// Events occurring on the given day (start time within day boundaries).
    func eventsOn(_ day: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let startOfDay = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        return combinedFeed.filter { ev in
            guard let s = ev.startDate else { return false }
            return s >= startOfDay && s < endOfDay
        }
    }

    /// Events whose [start, end] overlaps the [from, to] range at all.
    func eventsBetween(_ from: Date, _ to: Date) -> [CalendarEvent] {
        combinedFeed.filter { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return false }
            return s < to && e > from
        }
    }

    // MARK: - Conflicts

    /// Pairwise conflicts inside the given list (ignoring all-day events).
    func conflicts(in evts: [CalendarEvent]) -> Set<String> {
        var conflicting = Set<String>()
        let sorted = evts
            .filter { !$0.isAllDay }
            .sorted { (a, b) in DateUtil.sortKey(a.startRaw) < DateUtil.sortKey(b.startRaw) }
        for i in 0..<sorted.count {
            guard let aS = sorted[i].startDate, let aE = sorted[i].endDate else { continue }
            for j in (i + 1)..<sorted.count {
                guard let bS = sorted[j].startDate, let bE = sorted[j].endDate else { continue }
                if bS >= aE { break }   // sorted by start, no further overlap possible
                if aS < bE && bS < aE {
                    conflicting.insert(sorted[i].id)
                    conflicting.insert(sorted[j].id)
                }
            }
        }
        return conflicting
    }

    // MARK: - Free slots

    /// Slot search inside [from, to], honoring working hours (in `calendar.timeZone`).
    /// Returns slots of at least `minMinutes`. Excludes all-day events.
    func freeSlots(
        from: Date,
        to: Date,
        workingHourStart: Int = 9,
        workingHourEnd: Int = 18,
        minMinutes: Int = 30,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [DateInterval] {
        var cal = calendar
        cal.timeZone = .current

        // Build "busy" intervals for non-all-day events.
        let busy: [DateInterval] = combinedFeed.compactMap { ev in
            guard !ev.isAllDay,
                  let s = ev.startDate, let e = ev.endDate,
                  s < to && e > from else { return nil }
            let clipped = DateInterval(
                start: max(s, from),
                end: min(e, to)
            )
            return clipped.duration > 0 ? clipped : nil
        }.sorted { $0.start < $1.start }

        // Iterate over working windows day by day.
        var slots: [DateInterval] = []
        var dayStart = cal.startOfDay(for: from)
        while dayStart < to {
            guard let workStart = cal.date(bySettingHour: workingHourStart, minute: 0, second: 0, of: dayStart),
                  let workEnd   = cal.date(bySettingHour: workingHourEnd,   minute: 0, second: 0, of: dayStart),
                  workStart < workEnd else {
                dayStart = cal.date(byAdding: .day, value: 1, to: dayStart) ?? to
                continue
            }
            // Skip weekends (Sat=7, Sun=1 in Gregorian — but tr_TR has Mon-first).
            // Simpler: skip if isDateInWeekend.
            if cal.isDateInWeekend(dayStart) {
                dayStart = cal.date(byAdding: .day, value: 1, to: dayStart) ?? to
                continue
            }

            let win = DateInterval(start: max(workStart, from), end: min(workEnd, to))
            if win.duration <= 0 {
                dayStart = cal.date(byAdding: .day, value: 1, to: dayStart) ?? to
                continue
            }

            // Subtract busy intervals from this window.
            var cursor = win.start
            for b in busy where b.intersects(win) {
                if b.start > cursor {
                    let slot = DateInterval(start: cursor, end: min(b.start, win.end))
                    if slot.duration / 60.0 >= Double(minMinutes) { slots.append(slot) }
                }
                cursor = max(cursor, b.end)
                if cursor >= win.end { break }
            }
            if cursor < win.end {
                let slot = DateInterval(start: cursor, end: win.end)
                if slot.duration / 60.0 >= Double(minMinutes) { slots.append(slot) }
            }

            dayStart = cal.date(byAdding: .day, value: 1, to: dayStart) ?? to
        }
        return slots
    }

    // MARK: - Persistence

    private func persistEvents() {
        let snapshot = events
        let url = eventsURL
        Task.detached(priority: .background) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func persistEnrichment() {
        let snapshot = enrichment
        let url = enrichmentURL
        Task.detached(priority: .background) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func persistFocus() {
        let snapshot = focusBlocks
        let url = focusURL
        Task.detached(priority: .background) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadFromDisk() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: eventsURL),
           let arr = try? dec.decode([CalendarEvent].self, from: data) {
            self.events = arr
        }
        if let data = try? Data(contentsOf: enrichmentURL),
           let dict = try? dec.decode([String: EventEnrichment].self, from: data) {
            self.enrichment = dict
        }
        if let data = try? Data(contentsOf: focusURL),
           let arr = try? dec.decode([FocusBlock].self, from: data) {
            self.focusBlocks = arr
        }
    }
}
