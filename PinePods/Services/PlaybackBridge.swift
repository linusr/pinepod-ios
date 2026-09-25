import Foundation

/// Carries out widget button taps inside the app. After a cold launch nothing
/// is loaded yet, so playback falls back to the last played episode, then Up Next.
@MainActor
enum PlaybackBridge {
    static func togglePlayback() async {
        let player = AudioPlayerController.shared
        if let episode = player.currentEpisode {
            await player.playOrToggle(episode)
        } else if let episode = player.lastEpisode ?? LibraryStore.shared.nextInQueue(after: nil) {
            await player.play(episode: episode)
        }
    }

    static func skip(seconds: Int) async {
        let player = AudioPlayerController.shared
        guard player.currentEpisode != nil else { return }
        if seconds >= 0 {
            player.fastForward(milliseconds: seconds * 1000)
        } else {
            player.rewind(milliseconds: -seconds * 1000)
        }
    }

    static func play(episodeId: Int) async {
        let library = LibraryStore.shared
        let player = AudioPlayerController.shared
        let candidates = library.queuedEpisodes + library.knownEpisodes
            + DownloadManager.shared.sortedDownloads.map(\.episode) + [player.lastEpisode].compactMap { $0 }
        guard let episode = candidates.first(where: { $0.episodeId == episodeId }) else { return }
        await player.play(episode: episode)
    }
}
