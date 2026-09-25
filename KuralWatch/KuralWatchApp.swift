import SwiftUI

@main
struct KuralWatchApp: App {
    @State private var store = WatchStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(Color(hex: store.snapshot.accentHex))
        }
    }
}
