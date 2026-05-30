import SwiftUI

struct RightPanelView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var tab: PanelTab = .draft

    enum PanelTab: String, CaseIterable, Identifiable {
        case draft = "Taslak Yanıt"
        case tasks = "Görevler"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(PanelTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()
            Group {
                switch tab {
                case .draft: DraftPane()
                case .tasks: TasksFromMailPane()
                }
            }
        }
    }
}

// MARK: - Draft

private struct DraftPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 10) {
            if vm.loadedEmail == nil {
                ContentUnavailableView(
                    "Taslak için mail seç",
                    systemImage: "square.and.pencil",
                    description: Text("Sol panelden bir mail seçtikten sonra yanıt taslağı oluşturabilirim.")
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Niyet / talimat (opsiyonel)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $vm.draftIntent)
                        .font(.callout)
                        .frame(minHeight: 60, maxHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.tertiary))
                }

                HStack {
                    Button {
                        Task { await vm.generateDraft() }
                    } label: {
                        if vm.isDrafting {
                            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                        } else {
                            Label("Taslak Üret", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(vm.isDrafting)
                    Spacer()
                }

                if let draft = vm.draft {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Tag(text: "Ton: \(draft.tone)", color: .indigo)
                            if vm.editedDraftBody != draft.body {
                                Tag(text: "Düzenlendi", color: .orange)
                            }
                            Spacer()
                            Button {
                                vm.resetDraftEdits()
                            } label: {
                                Label("Sıfırla", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(vm.editedDraftBody == draft.body)
                            .help("AI'nın orijinal taslağına dön")
                        }
                        if !draft.rationale.isEmpty {
                            Text("Mantık: " + draft.rationale)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextEditor(text: $vm.editedDraftBody)
                            .font(.body)
                            .frame(minHeight: 200)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.tertiary))

                        HStack(spacing: 8) {
                            Button {
                                Task { await vm.saveDraftToOutlook(replyAll: false) }
                            } label: {
                                if vm.isSavingDraft {
                                    HStack(spacing: 6) {
                                        ProgressView().scaleEffect(0.55)
                                            .frame(width: 14, height: 14)
                                        Text("Outlook'a yazılıyor…")
                                    }
                                } else if vm.draftJustOpened {
                                    Label("Outlook'ta açıldı ✓", systemImage: "checkmark.circle.fill")
                                } else {
                                    Label("Outlook'ta Aç", systemImage: "paperplane")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(vm.draftJustOpened ? .green : .accentColor)
                            .disabled(vm.isSavingDraft || vm.editedDraftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button {
                                Task { await vm.saveDraftToOutlook(replyAll: true) }
                            } label: {
                                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                            }
                            .disabled(vm.isSavingDraft)

                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vm.editedDraftBody, forType: .string)
                            } label: {
                                Label("Kopyala", systemImage: "doc.on.doc")
                            }
                            .disabled(vm.isSavingDraft)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer()
            }
        }
        .padding(12)
    }
}

// MARK: - Tasks pulled from current email

private struct TasksFromMailPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.loadedEmail == nil {
                ContentUnavailableView(
                    "Görev çıkarmak için mail seç",
                    systemImage: "checklist",
                    description: Text("Açık maildeki eylem maddelerini Görevler sekmene eklerim.")
                )
            } else {
                HStack {
                    Button {
                        Task { await vm.extractTasksFromCurrentEmail() }
                    } label: {
                        if vm.isExtractingTasks {
                            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                        } else {
                            Label("Görevleri Çıkar", systemImage: "wand.and.rays")
                        }
                    }
                    .disabled(vm.isExtractingTasks)
                    Spacer()
                    if !vm.lastExtractedTasks.isEmpty {
                        Text("\(vm.lastExtractedTasks.count) görev eklendi")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                let mailId = vm.loadedEmail?.id ?? ""
                let related = vm.taskStore.tasks(for: mailId)
                if related.isEmpty && !vm.isExtractingTasks {
                    Text("Bu mail için henüz görev yok. AI ile çıkar veya Görevler sekmesinden manuel ekle.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(related) { t in
                                MailTaskRow(task: t)
                            }
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(12)
    }
}

private struct MailTaskRow: View {
    @Environment(AppViewModel.self) private var vm
    let task: TaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                let next: TaskStatus = (task.status == .done) ? .todo : .done
                vm.taskStore.setStatus(task.id, next)
            } label: {
                Image(systemName: task.status.systemImage)
                    .foregroundStyle(task.status.color)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.callout)
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                HStack(spacing: 6) {
                    Tag(text: task.priority.rawValue, color: task.priority.color)
                    if let due = task.dueHint, !due.isEmpty {
                        Tag(text: due, color: .orange)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                vm.taskStore.delete(task.id)
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Görevi sil")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.04)))
    }
}
