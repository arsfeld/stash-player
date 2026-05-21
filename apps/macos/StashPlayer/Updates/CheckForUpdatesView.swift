import Sparkle
import SwiftUI

// Sparkle 2.x `SPUUpdater` exposes `canCheckForUpdates` as KVO-compliant
// but not as `ObservableObject`. SwiftUI's `.disabled()` modifier inside a
// `CommandGroup` only updates reactively when its source is an
// `ObservableObject`, so we wrap the KVO publisher in a small VM. Pattern
// is the one Sparkle's own SwiftUI docs use verbatim.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
