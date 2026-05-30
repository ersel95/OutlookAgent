import SwiftUI
import Sparkle

/// Owns Sparkle'ın updater'ını. `startingUpdater: true` background scheduler'ı
/// hemen başlatır; `SUEnableAutomaticChecks` Info.plist'te true olduğu için
/// launch ve günlük interval'de appcast.xml'i poll eder. `SUAutomaticallyUpdate`
/// false — yeni sürüm bulunsa bile kullanıcı onay vermeden install etmez.
@MainActor
final class UpdaterController: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

/// Manuel "Check for Updates…" menu item'ının enable/disable state'ini takip eder.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// Menu item: "Güncellemeleri Denetle…" — App.swift `.commands` içinde kullanılıyor.
@MainActor
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Güncellemeleri Denetle…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
