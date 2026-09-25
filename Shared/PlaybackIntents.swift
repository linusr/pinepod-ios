import AppIntents

/// Widget buttons. As audio-playback intents, iOS runs `perform()` in the app's
/// process (launching it in the background if needed); the widget target only
/// needs the types to build its buttons.
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the current episode, or starts the next one in Up Next.")

    func perform() async throws -> some IntentResult {
        #if KURAL_APP
        await PlaybackBridge.togglePlayback()
        #endif
        return .result()
    }
}

struct SkipIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip"

    @Parameter(title: "Seconds") var seconds: Int

    init() {}

    init(seconds: Int) {
        self.seconds = seconds
    }

    func perform() async throws -> some IntentResult {
        #if KURAL_APP
        await PlaybackBridge.skip(seconds: seconds)
        #endif
        return .result()
    }
}

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Episode"

    @Parameter(title: "Episode ID") var episodeId: Int

    init() {}

    init(episodeId: Int) {
        self.episodeId = episodeId
    }

    func perform() async throws -> some IntentResult {
        #if KURAL_APP
        await PlaybackBridge.play(episodeId: episodeId)
        #endif
        return .result()
    }
}
