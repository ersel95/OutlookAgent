import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class AppViewModel {
    // Navigation
    var currentFeature: AppFeature = .inbox

    // Inbox state
    var emails: [EmailSummary] = []
    var triageStore = TriageStore()
    var triageMap: [String: TriageResult] { triageStore.map }
    var inboxLimit: Int = 30
    var unreadOnly: Bool = false           // UI-side filter
    var categoryFilter: TriageCategory?
    var selectedEmailId: String?

    // Thread (for the focused mail)
    var loadedEmail: EmailFull?
    var thread: EmailThread?

    // Workflow flags
    var isLoadingInbox = false
    var isTriaging = false
    var isLoadingEmail = false
    var isLoadingThread = false
    var isDrafting = false
    var isSavingDraft = false
    var draftJustOpened = false   // transient success indicator
    var isExtractingTasks = false

    // Draft + per-mail tasks (transient)
    var draft: DraftSuggestion?
    var draftIntent: String = ""
    var editedDraftBody: String = ""    // user-editable copy of draft.body
    var lastExtractedTasks: [TaskItem] = []

    // Tasks feature state
    var taskStore = TaskStore()
    var selectedTaskId: UUID?
    var taskStatusFilter: TaskStatus?
    var taskAccountFilter: String?
    var taskPriorityFilter: TaskPriority?
    var taskSearchQuery: String = ""

    // Calendar feature state
    var calendarStore = CalendarStore()
    var calendarRange: CalendarRange = .week
    var selectedEventId: String?
    var calendarSearchQuery: String = ""
    var calendarStageFilter: CalendarEvent.PipelineStage?
    var calendarHidePast: Bool = true
    var isLoadingCalendar: Bool = false
    var isClassifyingCalendar: Bool = false
    var isGeneratingBrief: Bool = false
    var briefForEventId: String?
    var draftingInviteFromEmail: EmailFull?
    var inviteSuggestion: InviteSuggestion?
    var isExtractingInvite: Bool = false
    var isCreatingEvent: Bool = false
    var isExtractingMeetingTasks: Bool = false
    var lastInviteAttemptStatus: String?
    var morningBriefMarkdown: String?
    var isGeneratingMorningBrief: Bool = false

    // Prospects feature state
    var prospectStore = ProspectStore()
    var selectedProspectId: UUID?
    var prospectStatusFilter: ProspectStatus?
    var prospectQueueFilter: ProspectQueue?
    var prospectSearchQuery: String = ""
    /// Soft-deleted prospect'leri listede göster (default kapalı).
    var prospectShowDeleted: Bool = false
    var prospectShowImport: Bool = false
    var prospectImportText: String = ""
    var prospectImportError: String?
    var isImportingProspect: Bool = false
    /// Import sheet'in hangi sekmesi aktif: paste / autoDiscover / appStore.
    var prospectImportMode: ProspectImportMode = .autoDiscover
    // Auto-discovery (Claude WebSearch) form state
    var discoveryVertical: String = "Live-Commerce"
    var discoveryCountry: String = "Türkiye"
    var discoveryCount: Int = 10
    // App Store (iTunes Lookup) form state
    var appStoreQuery: String = "live commerce"
    var appStoreCountry: String = "tr"
    var appStoreLimit: Int = 25
    /// Toplu ingest sonrası özet — "8 yeni, 2 zaten kuyrukta".
    var lastImportSummary: String?
    /// Hangi prospect üstünde async bir iş çalışıyor
    /// (dedup / score / draft / send / push / enrich).
    var prospectBusyId: UUID?
    var prospectBusyLabel: String?

    // Email pattern öğrenme + bounce safety
    var emailPatternCache = EmailPatternCache()
    /// Bugün tespit edilen hard bounce sayısı (Outlook inbox poll'undan).
    var dailyBounceCount: Int = 0
    /// Sayacı sıfırlamak için günün başlangıcı.
    var dailyBounceCountDate: Date?
    /// Bu eşik aşılırsa global sending pause edilir (deliverability koruması).
    var dailyBounceLimit: Int = 5
    /// Sender reputation tehlikede olduğunda otomatik true olur — UI banner'la
    /// kullanıcıya gösterilir, send akışı block edilir.
    var globalSendingPaused: Bool = false

    /// Yüksek öncelikli AI çağrısı aktif mi (discovery / score / draft / enrich).
    /// Background görevler (autoTriage, autoClassify) batch arası bunu kontrol
    /// edip bekler — Anthropic API rate limit'ini paylaşmayalım.
    var aiHighPriorityBusy: Bool = false

    enum ProspectImportMode: String, CaseIterable, Identifiable {
        case paste, autoDiscover, appStore
        var id: String { rawValue }
        var label: String {
            switch self {
            case .paste:        return "Yapıştır"
            case .autoDiscover: return "Otomatik Keşif"
            case .appStore:     return "App Store"
            }
        }
        var systemImage: String {
            switch self {
            case .paste:        return "doc.on.clipboard"
            case .autoDiscover: return "globe"
            case .appStore:     return "iphone"
            }
        }
    }

    enum CalendarRange: String, CaseIterable, Identifiable {
        case today, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return "Bugün"
            case .week:  return "Bu Hafta"
            case .month: return "30 Gün"
            }
        }
        /// (startOffset, endOffset) in days from today.
        var dayOffsets: (Int, Int) {
            switch self {
            case .today: return (0, 0)
            case .week:  return (-1, 7)   // include yesterday for context
            case .month: return (-1, 30)
            }
        }
    }

    // Errors
    var errorMessage: String?

    private let outlook = OutlookService.shared
    private let claude  = ClaudeService.shared

    // MARK: - Inbox

    func refreshInbox() async {
        isLoadingInbox = true
        errorMessage = nil
        let limit = inboxLimit
        do {
            let list = try await outlook.listInbox(limit: limit, unreadOnly: false)
            emails = list
            isLoadingInbox = false
            // auto-triage in background — never blocks UI
            Task { await autoTriage() }
            // Prospect reply detection — fromAddress eşleşmesiyle background.
            Task { await linkInboxRepliesToProspects() }
            // Bounce detection — postmaster mail'lerinden hard fail tespit.
            Task { await detectBouncesInInbox() }
        } catch {
            isLoadingInbox = false
            errorMessage = error.localizedDescription
        }
    }

    private func autoTriage() async {
        // Only triage emails not already in disk cache
        let pending = triageStore.untriaged(emails)
        guard !pending.isEmpty else { return }
        isTriaging = true
        defer { isTriaging = false }
        let batchSize = 10
        for chunk in stride(from: 0, to: pending.count, by: batchSize) {
            // Yüksek öncelikli AI çağrısı varsa (discovery/score/draft) batch arası bekle.
            while aiHighPriorityBusy {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let end = min(chunk + batchSize, pending.count)
            let batch = Array(pending[chunk..<end])
            do {
                let result = try await claude.triage(emails: batch)
                triageStore.merge(result)
            } catch {
                errorMessage = "Triage hatası: \(error.localizedDescription)"
                return
            }
        }
    }

    // MARK: - Filters

    var visibleEmails: [EmailSummary] {
        var out = emails
        if unreadOnly {
            out = out.filter { !$0.isRead }
        }
        if let cat = categoryFilter {
            out = out.filter { triageMap[$0.id]?.category == cat }
        }
        return out
    }

    // MARK: - Email focus + Thread

    func selectEmail(_ id: String) async {
        selectedEmailId = id
        loadedEmail = nil
        thread = nil
        draft = nil
        editedDraftBody = ""
        lastExtractedTasks = []
        isLoadingEmail = true
        defer { isLoadingEmail = false }   // stays true through thread fetch — no "yüklenemedi" flash
        do {
            let full = try await outlook.readEmail(id: id)
            loadedEmail = full
            if let convId = full.conversationId, !convId.isEmpty {
                await loadThread(conversationId: convId, fallbackEmail: full)
            } else {
                thread = EmailThread(
                    id: full.id,
                    subject: full.subject,
                    messages: [Self.threadMessage(from: full)]
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadThread(conversationId: String, fallbackEmail: EmailFull) async {
        isLoadingThread = true
        defer { isLoadingThread = false }
        do {
            let key = Self.normalizeSubjectKey(fallbackEmail.subject)
            let msgs = try await outlook.listThread(conversationId: conversationId, subjectKey: key)
            if msgs.isEmpty {
                thread = EmailThread(
                    id: conversationId,
                    subject: fallbackEmail.subject,
                    messages: [Self.threadMessage(from: fallbackEmail)]
                )
            } else {
                thread = EmailThread(
                    id: conversationId,
                    subject: msgs.first?.subject ?? fallbackEmail.subject,
                    messages: msgs
                )
            }
        } catch {
            thread = EmailThread(
                id: conversationId,
                subject: fallbackEmail.subject,
                messages: [Self.threadMessage(from: fallbackEmail)]
            )
        }
    }

    private static func normalizeSubjectKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "re :", "fw:", "fwd:", "fw :", "fwd :",
                        "yanıtla:", "yanit:", "ilet:", "ilt:", "iletilen:"]
        var dropped = true
        while dropped {
            dropped = false
            let lower = t.lowercased()
            for p in prefixes {
                if lower.hasPrefix(p) {
                    t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                    dropped = true
                    break
                }
            }
        }
        return t
    }

    private static func threadMessage(from f: EmailFull) -> ThreadMessage {
        ThreadMessage(
            id: f.id,
            folder: "inbox",
            date: f.date,
            sortKey: 0,
            fromName: f.fromName,
            fromAddress: f.fromAddress,
            toAddresses: f.toAddresses,
            ccAddresses: f.ccAddresses,
            subject: f.subject,
            body: f.body,
            isRead: f.isRead,
            hasAttachments: f.hasAttachments,
            attachmentNames: f.attachmentNames
        )
    }

    // MARK: - Draft

    func generateDraft() async {
        guard let email = loadedEmail else { return }
        isDrafting = true
        defer { isDrafting = false }
        do {
            let intent = draftIntent.isEmpty ? nil : draftIntent
            let suggestion = try await claude.generateDraft(for: email, userIntent: intent)
            draft = suggestion
            editedDraftBody = suggestion.body
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetDraftEdits() {
        editedDraftBody = draft?.body ?? ""
    }

    func saveDraftToOutlook(replyAll: Bool) async {
        guard let email = loadedEmail else { return }
        let bodyToSend = editedDraftBody.isEmpty ? (draft?.body ?? "") : editedDraftBody
        guard !bodyToSend.isEmpty else { return }
        isSavingDraft = true
        defer { isSavingDraft = false }
        do {
            try await outlook.createDraftReply(
                messageId: email.id, body: bodyToSend, replyAll: replyAll
            )
            draftJustOpened = true
            // Auto-clear the success badge after a moment
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.draftJustOpened = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mark read / Delete

    func markCurrentRead() async {
        guard let email = loadedEmail else { return }
        do {
            try await outlook.markRead(messageId: email.id, read: true)
            if let idx = emails.firstIndex(where: { $0.id == email.id }) {
                emails[idx].isRead = true
            }
            loadedEmail?.isRead = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteEmail(id: String) async {
        do {
            try await outlook.deleteEmail(messageId: id)
            emails.removeAll { $0.id == id }
            triageStore.remove(id)
            if selectedEmailId == id {
                selectedEmailId = nil
                loadedEmail = nil
                thread = nil
                draft = nil
                lastExtractedTasks = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Tasks

    func extractTasksFromCurrentEmail() async {
        guard let email = loadedEmail else { return }
        isExtractingTasks = true
        defer { isExtractingTasks = false }
        do {
            let items = try await claude.extractTasks(from: email)
            // Inherit triage category if available
            let cat = triageMap[email.id]?.category.rawValue
            let stamped = items.map { item -> TaskItem in
                var t = item
                t.category = cat
                return t
            }
            lastExtractedTasks = stamped
            _ = taskStore.ingest(stamped)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addManualTask(_ task: TaskItem) {
        taskStore.add(task)
    }

    func openTaskSource(_ task: TaskItem) async {
        guard let emailId = task.sourceEmailId else { return }
        currentFeature = .inbox
        // If the email is in the current visible inbox, just select it
        if emails.contains(where: { $0.id == emailId }) {
            await selectEmail(emailId)
        } else {
            // Try to load it directly (it might be older than current limit)
            do {
                let full = try await outlook.readEmail(id: emailId)
                loadedEmail = full
                selectedEmailId = emailId
                if let conv = full.conversationId, !conv.isEmpty {
                    await loadThread(conversationId: conv, fallbackEmail: full)
                } else {
                    thread = EmailThread(
                        id: full.id, subject: full.subject,
                        messages: [Self.threadMessage(from: full)]
                    )
                }
            } catch {
                errorMessage = "Kaynak mail yüklenemedi: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Filtered tasks

    var filteredTasks: [TaskItem] {
        var out = taskStore.tasks
        if let s = taskStatusFilter {
            out = out.filter { $0.status == s }
        }
        if let p = taskPriorityFilter {
            out = out.filter { $0.priority == p }
        }
        if let a = taskAccountFilter {
            out = out.filter { $0.account == a }
        }
        let q = taskSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter {
                $0.title.lowercased().contains(q) ||
                ($0.notes.lowercased().contains(q)) ||
                ($0.account?.lowercased().contains(q) ?? false) ||
                ($0.contactEmail?.lowercased().contains(q) ?? false)
            }
        }
        // Sort by status then priority then due/createdAt
        out.sort { a, b in
            if a.status.sortOrder != b.status.sortOrder { return a.status.sortOrder < b.status.sortOrder }
            if a.priority.sortOrder != b.priority.sortOrder { return a.priority.sortOrder < b.priority.sortOrder }
            switch (a.dueDate, b.dueDate) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.createdAt > b.createdAt
            }
        }
        return out
    }

    var selectedTask: TaskItem? {
        guard let id = selectedTaskId else { return nil }
        return taskStore.tasks.first { $0.id == id }
    }

    // MARK: - Calendar

    /// Pull events from Outlook for the current range and refresh enrichment.
    func refreshCalendar() async {
        let (s, e) = calendarRange.dayOffsets
        isLoadingCalendar = true
        defer { isLoadingCalendar = false }
        do {
            let evts = try await outlook.listCalendarEvents(startOffsetDays: s, endOffsetDays: e)
            calendarStore.replaceEvents(evts)
            // Auto-classify new events in background.
            Task { await autoClassifyCalendar() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func autoClassifyCalendar() async {
        let pending = calendarStore.events.filter { calendarStore.enrichment[$0.id] == nil }
        guard !pending.isEmpty else { return }
        isClassifyingCalendar = true
        defer { isClassifyingCalendar = false }
        // Process in batches of 10 to fit token budgets.
        let chunkSize = 10
        for i in stride(from: 0, to: pending.count, by: chunkSize) {
            while aiHighPriorityBusy {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let end = min(i + chunkSize, pending.count)
            let batch = Array(pending[i..<end])
            do {
                let result = try await claude.classifyMeetings(batch)
                for (id, enr) in result {
                    calendarStore.setEnrichment(enr, for: id)
                }
            } catch {
                errorMessage = "Toplantı sınıflandırma hatası: \(error.localizedDescription)"
                return
            }
        }
    }

    func selectEvent(_ id: String?) {
        selectedEventId = id
    }

    var selectedEvent: CalendarEvent? {
        guard let id = selectedEventId else { return nil }
        return calendarStore.combinedFeed.first { $0.id == id }
    }

    var visibleEvents: [CalendarEvent] {
        var out = calendarStore.combinedFeed
        if calendarHidePast {
            out = out.filter { !$0.isPast }
        }
        if let s = calendarStageFilter {
            out = out.filter { $0.pipelineStage == s }
        }
        let q = calendarSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter {
                $0.subject.lowercased().contains(q)
                || $0.location.lowercased().contains(q)
                || $0.allAttendees.contains(where: { $0.email.lowercased().contains(q) || $0.name.lowercased().contains(q) })
            }
        }
        return out
    }

    var conflictingEventIds: Set<String> {
        calendarStore.conflicts(in: visibleEvents)
    }

    /// Renewal flagged: pipelineStage == .renewal AND <= 60 days until start.
    var renewalAtRiskEventIds: Set<String> {
        let now = Date()
        let cutoff = now.addingTimeInterval(60 * 24 * 60 * 60)
        return Set(calendarStore.combinedFeed.filter { ev in
            guard ev.pipelineStage == .renewal,
                  let s = ev.startDate else { return false }
            return s >= now && s <= cutoff
        }.map { $0.id })
    }

    // MARK: - Calendar actions

    func generatePreparationBrief(for event: CalendarEvent) async {
        isGeneratingBrief = true
        briefForEventId = event.id
        defer {
            isGeneratingBrief = false
            briefForEventId = nil
        }
        // Gather context from the inbox: top mails involving any attendee domain.
        // QBR meetings deserve a wider window than ordinary syncs.
        let cap: Int = (event.pipelineStage == .qbr) ? 20 : 5
        let domains = Set(event.allAttendees.compactMap {
            $0.email.split(separator: "@").last.map(String.init)?.lowercased()
        })
        let related = emails.filter { mail in
            let from = mail.fromAddress.lowercased()
            if let d = from.split(separator: "@").last.map(String.init), domains.contains(d) {
                return true
            }
            return false
        }.prefix(cap).map { $0 }

        do {
            let brief = try await claude.preparationBrief(for: event, recentMails: related)
            calendarStore.updateBrief(brief, for: event.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// For an apparent POC kickoff, suggest 2/4/6-week check-in invites that the
    /// user can accept with one click. Only fires for stage .poc and a subject
    /// or body that mentions "kickoff" / "kick off" / "kick-off".
    func suggestedPOCCheckInDates(for event: CalendarEvent) -> [Date] {
        guard event.pipelineStage == .poc, let start = event.startDate else { return [] }
        let lower = (event.subject + " " + event.body).lowercased()
        let isKickoff = lower.contains("kickoff")
            || lower.contains("kick off")
            || lower.contains("kick-off")
            || lower.contains("kick-of")
        guard isKickoff else { return [] }
        let cal = Calendar.current
        return [2, 4, 6].compactMap { weeks in
            cal.date(byAdding: .day, value: weeks * 7, to: start)
        }
    }

    /// Build an InviteSuggestion for a POC follow-up at the given start date.
    func startPOCFollowUpFlow(for event: CalendarEvent, at start: Date, weekIndex: Int) async {
        // Pretend the source mail is "this event" for the sheet wiring; we'll
        // pre-populate via inviteSuggestion directly so the AI is bypassed.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        let end = start.addingTimeInterval(30 * 60)
        let attendees = event.externalAttendees.map { $0.email }
        let weekLabel = "Hafta \(weekIndex)"
        let suggestion = InviteSuggestion(
            subject: "POC Check-in (\(weekLabel)) — " + event.subject,
            startISO: f.string(from: start),
            endISO:   f.string(from: end),
            location: event.conferenceUrl ?? event.location,
            attendees: attendees,
            body: """
            POC \(weekLabel) check-in.

            Gündem (taslak):
            • İlerleme — entegrasyonun ulaştığı kilometre taşları
            • Engeller — açık teknik / ticari sorular
            • Sonraki adımlar — kalan POC süresi planı

            Kickoff: \(event.startRaw)
            """,
            rationale: "Kickoff'tan \(weekIndex * 2) hafta sonra otomatik check-in önerisi.",
            customerTimezone: TimezoneStrategy.timezoneId(for: event.inferredCustomerDomain ?? ""),
            customerLocalTime: nil
        )
        // Use a synthetic source EmailFull (id'yi event id ile prefix'lerim ki
        // Identifiable çakışma olmasın).
        let stub = EmailFull(
            id: "evt-" + event.id,
            isRead: true,
            date: event.startRaw,
            fromName: event.organizerName,
            fromAddress: event.organizerEmail,
            toAddresses: attendees,
            ccAddresses: [],
            subject: event.subject,
            body: event.body,
            hasAttachments: false,
            attachmentNames: [],
            conversationId: nil,
            attachmentPaths: [:]
        )
        draftingInviteFromEmail = stub
        inviteSuggestion = suggestion
    }

    func extractMeetingTasks(from event: CalendarEvent) async {
        isExtractingMeetingTasks = true
        defer { isExtractingMeetingTasks = false }
        do {
            let tasks = try await claude.extractMeetingTasks(from: event)
            let stamped = tasks.map { item -> TaskItem in
                var t = item
                t.account = event.inferredCustomerDomain
                t.category = event.pipelineStage?.rawValue
                return t
            }
            _ = taskStore.ingest(stamped)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func draftDeclineForEvent(_ event: CalendarEvent) async {
        // Best-effort: open a reply draft to the organizer with a polite decline.
        // Falls back to a "compose" if no source mail exists.
        guard !event.organizerEmail.isEmpty else {
            errorMessage = "Düzenleyen e-posta adresi yok — taslak oluşturulamadı."
            return
        }
        isDrafting = true
        defer { isDrafting = false }
        do {
            let body = try await claude.declineDraft(for: event)
            // Use existing inbox compose path: search for a mail by event subject.
            if let related = emails.first(where: { $0.subject.localizedCaseInsensitiveContains(event.subject) }) {
                try await outlook.createDraftReply(messageId: related.id, body: body, replyAll: false)
            } else {
                // No matching mail — fall back to opening the meeting itself for manual decline.
                lastInviteAttemptStatus = "Eşleşen mail bulunamadı. Outlook'tan toplantıyı manuel decline et — taslak panoya kopyalandı."
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(body, forType: .string)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFocusBlock(start: Date, end: Date, subject: String, notes: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        let block = CalendarStore.FocusBlock(
            id: UUID().uuidString,
            subject: subject.isEmpty ? "Focus / Hold" : subject,
            startRaw: f.string(from: start),
            endRaw:   f.string(from: end),
            notes: notes
        )
        calendarStore.addFocusBlock(block)
    }

    // MARK: - Mail → Calendar

    func startInviteFlow(from email: EmailFull) async {
        draftingInviteFromEmail = email
        inviteSuggestion = nil
        isExtractingInvite = true
        defer { isExtractingInvite = false }
        do {
            let thread = thread?.messages ?? []
            let suggestion = try await claude.extractInviteSuggestion(from: email, thread: thread)
            inviteSuggestion = suggestion
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelInviteFlow() {
        draftingInviteFromEmail = nil
        inviteSuggestion = nil
    }

    func confirmInvite(_ suggestion: InviteSuggestion) async {
        isCreatingEvent = true
        defer { isCreatingEvent = false }
        do {
            _ = try await outlook.createCalendarEvent(
                subject: suggestion.subject,
                startISO: suggestion.startISO,
                endISO: suggestion.endISO,
                location: suggestion.location,
                body: suggestion.body,
                attendees: suggestion.attendees
            )
            lastInviteAttemptStatus = "Davet Outlook'ta açıldı — Send tuşuna basarak gönder."
            cancelInviteFlow()
            // Auto-clear status after a moment
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self.lastInviteAttemptStatus?.hasPrefix("Davet") == true {
                    self.lastInviteAttemptStatus = nil
                }
            }
            // Refresh calendar so the new event shows up.
            await refreshCalendar()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Morning brief

    func generateMorningBrief() async {
        isGeneratingMorningBrief = true
        defer { isGeneratingMorningBrief = false }
        let today = Date()
        let evts = calendarStore.eventsBetween(
            Calendar.current.startOfDay(for: today),
            Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: today)) ?? today
        )
        do {
            let md = try await claude.morningBrief(events: evts, recentMails: Array(emails.prefix(20)))
            morningBriefMarkdown = md
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// AI-extracted draft of a calendar invite (subject, time, attendees, body).
struct InviteSuggestion: Codable, Hashable {
    var subject: String
    var startISO: String     // "yyyy-MM-dd HH:mm:ss" local TZ
    var endISO: String
    var location: String
    var attendees: [String]
    var body: String
    var rationale: String
    var customerTimezone: String?    // IANA, e.g. "Europe/London"
    var customerLocalTime: String?   // "Mon 3 Jun 16:00 BST" — optional human label
}
