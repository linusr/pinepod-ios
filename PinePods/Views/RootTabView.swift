import SwiftUI

struct RootTabView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @Namespace private var playerTransition

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Feed", systemImage: "dot.radiowaves.left.and.right", value: AppTab.feed) {
                FeedView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                PodcastListView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: AppTab.downloads) {
                DownloadsView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: player.currentEpisode != nil) {
            MiniPlayerView { router.presentPlayer() }
                .matchedTransitionSource(id: "now-playing", in: playerTransition)
        }
        .fullScreenCover(isPresented: $router.isPlayerPresented) {
            PlayerView()
                .navigationTransition(.zoom(sourceID: "now-playing", in: playerTransition))
        }
        .sheet(isPresented: $router.isSettingsPresented) {
            SettingsView()
        }
        .task {
            if !library.podcastsLoaded {
                await library.loadPodcasts()
            }
            if library.homeOverview == nil {
                await library.loadHome()
            }
            await library.loadQueue()
            AutomationEngine.shared.runIfDue()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            SyncOutbox.shared.flush()
            Task { await library.loadQueue() }
            AutomationEngine.shared.runIfDue()
        }
    }
}

/// Toolbar avatar that opens Settings.
struct AccountButton: View {
    @Environment(SessionStore.self) private var session
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.isSettingsPresented = true
        } label: {
            Text(initial)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.7), Theme.accent],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account and Settings")
    }

    private var initial: String {
        session.username.first.map { String($0).uppercased() } ?? "P"
    }
}
