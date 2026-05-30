import SwiftUI
import AppKit

struct LogsFeatureView: View {
    @State private var logger = AppLogger.shared
    @State private var levelFilter: LogLevel?
    @State private var categoryFilter: LogCategory?
    @State private var searchQuery: String = ""
    @State private var autoScroll: Bool = true
    @State private var selectedEntryId: UUID?
    @State private var showOnlyTraceId: UUID?

    private var visibleEntries: [LogEntry] {
        var out = logger.entries
        if let t = showOnlyTraceId {
            out = out.filter { $0.traceId == t }
        }
        if let l = levelFilter {
            out = out.filter { $0.level == l }
        }
        if let c = categoryFilter {
            out = out.filter { $0.category == c }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter { e in
                e.message.lowercased().contains(q)
                || e.metadata.values.contains(where: { $0.display.lowercased().contains(q) })
            }
        }
        // En yeni en üstte
        return out.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                listView
                detailView
                    .frame(minWidth: 320, idealWidth: 380)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Loglar")
                    .font(.title3.weight(.semibold))
                Text("(\(logger.entries.count) entry)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([logger.todayLogFileURL])
                } label: {
                    Label("Finder", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    logger.clearMemoryEntries()
                } label: {
                    Label("Memory'i Temizle", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Ara — mesaj, metadata", text: $searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                Menu {
                    Button("Hepsi") { levelFilter = nil }
                    Divider()
                    ForEach(LogLevel.allCases) { lvl in
                        Button {
                            levelFilter = lvl
                        } label: {
                            Label(lvl.label, systemImage: lvl.systemImage)
                        }
                    }
                } label: {
                    pill(label: levelFilter?.label ?? "Level",
                         icon: levelFilter?.systemImage ?? "line.3.horizontal.decrease.circle",
                         color: levelFilter?.color ?? .secondary,
                         active: levelFilter != nil)
                }
                .menuStyle(.borderlessButton).fixedSize()

                Menu {
                    Button("Hepsi") { categoryFilter = nil }
                    Divider()
                    ForEach(LogCategory.allCases) { cat in
                        Button {
                            categoryFilter = cat
                        } label: {
                            Label(cat.label, systemImage: cat.systemImage)
                        }
                    }
                } label: {
                    pill(label: categoryFilter?.label ?? "Kategori",
                         icon: categoryFilter?.systemImage ?? "tag",
                         color: .secondary,
                         active: categoryFilter != nil)
                }
                .menuStyle(.borderlessButton).fixedSize()

                if let t = showOnlyTraceId {
                    pill(label: "Trace: " + String(t.uuidString.prefix(8)),
                         icon: "link",
                         color: .purple,
                         active: true)
                        .onTapGesture { showOnlyTraceId = nil }
                }
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var listView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleEntries) { entry in
                        LogRow(entry: entry, isSelected: selectedEntryId == entry.id)
                            .onTapGesture {
                                selectedEntryId = entry.id
                            }
                            .id(entry.id)
                        Divider().opacity(0.4)
                    }
                }
            }
            .onChange(of: logger.entries.count) { _, _ in
                if autoScroll, let first = visibleEntries.first {
                    withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailView: some View {
        Group {
            if let id = selectedEntryId,
               let entry = logger.entries.first(where: { $0.id == id }) {
                LogDetailView(entry: entry,
                              traceFilter: $showOnlyTraceId)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Detay için bir entry seç.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func pill(label: String, icon: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(
            Capsule().fill(active ? color.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            Capsule().stroke(active ? color.opacity(0.5) : .clear, lineWidth: 0.5)
        )
        .foregroundStyle(active ? color : .primary)
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let isSelected: Bool

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.level.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.level.color)
                .frame(width: 14)
            Text(Self.timeFmt.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(entry.category.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.callout)
                    .lineLimit(2)
                if !entry.metadata.isEmpty {
                    Text(metaSummary)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
    }

    private var metaSummary: String {
        entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.display)" }
            .joined(separator: " · ")
    }
}

private struct LogDetailView: View {
    let entry: LogEntry
    @Binding var traceFilter: UUID?

    private static let fullFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: entry.level.systemImage)
                        .foregroundStyle(entry.level.color)
                    Text(entry.level.label).font(.title3.weight(.semibold))
                    Spacer()
                    Text(entry.category.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }

                Text(entry.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    detailLine("Zaman", Self.fullFmt.string(from: entry.timestamp))
                    detailLine("Entry Id", String(entry.id.uuidString.prefix(8)))
                    if let t = entry.traceId {
                        HStack {
                            detailLine("Trace Id", String(t.uuidString.prefix(8)))
                            Button("Filtrele") {
                                traceFilter = t
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .font(.caption.monospaced())

                if !entry.metadata.isEmpty {
                    Divider()
                    Text("METADATA").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.key)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                Text(item.value.display)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}
