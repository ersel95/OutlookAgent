import SwiftUI

struct ProspectsFeatureView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        HStack(spacing: 0) {
            ProspectListPane()
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
            Divider()
            ProspectDetailPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $vm.prospectShowImport) {
            ImportProspectSheet()
                .environment(vm)
        }
    }
}

// MARK: - List pane

private struct ProspectListPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Prospects")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    vm.prospectShowImport = true
                } label: {
                    Label("Yeni", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Ara — şirket, kişi, domain", text: $vm.prospectSearchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 14).padding(.vertical, 8)

            // Filters
            FilterStrip()
                .padding(.horizontal, 14).padding(.bottom, 8)

            Divider()

            // List
            if vm.visibleProspects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text(vm.prospectStore.prospects.isEmpty
                         ? "Henüz prospect yok.\nYeni → Crunchbase profilini paste et."
                         : "Filtreyle eşleşen prospect yok.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.visibleProspects) { p in
                            ProspectRow(prospect: p,
                                        isSelected: vm.selectedProspectId == p.id)
                                .onTapGesture {
                                    vm.selectedProspectId = p.id
                                }
                                .contextMenu {
                                    ProspectRowContextMenu(prospect: p)
                                }
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }
}

private struct FilterStrip: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        HStack(spacing: 6) {
            Menu {
                Button("Hepsi") { vm.prospectStatusFilter = nil }
                Divider()
                ForEach(ProspectStatus.allCases) { s in
                    Button(s.label) { vm.prospectStatusFilter = s }
                }
            } label: {
                FilterPill(
                    label: vm.prospectStatusFilter?.label ?? "Durum",
                    icon: vm.prospectStatusFilter?.systemImage ?? "line.3.horizontal.decrease.circle",
                    active: vm.prospectStatusFilter != nil
                )
            }
            .menuStyle(.borderlessButton).fixedSize()

            Menu {
                Button("Hepsi") { vm.prospectQueueFilter = nil }
                Divider()
                ForEach(ProspectQueue.allCases) { q in
                    Button(q.label) { vm.prospectQueueFilter = q }
                }
            } label: {
                FilterPill(
                    label: vm.prospectQueueFilter?.label ?? "Kuyruk",
                    icon: "tray.2",
                    active: vm.prospectQueueFilter != nil
                )
            }
            .menuStyle(.borderlessButton).fixedSize()

            Spacer()

            if vm.prospectStore.deletedCount > 0 {
                Toggle(isOn: $vm.prospectShowDeleted) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash").font(.caption2)
                        Text("Silinenler (\(vm.prospectStore.deletedCount))")
                            .font(.caption.weight(.medium))
                    }
                }
                .toggleStyle(.button)
                .controlSize(.mini)
            }
        }
    }
}

private struct FilterPill: View {
    let label: String
    let icon: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(
            Capsule().fill(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            Capsule().stroke(active ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 0.5)
        )
        .foregroundStyle(active ? Color.accentColor : .primary)
    }
}

private struct ProspectRow: View {
    let prospect: Prospect
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18))
                Text(initials(for: prospect.companyName))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if prospect.isTurkey {
                        Text("🇹🇷").font(.caption)
                    }
                    Text(prospect.companyName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .strikethrough(prospect.isDeleted, color: .secondary)
                    Spacer()
                    if prospect.isDeleted {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let s = prospect.score {
                        StarBadge(stars: s.stars)
                    }
                }
                HStack(spacing: 4) {
                    Text(prospect.contact.fullName.isEmpty ? prospect.domain : prospect.contact.fullName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if prospect.isDeleted {
                        Text("Silindi")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    } else {
                        StatusBadge(status: prospect.status)
                    }
                }
                if prospect.queue == .winBack && !prospect.isDeleted {
                    Text("Win-Back")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .opacity(prospect.isDeleted ? 0.55 : 1.0)
        .contentShape(Rectangle())
    }

    private func initials(for s: String) -> String {
        let parts = s.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

private struct ProspectRowContextMenu: View {
    let prospect: Prospect
    @Environment(AppViewModel.self) private var vm
    @State private var showHardDeleteConfirm = false

    var body: some View {
        Group {
            if prospect.isDeleted {
                Button {
                    vm.restoreProspect(prospect.id)
                } label: {
                    Label("Geri Al", systemImage: "arrow.uturn.backward")
                }
                Divider()
                Button(role: .destructive) {
                    showHardDeleteConfirm = true
                } label: {
                    Label("Kalıcı Sil", systemImage: "trash.slash")
                }
                .confirmationDialog(
                    "\(prospect.companyName) kalıcı silinsin mi? Geri alınamaz.",
                    isPresented: $showHardDeleteConfirm
                ) {
                    Button("Kalıcı Sil", role: .destructive) {
                        vm.hardDeleteProspect(prospect.id)
                    }
                }
            } else {
                if prospect.status == .paused {
                    Button {
                        vm.resumeProspect(prospect.id)
                    } label: {
                        Label("Sequence'i Devam Ettir", systemImage: "play.circle")
                    }
                } else if prospect.status != .completed && prospect.status != .excluded {
                    Button {
                        vm.pauseProspect(prospect.id)
                    } label: {
                        Label("Sequence'i Duraklat", systemImage: "pause.circle")
                    }
                }
                if let url = prospect.salesforceLeadUrl,
                   let sfUrl = URL(string: url) {
                    Button {
                        NSWorkspace.shared.open(sfUrl)
                    } label: {
                        Label("Salesforce'ta Aç", systemImage: "cloud")
                    }
                }
                if let w = prospect.website ?? URL(string: "https://\(prospect.domain)")?.absoluteString,
                   let webUrl = URL(string: w) {
                    Button {
                        NSWorkspace.shared.open(webUrl)
                    } label: {
                        Label("Website'i Aç", systemImage: "safari")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    vm.softDeleteProspect(prospect.id)
                } label: {
                    Label("Sil", systemImage: "trash")
                }
            }
        }
    }
}

private struct StatusBadge: View {
    let status: ProspectStatus
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.systemImage).font(.caption2)
            Text(status.label).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(status.color.opacity(0.18)))
        .foregroundStyle(status.color)
    }
}

private struct StarBadge: View {
    let stars: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5) { i in
                Image(systemName: i < stars ? "star.fill" : "star")
                    .font(.system(size: 8))
                    .foregroundStyle(i < stars ? Color.yellow : .secondary.opacity(0.3))
            }
        }
    }
}

// MARK: - Detail pane

private struct ProspectDetailPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        if let p = vm.selectedProspect {
            ProspectDetailView(prospect: p)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Soldan bir prospect seç ya da yeni ekle.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProspectDetailView: View {
    let prospect: Prospect
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if vm.globalSendingPaused {
                    BouncePauseBanner()
                }
                CompanyHeader(prospect: prospect)
                ContactCard(contact: prospect.contact, prospect: prospect)
                if let dedup = prospect.dedup {
                    DedupCard(dedup: dedup)
                }
                if let score = prospect.score {
                    ScoreCard(score: score)
                }
                if !prospect.sequenceSteps.isEmpty {
                    SequenceCard(prospect: prospect)
                }
                if let leadId = prospect.salesforceLeadId {
                    SalesforceCard(leadId: leadId, leadUrl: prospect.salesforceLeadUrl,
                                   taskCount: prospect.salesforceTaskIds.count)
                }
                ActionPanel(prospect: prospect)
                if let status = vm.lastInviteAttemptStatus {
                    Text(status)
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(20)
        }
    }
}

private struct CompanyHeader: View {
    let prospect: Prospect

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if prospect.isTurkey { Text("🇹🇷") }
                        Text(prospect.companyName)
                            .font(.title2.weight(.semibold))
                    }
                    HStack(spacing: 8) {
                        if let url = prospect.website ?? URL(string: "https://\(prospect.domain)")?.absoluteString,
                           let u = URL(string: url) {
                            Link(prospect.domain, destination: u)
                                .font(.callout).foregroundStyle(Color.accentColor)
                        } else {
                            Text(prospect.domain)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let cb = prospect.crunchbaseUrl, let u = URL(string: cb) {
                            Link("Crunchbase", destination: u)
                                .font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Spacer()
                StatusBadgeBig(status: prospect.status)
            }
            // Meta strip
            HStack(spacing: 14) {
                if let i = prospect.industry { MetaItem(label: "Vertical", value: i) }
                if let f = prospect.fundingStage { MetaItem(label: "Funding", value: f) }
                if let e = prospect.employeeRange { MetaItem(label: "Çalışan", value: e) }
                if let c = prospect.country { MetaItem(label: "Ülke", value: c) }
            }
            if let d = prospect.description, !d.isEmpty {
                Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBadgeBig: View {
    let status: ProspectStatus
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage).font(.caption)
            Text(status.label).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(status.color.opacity(0.18)))
        .foregroundStyle(status.color)
    }
}

private struct MetaItem: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).lineLimit(1)
        }
    }
}

private struct ContactCard: View {
    let contact: ProspectContact
    let prospect: Prospect
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Birincil Kontak")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let lin = contact.linkedinUrl, let u = URL(string: lin) {
                    Link(destination: u) {
                        Label("LinkedIn", systemImage: "person.crop.square")
                            .font(.caption)
                    }
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.fullName.isEmpty ? "(isim yok)" : contact.fullName)
                        .font(.callout.weight(.medium))
                    if !contact.title.isEmpty {
                        Text(contact.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if contact.email.isEmpty {
                        Label("Email yok — tahmin etmeden send edilemez",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        HStack(spacing: 4) {
                            Text(contact.email)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .textSelection(.enabled)
                            if vm.emailPatternCache.bestPattern(for: prospect.domain) != nil {
                                Image(systemName: "brain.head.profile")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                                    .help("Pattern cache'ten — \(prospect.domain) için öğrenilmiş")
                            }
                        }
                    }
                }
                Spacer()
                if contact.email.isEmpty && !contact.firstName.isEmpty {
                    Button {
                        Task { await vm.ensureEmailForProspect(prospectId: prospect.id) }
                    } label: {
                        if vm.prospectBusyId == prospect.id
                            && vm.prospectBusyLabel?.contains("Email") == true {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                                Text("Tahmin…").font(.caption)
                            }
                        } else {
                            Label("Email Tahmin Et", systemImage: "wand.and.stars")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.prospectBusyId == prospect.id)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BouncePauseBanner: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sender Reputation Koruması — Sending Pause")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text("Bugün \(vm.dailyBounceCount) hard bounce tespit edildi. Inbox'taki postmaster mail'lerini gözden geçir, ilgili prospect'lerin email'ini düzelt, sonra pause'u kaldır.")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                vm.resumeSendingAfterBounceReview()
            } label: {
                Label("Pause'u Kaldır", systemImage: "play.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.red.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct DedupCard: View {
    let dedup: DedupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Salesforce Dedup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(dedup.decision.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(decisionColor.opacity(0.18)))
                    .foregroundStyle(decisionColor)
            }
            if let acc = dedup.accountName {
                Text("Account: \(acc)").font(.caption).foregroundStyle(.secondary)
            }
            if let lead = dedup.leadOwner {
                Text("Lead Owner: \(lead) (\(dedup.leadStatus ?? "—"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let opp = dedup.opportunityName {
                Text("Opp: \(opp) — \(dedup.opportunityStage ?? "—") (\(dedup.opportunityCloseDate ?? "—"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var decisionColor: Color {
        switch dedup.decision {
        case .freshNoRecord:           return .green
        case .disqualifiedLead:        return .blue
        case .closedLost:              return .orange
        case .openLeadOtherRep:        return .purple
        case .skippedActiveAccount,
             .skippedOpenOpportunity:  return .red
        }
    }
}

private struct ScoreCard: View {
    let score: ProspectScore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI Skor")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                StarBadgeBig(stars: score.stars)
            }
            HStack(spacing: 14) {
                ScoreBar(label: "ICP Fit", value: score.icpFit, color: .green)
                ScoreBar(label: "Revenue Fit", value: score.revenueFit, color: .indigo)
            }
            if !score.rationale.isEmpty {
                Text(score.rationale)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !score.matchedSignals.isEmpty {
                FlowTags(items: score.matchedSignals, color: .green, prefix: "✓")
            }
            if !score.concerns.isEmpty {
                FlowTags(items: score.concerns, color: .red, prefix: "!")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StarBadgeBig: View {
    let stars: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Image(systemName: i < stars ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(i < stars ? Color.yellow : .secondary.opacity(0.3))
            }
        }
    }
}

private struct ScoreBar: View {
    let label: String
    let value: Double          // 0-1
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption2.weight(.semibold))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * value))
                }
            }
            .frame(height: 5)
        }
    }
}

private struct FlowTags: View {
    let items: [String]
    let color: Color
    let prefix: String

    var body: some View {
        // Simple horizontal wrap.
        let columns = [GridItem(.adaptive(minimum: 120), spacing: 4)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text("\(prefix) \(item)")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Sequence

private struct SequenceCard: View {
    let prospect: Prospect

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sequence (\(prospect.sequenceSteps.count) step)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if prospect.queue == .winBack {
                    Text("Win-Back")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
            }
            ForEach(prospect.sequenceSteps) { step in
                StepRow(prospect: prospect, step: step)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StepRow: View {
    let prospect: Prospect
    let step: SequenceStep
    @State private var expanded = false
    @State private var editing = false
    @State private var draftSubject: String = ""
    @State private var draftBody: String = ""
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(step.channel.color.opacity(0.18))
                    Image(systemName: step.channel.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(step.channel.color)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Day \(step.dayOffset)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(step.channel.label)
                            .font(.caption.weight(.medium))
                        Spacer()
                        StepStatusBadge(status: step.status)
                    }
                    if let subj = step.subject, !subj.isEmpty {
                        Text(subj).font(.caption).lineLimit(1)
                    } else if !step.body.isEmpty {
                        Text(step.body.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if editing {
                        if step.channel == .email || step.channel == .linkedinInMail {
                            TextField("Subject", text: $draftSubject)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextEditor(text: $draftBody)
                            .font(.system(.callout, design: .default))
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(.secondary.opacity(0.3), lineWidth: 0.5))
                        HStack {
                            Spacer()
                            Button("İptal") {
                                editing = false
                            }
                            Button("Kaydet") {
                                vm.editStep(prospectId: prospect.id, stepId: step.id,
                                            subject: draftSubject.isEmpty ? nil : draftSubject,
                                            body: draftBody)
                                editing = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        if let subj = step.subject, !subj.isEmpty {
                            Text("Subject: \(subj)")
                                .font(.caption.weight(.medium))
                        }
                        if !step.body.isEmpty {
                            Text(step.body)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.background.opacity(0.5),
                                            in: RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text("(taslak boş — AI henüz draft etmedi)")
                                .font(.caption).foregroundStyle(.secondary).italic()
                        }
                        if let r = step.rationale, !r.isEmpty {
                            Text("AI: \(r)").font(.caption2).foregroundStyle(.secondary)
                        }
                        if step.status == .repliedTo, let summary = step.replySummary {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Cevap Geldi", systemImage: "bubble.left.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.mint)
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.mint.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4))
                        }
                        if let why = step.failureReason {
                            Text("Hata: \(why)")
                                .font(.caption).foregroundStyle(.red)
                        }
                        // Action row
                        HStack(spacing: 6) {
                            if step.status == .drafted || step.status == .approved {
                                Button {
                                    draftSubject = step.subject ?? ""
                                    draftBody = step.body
                                    editing = true
                                } label: {
                                    Label("Düzenle", systemImage: "pencil").font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            if step.status == .drafted || step.status == .approved {
                                Button {
                                    vm.skipStep(prospectId: prospect.id, stepId: step.id)
                                } label: {
                                    Label("Atla", systemImage: "forward").font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Spacer()
                            if step.status == .repliedTo {
                                Button {
                                    Task { await vm.openProspectReplyInInbox(prospectId: prospect.id) }
                                } label: {
                                    Label("Inbox'ta Cevap Yaz", systemImage: "arrowshape.turn.up.left.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else if isNextStep && (step.status == .drafted || step.status == .approved) {
                                Button {
                                    Task { await vm.sendNextStep(prospectId: prospect.id) }
                                } label: {
                                    if step.channel.isAutoSend {
                                        Label("Şimdi Gönder", systemImage: "paperplane.fill")
                                            .font(.caption)
                                    } else {
                                        Label("LinkedIn'de Aç", systemImage: "arrow.up.right.square")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(vm.prospectBusyId == prospect.id)
                            }
                        }
                    }
                }
                .padding(.leading, 38)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }
        }
    }

    private var isNextStep: Bool {
        prospect.currentStepIndex < prospect.sequenceSteps.count
            && prospect.sequenceSteps[prospect.currentStepIndex].id == step.id
    }
}

private struct StepStatusBadge: View {
    let status: SequenceStepStatus
    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(status.color.opacity(0.18)))
            .foregroundStyle(status.color)
    }
}

// MARK: - Salesforce + Action

private struct SalesforceCard: View {
    let leadId: String
    let leadUrl: String?
    let taskCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Salesforce Lead")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let url = leadUrl, let u = URL(string: url) {
                    Link(leadId, destination: u)
                        .font(.callout).foregroundStyle(Color.accentColor)
                } else {
                    Text(leadId).font(.callout)
                }
                if taskCount > 0 {
                    Text("\(taskCount) Activity Task loglandı")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActionPanel: View {
    let prospect: Prospect
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if prospect.score == nil {
                    Button {
                        Task { await vm.runWebEnrichment(prospectId: prospect.id) }
                    } label: {
                        Label("Webden Zenginleştir", systemImage: "globe.badge.chevron.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .help("Şirket web sitesi + LinkedIn şirket sayfası + Crunchbase'i tarayıp eksik alanları doldurur")
                }
                if prospect.dedup == nil {
                    Button {
                        Task { await vm.runDedup(prospectId: prospect.id) }
                    } label: {
                        Label("Dedup", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                if prospect.dedup?.decision.shouldSequence == true && prospect.score == nil {
                    Button {
                        Task { await vm.runScoring(prospectId: prospect.id) }
                    } label: {
                        Label("Skorla", systemImage: "chart.bar")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                if prospect.score != nil && prospect.sequenceSteps.isEmpty {
                    Button {
                        Task { await vm.runSequenceDraft(prospectId: prospect.id) }
                    } label: {
                        Label("Sequence Draft Et", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
                if !prospect.sequenceSteps.isEmpty
                   && prospect.sequenceSteps.contains(where: { $0.status == .drafted }) {
                    Button {
                        vm.approveAllSteps(prospectId: prospect.id)
                    } label: {
                        Label("Hepsini Onayla", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                if prospect.salesforceLeadId == nil
                   && prospect.dedup?.decision.shouldSequence == true {
                    Button {
                        Task { await vm.pushToSalesforce(prospectId: prospect.id) }
                    } label: {
                        Label("SF'ye Lead Yaz", systemImage: "icloud.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                Spacer()
            }
            if let label = vm.prospectBusyLabel, vm.prospectBusyId == prospect.id {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text(label + "…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var busy: Bool { vm.prospectBusyId == prospect.id }
}

// MARK: - Import sheet

private struct ImportProspectSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yeni Prospect")
                        .font(.title3.weight(.semibold))
                    Text("Otomatik keşif, App Store araması ya da elle paste — istediğin yolu seç.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("Yöntem", selection: $vm.prospectImportMode) {
                ForEach(AppViewModel.ProspectImportMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch vm.prospectImportMode {
                case .paste:        PasteProspectForm()
                case .autoDiscover: AutoDiscoveryForm()
                case .appStore:     AppStoreDiscoveryForm()
                }
            }

            if let err = vm.prospectImportError {
                Text(err)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            if let summary = vm.lastImportSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420)
    }
}

private struct PasteProspectForm: View {
    @Environment(AppViewModel.self) private var vm
    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 8) {
            Text("Crunchbase profili / LinkedIn About / serbest metin paste et — AI parse eder.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $vm.prospectImportText)
                .font(.system(.callout, design: .default))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(.secondary.opacity(0.3), lineWidth: 0.5))
            HStack {
                Spacer()
                Button {
                    Task { await vm.importProspectFromText() }
                } label: {
                    if vm.isImportingProspect {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            Text("Parse ediliyor…")
                        }
                    } else {
                        Text("AI Parse")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.prospectImportText.trimmingCharacters(in: .whitespaces).isEmpty
                          || vm.isImportingProspect)
            }
        }
    }
}

private struct AutoDiscoveryForm: View {
    @Environment(AppViewModel.self) private var vm

    private static let verticals = [
        "Live-Commerce", "Social", "Future of Work",
        "Faith Tech", "EdTech", "Media & Entertainment",
        "Healthcare", "Live Streaming", "Audio Rooms / Social Audio"
    ]
    private static let countries = [
        "Türkiye", "UK", "Germany", "Sweden", "Norway",
        "Spain", "Italy", "Netherlands", "Poland"
    ]

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude WebSearch + WebFetch ile gerçek şirket araştırması yapar. ICP V1 + ülke filtreleri otomatik uygulanır. **2-5 dakika** sürebilir — Anthropic 30-40 web search adımı çalıştırıyor.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vertical").font(.caption).foregroundStyle(.secondary)
                    Picker("Vertical", selection: $vm.discoveryVertical) {
                        ForEach(Self.verticals, id: \.self) { v in
                            Text(v).tag(v)
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ülke").font(.caption).foregroundStyle(.secondary)
                    Picker("Ülke", selection: $vm.discoveryCountry) {
                        ForEach(Self.countries, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Şirket sayısı").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(vm.discoveryCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Slider(value: Binding(
                    get: { Double(vm.discoveryCount) },
                    set: { vm.discoveryCount = Int($0) }
                ), in: 3...25, step: 1)
            }

            HStack {
                Text("Kaynaklar: Crunchbase summary, LinkedIn şirket sayfaları, webrazzi, startups.watch, App Store, sektör haberleri.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    Task { await vm.runAutoDiscovery() }
                } label: {
                    if vm.isImportingProspect {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            Text("Aranıyor…")
                        }
                    } else {
                        Label("Keşfet", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isImportingProspect)
            }
        }
    }
}

private struct AppStoreDiscoveryForm: View {
    @Environment(AppViewModel.self) private var vm

    private static let countryCodes: [(String, String)] = [
        ("tr", "🇹🇷 Türkiye"), ("gb", "🇬🇧 UK"), ("de", "🇩🇪 Germany"),
        ("se", "🇸🇪 Sweden"), ("nl", "🇳🇱 Netherlands"), ("es", "🇪🇸 Spain"),
        ("it", "🇮🇹 Italy"), ("fr", "🇫🇷 France"), ("us", "🇺🇸 US")
    ]
    private static let presetQueries = [
        "live commerce", "live shopping", "canlı yayın alışveriş",
        "social audio", "audio rooms", "video call",
        "live streaming", "sohbet odaları", "ibadet namaz",
        "education video", "fitness coaching"
    ]

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 12) {
            Text("iTunes Lookup API — Apple'ın public endpoint'i. SDK detection yok (Apptopia paid) ama mobile-first şirketleri hızlıca bulur. Aynı şirketin birden çok app'i varsa tek prospect olur.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arama").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("e.g. live commerce", text: $vm.appStoreQuery)
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(Self.presetQueries, id: \.self) { q in
                                Button(q) { vm.appStoreQuery = q }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.callout)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Market").font(.caption).foregroundStyle(.secondary)
                    Picker("Market", selection: $vm.appStoreCountry) {
                        ForEach(Self.countryCodes, id: \.0) { code, label in
                            Text(label).tag(code)
                        }
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: 180)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Üst limit").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(vm.appStoreLimit) app")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Slider(value: Binding(
                    get: { Double(vm.appStoreLimit) },
                    set: { vm.appStoreLimit = Int($0) }
                ), in: 5...50, step: 5)
            }

            HStack {
                Text("Apple iTunes Lookup public — auth yok, rate-limited 100 req/dk.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await vm.runAppStoreDiscovery() }
                } label: {
                    if vm.isImportingProspect {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            Text("Aranıyor…")
                        }
                    } else {
                        Label("App Store'da Ara", systemImage: "iphone.gen2")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isImportingProspect
                          || vm.appStoreQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
