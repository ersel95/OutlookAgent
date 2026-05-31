import SwiftUI

/// Inbox feature root: 3-pane (mail list / thread / right panel).
struct InboxFeatureView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        NavigationSplitView {
            InboxView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
        } content: {
            ThreadFeatureView()
                .navigationSplitViewColumnWidth(min: 420, ideal: 520)
        } detail: {
            RightPanelView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        }
        .toolbar { InboxToolbar() }
    }
}

private struct InboxToolbar: ToolbarContent {
    @Environment(AppViewModel.self) private var vm

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Toolbar'da .pickerStyle(.menu) label'i light mode'da render etmiyor
            // (sadece chevron gozukuyor) — Menu + explicit Label ile sariyoruz.
            Menu {
                ForEach([20, 30, 50, 100], id: \.self) { n in
                    Button("\(n) mail") {
                        vm.inboxLimit = n
                        Task { await vm.refreshInbox() }
                    }
                }
            } label: {
                Label("\(vm.inboxLimit)", systemImage: "tray.full")
            }
            .help("Inbox'tan kac mail cekilecegi")

            Button {
                Task { await vm.refreshInbox() }
            } label: {
                if vm.isLoadingInbox || vm.isTriaging {
                    ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
                } else {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
            }
            .disabled(vm.isLoadingInbox)
            .help(vm.isTriaging ? "AI mailleri kategorize ediyor…" : "Outlook'tan tekrar çek")
        }
    }
}
