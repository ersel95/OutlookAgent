import SwiftUI

/// Wraps the thread view with a header (subject, participants, actions).
struct ThreadFeatureView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var deleteCurrent = false

    var body: some View {
        Group {
            if vm.isLoadingEmail {
                ProgressView("Mail yükleniyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let thread = vm.thread, let email = vm.loadedEmail {
                let segments = Self.flatten(thread: thread)
                VStack(spacing: 0) {
                    ThreadHeader(thread: thread, email: email,
                                 segmentCount: segments.count,
                                 isLoadingThread: vm.isLoadingThread,
                                 isExtractingInvite: vm.isExtractingInvite,
                                 onMarkRead: { Task { await vm.markCurrentRead() } },
                                 onDelete: { deleteCurrent = true },
                                 onCreateInvite: { Task { await vm.startInviteFlow(from: email) } })
                    Divider()
                    if let triage = vm.triageMap[email.id] {
                        TriageInline(triage: triage)
                            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
                    }
                    ThreadChatView(segments: segments)
                }
                .confirmationDialog(
                    "“\(email.subject)” silinsin mi?",
                    isPresented: $deleteCurrent,
                    titleVisibility: .visible
                ) {
                    Button("Sil (Deleted Items'a)", role: .destructive) {
                        Task { await vm.deleteEmail(id: email.id) }
                    }
                    Button("İptal", role: .cancel) { }
                }
            } else if vm.selectedEmailId == nil {
                ContentUnavailableView(
                    "Mail seçili değil",
                    systemImage: "envelope",
                    description: Text("Sol panelden bir mail seç.")
                )
            } else {
                ContentUnavailableView(
                    "Mail yüklenemedi",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Tekrar denemek için listeden başka bir mail seç.")
                )
            }
        }
    }

    /// Build a deduplicated, chronologically-ordered list of EmailSegments
    /// from all physical messages in the thread. Each physical message body
    /// is split at quote separators and wrote-intros into logical messages.
    static func flatten(thread: EmailThread) -> [EmailSegment] {
        var built: [EmailSegment] = []
        var seen = Set<String>()

        // thread.messages is sorted by Outlook id ascending (earliest physical first)
        for phys in thread.messages {
            var segs = EmailBodyParser.parse(
                phys.body,
                defaultAuthor: phys.fromName,
                defaultEmail: phys.fromAddress,
                sourceMessageId: phys.id,
                sourceFolder: phys.folder
            )
            // Within a physical message: depth N (oldest quote) → 0 (newest body part)
            // We want oldest first, so reverse:
            segs.reverse()

            // Anchor depth==0 (the physical message itself) with the canonical
            // metadata from Outlook: time received, attachments, image paths.
            // Parser's dateRaw for depth==0 is usually empty.
            if let i = segs.firstIndex(where: { $0.depth == 0 }) {
                if (segs[i].dateRaw ?? "").isEmpty {
                    segs[i].dateRaw = phys.date
                }
                if phys.hasAttachments && !phys.attachmentNames.isEmpty {
                    segs[i].attachmentNames = phys.attachmentNames
                }
                if !phys.attachmentPaths.isEmpty {
                    segs[i].attachmentPaths = phys.attachmentPaths
                }
            }

            for seg in segs {
                if !seen.contains(seg.dedupeKey) {
                    seen.insert(seg.dedupeKey)
                    built.append(seg)
                }
            }
        }
        return built
    }
}

private struct ThreadHeader: View {
    let thread: EmailThread
    let email: EmailFull
    let segmentCount: Int
    let isLoadingThread: Bool
    let isExtractingInvite: Bool
    let onMarkRead: () -> Void
    let onDelete: () -> Void
    let onCreateInvite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.subject.isEmpty ? "(konu yok)" : thread.subject)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(.secondary)
                        Text("\(segmentCount) mesaj")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                        Text(thread.participants.prefix(4).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if isLoadingThread {
                            ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                        }
                    }
                }
                Spacer()
                Button(action: onCreateInvite) {
                    if isExtractingInvite {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                            Text("Davet hazırlanıyor…")
                        }
                    } else {
                        Label("Davet Oluştur", systemImage: "calendar.badge.plus")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(isExtractingInvite)
                .help("Bu mailden Outlook takvim daveti öner")

                if !email.isRead {
                    Button("Okundu", action: onMarkRead)
                        .buttonStyle(.borderless).font(.caption)
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Sil", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Maili Deleted Items'a taşı")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct TriageInline: View {
    let triage: TriageResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Tag(text: triage.category.rawValue, color: triage.category.color)
                Tag(text: triage.priority.rawValue, color: triage.priority.color)
                if !triage.competitorMentions.isEmpty {
                    Tag(text: "Rakip: " + triage.competitorMentions.joined(separator: ", "), color: .pink)
                }
                if triage.dataResidencyFlag {
                    Tag(text: "Veri Yerleşimi", color: .orange)
                }
                Spacer()
            }
            if !triage.summary.isEmpty {
                Text(triage.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Chat-style messages

private struct ThreadChatView: View {
    let segments: [EmailSegment]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(segments) { seg in
                        ChatBubble(segment: seg)
                            .id(seg.id)
                            .padding(.horizontal, 14)
                    }
                    Color.clear.frame(height: 12).id("BOTTOM")
                }
                .padding(.top, 12)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
            .onChange(of: segments.first?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }
}

private struct ChatBubble: View {
    let segment: EmailSegment

    private var isMe: Bool { segment.isOutgoing }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMe { Spacer(minLength: 60) }
            if !isMe {
                Avatar(name: segment.displayName, address: segment.authorEmail ?? "")
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isMe {
                        if let d = segment.dateRaw, !d.isEmpty {
                            Text(DateUtil.fullDisplay(d)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Sen").font(.caption.weight(.semibold))
                    } else {
                        Text(segment.displayName)
                            .font(.caption.weight(.semibold))
                        if let d = segment.dateRaw, !d.isEmpty {
                            Text(DateUtil.fullDisplay(d)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                BodyContent(segment: segment, isMe: isMe)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(bubbleColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    )
                    .foregroundStyle(textColor)
                    .frame(maxWidth: 600, alignment: isMe ? .trailing : .leading)

                let bodyMarkers = ChatBodyParts.imageMarkerNames(in: segment.body)
                let nonInlineNames = segment.attachmentNames.filter { !bodyMarkers.contains($0) }
                if !nonInlineNames.isEmpty {
                    AttachmentsBar(
                        names: nonInlineNames,
                        paths: segment.attachmentPaths,
                        isMe: isMe
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)

            if isMe { Avatar(name: "Sen", address: AgoraContext.userEmail) }
            if !isMe { Spacer(minLength: 60) }
        }
    }

    private var bubbleColor: Color {
        if isMe { return Color.accentColor }
        return ParticipantPalette.color(for: segment.authorEmail ?? segment.author ?? "?").opacity(0.18)
    }
    private var borderColor: Color {
        if isMe { return Color.accentColor.opacity(0.4) }
        return ParticipantPalette.color(for: segment.authorEmail ?? segment.author ?? "?").opacity(0.35)
    }
    private var textColor: Color {
        isMe ? .white : .primary
    }

}

// MARK: - Body parts (text + inline images)

enum ChatBodyParts {
    enum Part: Hashable {
        case text(String)
        case image(path: String, name: String)
        case missingImage(name: String)   // marker present, but file not on disk
    }

    private static let markerRegex = try! NSRegularExpression(
        pattern: #"<([^<>\n\r]+\.(?:png|jpg|jpeg|gif|webp|bmp))>"#,
        options: [.caseInsensitive])

    static func split(body: String, paths: [String: String]) -> [Part] {
        let nsRange = NSRange(body.startIndex..., in: body)
        let matches = markerRegex.matches(in: body, range: nsRange)
        if matches.isEmpty {
            return body.isEmpty ? [] : [.text(body)]
        }
        var parts: [Part] = []
        var cursor = body.startIndex
        for m in matches {
            guard let mr = Range(m.range, in: body),
                  let nameR = Range(m.range(at: 1), in: body) else { continue }
            let pre = String(body[cursor..<mr.lowerBound])
            if !pre.isEmpty { parts.append(.text(pre)) }
            let name = String(body[nameR])
            if let path = paths[name] {
                parts.append(.image(path: path, name: name))
            } else {
                parts.append(.missingImage(name: name))
            }
            cursor = mr.upperBound
        }
        let tail = String(body[cursor...])
        if !tail.isEmpty { parts.append(.text(tail)) }
        return parts
    }

    /// Names of images referenced inline in the body (used to hide them from the attachments bar).
    static func imageMarkerNames(in body: String) -> Set<String> {
        let nsRange = NSRange(body.startIndex..., in: body)
        var out = Set<String>()
        for m in markerRegex.matches(in: body, range: nsRange) {
            if let r = Range(m.range(at: 1), in: body) {
                out.insert(String(body[r]))
            }
        }
        return out
    }
}

private struct BodyContent: View {
    let segment: EmailSegment
    let isMe: Bool

    var body: some View {
        let parts = ChatBodyParts.split(body: segment.body, paths: segment.attachmentPaths)
        let visible = parts.compactMap { renderable(for: $0) }
        Group {
            if visible.isEmpty {
                EmptyBodyPlaceholder(isMe: isMe)
            } else {
                VStack(alignment: isMe ? .trailing : .leading, spacing: 8) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, view in
                        view
                    }
                }
                .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            }
        }
    }

    private func renderable(for part: ChatBodyParts.Part) -> AnyView? {
        switch part {
        case .text(let s):
            if let formatted = BodyFormatter.format(s) {
                return AnyView(
                    Text(formatted)
                        .font(.body)
                        .tint(isMe ? Color.white : Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
                )
            }
            return nil
        case .image(let path, let name):
            return AnyView(InlineImageView(path: path, name: name, isMe: isMe))
        case .missingImage(let name):
            return AnyView(
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            )
        }
    }
}

private struct InlineImageView: View {
    let path: String
    let name: String
    let isMe: Bool
    @State private var nsImage: NSImage?
    @State private var hovered = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .scaleEffect(hovered ? 1.015 : 1.0)
                    .shadow(color: .black.opacity(hovered ? 0.18 : 0.0), radius: 8, y: 2)
                    .animation(.easeOut(duration: 0.15), value: hovered)
                    .onHover { hovered = $0 }
                    .onTapGesture { openInPreview() }
                    .help("\(name) · tıkla: Preview'da aç")
            } else if loadFailed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Yüklenemedi: \(name)").font(.caption).italic()
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: path) {
            await load()
        }
    }

    private func load() async {
        let p = path
        let img = await Task.detached(priority: .utility) {
            NSImage(contentsOfFile: p)
        }.value
        await MainActor.run {
            if let img {
                self.nsImage = img
            } else {
                self.loadFailed = true
            }
        }
    }

    private func openInPreview() {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}

private struct EmptyBodyPlaceholder: View {
    let isMe: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.below.ecg")
                .font(.caption)
                .foregroundStyle(isMe ? Color.white.opacity(0.7) : .secondary)
            Text("Metin gövdesi yok — takvim daveti veya HTML-only mail")
                .font(.caption)
                .italic()
                .foregroundStyle(isMe ? Color.white.opacity(0.85) : .secondary)
        }
    }
}

private struct Avatar: View {
    let name: String
    let address: String
    var body: some View {
        let initials = Self.initials(from: name.isEmpty ? address : name)
        let color = ParticipantPalette.color(for: address.isEmpty ? name : address)
        Text(initials)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(color))
            .help(address.isEmpty ? name : "\(name) <\(address)>")
    }

    static func initials(from s: String) -> String {
        let parts = s.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            let a = parts[0].first.map { String($0) } ?? "?"
            let b = parts[1].first.map { String($0) } ?? ""
            return (a + b).uppercased()
        }
        if let first = s.first { return String(first).uppercased() }
        return "?"
    }
}

private struct AttachmentsBar: View {
    let names: [String]
    let paths: [String: String]
    let isMe: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    AttachmentChip(name: name, localPath: paths[name])
                }
            }
        }
        .frame(maxWidth: 600, alignment: isMe ? .trailing : .leading)
    }
}

private struct AttachmentChip: View {
    let name: String
    let localPath: String?
    @State private var thumb: NSImage?
    @State private var hovered = false

    var body: some View {
        Button {
            openLocally()
        } label: {
            HStack(spacing: 6) {
                if let thumb = thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: iconName(for: name))
                        .font(.caption)
                }
                Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(hovered ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(localPath == nil
              ? "\(name) (önbellekte değil — Outlook'ta indirilmeli)"
              : "\(name) · tıkla: Preview'da aç")
        .task(id: localPath) {
            guard let path = localPath else { return }
            let img = await Task.detached(priority: .utility) {
                NSImage(contentsOfFile: path)
            }.value
            await MainActor.run { self.thumb = img }
        }
    }

    private func openLocally() {
        guard let path = localPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func iconName(for name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".pdf") { return "doc.richtext" }
        if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".gif") {
            return "photo"
        }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".gz") { return "archivebox" }
        if lower.hasSuffix(".xlsx") || lower.hasSuffix(".xls") || lower.hasSuffix(".csv") {
            return "tablecells"
        }
        if lower.hasSuffix(".docx") || lower.hasSuffix(".doc") { return "doc.text" }
        if lower.hasSuffix(".pptx") || lower.hasSuffix(".ppt") { return "rectangle.stack" }
        return "paperclip"
    }
}

// MARK: - Deterministic per-participant color

enum ParticipantPalette {
    private static let palette: [Color] = [
        Color(red: 0.30, green: 0.55, blue: 0.95),
        Color(red: 0.55, green: 0.35, blue: 0.95),
        Color(red: 0.95, green: 0.45, blue: 0.55),
        Color(red: 0.20, green: 0.70, blue: 0.55),
        Color(red: 0.95, green: 0.60, blue: 0.20),
        Color(red: 0.45, green: 0.65, blue: 0.85),
        Color(red: 0.85, green: 0.45, blue: 0.85),
        Color(red: 0.20, green: 0.60, blue: 0.75),
        Color(red: 0.65, green: 0.40, blue: 0.30),
        Color(red: 0.50, green: 0.50, blue: 0.55)
    ]

    static func color(for key: String) -> Color {
        let normalized = key.lowercased()
        var hash: UInt64 = 1469598103934665603
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
