import SwiftUI

struct EpisodeRow: View {
    @Environment(AudioPlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads

    let episode: PinepodsEpisode
    var showsPodcast = true
    var showsDescription = false

    var body: some View {
        let isCurrent = player.currentEpisode?.episodeId == episode.episodeId

        HStack(alignment: .top, spacing: 14) {
            ArtworkImage(episode.episodeArtwork, cornerRadius: 10)
                .frame(width: 64, height: 64)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.35))
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(episode.formattedPubDate.uppercased())
                    if showsPodcast && !episode.podcastName.isEmpty {
                        Text("·")
                        Text(episode.podcastName.uppercased())
                            .lineLimit(1)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                Text(episode.episodeTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(episode.completed ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if showsDescription {
                    let preview = HTMLText.preview(episode.episodeDescription)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                HStack(spacing: 10) {
                    EpisodePlayButton(episode: episode)
                    Spacer(minLength: 0)
                    statusIcons
                }
                .padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusIcons: some View {
        HStack(spacing: 8) {
            if library.isQueued(episode.episodeId) {
                Image(systemName: "list.bullet")
                    .accessibilityLabel("Queued")
            }
            if episode.saved {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(PineGreen)
                    .accessibilityLabel("Saved")
            }
            if let fraction = downloads.progress[episode.episodeId] {
                DownloadRing(fraction: fraction)
                    .frame(width: 13, height: 13)
                    .accessibilityLabel("Downloading to iPhone")
            } else if downloads.isDownloaded(episode.episodeId) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(PineGreen)
                    .accessibilityLabel("On iPhone")
            }
            if episode.downloaded {
                Image(systemName: "externaldrive.fill")
                    .accessibilityLabel("On server")
            }
            if episode.completed {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityLabel("Played")
            }
        }
        .font(.footnote)
        .foregroundStyle(.tertiary)
    }
}

struct EpisodeDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(DownloadManager.self) private var downloads

    @State private var episode: PinepodsEpisode
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var confirmRemoveDownload = false

    init(episode: PinepodsEpisode) {
        _episode = State(initialValue: episode)
    }

    private var isCurrent: Bool { player.currentEpisode?.episodeId == episode.episodeId }
    private var isPlaying: Bool { isCurrent && player.isPlaying }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                playSection
                actionRow

                if let error = actionError ?? (isCurrent ? player.errorMessage : nil) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                let notes = HTMLText.plainText(episode.episodeDescription)
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Show Notes")
                            .font(.title3.weight(.bold))
                        Text(notes)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
        .background(alignment: .top) {
            ArtworkBackdrop(episode.episodeArtwork, style: .header)
                .frame(height: 520)
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await library.refreshDownloads()
        }
        .onChange(of: player.currentEpisode) { _, current in
            if let current, current.episodeId == episode.episodeId {
                episode = current
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 16) {
            ArtworkImage(episode.episodeArtwork, cornerRadius: 22)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.25), radius: 22, y: 12)

            VStack(spacing: 6) {
                if let podcastId = episode.podcastId {
                    NavigationLink {
                        PodcastDetailView(podcastId: podcastId, title: episode.podcastName, artworkUrl: episode.episodeArtwork)
                    } label: {
                        HStack(spacing: 2) {
                            Text(episode.podcastName)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PineGreen)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(episode.podcastName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PineGreen)
                }

                Text(episode.episodeTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(metaLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var playSection: some View {
        VStack(spacing: 10) {
            Button {
                if isCurrent {
                    Task { await player.playOrToggle(episode) }
                } else {
                    router.presentPlayer(for: episode)
                    Task { await player.play(episode: episode) }
                }
            } label: {
                Label(playLabel, systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(PineGreen)
            .controlSize(.large)
            .sensoryFeedback(.impact(weight: .medium), trigger: isPlaying)

            if let fraction = progressFraction {
                HStack(spacing: 10) {
                    ProgressCapsule(fraction: fraction)
                        .frame(height: 4)
                        .foregroundStyle(PineGreen)
                    Text(remainingLabel)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionRow: some View {
        let queued = library.isQueued(episode.episodeId)
        return GlassEffectContainer {
            HStack(alignment: .top) {
                actionButton(
                    episode.saved ? "Saved" : "Save",
                    icon: episode.saved ? "bookmark.fill" : "bookmark",
                    active: episode.saved
                ) {
                    guard let updated = await library.setSaved(episode, !episode.saved) else {
                        actionError = "Couldn't update saved state."
                        return
                    }
                    episode = updated
                }

                actionButton(
                    episode.completed ? "Played" : "Mark Played",
                    icon: episode.completed ? "checkmark.circle.fill" : "checkmark.circle",
                    active: episode.completed
                ) {
                    guard let updated = await library.setCompleted(episode, !episode.completed) else {
                        actionError = "Couldn't update played state."
                        return
                    }
                    episode = updated
                }

                actionButton(
                    queued ? "Queued" : "Queue",
                    icon: queued ? "list.bullet.circle.fill" : "text.line.last.and.arrowtriangle.forward",
                    active: queued
                ) {
                    if queued {
                        await library.removeFromQueue(episode)
                    } else if !(await library.addToQueue(episode)) {
                        actionError = "Couldn't add to the queue."
                    }
                }

                phoneDownloadButton

                VStack(spacing: 6) {
                    Menu {
                        if episode.downloaded {
                            Button(role: .destructive) {
                                Task {
                                    await library.deleteDownload(episode: episode)
                                    episode = episode.updated(downloaded: false)
                                }
                            } label: {
                                Label("Remove from Server", systemImage: "externaldrive.badge.minus")
                            }
                        } else {
                            Button {
                                Task {
                                    if await library.startDownload(episode: episode) {
                                        episode = episode.updated(downloaded: true)
                                    } else {
                                        actionError = "Couldn't start the server download."
                                    }
                                }
                            } label: {
                                Label("Download to Server", systemImage: "externaldrive.badge.plus")
                            }
                        }
                        if let url = URL(string: episode.episodeUrl), !episode.episodeUrl.isEmpty {
                            ShareLink(item: url, subject: Text(episode.episodeTitle)) {
                                Label("Share Episode", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    Text(serverTaskLabel ?? "More")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var phoneDownloadButton: some View {
        let id = episode.episodeId
        if let fraction = downloads.progress[id] {
            VStack(spacing: 6) {
                Button {
                    downloads.cancel(id)
                } label: {
                    ZStack {
                        DownloadRing(fraction: fraction)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PineGreen)
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Cancel download, \(Int(fraction * 100)) percent")
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else if downloads.isDownloaded(id) {
            actionButton("On iPhone", icon: "arrow.down.circle.fill", active: true) {
                confirmRemoveDownload = true
            }
            .confirmationDialog("Remove this episode from your iPhone?", isPresented: $confirmRemoveDownload, titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) { downloads.delete(id) }
            }
        } else {
            actionButton("Download", icon: "arrow.down.circle", active: false) {
                downloads.download(episode)
                if let error = downloads.lastError { actionError = error }
            }
        }
    }

    private var serverTaskLabel: String? {
        activeDownloadTask.map { "Server \(Int($0.progress))%" }
    }

    private func actionButton(
        _ title: String, icon: String, active: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    isWorking = true
                    actionError = nil
                    defer { isWorking = false }
                    await action()
                }
            } label: {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(active ? PineGreen : .primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(isWorking)
            .sensoryFeedback(.success, trigger: active)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived

    private var activeDownloadTask: DownloadTask? {
        library.downloadTasks.first { $0.episodeId == episode.episodeId && $0.isActive }
    }

    private var metaLine: String {
        var parts = [episode.formattedPubDate]
        if episode.episodeDuration > 0 {
            parts.append(Formatters.compactDuration(seconds: episode.episodeDuration))
        }
        return parts.joined(separator: " · ").uppercased()
    }

    private var progressFraction: Double? {
        if isCurrent, player.durationSeconds > 0, player.positionSeconds > 0 {
            return player.positionSeconds / player.durationSeconds
        }
        if !episode.completed, episode.progressPercentage > 0 {
            return episode.progressPercentage / 100
        }
        return nil
    }

    private var remainingLabel: String {
        let remaining: Int
        if isCurrent, player.durationSeconds > 0 {
            remaining = Int(player.durationSeconds - player.positionSeconds)
        } else {
            remaining = episode.remainingSeconds ?? 0
        }
        return "\(Formatters.compactDuration(seconds: remaining)) left"
    }

    private var playLabel: String {
        if isPlaying { return "Pause" }
        if isCurrent { return "Resume" }
        if episode.completed { return "Play Again" }
        return episode.progressPercentage > 0 ? "Resume" : "Play Episode"
    }
}
