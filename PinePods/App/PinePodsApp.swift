import SwiftUI

@main
struct PinePodsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var session = SessionStore.shared
    @State private var library = LibraryStore.shared
    @State private var player = AudioPlayerController.shared
    @State private var settings = SettingsStore.shared
    @State private var router = AppRouter.shared
    @State private var downloads = DownloadManager.shared
    @State private var outbox = SyncOutbox.shared
    @State private var automation = AutomationEngine.shared

    init() {
        #if DEBUG
        DemoMode.installIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(library)
                .environment(player)
                .environment(settings)
                .environment(router)
                .environment(downloads)
                .environment(outbox)
                .environment(automation)
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            if showsApp {
                RootTabView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showsApp)
        .tint(Theme.accent)
        .onOpenURL { url in
            // kural://nowplaying — tapped from a widget.
            guard url.scheme == "kural", url.host() == "nowplaying", showsApp else { return }
            AppRouter.shared.presentPlayer()
        }
        .task {
            WidgetPublisher.setNeedsUpdate()
        }
    }

    private var showsApp: Bool {
        #if DEBUG
        if DemoMode.isActive { return true }
        #endif
        return session.isLoggedIn
    }
}
