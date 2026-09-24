import Observation
import SwiftUI

enum AppTab: Hashable {
    case home, feed, library, downloads, search
}

/// App-level presentation state: selected tab, Now Playing cover, settings sheet.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedTab: AppTab = .home
    var isPlayerPresented = false
    var isSettingsPresented = false

    /// Shown by the Now Playing screen until the player publishes the episode
    /// it is loading.
    private(set) var pendingEpisode: PinepodsEpisode?

    private init() {}

    func presentPlayer(for episode: PinepodsEpisode? = nil) {
        pendingEpisode = episode
        isPlayerPresented = true
    }
}
