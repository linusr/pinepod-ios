import SwiftUI

struct PodcastListView: View {
    @Environment(LibraryStore.self) private var library

    @AppStorage("library_sort") private var sort: Sort = .title

    enum Sort: String, CaseIterable, Identifiable {
        case title = "Title"
        case episodes = "Most Episodes"
        case favorites = "Favorites First"

        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.podcasts.isEmpty && !library.podcastsLoaded {
                    ProgressView()
                        .padding(.top, 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(sortedPodcasts) { podcast in
                            NavigationLink {
                                PodcastDetailView(podcastId: podcast.id, title: podcast.title, artworkUrl: podcast.imageUrl)
                            } label: {
                                PodcastTile(podcast: podcast)
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.96))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
            .overlay {
                if library.podcasts.isEmpty && library.podcastsLoaded {
                    ContentUnavailableView {
                        Label("No Shows Yet", systemImage: "square.stack")
                    } description: {
                        Text("Podcasts you subscribe to on your PinePods server appear here.")
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    AccountButton()
                }
            }
            .refreshable {
                await library.loadPodcasts()
            }
        }
    }

    private var sortedPodcasts: [Podcast] {
        switch sort {
        case .title:
            library.podcasts.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .episodes:
            library.podcasts.sorted { $0.episodeCount > $1.episodeCount }
        case .favorites:
            library.podcasts.sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }
}

private struct PodcastTile: View {
    let podcast: Podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(podcast.imageUrl, cornerRadius: 16)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .overlay(alignment: .topTrailing) {
                    if podcast.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.pink)
                            .padding(7)
                            .glassEffect(.regular, in: Circle())
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(podcast.episodeCount) episodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PodcastDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayerController.self) private var player

    let podcastId: Int
    let title: String
    var artworkUrl: String?

    @State private var isLoading = true
    @State private var filter: Filter = .all
    @State private var descriptionExpanded = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unplayed = "Unplayed"
        case downloaded = "Downloaded"

        var id: String { rawValue }
    }

    private var podcast: Podcast? {
        library.podcasts.first { $0.id == podcastId }
    }

    private var episodes: [PinepodsEpisode] {
        library.cachedEpisodes(for: podcastId) ?? []
    }

    private var artwork: String? {
        if let url = podcast?.imageUrl, !url.isEmpty { return url }
        if let artworkUrl, !artworkUrl.isEmpty { return artworkUrl }
        return episodes.first?.episodeArtwork
    }

    private var filteredEpisodes: [PinepodsEpisode] {
        switch filter {
        case .all: episodes
        case .unplayed: episodes.filter { !$0.completed }
        case .downloaded: episodes.filter(\.downloaded)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)

                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                if isLoading && episodes.isEmpty {
                    ProgressView().padding(.top, 40)
                } else if filteredEpisodes.isEmpty {
                    ContentUnavailableView {
                        Label("No Episodes", systemImage: "waveform")
                    } description: {
                        Text(filter == .all ? "This show has no episodes yet." : "No \(filter.rawValue.lowercased()) episodes.")
                    }
                    .padding(.top, 20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEpisodes) { episode in
                            NavigationLink {
                                EpisodeDetailView(episode: episode)
                            } label: {
                                EpisodeRow(episode: episode, showsPodcast: false, showsDescription: true)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .episodeActions(episode)
                            Divider().padding(.leading, 98)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(alignment: .top) {
            ArtworkBackdrop(artwork, style: .header)
                .frame(height: 520)
                .ignoresSafeArea()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            _ = await library.episodes(for: podcastId, force: true)
        }
        .task {
            _ = await library.episodes(for: podcastId)
            isLoading = false
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkImage(artwork, cornerRadius: 20)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                .padding(.top, 8)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let author = podcast?.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PineGreen)
                }
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let latest = episodes.first {
                Button {
                    Task { await player.playOrToggle(latest) }
                } label: {
                    Label(playLabel(latest), systemImage: isPlaying(latest) ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: 260)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(PineGreen)
                .controlSize(.large)
            }

            if let description = podcast?.description, !description.isEmpty {
                Text(HTMLText.plainText(description))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy) { descriptionExpanded.toggle() }
                    }
                    .accessibilityHint(descriptionExpanded ? "Collapses description" : "Expands description")
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        let count = podcast?.episodeCount ?? episodes.count
        if count > 0 { parts.append("\(count) episodes") }
        if let categories = podcast?.categories {
            parts.append(categories.components(separatedBy: ", ").prefix(2).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func isPlaying(_ episode: PinepodsEpisode) -> Bool {
        player.currentEpisode?.episodeId == episode.episodeId && player.isPlaying
    }

    private func playLabel(_ episode: PinepodsEpisode) -> String {
        if isPlaying(episode) { return "Pause" }
        return episode.progressPercentage > 0 && !episode.completed ? "Resume Latest" : "Play Latest"
    }
}
