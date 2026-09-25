import UIKit
import WidgetKit

/// Writes what the widgets show into the App Group and asks WidgetKit to
/// refresh. Only discrete changes (episode, play/pause, seek, queue, accent)
/// publish; progress between them is extrapolated by the widget itself.
@MainActor
enum WidgetPublisher {
    private static var pending: Task<Void, Never>?
    private static let thumbnailSize: CGFloat = 300

    static func setNeedsUpdate() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await publish()
        }
    }

    private static func publish() async {
        let player = AudioPlayerController.shared
        let settings = SettingsStore.shared
        var snapshot = WidgetSnapshot(
            nowPlaying: nil, upNext: [], accentHex: settings.accent.hex,
            skipBackSeconds: settings.skipBackwardSeconds, skipForwardSeconds: settings.skipForwardSeconds)

        let current = player.currentEpisode
        if let episode = current ?? player.lastEpisode {
            let isLoaded = current != nil
            let duration = isLoaded && player.durationSeconds > 0 ? player.durationSeconds : Double(episode.episodeDuration)
            let position = isLoaded
                ? player.positionSeconds
                : SyncOutbox.shared.lastPosition(for: episode.episodeId) ?? Double(episode.savedPosition ?? 0)
            snapshot.nowPlaying = .init(
                episode: await widgetEpisode(episode, duration: duration, position: position),
                isPlaying: player.isPlaying, speed: player.speed, capturedAt: .now)
        }

        let playingId = snapshot.nowPlaying?.episode.id
        for episode in LibraryStore.shared.queuedEpisodes
            .filter({ $0.episodeId != playingId && !$0.isNearlyFinished }).prefix(4) {
            snapshot.upNext.append(await widgetEpisode(
                episode, duration: Double(episode.episodeDuration), position: Double(episode.savedPosition ?? 0)))
        }

        SharedContainer.save(snapshot)
        pruneArtwork(keeping: Set(([snapshot.nowPlaying?.episode] + snapshot.upNext).compactMap { $0?.artworkFile }))
        WidgetCenter.shared.reloadTimelines(ofKind: SharedContainer.widgetKind)
    }

    private static func widgetEpisode(_ episode: PinepodsEpisode, duration: Double, position: Double) async -> WidgetSnapshot.Episode {
        WidgetSnapshot.Episode(
            id: episode.episodeId, title: episode.episodeTitle, podcast: episode.podcastName,
            artworkFile: await thumbnail(for: episode), duration: duration, position: position)
    }

    /// Widgets can't load remote images, so artwork is copied into the App Group.
    private static func thumbnail(for episode: PinepodsEpisode) async -> String? {
        guard let folder = SharedContainer.artworkFolder, !episode.episodeArtwork.isEmpty else { return nil }
        let name = "\(episode.episodeId).jpg"
        let url = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        guard let image = await ImagePipeline.shared.image(for: episode.episodeArtwork) else { return nil }
        let size = CGSize(width: thumbnailSize, height: thumbnailSize)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : name
    }

    private static func pruneArtwork(keeping names: Set<String>) {
        guard let folder = SharedContainer.artworkFolder,
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
    }
}
