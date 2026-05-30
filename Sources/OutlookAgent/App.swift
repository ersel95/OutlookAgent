import SwiftUI

@main
struct OutlookAgentApp: App {
    @State private var vm = AppViewModel()

    var body: some Scene {
        WindowGroup(AgoraContext.userEmail) {
            RootView()
                .environment(vm)
                .frame(minWidth: 1240, minHeight: 760)
                .task {
                    await vm.refreshInbox()
                    await vm.refreshCalendar()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Agent") {
                Button("Inbox'ı Yenile") {
                    Task { await vm.refreshInbox() }
                }.keyboardShortcut("r")
                Button("Takvimi Yenile") {
                    Task { await vm.refreshCalendar() }
                }.keyboardShortcut("R", modifiers: [.command, .shift])
                Divider()
                Button("Gelen Kutusu") {
                    vm.currentFeature = .inbox
                }.keyboardShortcut("1")
                Button("Görevler") {
                    vm.currentFeature = .tasks
                }.keyboardShortcut("2")
                Button("Takvim") {
                    vm.currentFeature = .calendar
                }.keyboardShortcut("3")
                Button("Prospects") {
                    vm.currentFeature = .prospects
                }.keyboardShortcut("4")
                Button("Loglar") {
                    vm.currentFeature = .logs
                }.keyboardShortcut("5")
            }
        }
    }
}
