import SwiftUI

struct RootView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        HStack(spacing: 0) {
            FeatureSidebar()
                .frame(width: 200)
                .background(.regularMaterial)
            Divider()
            Group {
                switch vm.currentFeature {
                case .inbox:     InboxFeatureView()
                case .tasks:     TasksFeatureView()
                case .calendar:  CalendarFeatureView()
                case .prospects: ProspectsFeatureView()
                case .logs:      LogsFeatureView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Hata",
               isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
               ),
               actions: { Button("Tamam") { vm.errorMessage = nil } },
               message: { Text(vm.errorMessage ?? "") })
        .sheet(item: Binding(
            get: { vm.draftingInviteFromEmail },
            set: { if $0 == nil { vm.cancelInviteFlow() } }
        )) { email in
            InviteSheet(sourceEmail: email)
                .environment(vm)
        }
    }
}

private struct FeatureSidebar: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bağlı Hesap")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(AgoraContext.userEmail)
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(AgoraContext.userEmail)
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                ForEach(AppFeature.allCases) { feature in
                    FeatureRow(
                        feature: feature,
                        isSelected: vm.currentFeature == feature,
                        badge: badge(for: feature),
                        enabled: feature.available
                    ) {
                        if feature.available { vm.currentFeature = feature }
                    }
                }
            }
            .padding(.vertical, 6)

            Spacer()

            // Bottom-aligned status hint
            if vm.isTriaging {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("AI mailleri kategorize ediyor…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    @MainActor
    private func badge(for feature: AppFeature) -> String? {
        switch feature {
        case .inbox:
            let unread = vm.emails.filter { !$0.isRead }.count
            return unread > 0 ? "\(unread)" : nil
        case .tasks:
            let pending = vm.taskStore.pendingCount
            return pending > 0 ? "\(pending)" : nil
        case .calendar:
            let upcoming = vm.calendarStore.combinedFeed.filter { !$0.isPast }.count
            return upcoming > 0 ? "\(upcoming)" : nil
        case .prospects:
            let active = vm.prospectStore.activeCount
            return active > 0 ? "\(active)" : nil
        case .logs:
            let errCount = AppLogger.shared.entries.filter { $0.level == .error }.count
            return errCount > 0 ? "\(errCount)" : nil
        }
    }
}

private struct FeatureRow: View {
    let feature: AppFeature
    let isSelected: Bool
    let badge: String?
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: feature.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                Text(feature.rawValue)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (enabled ? .primary : .secondary))
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(
                            isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.18)
                        ))
                        .foregroundStyle(isSelected ? Color.white : .secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor :
                            (hovering && enabled ? Color.primary.opacity(0.06) : Color.clear))
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(!enabled)
    }
}
