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
            Picker("Mail sayısı", selection: Binding(
                get: { vm.inboxLimit },
                set: { v in vm.inboxLimit = v; Task { await vm.refreshInbox() } }
            )) {
                Text("20").tag(20)
                Text("30").tag(30)
                Text("50").tag(50)
                Text("100").tag(100)
            }
            .pickerStyle(.menu)

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
