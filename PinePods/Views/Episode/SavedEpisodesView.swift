import SwiftUI

struct SavedEpisodesView: View {
    @Environment(LibraryStore.self) private var library

    @State private var hasLoaded = false

    var body: some View {
        List {
            ForEach(library.savedEpisodes) { episode in
                NavigationLink {
                    EpisodeDetailView(episode: episode)
                } label: {
                    EpisodeRow(episode: episode)
                }
                .episodeActions(episode)
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.savedEpisodes.isEmpty {
                if hasLoaded {
                    ContentUnavailableView {
                        Label("No Saved Episodes", systemImage: "bookmark")
                    } description: {
                        Text("Save episodes from any episode page or by long-pressing an episode.")
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Saved")
        .refreshable { await library.loadSaved() }
        .task {
            await library.loadSaved()
            hasLoaded = true
        }
    }
}
