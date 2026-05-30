import SwiftUI

struct CalendarFeatureView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        NavigationSplitView {
            CalendarSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } content: {
            CalendarAgendaPane()
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            CalendarDetailPane()
                .navigationSplitViewColumnWidth(min: 380, ideal: 480)
        }
        .task {
            if vm.calendarStore.events.isEmpty {
                await vm.refreshCalendar()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("", selection: Binding(
                    get: { vm.calendarRange },
                    set: { v in vm.calendarRange = v; Task { await vm.refreshCalendar() } }
                )) {
                    ForEach(AppViewModel.CalendarRange.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                TextField("Ara…", text: $vm.calendarSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button {
                    Task { await vm.refreshCalendar() }
                } label: {
                    if vm.isLoadingCalendar {
                        ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
                    } else {
                        Label("Yenile", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(vm.isLoadingCalendar)
                .help(vm.isClassifyingCalendar ? "AI toplantıları sınıflandırıyor…" : "Outlook'tan tekrar çek")
            }
        }
    }
}

// MARK: - Sidebar

private struct CalendarSidebar: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        List {
            Section("Görünüm") {
                Toggle("Geçmiş toplantıları gizle", isOn: $vm.calendarHidePast)
            }

            Section("Pipeline") {
                FilterRowCal(label: "Tümü",
                             count: vm.visibleEvents.count,
                             accent: .secondary,
                             isOn: vm.calendarStageFilter == nil) {
                    vm.calendarStageFilter = nil
                }
                ForEach(activeStages, id: \.self) { s in
                    FilterRowCal(
                        label: s.label,
                        count: vm.calendarStore.combinedFeed.filter { $0.pipelineStage == s }.count,
                        accent: s.color,
                        isOn: vm.calendarStageFilter == s
                    ) {
                        vm.calendarStageFilter = (vm.calendarStageFilter == s) ? nil : s
                    }
                }
            }

            Section("İçgörü") {
                InsightRow(label: "Yaklaşan Renewal (≤60g)",
                           count: vm.renewalAtRiskEventIds.count,
                           color: .red)
                InsightRow(label: "Çakışma",
                           count: vm.conflictingEventIds.count,
                           color: .orange)
                InsightRow(label: "Toplam (görünür)",
                           count: vm.visibleEvents.count,
                           color: .blue)
                let deepWorkMin = deepWorkMinutesThisWeek()
                HStack {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                    Text("Deep-work bu hafta").font(.caption)
                    Spacer()
                    Text("\(deepWorkMin / 60)s \(deepWorkMin % 60)dk")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Section("Yoğunluk Haritası") {
                HeatmapView()
            }

            Section("Sabah Brief") {
                Button {
                    Task { await vm.generateMorningBrief() }
                } label: {
                    if vm.isGeneratingMorningBrief {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Label("Bugün için brief üret", systemImage: "sunrise")
                    }
                }
                .disabled(vm.isGeneratingMorningBrief)
                if let md = vm.morningBriefMarkdown, !md.isEmpty {
                    BriefMarkdownView(markdown: md)
                        .padding(.top, 4)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Takvim")
    }

    /// Sum of free-slot minutes inside working hours over the next 7 days.
    private func deepWorkMinutesThisWeek() -> Int {
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.date(byAdding: .day, value: 7, to: from) ?? from
        let slots = vm.calendarStore.freeSlots(
            from: from, to: to,
            workingHourStart: 9, workingHourEnd: 18,
            minMinutes: 30
        )
        let total = slots.reduce(0.0) { $0 + $1.duration }
        return Int(total / 60.0)
    }

    private var activeStages: [CalendarEvent.PipelineStage] {
        var seen = Set<CalendarEvent.PipelineStage>()
        var out: [CalendarEvent.PipelineStage] = []
        for e in vm.calendarStore.combinedFeed {
            if let s = e.pipelineStage, !seen.contains(s) {
                seen.insert(s); out.append(s)
            }
        }
        // Stable order based on enum cases
        return CalendarEvent.PipelineStage.allCases.filter { seen.contains($0) }
    }
}

private struct FilterRowCal: View {
    let label: String
    let count: Int
    var accent: Color = .secondary
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(label).font(.callout)
                Spacer()
                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .background(isOn ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct InsightRow: View {
    let label: String
    let count: Int
    let color: Color
    var body: some View {
        HStack {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(color)
            Text(label).font(.caption)
            Spacer()
            Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }
}

// MARK: - Heatmap (Özellik 7)

private struct HeatmapView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        let weeks = HeatmapBuilder.build(events: vm.calendarStore.combinedFeed)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 2) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(["Pzt","Sal","Çar","Per","Cum","Cmt","Paz"], id: \.self) { d in
                        Text(d).font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(height: 14)
                    }
                }
                ForEach(0..<weeks.count, id: \.self) { wIdx in
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { dIdx in
                            let value = weeks[wIdx][dIdx]
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(heatColor(for: value))
                                .frame(width: 14, height: 14)
                                .help("\(value) toplantı")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Az").font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach([0, 1, 2, 3, 5], id: \.self) { v in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatColor(for: v))
                        .frame(width: 10, height: 10)
                }
                Text("Çok").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func heatColor(for n: Int) -> Color {
        switch n {
        case 0:    return Color.primary.opacity(0.06)
        case 1:    return Color.green.opacity(0.30)
        case 2:    return Color.green.opacity(0.55)
        case 3:    return Color.orange.opacity(0.65)
        case 4:    return Color.red.opacity(0.55)
        default:   return Color.red.opacity(0.85)
        }
    }
}

enum HeatmapBuilder {
    /// Returns `weeks[w][dayOfWeek]` — last 4 weeks ending today.
    static func build(events: [CalendarEvent]) -> [[Int]] {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: Date())
        // 4 weeks → 28 days ending today
        var counts: [Date: Int] = [:]
        let oldest = cal.date(byAdding: .day, value: -27, to: today) ?? today
        for ev in events {
            guard let s = ev.startDate else { continue }
            let d = cal.startOfDay(for: s)
            if d < oldest || d > today { continue }
            counts[d, default: 0] += 1
        }

        var weeks: [[Int]] = []
        var weekStart = oldest
        while weekStart <= today {
            var week: [Int] = []
            for offset in 0..<7 {
                guard let d = cal.date(byAdding: .day, value: offset, to: weekStart) else {
                    week.append(0); continue
                }
                week.append(counts[d, default: 0])
            }
            weeks.append(week)
            guard let next = cal.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = next
        }
        return weeks
    }
}

// MARK: - Agenda list

private struct CalendarAgendaPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        let groups = grouped(vm.visibleEvents)
        let conflicts = vm.conflictingEventIds
        let renewals = vm.renewalAtRiskEventIds

        Group {
            if vm.calendarStore.events.isEmpty && !vm.isLoadingCalendar {
                ContentUnavailableView(
                    "Takvim boş",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Outlook'ta seçilen aralıkta toplantı yok ya da Classic Outlook ile bağlantı kurulamadı.")
                )
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "Eşleşen toplantı yok",
                    systemImage: "magnifyingglass",
                    description: Text("Filtre veya arama eşleşmiyor.")
                )
            } else {
                List(selection: Binding(
                    get: { vm.selectedEventId },
                    set: { vm.selectEvent($0) }
                )) {
                    ForEach(groups, id: \.0) { (label, items) in
                        Section(header: Text(label)) {
                            ForEach(items) { ev in
                                AgendaRow(event: ev,
                                          isConflict: conflicts.contains(ev.id),
                                          isRenewalRisk: renewals.contains(ev.id))
                                    .tag(ev.id)
                                    .contextMenu {
                                        if !ev.organizerEmail.isEmpty {
                                            Button("Decline taslağı oluştur") {
                                                Task { await vm.draftDeclineForEvent(ev) }
                                            }
                                        }
                                        if ev.id.hasPrefix("focus:") {
                                            Button("Focus block sil", role: .destructive) {
                                                let raw = String(ev.id.dropFirst("focus:".count))
                                                vm.calendarStore.removeFocusBlock(id: raw)
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(vm.calendarRange.label + " (" + String(vm.visibleEvents.count) + ")")
    }

    private func grouped(_ events: [CalendarEvent]) -> [(String, [CalendarEvent])] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = .current

        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today

        var dict: [String: [CalendarEvent]] = [:]
        var order: [String] = []

        for e in events {
            guard let d = e.startDate else { continue }
            let day = Calendar.current.startOfDay(for: d)
            let label: String
            if day == today {
                f.dateFormat = "d MMMM EEEE"
                label = "Bugün — " + f.string(from: d)
            } else if day == tomorrow {
                f.dateFormat = "d MMMM EEEE"
                label = "Yarın — " + f.string(from: d)
            } else {
                f.dateFormat = "d MMMM EEEE"
                label = f.string(from: d)
            }
            if dict[label] == nil { order.append(label) }
            dict[label, default: []].append(e)
        }
        return order.map { ($0, dict[$0] ?? []) }
    }
}

private struct AgendaRow: View {
    let event: CalendarEvent
    let isConflict: Bool
    let isRenewalRisk: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Text(timeStart).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("→").foregroundStyle(.secondary).font(.caption2)
                Text(timeEnd).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                Text("\(event.durationMinutes)dk").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 56)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(stageColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.subject.isEmpty ? "(konu yok)" : event.subject)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if event.isRecurring {
                        Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let conf = event.conferenceType {
                        Tag(text: conf.label, color: conf.color)
                    }
                }
                HStack(spacing: 6) {
                    if let stage = event.pipelineStage {
                        Tag(text: stage.label, color: stage.color)
                    }
                    if event.isInternal {
                        Tag(text: "İç", color: .gray)
                    } else if let dom = event.inferredCustomerDomain {
                        Tag(text: dom, color: .indigo)
                    }
                    if isRenewalRisk {
                        Tag(text: "Renewal ≤60g", color: .red)
                    }
                    if isConflict {
                        Tag(text: "Çakışma", color: .orange)
                    }
                    if event.allAttendees.count > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2").font(.caption2)
                            Text("\(event.allAttendees.count)").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                if !event.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").font(.caption2)
                        Text(event.location).font(.caption2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(event.isPast ? 0.55 : 1.0)
    }

    private var stageColor: Color {
        event.pipelineStage?.color ?? .accentColor
    }

    private var timeStart: String {
        guard let d = event.startDate else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = event.isAllDay ? "—" : "HH:mm"
        return event.isAllDay ? "Tüm gün" : f.string(from: d)
    }
    private var timeEnd: String {
        guard let d = event.endDate, !event.isAllDay else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Detail pane

private struct CalendarDetailPane: View {
    @Environment(AppViewModel.self) private var vm
    @State private var detailTab: DetailTab = .overview
    @State private var showingFocusSheet = false
    @State private var showingSlotFinder = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Özet"
        case prep     = "Hazırlık"
        case actions  = "Eylemler"
        var id: String { rawValue }
    }

    var body: some View {
        if let event = vm.selectedEvent {
            VStack(spacing: 0) {
                EventHeader(event: event)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.ultraThinMaterial)

                Picker("", selection: $detailTab) {
                    ForEach(DetailTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(10)
                Divider()

                ScrollView {
                    switch detailTab {
                    case .overview: OverviewTab(event: event)
                    case .prep:     PrepTab(event: event)
                    case .actions:  ActionsTab(event: event,
                                               showFocusSheet: $showingFocusSheet,
                                               showSlotFinder: $showingSlotFinder)
                    }
                }
            }
            .id(event.id)
            .sheet(isPresented: $showingFocusSheet) {
                FocusBlockSheet()
            }
            .sheet(isPresented: $showingSlotFinder) {
                SlotFinderSheet(eventForCustomer: event)
            }
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "Toplantı seç",
                    systemImage: "calendar",
                    description: Text("Listeden bir toplantı seçtiğinde detay, hazırlık brief'i ve eylemler burada görünür.")
                )
                HStack(spacing: 12) {
                    Button {
                        showingFocusSheet = true
                    } label: {
                        Label("Focus block koy", systemImage: "rectangle.stack.badge.plus")
                    }
                    Button {
                        showingSlotFinder = true
                    } label: {
                        Label("Boş slot bul", systemImage: "clock.badge.checkmark")
                    }
                }
                .buttonStyle(.bordered)
                if let status = vm.lastInviteAttemptStatus {
                    Text(status).font(.caption).foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .sheet(isPresented: $showingFocusSheet) {
                FocusBlockSheet()
            }
            .sheet(isPresented: $showingSlotFinder) {
                SlotFinderSheet(eventForCustomer: nil)
            }
        }
    }
}

private struct EventHeader: View {
    let event: CalendarEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.subject.isEmpty ? "(konu yok)" : event.subject)
                .font(.title3.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 8) {
                if let stage = event.pipelineStage {
                    Tag(text: stage.label, color: stage.color)
                }
                if let conf = event.conferenceType {
                    Tag(text: conf.label, color: conf.color)
                }
                if event.isRecurring {
                    Tag(text: "Yineleyen", color: .secondary)
                }
                Tag(text: event.ownResponse.label, color: event.ownResponse.color)
            }

            HStack(spacing: 14) {
                Label(timeRange, systemImage: "clock")
                if !event.location.isEmpty {
                    Label(event.location, systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var timeRange: String {
        guard let s = event.startDate, let e = event.endDate else { return event.startRaw }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM HH:mm"
        let endF = DateFormatter()
        endF.locale = Locale(identifier: "tr_TR")
        endF.dateFormat = Calendar.current.isDate(s, inSameDayAs: e) ? "HH:mm" : "d MMM HH:mm"
        return f.string(from: s) + " → " + endF.string(from: e)
    }
}

// MARK: - Detail: Overview

private struct OverviewTab: View {
    @Environment(AppViewModel.self) private var vm
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Multi-TZ row (Özellik 2)
            TimezoneStripView(event: event)
                .padding(.horizontal, 16)

            // Conference link
            if let url = event.conferenceUrl {
                GroupBox(label: Label("Bağlantı", systemImage: "video")) {
                    HStack {
                        Text(url).font(.caption).lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Aç") {
                            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                        }
                        Button("Kopyala") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // Organizer + attendees
            GroupBox(label: Label("Katılımcılar", systemImage: "person.3")) {
                VStack(alignment: .leading, spacing: 6) {
                    if !event.organizerEmail.isEmpty {
                        AttendeeRow(name: event.organizerName,
                                    email: event.organizerEmail,
                                    response: .organizer,
                                    isOrganizer: true)
                    }
                    ForEach(event.allAttendees) { a in
                        AttendeeRow(name: a.name, email: a.email,
                                    response: a.response, isOrganizer: false)
                    }
                    if event.allAttendees.isEmpty && event.organizerEmail.isEmpty {
                        Text("(katılımcı listesi yok)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)

            // Body
            if !event.body.isEmpty {
                GroupBox(label: Label("Açıklama", systemImage: "text.alignleft")) {
                    Text(event.body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 14)
    }
}

private struct AttendeeRow: View {
    let name: String
    let email: String
    let response: CalendarEvent.ResponseStatus
    let isOrganizer: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(response.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? email : name).font(.callout)
                if !name.isEmpty {
                    Text(email).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Tag(text: isOrganizer ? "Düzenleyen" : response.label,
                color: isOrganizer ? .purple : response.color)
        }
    }
}

// MARK: - Multi-timezone strip (Özellik 2)

private struct TimezoneStripView: View {
    let event: CalendarEvent

    var body: some View {
        let tzs = TimezoneStrategy.zones(for: event)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text("Timezone'lar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(tzs, id: \.id) { tz in
                    TimezoneChip(zone: tz, start: event.startDate, end: event.endDate)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

private struct TimezoneChip: View {
    let zone: TimezoneStrategy.Zone
    let start: Date?
    let end:   Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(zone.label).font(.caption.weight(.semibold))
                Text(zone.flag).font(.caption2)
            }
            Text(rangeText)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
            Text(zone.tz.identifier)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(zone.color.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(zone.color.opacity(0.4), lineWidth: 0.5))
    }

    private var rangeText: String {
        guard let s = start, let e = end else { return "—" }
        let f = DateFormatter()
        f.timeZone = zone.tz
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE HH:mm"
        let endF = DateFormatter()
        endF.timeZone = zone.tz
        endF.dateFormat = "HH:mm"
        return f.string(from: s) + "–" + endF.string(from: e)
    }
}

// MARK: - Detail: Prep

private struct PrepTab: View {
    @Environment(AppViewModel.self) private var vm
    let event: CalendarEvent

    var body: some View {
        let enr = vm.calendarStore.enrichment[event.id]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await vm.generatePreparationBrief(for: event) }
                } label: {
                    if vm.isGeneratingBrief && vm.briefForEventId == event.id {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    } else {
                        Label("Hazırlık brief'i üret", systemImage: "wand.and.rays")
                    }
                }
                .disabled(vm.isGeneratingBrief)
                Spacer()
                if let ts = enr?.briefGeneratedAt {
                    Text("Üretildi: " + ts.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let brief = enr?.preparationBrief, !brief.isEmpty {
                BriefMarkdownView(markdown: brief)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04)))
            } else {
                Text("Henüz brief üretilmedi. Üretildikten sonra son ilgili mailler, açık konular ve sorulacak sorular burada listelenir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

/// Lightweight markdown renderer — handles **bold**, *italic*, headings, bullets.
struct BriefMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] { markdown.components(separatedBy: "\n") }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 4)
        } else if line.hasPrefix("# ") {
            Text(stripPrefix(line, "# "))
                .font(.title3.weight(.bold))
        } else if line.hasPrefix("## ") {
            Text(stripPrefix(line, "## "))
                .font(.headline)
        } else if line.hasPrefix("### ") {
            Text(stripPrefix(line, "### "))
                .font(.subheadline.weight(.semibold))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(attributed(stripPrefix(line, "- ").trimmingCharacters(in: .init(charactersIn: "*"))))
                    .font(.callout)
            }
        } else {
            Text(attributed(line))
                .font(.callout)
        }
    }

    private func stripPrefix(_ s: String, _ p: String) -> String {
        s.hasPrefix(p) ? String(s.dropFirst(p.count)) : s
    }

    private func attributed(_ s: String) -> AttributedString {
        if let a = try? AttributedString(markdown: s) { return a }
        return AttributedString(s)
    }
}

// MARK: - Detail: Actions (Özellik 6)

private struct ActionsTab: View {
    @Environment(AppViewModel.self) private var vm
    let event: CalendarEvent
    @Binding var showFocusSheet: Bool
    @Binding var showSlotFinder: Bool

    var body: some View {
        let pocDates = vm.suggestedPOCCheckInDates(for: event)
        VStack(alignment: .leading, spacing: 12) {
            if !pocDates.isEmpty {
                GroupBox(label: Label("POC Check-in Önerisi", systemImage: "calendar.badge.clock")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kickoff sonrası 2/4/6. hafta için takip toplantıları öner. Tek tıkla davet taslağı Outlook'ta açılır.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            ForEach(Array(pocDates.enumerated()), id: \.offset) { idx, date in
                                Button {
                                    Task {
                                        await vm.startPOCFollowUpFlow(
                                            for: event,
                                            at: date,
                                            weekIndex: (idx + 1) * 2
                                        )
                                    }
                                } label: {
                                    Label("\((idx + 1) * 2) hafta — \(formatShort(date))",
                                          systemImage: "plus.circle")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }

            GroupBox(label: Label("Görev üretimi", systemImage: "checklist")) {
                HStack {
                    Text("Toplantı açıklamasından action items çıkar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await vm.extractMeetingTasks(from: event) }
                    } label: {
                        if vm.isExtractingMeetingTasks {
                            ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                        } else {
                            Label("Görevleri çıkar", systemImage: "wand.and.rays")
                        }
                    }
                    .disabled(vm.isExtractingMeetingTasks)
                }
            }

            GroupBox(label: Label("Toplantı yönetimi", systemImage: "envelope.badge.shield.half.filled")) {
                HStack {
                    Text("Bu toplantıyı kibarca reddet — taslak Outlook'ta açılır ya da panoya kopyalanır.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await vm.draftDeclineForEvent(event) }
                    } label: {
                        Label("Decline taslağı", systemImage: "xmark.circle")
                    }
                    .disabled(event.organizerEmail.isEmpty)
                }
            }

            GroupBox(label: Label("Müşteri için boş slot", systemImage: "clock.badge.checkmark")) {
                HStack {
                    Text(event.inferredCustomerDomain.map { "\($0) timezone'unda 7 gün içindeki uygun slotlarımı listele." } ?? "İlgili müşteri timezone'unda 7 gün içindeki uygun slotlarımı listele.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showSlotFinder = true
                    } label: {
                        Label("Slot bul", systemImage: "magnifyingglass")
                    }
                }
            }

            GroupBox(label: Label("Focus block", systemImage: "rectangle.stack.badge.plus")) {
                HStack {
                    Text("Müsait olmadığım bir saat aralığına 'hold' koy. Outlook'a yazılmaz, yerel saklanır.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showFocusSheet = true
                    } label: {
                        Label("Hold koy", systemImage: "plus.circle")
                    }
                }
            }

            if let status = vm.lastInviteAttemptStatus {
                Text(status).font(.caption).foregroundStyle(.green)
            }
        }
        .padding(16)
    }

    private func formatShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM EEE"
        return f.string(from: date)
    }
}

// MARK: - Slot finder sheet (Özellik 2 + 6)

private struct SlotFinderSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let eventForCustomer: CalendarEvent?

    @State private var fromDate: Date = Date()
    @State private var toDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var workStart: Int = 9
    @State private var workEnd:   Int = 18
    @State private var minMinutes: Int = 30
    @State private var customerTzId: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Boş Slot Bul").font(.title3.weight(.semibold))
            HStack {
                DatePicker("Başlangıç", selection: $fromDate, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Bitiş", selection: $toDate, displayedComponents: [.date, .hourAndMinute])
            }
            HStack {
                Stepper("Mesai başlangıç: \(workStart):00", value: $workStart, in: 6...22)
                Stepper("Mesai bitiş: \(workEnd):00", value: $workEnd, in: 7...23)
            }
            Stepper("Minimum slot: \(minMinutes) dk", value: $minMinutes, in: 15...240, step: 15)

            Picker("Müşteri TZ", selection: $customerTzId) {
                Text("(yok)").tag("")
                ForEach(TimezoneStrategy.commonZones, id: \.self) { id in
                    Text(id).tag(id)
                }
            }

            Divider()

            ScrollView {
                let slots = vm.calendarStore.freeSlots(
                    from: fromDate, to: toDate,
                    workingHourStart: workStart, workingHourEnd: workEnd,
                    minMinutes: minMinutes
                )
                if slots.isEmpty {
                    Text("Bu aralıkta uygun slot yok.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding()
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                            SlotRow(slot: slot, customerTzId: customerTzId)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Kapat") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 560, height: 540)
        .onAppear {
            if let dom = eventForCustomer?.inferredCustomerDomain {
                customerTzId = TimezoneStrategy.timezoneId(for: dom) ?? ""
            }
        }
    }
}

private struct SlotRow: View {
    let slot: DateInterval
    let customerTzId: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localText).font(.callout.weight(.medium)).monospacedDigit()
                if let tz = TimeZone(identifier: customerTzId) {
                    Text(text(in: tz) + " (" + customerTzId + ")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(Int(slot.duration / 60)) dk")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(localText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Yerel saati panoya kopyala")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private var localText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = .current
        f.dateFormat = "d MMM EEEE HH:mm"
        let endF = DateFormatter()
        endF.timeZone = .current
        endF.dateFormat = "HH:mm"
        return f.string(from: slot.start) + " – " + endF.string(from: slot.end)
    }
    private func text(in tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = tz
        f.dateFormat = "EEE HH:mm"
        let endF = DateFormatter()
        endF.timeZone = tz
        endF.dateFormat = "HH:mm"
        return f.string(from: slot.start) + " – " + endF.string(from: slot.end)
    }
}

// MARK: - Focus block sheet

private struct FocusBlockSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var subject = "Focus / Hold"
    @State private var notes = ""
    @State private var start: Date = Date()
    @State private var end: Date = Date().addingTimeInterval(60 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Focus Block").font(.title3.weight(.semibold))
            TextField("Başlık", text: $subject).textFieldStyle(.roundedBorder)
            DatePicker("Başlangıç", selection: $start, displayedComponents: [.date, .hourAndMinute])
            DatePicker("Bitiş", selection: $end, displayedComponents: [.date, .hourAndMinute])
            VStack(alignment: .leading, spacing: 4) {
                Text("Not (ops.)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes).frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tertiary))
            }
            HStack {
                Button("İptal") { dismiss() }
                Spacer()
                Button("Hold koy") {
                    vm.addFocusBlock(start: start, end: end, subject: subject, notes: notes)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(end <= start)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

// MARK: - Invite sheet (Özellik 3)

struct InviteSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let sourceEmail: EmailFull

    @State private var subject = ""
    @State private var startDate: Date = Date().addingTimeInterval(60 * 60)
    @State private var endDate: Date   = Date().addingTimeInterval(2 * 60 * 60)
    @State private var location = ""
    @State private var attendeesText = ""
    @State private var body_ = ""
    @State private var rationale = ""
    @State private var customerTzId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mailden Davet Oluştur")
                    .font(.title3.weight(.semibold))
                Spacer()
                if vm.isExtractingInvite {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                        Text("AI öneri hazırlıyor…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !rationale.isEmpty {
                Text("AI: " + rationale)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }

            Group {
                TextField("Konu", text: $subject).textFieldStyle(.roundedBorder)
                HStack {
                    DatePicker("Başlangıç", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Bitiş", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                }
                TextField("Lokasyon / Bağlantı", text: $location).textFieldStyle(.roundedBorder)
                TextField("Katılımcılar (virgülle)", text: $attendeesText).textFieldStyle(.roundedBorder)
                Picker("Müşteri TZ", selection: $customerTzId) {
                    Text("(yok)").tag("")
                    ForEach(TimezoneStrategy.commonZones, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                if let tz = TimeZone(identifier: customerTzId) {
                    Text("Müşteri saati: " + customerSideText(tz: tz))
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Açıklama").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $body_).frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tertiary))
                }
            }
            .disabled(vm.isExtractingInvite)

            HStack {
                Button("İptal") { dismiss(); vm.cancelInviteFlow() }
                Spacer()
                Button {
                    Task {
                        let suggestion = buildSuggestion()
                        await vm.confirmInvite(suggestion)
                        dismiss()
                    }
                } label: {
                    if vm.isCreatingEvent {
                        ProgressView().scaleEffect(0.55)
                    } else {
                        Label("Outlook'ta aç", systemImage: "calendar.badge.plus")
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(subject.isEmpty || endDate <= startDate || vm.isExtractingInvite || vm.isCreatingEvent)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { hydrateFromSuggestion() }
        .onChange(of: vm.inviteSuggestion) { _, _ in
            hydrateFromSuggestion()
        }
    }

    private func hydrateFromSuggestion() {
        guard let s = vm.inviteSuggestion else { return }
        subject = s.subject
        location = s.location
        attendeesText = s.attendees.joined(separator: ", ")
        body_ = s.body
        rationale = s.rationale
        customerTzId = s.customerTimezone ?? ""
        if let sd = DateUtil.parse(s.startISO) { startDate = sd }
        if let ed = DateUtil.parse(s.endISO)   { endDate = ed }
    }

    private func customerSideText(tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM HH:mm"
        let ef = DateFormatter()
        ef.timeZone = tz
        ef.dateFormat = "HH:mm"
        return f.string(from: startDate) + " – " + ef.string(from: endDate)
    }

    private func buildSuggestion() -> InviteSuggestion {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        let attendees = attendeesText.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return InviteSuggestion(
            subject: subject,
            startISO: f.string(from: startDate),
            endISO: f.string(from: endDate),
            location: location,
            attendees: attendees,
            body: body_,
            rationale: rationale,
            customerTimezone: customerTzId.isEmpty ? nil : customerTzId,
            customerLocalTime: nil
        )
    }
}
