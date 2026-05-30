import SwiftUI

struct TasksFeatureView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var showingNewTask = false

    var body: some View {
        @Bindable var vm = vm
        NavigationSplitView {
            TaskFiltersSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            TaskListPane()
                .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        } detail: {
            TaskDetailPane()
                .navigationSplitViewColumnWidth(min: 360, ideal: 460)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                TextField("Ara…", text: $vm.taskSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    showingNewTask = true
                } label: {
                    Label("Yeni Görev", systemImage: "plus")
                }
                .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskSheet { task in
                vm.addManualTask(task)
                vm.selectedTaskId = task.id
            }
        }
    }
}

// MARK: - Filters sidebar

private struct TaskFiltersSidebar: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        List {
            Section("Durum") {
                FilterRow(label: "Tümü", count: vm.taskStore.tasks.count,
                          isOn: vm.taskStatusFilter == nil) {
                    vm.taskStatusFilter = nil
                }
                ForEach(TaskStatus.allCases) { s in
                    FilterRow(
                        label: s.rawValue,
                        count: vm.taskStore.tasks.filter { $0.status == s }.count,
                        accent: s.color,
                        isOn: vm.taskStatusFilter == s
                    ) {
                        vm.taskStatusFilter = (vm.taskStatusFilter == s) ? nil : s
                    }
                }
            }

            Section("Öncelik") {
                FilterRow(label: "Tümü", count: vm.taskStore.tasks.count,
                          isOn: vm.taskPriorityFilter == nil) {
                    vm.taskPriorityFilter = nil
                }
                ForEach(TaskPriority.allCases) { p in
                    FilterRow(
                        label: p.rawValue,
                        count: vm.taskStore.tasks.filter { $0.priority == p }.count,
                        accent: p.color,
                        isOn: vm.taskPriorityFilter == p
                    ) {
                        vm.taskPriorityFilter = (vm.taskPriorityFilter == p) ? nil : p
                    }
                }
            }

            let accs = vm.taskStore.accounts
            if !accs.isEmpty {
                Section("Hesap / Domain") {
                    FilterRow(label: "Tümü", count: vm.taskStore.tasks.count,
                              isOn: vm.taskAccountFilter == nil) {
                        vm.taskAccountFilter = nil
                    }
                    ForEach(accs, id: \.self) { a in
                        FilterRow(
                            label: a,
                            count: vm.taskStore.tasks.filter { $0.account == a }.count,
                            isOn: vm.taskAccountFilter == a
                        ) {
                            vm.taskAccountFilter = (vm.taskAccountFilter == a) ? nil : a
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Filtreler")
    }
}

private struct FilterRow: View {
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

// MARK: - List

private struct TaskListPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        let items = vm.filteredTasks
        if items.isEmpty {
            ContentUnavailableView(
                "Görev yok",
                systemImage: "checklist",
                description: Text("Sağ üstten yeni görev ekle veya bir mailden AI ile çıkart.")
            )
        } else {
            List(selection: Binding(
                get: { vm.selectedTaskId },
                set: { vm.selectedTaskId = $0 }
            )) {
                ForEach(groupedByStatus(items), id: \.0) { (status, group) in
                    Section(header: HStack {
                        Image(systemName: status.systemImage).foregroundStyle(status.color)
                        Text(status.rawValue)
                        Spacer()
                        Text("\(group.count)").foregroundStyle(.secondary).font(.caption)
                    }) {
                        ForEach(group) { t in
                            TaskListRow(task: t).tag(t.id)
                                .contextMenu {
                                    Menu("Durum") {
                                        ForEach(TaskStatus.allCases) { s in
                                            Button(s.rawValue) { vm.taskStore.setStatus(t.id, s) }
                                        }
                                    }
                                    Menu("Öncelik") {
                                        ForEach(TaskPriority.allCases) { p in
                                            Button(p.rawValue) { vm.taskStore.setPriority(t.id, p) }
                                        }
                                    }
                                    if t.sourceEmailId != nil {
                                        Button("Kaynak Maili Aç") {
                                            Task { await vm.openTaskSource(t) }
                                        }
                                    }
                                    Divider()
                                    Button("Sil", role: .destructive) {
                                        vm.taskStore.delete(t.id)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func groupedByStatus(_ items: [TaskItem]) -> [(TaskStatus, [TaskItem])] {
        var dict: [TaskStatus: [TaskItem]] = [:]
        for it in items { dict[it.status, default: []].append(it) }
        return TaskStatus.allCases.compactMap { s in
            guard let arr = dict[s], !arr.isEmpty else { return nil }
            return (s, arr)
        }
    }
}

private struct TaskListRow: View {
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
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.callout.weight(.medium))
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                HStack(spacing: 6) {
                    Tag(text: task.priority.rawValue, color: task.priority.color)
                    if let due = task.dueHint, !due.isEmpty {
                        Tag(text: due, color: .orange)
                    }
                    if task.isOverdue {
                        Tag(text: "Gecikti", color: .red)
                    }
                    if let acc = task.account, !acc.isEmpty {
                        Tag(text: acc, color: .indigo)
                    }
                    if let cat = task.category, !cat.isEmpty {
                        Tag(text: cat, color: .purple)
                    }
                }
                if let subj = task.sourceSubject, !subj.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "envelope").font(.caption2)
                        Text(subj).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

private struct TaskDetailPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        if let task = vm.selectedTask {
            TaskDetailEditor(task: task)
        } else {
            ContentUnavailableView(
                "Görev seç",
                systemImage: "rectangle.and.text.magnifyingglass",
                description: Text("Listeden bir görev seç ya da yeni görev ekle.")
            )
        }
    }
}

private struct TaskDetailEditor: View {
    @Environment(AppViewModel.self) private var vm
    let task: TaskItem

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .normal
    @State private var account: String = ""
    @State private var contactEmail: String = ""
    @State private var dueDate: Date = Date()
    @State private var hasDueDate: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Başlık", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { commit() }

                HStack {
                    Picker("Durum", selection: $status) {
                        ForEach(TaskStatus.allCases) { s in
                            Label(s.rawValue, systemImage: s.systemImage).tag(s)
                        }
                    }
                    Picker("Öncelik", selection: $priority) {
                        ForEach(TaskPriority.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                }

                Toggle("Tarihli", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Bitiş", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                }

                TextField("Hesap / Domain", text: $account)
                    .textFieldStyle(.roundedBorder)
                TextField("İletişim e-postası", text: $contactEmail)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notlar").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tertiary))
                }

                if let subj = task.sourceSubject, !subj.isEmpty {
                    GroupBox("Kaynak") {
                        HStack {
                            Image(systemName: "envelope")
                            Text(subj).font(.callout).lineLimit(2)
                            Spacer()
                            Button("Maili Aç") {
                                Task { await vm.openTaskSource(task) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                HStack {
                    Button("Kaydet") { commit() }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                    Button("Sil", role: .destructive) {
                        vm.taskStore.delete(task.id)
                        vm.selectedTaskId = nil
                    }
                    Spacer()
                    Text("Oluşturuldu: \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .id(task.id)
        .onAppear { load(from: task) }
        .onChange(of: task.id) { _, _ in load(from: task) }
    }

    private func load(from t: TaskItem) {
        title = t.title
        notes = t.notes
        status = t.status
        priority = t.priority
        account = t.account ?? ""
        contactEmail = t.contactEmail ?? ""
        if let d = t.dueDate {
            dueDate = d; hasDueDate = true
        } else {
            hasDueDate = false
        }
    }

    private func commit() {
        var t = task
        t.title = title
        t.notes = notes
        t.status = status
        t.priority = priority
        t.account = account.isEmpty ? nil : account
        t.contactEmail = contactEmail.isEmpty ? nil : contactEmail
        t.dueDate = hasDueDate ? dueDate : nil
        if status == .done && t.completedAt == nil { t.completedAt = Date() }
        vm.taskStore.update(t)
    }
}

// MARK: - New task sheet

private struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCreate: (TaskItem) -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var priority: TaskPriority = .normal
    @State private var hasDueDate = false
    @State private var dueDate: Date = Date().addingTimeInterval(86400)
    @State private var account = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Yeni Görev").font(.title3.weight(.semibold))
            TextField("Başlık", text: $title)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Öncelik", selection: $priority) {
                    ForEach(TaskPriority.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                Toggle("Tarih", isOn: $hasDueDate)
            }
            if hasDueDate {
                DatePicker("Bitiş", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
            }
            TextField("Hesap / Domain (ops.)", text: $account)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("Notlar").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes).frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tertiary))
            }
            HStack {
                Button("İptal") { dismiss() }
                Spacer()
                Button("Oluştur") {
                    let t = TaskItem(
                        title: title, notes: notes,
                        status: .todo, priority: priority,
                        dueDate: hasDueDate ? dueDate : nil,
                        account: account.isEmpty ? nil : account
                    )
                    onCreate(t)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
