import SwiftUI

struct DownloadsView: View {
    enum Location: String, CaseIterable, Identifiable {
        case phone = "On iPhone"
        case server = "On Server"

        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads

    @AppStorage("downloads_location") private var location: Location = .phone

    var body: some View {
        NavigationStack {
            List {
                Picker("Location", selection: $location) {
                    ForEach(Location.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))

                switch location {
                case .phone: phoneSections
                case .server: serverSections
                }
            }
            .listStyle(.plain)
            .animation(.default, value: downloads.progress.keys.sorted())
            .overlay {
                if isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: location == .phone ? "iphone" : "externaldrive")
                    } description: {
                        Text(location == .phone
                            ? "Episodes downloaded to your iPhone play without a connection. Long-press an episode and choose Download to iPhone, or keep your queue downloaded in Settings."
                            : "Episodes downloaded to your PinePods server appear here.")
                    }
                    .padding(.top, 60)
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AccountButton()
                }
            }
            .refreshable {
                await library.refreshDownloads()
            }
            .task {
                await library.refreshDownloads()
            }
        }
    }

    private var isEmpty: Bool {
        switch location {
        case .phone: downloads.downloads.isEmpty && downloads.activeEpisodes.isEmpty
        case .server: library.serverDownloads.isEmpty && activeServerTasks.isEmpty
        }
    }

    // MARK: - On iPhone

    @ViewBuilder
    private var phoneSections: some View {
        if let error = downloads.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }

        if !downloads.activeEpisodes.isEmpty {
            Section("Downloading") {
                ForEach(downloads.activeEpisodes) { episode in
                    progressRow(
                        title: episode.episodeTitle,
                        subtitle: episode.podcastName,
                        fraction: downloads.progress[episode.episodeId] ?? 0
                    ) {
                        downloads.cancel(episode.episodeId)
                    }
                }
            }
        }

        if !downloads.downloads.isEmpty {
            Section {
                ForEach(downloads.sortedDownloads) { download in
                    NavigationLink {
                        EpisodeDetailView(episode: download.episode)
                    } label: {
                        EpisodeRow(episode: download.episode)
                    }
                    .episodeActions(download.episode, swipes: false)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            downloads.delete(download.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                }
            } header: {
                Text("^[\(downloads.downloads.count) episode](inflect: true) · \(downloads.usedBytes.formatted(.byteCount(style: .file)))")
            }
        }
    }

    // MARK: - On server

    private var activeServerTasks: [DownloadTask] {
        library.downloadTasks.filter(\.isActive)
    }

    @ViewBuilder
    private var serverSections: some View {
        if !activeServerTasks.isEmpty {
            Section("Downloading") {
                ForEach(activeServerTasks) { task in
                    progressRow(
                        title: task.episodeTitle ?? "Downloading…",
                        subtitle: task.podcastName,
                        fraction: task.progress / 100,
                        cancel: nil)
                }
            }
        }

        if !library.serverDownloads.isEmpty {
            Section {
                ForEach(library.serverDownloads) { episode in
                    NavigationLink {
                        EpisodeDetailView(episode: episode)
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .episodeActions(episode)
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                }
            } header: {
                Text("^[\(library.serverDownloads.count) episode](inflect: true) on your server")
            }
        }
    }

    private func progressRow(
        title: String, subtitle: String?, fraction: Double, cancel: (() -> Void)?
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                DownloadRing(fraction: fraction)
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PineGreen)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("\(Int(fraction * 100))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            if let cancel {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }
        }
        .padding(.vertical, 4)
    }
}
