import SwiftUI

struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationStack {
            ScrollView {
                if let overview = library.homeOverview {
                    content(overview)
                } else if library.errorMessage != nil {
                    ContentUnavailableView {
                        Label("Couldn't Load Home", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection to the PinePods server, then pull to refresh.")
                    }
                    .padding(.top, 80)
                } else {
                    HomeSkeleton()
                }
            }
            .navigationTitle("Home")
            .navigationSubtitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AccountButton()
                }
            }
            .refreshable {
                await library.loadHome()
            }
            .task {
                if library.homeOverview == nil {
                    await library.loadHome()
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        return session.username.isEmpty ? part : "\(part), \(session.username)"
    }

    private func content(_ overview: HomeOverview) -> some View {
        // Mid-episode only: started, unfinished, and not within a few percent of the end.
        let inProgress = overview.inProgressEpisodes.filter {
            !$0.completed && $0.progressPercentage > 1 && $0.progressPercentage < 97
        }
        let latest = Array(overview.recentEpisodes.prefix(12))
        let queue = library.queuedEpisodes.isEmpty
            ? overview.queuePreview.map(\.asPinepodsEpisode)
            : library.queuedEpisodes
        let upNext = Array(queue.filter { !$0.isNearlyFinished }.prefix(3))

        return LazyVStack(alignment: .leading, spacing: 32) {
            if !inProgress.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("Continue Listening")
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(inProgress) { episode in
                                NavigationLink {
                                    EpisodeDetailView(episode: episode.asPinepodsEpisode)
                                } label: {
                                    ContinueListeningCard(episode: episode.asPinepodsEpisode)
                                        .containerRelativeFrame(.horizontal, count: 8, span: 7, spacing: 12)
                                }
                                .buttonStyle(PressableButtonStyle(scale: 0.97))
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 20, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                }
            }

            if !upNext.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Up Next") {
                        NavigationLink("See All") {
                            QueueView()
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    episodeList(upNext)
                }
            }

            StatsStrip(overview: overview)

            if !overview.topPodcasts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("Your Top Shows")
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(overview.topPodcasts) { podcast in
                                NavigationLink {
                                    PodcastDetailView(
                                        podcastId: podcast.podcastId,
                                        title: podcast.podcastName,
                                        artworkUrl: podcast.artworkUrl)
                                } label: {
                                    TopPodcastTile(podcast: podcast)
                                }
                                .buttonStyle(PressableButtonStyle(scale: 0.96))
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 20, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                }
            }

            if !latest.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Latest Episodes")
                    episodeList(latest.map(\.asPinepodsEpisode))
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private func episodeList(_ episodes: [PinepodsEpisode]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(episodes) { episode in
                NavigationLink {
                    EpisodeDetailView(episode: episode)
                } label: {
                    EpisodeRow(episode: episode)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .episodeActions(episode)
                if episode.id != episodes.last?.id {
                    Divider().padding(.leading, 98)
                }
            }
        }
    }
}

private struct ContinueListeningCard: View {
    let episode: PinepodsEpisode

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkImage(episode.episodeArtwork, cornerRadius: 12)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.podcastName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(episode.episodeTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                EpisodePlayButton(episode: episode, style: .onColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(height: 150)
        .background {
            ArtworkBackdrop(episode.episodeArtwork, style: .card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct TopPodcastTile: View {
    let podcast: HomePodcast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(podcast.artworkUrl, cornerRadius: 16)
                .frame(width: 136, height: 136)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.podcastName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if podcast.playCount > 0 {
                    Text("\(podcast.playCount) plays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 136, alignment: .leading)
        }
    }
}

private struct StatsStrip: View {
    @Environment(AppRouter.self) private var router

    let overview: HomeOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Your Library")
            HStack(spacing: 10) {
                NavigationLink {
                    SavedEpisodesView()
                } label: {
                    tile(value: "\(overview.savedCount)", label: "Saved", icon: "bookmark.fill", tint: PineGreen, tappable: true)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.96))

                Button {
                    router.selectedTab = .downloads
                } label: {
                    tile(value: "\(overview.downloadedCount)", label: "Downloads", icon: "arrow.down.circle.fill", tint: .teal, tappable: true)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.96))

                if overview.weeklyStats.hasActivity {
                    tile(value: overview.weeklyStats.formattedListened, label: "This Week", icon: "headphones", tint: .orange, tappable: false)
                } else {
                    NavigationLink {
                        QueueView()
                    } label: {
                        tile(value: "\(overview.queueCount)", label: "Queued", icon: "list.bullet", tint: .indigo, tappable: true)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.96))
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func tile(value: String, label: String, icon: String, tint: Color, tappable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.15), in: Circle())
                Spacer(minLength: 0)
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .fontDesign(.rounded)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Shimmer-free placeholder layout shown on first load.
private struct HomeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 8).frame(width: 200, height: 24)
            RoundedRectangle(cornerRadius: 22).frame(height: 150)
            RoundedRectangle(cornerRadius: 8).frame(width: 150, height: 24)
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 10).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).frame(height: 14)
                        RoundedRectangle(cornerRadius: 4).frame(width: 140, height: 12)
                    }
                }
            }
        }
        .foregroundStyle(Color(.secondarySystemBackground))
        .padding(20)
        .accessibilityLabel("Loading")
    }
}

struct FeedView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.feedEpisodes) { episode in
                    NavigationLink {
                        EpisodeDetailView(episode: episode)
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .episodeActions(episode)
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                    .onAppear {
                        if episode.id == library.feedEpisodes.last?.id,
                           library.feedEpisodes.count < library.feedTotal {
                            Task { await library.loadFeed() }
                        }
                    }
                }

                if library.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .overlay {
                if library.feedEpisodes.isEmpty && !library.isLoading {
                    ContentUnavailableView {
                        Label("No New Episodes", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("New episodes from your subscriptions show up here.")
                    }
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AccountButton()
                }
            }
            .refreshable {
                await library.loadFeed(reset: true)
            }
            .task {
                if library.feedEpisodes.isEmpty {
                    await library.loadFeed(reset: true)
                }
            }
        }
    }
}

struct SearchView: View {
    @Environment(LibraryStore.self) private var library

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    if !library.podcasts.isEmpty {
                        Section("Your Shows") {
                            ForEach(library.podcasts.prefix(8)) { podcast in
                                podcastLink(podcast)
                            }
                        }
                    }
                } else {
                    if !podcastMatches.isEmpty {
                        Section("Shows") {
                            ForEach(podcastMatches) { podcast in
                                podcastLink(podcast)
                            }
                        }
                    }
                    if !episodeMatches.isEmpty {
                        Section("Episodes") {
                            ForEach(episodeMatches) { episode in
                                NavigationLink {
                                    EpisodeDetailView(episode: episode)
                                } label: {
                                    EpisodeRow(episode: episode)
                                }
                                .episodeActions(episode)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if !trimmedQuery.isEmpty && podcastMatches.isEmpty && episodeMatches.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Shows and episodes")
            .task {
                if library.feedEpisodes.isEmpty {
                    await library.loadFeed(reset: true)
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var podcastMatches: [Podcast] {
        library.podcasts.filter {
            $0.title.localizedStandardContains(trimmedQuery)
                || $0.author.localizedStandardContains(trimmedQuery)
        }
    }

    private var episodeMatches: [PinepodsEpisode] {
        Array(library.knownEpisodes.filter {
            $0.episodeTitle.localizedStandardContains(trimmedQuery)
                || $0.podcastName.localizedStandardContains(trimmedQuery)
        }.prefix(50))
    }

    private func podcastLink(_ podcast: Podcast) -> some View {
        NavigationLink {
            PodcastDetailView(podcastId: podcast.id, title: podcast.title, artworkUrl: podcast.imageUrl)
        } label: {
            HStack(spacing: 12) {
                ArtworkImage(podcast.imageUrl, cornerRadius: 10)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(podcast.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(podcast.author.isEmpty ? "\(podcast.episodeCount) episodes" : podcast.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
