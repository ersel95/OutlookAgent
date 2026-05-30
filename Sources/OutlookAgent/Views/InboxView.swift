import SwiftUI

struct InboxView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var deleteCandidate: EmailSummary?

    var body: some View {
        VStack(spacing: 0) {
            CategoryFilterBar()
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial)

            if vm.isLoadingInbox && vm.emails.isEmpty {
                Spacer()
                ProgressView("Inbox yükleniyor…")
                Spacer()
            } else if vm.visibleEmails.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "Hiç mail yok",
                    systemImage: "tray",
                    description: Text("Inbox boş görünüyor ya da filtre eşleşmiyor.")
                )
                Spacer()
            } else {
                List(selection: Binding(
                    get: { vm.selectedEmailId },
                    set: { newId in
                        if let id = newId {
                            Task { await vm.selectEmail(id) }
                        }
                    }
                )) {
                    ForEach(vm.visibleEmails) { email in
                        InboxRow(email: email, triage: vm.triageMap[email.id])
                            .tag(email.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteCandidate = email
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteCandidate = email
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Inbox (\(vm.visibleEmails.count))")
        .confirmationDialog(
            deleteCandidate.map { "“\($0.subject)” silinsin mi?" } ?? "Sil",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sil (Deleted Items'a)", role: .destructive) {
                if let mail = deleteCandidate {
                    Task { await vm.deleteEmail(id: mail.id) }
                }
                deleteCandidate = nil
            }
            Button("İptal", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("Mail Outlook'un Deleted Items klasörüne taşınır. Outlook üzerinden geri alabilirsin.")
        }
    }
}

private struct CategoryFilterBar: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(label: "Tümü",
                           color: .secondary,
                           isOn: vm.categoryFilter == nil && !vm.unreadOnly) {
                    vm.categoryFilter = nil
                    vm.unreadOnly = false
                }
                FilterChip(label: "Okunmamış",
                           color: .accentColor,
                           isOn: vm.unreadOnly) {
                    vm.unreadOnly.toggle()
                }
                ForEach(activeCategories, id: \.self) { cat in
                    FilterChip(
                        label: cat.rawValue,
                        color: cat.color,
                        isOn: vm.categoryFilter == cat
                    ) {
                        vm.categoryFilter = (vm.categoryFilter == cat) ? nil : cat
                    }
                }
            }
        }
    }

    private var activeCategories: [TriageCategory] {
        var seen = Set<TriageCategory>()
        var out: [TriageCategory] = []
        for e in vm.emails {
            if let c = vm.triageMap[e.id]?.category, !seen.contains(c) {
                seen.insert(c); out.append(c)
            }
        }
        return out
    }
}

private struct FilterChip: View {
    let label: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(isOn ? color.opacity(0.25) : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(color.opacity(isOn ? 0.7 : 0.3), lineWidth: 1)
                )
                .foregroundStyle(isOn ? color : .secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct InboxRow: View {
    let email: EmailSummary
    let triage: TriageResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !email.isRead {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
                Text(email.displaySender)
                    .font(.subheadline.weight(email.isRead ? .regular : .semibold))
                    .lineLimit(1)
                Spacer()
                if email.hasAttachments {
                    Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                }
                Text(DateUtil.display(email.date))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text(email.subject.isEmpty ? "(konu yok)" : email.subject)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(email.isRead ? .secondary : .primary)

            Text(email.preview)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)

            if let t = triage {
                HStack(spacing: 6) {
                    Tag(text: t.category.rawValue, color: t.category.color)
                    Tag(text: t.priority.rawValue, color: t.priority.color)
                    if !t.competitorMentions.isEmpty {
                        Tag(text: "Rakip: " + t.competitorMentions.joined(separator: ", "),
                            color: .pink)
                    }
                    if t.dataResidencyFlag {
                        Tag(text: "Veri Yerleşimi", color: .orange)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
