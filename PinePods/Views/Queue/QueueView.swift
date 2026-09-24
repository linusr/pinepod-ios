import SwiftUI

/// The play queue: drag to reorder, swipe to remove.
struct QueueView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings

    @State private var editMode: EditMode = .inactive
    @State private var confirmClear = false
    @State private var hasLoaded = false

    var body: some View {
        List {
            Section {
                ForEach(library.queuedEpisodes) { episode in
                    NavigationLink {
                        EpisodeDetailView(episode: episode)
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .episodeActions(episode, swipes: false)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await library.removeFromQueue(episode) }
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                }
                .onMove { source, destination in
                    Task { await library.moveQueue(fromOffsets: source, toOffset: destination) }
                }
            } footer: {
                if !library.queuedEpisodes.isEmpty {
                    Text(summary)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .overlay {
            if library.queuedEpisodes.isEmpty {
                if hasLoaded {
                    ContentUnavailableView {
                        Label("Queue Is Empty", systemImage: "list.bullet")
                    } description: {
                        Text("Long-press any episode and choose Play Next or Add to Queue.")
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Up Next")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: Binding(
                        get: { settings.continuePlayback },
                        set: { settings.continuePlayback = $0 }
                    )) {
                        Label("Continue Playing Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        Label(editMode.isEditing ? "Done Reordering" : "Reorder", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(library.queuedEpisodes.count < 2)
                    Divider()
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                    .disabled(library.queuedEpisodes.isEmpty)
                } label: {
                    Label("Queue Options", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog("Clear the queue?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Queue", role: .destructive) {
                Task { await library.clearQueue() }
            }
        } message: {
            Text("Episodes stay in your library; only the queue is emptied.")
        }
        .refreshable { await library.loadQueue() }
        .task {
            await library.loadQueue()
            hasLoaded = true
        }
    }

    private var summary: String {
        let seconds = library.queuedEpisodes.reduce(0) { $0 + ($1.remainingSeconds ?? 0) }
        let count = library.queuedEpisodes.count
        return "\(count) episode\(count == 1 ? "" : "s") · \(Formatters.compactDuration(seconds: seconds)) left"
    }
}
