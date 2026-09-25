import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Core audio player: AVPlayer + AVAudioSession + Now Playing / remote command
/// integration, with the Flutter client's server-sync behavior (position every
/// 15 s with a 2 s delta threshold, listen time every 60 s, immediate sync on
/// pause/seek, completion marking).
@MainActor
@Observable
final class AudioPlayerController {
    static let shared = AudioPlayerController()

    private(set) var currentEpisode: PinepodsEpisode? {
        didSet {
            guard oldValue?.episodeId != currentEpisode?.episodeId else { return }
            if let currentEpisode {
                lastEpisode = currentEpisode
                LocalFiles.save(currentEpisode, to: Self.lastEpisodeFileName)
            }
            WidgetPublisher.setNeedsUpdate()
        }
    }
    private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { WidgetPublisher.setNeedsUpdate() } }
    }
    /// The most recent episode, kept across launches so widgets and remote
    /// controls can resume it before anything is loaded.
    private(set) var lastEpisode: PinepodsEpisode? = LocalFiles.load(PinepodsEpisode.self, from: lastEpisodeFileName)
    private static let lastEpisodeFileName = "last-episode.json"
    private(set) var isBuffering = false
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var bufferedSeconds: Double = 0
    private(set) var errorMessage: String?
    private(set) var didComplete = false

    var speed: Double = 1.0 {
        didSet {
            if oldValue != speed {
                SettingsStore.shared.playbackSpeed = speed
                player?.defaultRate = Float(speed)
                applyRate()
                updateNowPlayingPlaybackInfo()
            }
        }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private let nowPlayingManager = NowPlayingManager()
    private var remoteCommandManager: RemoteCommandManager?
    private var audioSessionConfigured = false

    private var currentUserId: Int?
    private var currentIsYoutube = false
    private var currentEpisodeId: Int?
    private var lastSyncedPosition: Double = -100
    private var positionSyncTask: Task<Void, Never>?
    private var listenTimeTask: Task<Void, Never>?

    private var currentAudioTrack: AVAssetTrack?
    private var silenceBoostActive = false
    private var silenceReported = false
    private var silenceObserver: Any?
    private var silenceGeneration = 0

    /// Set when a call or other interruption paused playback; cleared by any
    /// explicit play/pause/stop so a user's choice isn't overridden.
    private var resumeAfterInterruption = false

    private var completionObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var interruptionTokens: [Any] = []

    private init() {
        speed = SettingsStore.shared.playbackSpeed
        setupPlayer()
        setupRemoteCommands()
        setupInterruptionHandling()
    }

    // MARK: - Setup

    /// The audio session is activated lazily at playback time. Retried on every
    /// play attempt, so a transient failure (e.g. session busy at launch) does
    /// not permanently break playback.
    ///
    /// Uses the long-form audio route-sharing policy, which is the supported
    /// podcast setup on modern iOS. Note the policy forbids category options
    /// (the legacy allowBluetooth* options fail with OSStatus -50 on iOS 26+);
    /// Bluetooth/AirPlay routing is handled by the policy itself.
    ///
    /// Activation runs on a background thread: synchronous `setActive` on the
    /// main thread can block the UI for seconds during route/policy
    /// negotiation (the "AVAudioSession_iOS.mm:978" watchdog warning).
    private func ensureAudioSession() async throws {
        guard !audioSessionConfigured else { return }
        try await Task.detached(priority: .userInitiated) {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: []
            )
            try audioSession.setActive(true)
        }.value
        audioSessionConfigured = true
    }

    private func setupPlayer() {
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = Float(speed)
        self.player = player

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlaybackState()
            }
        }

        if #available(iOS 27.0, *) {
            completionObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleEpisodeCompleted()
                }
            }
        } else {
            // String-based name: the pre-iOS 27 constant is deprecated when
            // building against the iOS 27 SDK.
            completionObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("AVPlayerItemDidPlayToEndTime"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleEpisodeCompleted()
                }
            }
        }
    }

    private func setupRemoteCommands() {
        remoteCommandManager = RemoteCommandManager(player: self)
        updateSkipIntervals()
    }

    private func setupInterruptionHandling() {
        let center = NotificationCenter.default

        if #available(iOS 27.0, *) {
            // iOS 27 typed notifications replace interruptionNotification.
            let session = AVAudioSession.sharedInstance()
            let inactiveID: NotificationCenter.BaseMessageIdentifier<AVAudioSession.DidBecomeInactiveMessage> = .didBecomeInactive
            interruptionTokens.append(center.addObserver(of: session, for: inactiveID) { [weak self] message in
                guard let self else { return }
                NSLog("[PinePods] session became inactive (deactivation=%@) — pausing", "\(message.deactivationResult)")
                let wasPlaying = self.isPlaying || self.isBuffering
                self.pause()
                self.resumeAfterInterruption = wasPlaying
                // The interruption deactivated the session; reactivate before playing again.
                self.audioSessionConfigured = false
            })
            let resumeID: NotificationCenter.BaseMessageIdentifier<AVAudioSession.ResumptionRecommendationMessage> = .resumptionRecommendation
            interruptionTokens.append(center.addObserver(of: session, for: resumeID) { [weak self] message in
                guard let self else { return }
                let shouldResume = message.recommendation == .shouldResume && self.resumeAfterInterruption
                NSLog("[PinePods] resumption recommendation: %@ — %@", "\(message.recommendation)", shouldResume ? "resuming" : "staying paused")
                self.resumeAfterInterruption = false
                if shouldResume {
                    self.play()
                }
            })
        } else {
            center.addObserver(
                self,
                selector: #selector(handleInterruption(_:)),
                name: AVAudioSession.interruptionNotification,
                object: nil
            )
        }

        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    func updateSkipIntervals() {
        remoteCommandManager?.updateSkipIntervals(
            forwardMs: SettingsStore.shared.skipForwardSeconds * 1000,
            backwardMs: SettingsStore.shared.skipBackwardSeconds * 1000
        )
    }

    /// Replaces the now-playing episode copy (e.g. after a save/download toggle)
    /// so the mini player and full player reflect fresh server state.
    func updateCurrentEpisode(_ episode: PinepodsEpisode) {
        guard episode.episodeId == currentEpisodeId else { return }
        currentEpisode = episode
    }

    @objc private nonisolated func handleInterruption(_ notification: Notification) {
        // Raw value 0 is InterruptionType.began; using the raw value avoids the
        // deprecated AVAudioSession.InterruptionType enum (iOS 27 SDK).
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo["AVAudioSessionInterruptionTypeKey"] as? UInt,
              typeValue == 0 else { return }
        Task { @MainActor [weak self] in self?.pause() }
    }

    @objc private nonisolated func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        NSLog("[PinePods] audio route change: reason %ld", reasonValue)
        guard reasonValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        Task { @MainActor [weak self] in self?.pause() }
    }

    // MARK: - Playback

    /// Start (or resume) an episode. `resume: false` plays from the start,
    /// ignoring any saved position and applying the podcast's intro-skip.
    func play(episode: PinepodsEpisode, resume: Bool = true) async {
        guard episode.episodeId != 0 else { return }
        let session = SessionStore.shared
        guard session.isLoggedIn else { return }

        do {
            try await ensureAudioSession()
        } catch {
            errorMessage = "Could not activate audio session: \(error.localizedDescription)"
            return
        }

        if currentEpisodeId == episode.episodeId, player?.currentItem != nil {
            play()
            return
        }

        syncPositionNow()
        stopSyncTasks()

        currentEpisode = episode
        currentEpisodeId = episode.episodeId
        currentUserId = session.userId
        currentIsYoutube = episode.isYoutube
        didComplete = false
        errorMessage = nil

        let userId = session.userId
        let client = session.client

        // Per-podcast playback settings (speed, intro skip). Streams wait for
        // them; a downloaded file starts at once and applies them on arrival,
        // so playback never waits on the network.
        let localFile = DownloadManager.shared.localURL(for: episode.episodeId)
        let detailsTask = Task { () -> PlayEpisodeDetails in
            guard let podcastId = episode.podcastId else { return .default }
            return (try? await client.playEpisodeDetails(
                userId: userId, podcastId: podcastId, isYoutube: episode.isYoutube)) ?? .default
        }
        let playDetails: PlayEpisodeDetails = localFile == nil ? await detailsTask.value : .default
        NSLog("[PinePods] play: %@ (speed %.2fx)", localFile == nil ? "streaming" : "local file", playDetails.playbackSpeed)

        let streamUrl: String?
        if let localFile {
            streamUrl = localFile.absoluteString
        } else if episode.isYoutube || episode.downloaded {
            streamUrl = client.streamURL(
                episodeId: episode.episodeId, userId: userId,
                isYoutube: episode.isYoutube, isLocal: episode.downloaded)
        } else {
            streamUrl = episode.episodeUrl.isEmpty ? nil : episode.episodeUrl
        }

        guard let urlString = streamUrl, let url = URL(string: urlString) else {
            errorMessage = "No playable URL for this episode"
            NSLog("[PinePods] play: no playable URL (downloaded=\(episode.downloaded), youtube=\(episode.isYoutube))")
            return
        }
        NSLog("[PinePods] play: source \(APIClient.redacted(url))")

        let assetOptions: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": [
                // A generic AppleCoreMedia UA: CDNs (Acast, Megaphone, …) treat
                // custom app UAs as bots and throttle or stall the response.
                "User-Agent": "AppleCoreMedia/1.0.0.27B91 (iPhone; U; CPU OS 27_0 like Mac OS X; en_us)",
            ],
        ]
        var asset = AVURLAsset(url: url, options: assetOptions)
        usesPreciseTiming = false

        // Preflight like the original Flutter player (load playability/duration
        // before creating the item) but via the modern async API, awaited
        // directly — no task groups, so nothing to cancel mid-AVFoundation-load.
        var assetSeconds: Double = 0
        if let (playable, duration) = try? await asset.load(.isPlayable, .duration) {
            guard playable else {
                errorMessage = "Playback failed: audio format not supported"
                return
            }
            assetSeconds = CMTimeGetSeconds(duration)
        }

        // VBR MP3s without a Xing/VBRI header get a bitrate-estimated duration
        // and seek map that can be several times off. Precise timing parses
        // frames instead: slower far seeks, but correct times.
        let metaSeconds = Double(episode.episodeDuration)
        if Self.durationsDisagree(estimated: assetSeconds, metadata: metaSeconds) {
            NSLog("[PinePods] play: estimated duration %.0fs vs feed %.0fs; using precise timing", assetSeconds, metaSeconds)
            var preciseOptions = assetOptions
            preciseOptions[AVURLAssetPreferPreciseDurationAndTimingKey] = true
            asset = AVURLAsset(url: url, options: preciseOptions)
            usesPreciseTiming = true
        }

        currentAudioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        configureSilenceSkipping(for: item)
        item.preferredForwardBufferDuration = 180
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        observeItemStatus(item)
        player?.replaceCurrentItem(with: item)

        // Duration starts from the asset (if the preflight resolved it) or
        // episode metadata; the periodic observer corrects it once ready. In
        // precise mode the feed duration holds until the frame scan finishes.
        let displayDuration = !usesPreciseTiming && assetSeconds.isFinite && assetSeconds > 0
            ? assetSeconds : metaSeconds
        durationSeconds = displayDuration

        // A saved position past the end is corrupt: record_podcast_history
        // stores position × 100. Restart, and reset the row server-side
        // (mark-uncompleted zeroes it; record_listen_duration can only raise it).
        let savedSeconds = episode.listenDuration ?? 0
        let savedIsCorrupt = displayDuration > 0 && Double(savedSeconds) > displayDuration + 1
        if savedIsCorrupt && !episode.completed {
            NSLog("[PinePods] play: saved position %lds exceeds duration %.0fs; resetting", savedSeconds, displayDuration)
            Task {
                guard (try? await client.markUncompleted(
                    episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube)) == true else { return }
                LibraryStore.shared.updateEpisode(episode.updated(listenDuration: 0))
            }
        }
        // Positions played offline may not have reached the server yet.
        let serverSeconds = savedIsCorrupt ? 0 : savedSeconds
        let deviceSeconds = Int(SyncOutbox.shared.lastPosition(for: episode.episodeId) ?? 0)
        let startPositionMs = resume && !episode.completed ? max(serverSeconds, deviceSeconds) * 1000 : 0

        if usesPreciseTiming {
            let preciseAsset = asset
            Task { [weak self] in
                guard let loaded = try? await preciseAsset.load(.duration) else { return }
                let seconds = CMTimeGetSeconds(loaded)
                guard let self, self.currentEpisodeId == episode.episodeId,
                      seconds.isFinite, seconds > 0 else { return }
                self.durationSeconds = seconds
                NSLog("[PinePods] precise duration resolved: %.0fs", seconds)
            }
        }

        nowPlayingManager.updateNowPlaying(
            title: episode.episodeTitle,
            artist: episode.podcastName,
            artworkUrl: episode.episodeArtwork.isEmpty ? nil : episode.episodeArtwork,
            duration: displayDuration,
            playbackRate: 1.0,
            elapsedTime: Double(startPositionMs) / 1000.0
        )

        // Start playback FIRST, then seek to the resume position fire-and-forget.
        // `await seek(...)` on a not-yet-ready item blocks until the seek
        // completes, which hangs indefinitely when the CDN is slow to answer.
        NSLog("[PinePods] play: starting at %ld ms, speed %.2fx", startPositionMs, playDetails.playbackSpeed)
        player?.play()
        if localFile == nil {
            setSpeed(playDetails.playbackSpeed)
        } else {
            let episodeId = episode.episodeId
            Task { [weak self] in
                let details = await detailsTask.value
                guard let self, self.currentEpisodeId == episodeId else { return }
                self.setSpeed(details.playbackSpeed)
                if !resume, details.startSkip > 0, self.positionSeconds < Double(details.startSkip) {
                    self.seek(to: Double(details.startSkip))
                }
            }
        }

        if startPositionMs > 0 {
            let time = CMTime(value: CMTimeValue(startPositionMs), timescale: 1000)
            player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard finished else { return }
                Task { @MainActor in self?.refreshPlaybackState() }
            }
        }

        if localFile == nil, playDetails.startSkip > 0, !resume {
            try? await Task.sleep(for: .milliseconds(500))
            guard currentEpisodeId == episode.episodeId else { return }
            player?.seek(
                to: CMTime(seconds: Double(playDetails.startSkip), preferredTimescale: 1000),
                toleranceBefore: .zero, toleranceAfter: .zero,
                completionHandler: { _ in })
        }

        refreshPlaybackState()
        lastSyncedPosition = Double(startPositionMs) / 1000.0
        watchdogBaseline = Double(startPositionMs) / 1000.0
        SyncOutbox.shared.recordPosition(
            episodeId: episode.episodeId, userId: userId,
            seconds: Double(startPositionMs) / 1000.0, isYoutube: episode.isYoutube)
        Task {
            _ = try? await client.incrementPlayed(userId: userId)
        }
        startSyncTasks()
    }

    func play() {
        resumeAfterInterruption = false
        guard audioSessionConfigured else {
            // Remote commands may resume before the session has ever been
            // activated; run the background activation, then start playback.
            Task {
                do {
                    try await ensureAudioSession()
                    player?.play()
                    applyRate()
                    refreshPlaybackState()
                } catch {
                    errorMessage = "Could not activate audio session: \(error.localizedDescription)"
                }
            }
            return
        }
        player?.play()
        applyRate()
        refreshPlaybackState()
    }

    func pause() {
        NSLog("[PinePods] pause() called")
        resumeAfterInterruption = false
        player?.pause()
        syncPositionNow()
        refreshPlaybackState()
        updateNowPlayingPlaybackInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Row-level control: toggles the loaded episode, restarts it if it
    /// finished, otherwise starts the given one.
    func playOrToggle(_ episode: PinepodsEpisode) async {
        guard currentEpisode?.episodeId == episode.episodeId, errorMessage == nil else {
            await play(episode: episode)
            return
        }
        if didComplete {
            seek(to: 0)
            play()
        } else {
            togglePlayPause()
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(durationSeconds - 0.5, 0)))
        let time = CMTime(seconds: clamped, preferredTimescale: 1000)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        positionSeconds = clamped
        didComplete = false
        WidgetPublisher.setNeedsUpdate()
        // Pending transitions refer to the old position; the tap re-reports from the new one.
        cancelPendingSilenceTransition()
        silenceBoostActive = silenceReported
        applyRate()
        updateNowPlayingPlaybackInfo()
        syncPositionNow()
    }

    func fastForward(milliseconds: Int) {
        seek(to: positionSeconds + Double(milliseconds) / 1000.0)
    }

    func rewind(milliseconds: Int) {
        seek(to: positionSeconds - Double(milliseconds) / 1000.0)
    }

    func setSpeed(_ newSpeed: Double) {
        let clamped = min(max(newSpeed, 0.5), 3.0)
        speed = clamped
    }

    func stop() {
        syncPositionNow()
        stopSyncTasks()
        player?.pause()
        resumeAfterInterruption = false
        resetSilenceBoost()
        currentAudioTrack = nil
        player?.replaceCurrentItem(with: nil)
        nowPlayingManager.clearNowPlaying()
        currentEpisode = nil
        currentEpisodeId = nil
        currentUserId = nil
        positionSeconds = 0
        durationSeconds = 0
        bufferedSeconds = 0
        usesPreciseTiming = false
        isPlaying = false
        isBuffering = false
        didComplete = false
    }

    #if DEBUG
    func installDemo(episode: PinepodsEpisode, position: Double, duration: Double) {
        currentEpisode = episode
        currentEpisodeId = episode.episodeId
        positionSeconds = position
        durationSeconds = duration
        bufferedSeconds = min(position + 600, duration)
    }
    #endif

    // MARK: - Completion

    /// Surfaces AVPlayerItem load failures (bad URL, unsupported codec, TLS
    /// errors) that AVPlayer otherwise swallows silently.
    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                switch status {
                case .failed:
                    self.errorMessage = "Playback failed: \(error?.localizedDescription ?? "unknown error")"
                    self.isBuffering = false
                    self.isPlaying = false
                    NSLog("[PinePods] item FAILED: \(String(describing: error))")
                case .readyToPlay:
                    self.isBuffering = false
                    NSLog("[PinePods] item readyToPlay")
                case .unknown:
                    NSLog("[PinePods] item status unknown")
                @unknown default:
                    break
                }
            }
        }
    }

    private func handleEpisodeCompleted() {
        guard let episodeId = currentEpisodeId,
              let userId = currentUserId,
              let episode = currentEpisode else { return }

        didComplete = true
        isPlaying = false
        player?.rate = 0
        positionSeconds = durationSeconds
        lastSyncedPosition = positionSeconds

        stopSyncTasks()

        let playedSeconds = episode.episodeDuration > 0 ? Double(episode.episodeDuration) : durationSeconds
        SyncOutbox.shared.recordCompleted(
            episodeId: episodeId, userId: userId, durationSeconds: playedSeconds, isYoutube: currentIsYoutube)

        let library = LibraryStore.shared
        let next = library.nextInQueue(after: episodeId)
        library.updateEpisode(episode.updated(listenDuration: Int(playedSeconds), completed: true))
        library.removeCompletedFromQueue(episodeId)

        if SettingsStore.shared.continuePlayback, let next {
            NSLog("[PinePods] completed %ld; continuing with queued %ld", episodeId, next.episodeId)
            Task { await play(episode: next) }
        }
    }

    // MARK: - Server sync

    private func syncPositionNow() {
        guard let episodeId = currentEpisodeId,
              let userId = currentUserId else { return }
        let position = positionSeconds
        guard abs(position - lastSyncedPosition) > 2 else { return }
        lastSyncedPosition = position
        SyncOutbox.shared.recordPosition(
            episodeId: episodeId, userId: userId, seconds: position, isYoutube: currentIsYoutube)
        if let episode = currentEpisode {
            LibraryStore.shared.updateEpisode(episode.updated(listenDuration: Int(position)))
        }
    }

    private func syncPositionIfNeeded() {
        syncPositionNow()
    }

    private func startSyncTasks() {
        stopSyncTasks()
        positionSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                self.syncPositionIfNeeded()
            }
        }
        listenTimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                let userId = self.currentUserId
                if let userId {
                    let client = SessionStore.shared.client
                    try? await client.incrementListenTime(userId: userId)
                }
            }
        }
        startStallWatchdog()
    }

    /// Converts the "waits forever" failure mode into a visible error: if the
    /// playhead hasn't moved off its start position after 25 s, the stream
    /// isn't delivering data and the user is told instead of left staring at a
    /// spinner. Baseline is the seek/resume position, so resumed episodes are
    /// covered too.
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        let baseline = watchdogBaseline
        stallWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled else { return }
            if self.currentEpisodeId != nil, !self.isPlaying,
               abs(self.positionSeconds - baseline) < 1, self.player?.rate == 0 {
                self.errorMessage = "Playback stalled — the stream didn't respond"
                NSLog("[PinePods] stall watchdog fired: no progress from %.1fs after 25 s", baseline)
            }
        }
    }

    private func stopSyncTasks() {
        positionSyncTask?.cancel()
        listenTimeTask?.cancel()
        positionSyncTask = nil
        listenTimeTask = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    // MARK: - State

    private var lastLoggedState = ""
    private var usesPreciseTiming = false

    /// True when the stream's estimated duration is more than 10% away from
    /// the feed's; either side unknown means no evidence of a mismatch.
    nonisolated private static func durationsDisagree(estimated: Double, metadata: Double) -> Bool {
        guard estimated.isFinite, estimated > 0, metadata > 0 else { return false }
        return abs(estimated - metadata) / metadata > 0.1
    }
    private var stallWatchdog: Task<Void, Never>?
    private var watchdogBaseline: Double = 0

    private func refreshPlaybackState() {
        guard let player else { return }

        let position = player.currentTime()
        if position.isValid && !position.isIndefinite {
            positionSeconds = CMTimeGetSeconds(position)
        }
        let duration = player.currentItem?.duration
        if !usesPreciseTiming, let duration, duration.isValid && !duration.isIndefinite {
            durationSeconds = CMTimeGetSeconds(duration)
        }
        bufferedSeconds = bufferedPosition(player)

        switch player.timeControlStatus {
        case .playing:
            isPlaying = true
            isBuffering = false
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
        default:
            isPlaying = false
            isBuffering = false
        }

        // Ground-truth playback logging: emit one line per state transition so
        // a stall can be diagnosed from the console alone.
        let itemStatus = player.currentItem?.status.rawValue ?? -1
        let stateName = isPlaying ? "playing" : (isBuffering ? "buffering" : "stopped")
        if stateName != lastLoggedState {
            lastLoggedState = stateName
            NSLog(
                "[PinePods] state -> %@ (pos %.1fs buffered %.1fs dur %.1fs itemStatus %ld rate %.2f)",
                stateName, positionSeconds, bufferedSeconds, durationSeconds, itemStatus, player.rate)
        }

        updateNowPlayingPlaybackInfo()
    }

    private func bufferedPosition(_ player: AVPlayer) -> Double {
        guard let timeRanges = player.currentItem?.loadedTimeRanges, let first = timeRanges.first else {
            return 0
        }
        let timeRange = first.timeRangeValue
        let bufferedTime = CMTimeAdd(timeRange.start, timeRange.duration)
        return CMTimeGetSeconds(bufferedTime)
    }

    private func updateNowPlayingPlaybackInfo() {
        let rate: Float = (player?.rate ?? 0) > 0 ? Float(speed) : 0
        nowPlayingManager.updatePlaybackInfo(elapsedTime: positionSeconds, playbackRate: rate)
    }

    // MARK: - Rate and silence skipping

    /// Rate while playing: the chosen speed, raised during detected silence.
    private var effectiveRate: Float {
        Float(silenceBoostActive ? max(speed, min(speed * 3, 4)) : speed)
    }

    /// Updates the rate of a playing player; a paused one stays paused and
    /// resumes at `defaultRate`.
    private func applyRate() {
        guard let player, player.rate != 0 else { return }
        player.rate = effectiveRate
    }

    func setSkipSilence(_ enabled: Bool) {
        SettingsStore.shared.skipSilence = enabled
        if let item = player?.currentItem {
            configureSilenceSkipping(for: item)
        }
    }

    private func configureSilenceSkipping(for item: AVPlayerItem) {
        resetSilenceBoost()
        guard SettingsStore.shared.skipSilence, let track = currentAudioTrack else {
            item.audioMix = nil
            return
        }
        let generation = silenceGeneration
        let detector = SilenceDetector { [weak self] isSilent, time in
            Task { @MainActor in
                self?.scheduleSilenceTransition(isSilent, at: time, generation: generation)
            }
        }
        item.audioMix = detector.audioMix(for: track)
    }

    /// The tap runs about a second ahead of playback, so transitions are
    /// applied when the playhead reaches them; normal speed returns 0.25 s
    /// before speech.
    private func scheduleSilenceTransition(_ isSilent: Bool, at time: CMTime, generation: Int) {
        guard generation == silenceGeneration, let player else { return }
        cancelPendingSilenceTransition()
        silenceReported = isSilent
        let target = isSilent ? time : time - CMTime(seconds: 0.25, preferredTimescale: 600)
        guard target.isValid, target > player.currentTime() else {
            setSilenceBoost(isSilent)
            return
        }
        silenceObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: target)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.silenceGeneration else { return }
                self.cancelPendingSilenceTransition()
                self.setSilenceBoost(isSilent)
            }
        }
    }

    private func setSilenceBoost(_ active: Bool) {
        guard silenceBoostActive != active else { return }
        silenceBoostActive = active
        applyRate()
    }

    private func cancelPendingSilenceTransition() {
        if let silenceObserver {
            player?.removeTimeObserver(silenceObserver)
            self.silenceObserver = nil
        }
    }

    private func resetSilenceBoost() {
        silenceGeneration += 1
        cancelPendingSilenceTransition()
        silenceReported = false
        setSilenceBoost(false)
    }
}
