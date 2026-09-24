import MediaPlayer
import Foundation

/// Manages remote command center controls (lock screen, headphones, CarPlay,
/// head units). Ported from the Flutter client's native layer. Handlers are
/// invoked on the main thread by the system.
@MainActor
final class RemoteCommandManager {
    private weak var player: AudioPlayerController?
    private let commandCenter = MPRemoteCommandCenter.shared()

    private var forwardMs: Int = 30000
    private var backwardMs: Int = 10000

    init(player: AudioPlayerController) {
        self.player = player
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            if player.isPlaying {
                player.pause()
            } else {
                player.play()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: forwardMs / 1000)]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                let milliseconds = Int(skipEvent.interval * 1000)
                self?.player?.fastForward(milliseconds: milliseconds)
            } else {
                self?.player?.fastForward(milliseconds: self?.forwardMs ?? 30000)
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: backwardMs / 1000)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                let milliseconds = Int(skipEvent.interval * 1000)
                self?.player?.rewind(milliseconds: milliseconds)
            } else {
                self?.player?.rewind(milliseconds: self?.backwardMs ?? 10000)
            }
            return .success
        }

        // Next / previous track commands from car head units and steering-wheel
        // controls are mapped to skip-by-interval, matching podcast convention.
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.player?.fastForward(milliseconds: self?.forwardMs ?? 30000)
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.player?.rewind(milliseconds: self?.backwardMs ?? 10000)
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let seekEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.player?.seek(to: seekEvent.positionTime)
                return .success
            }
            return .commandFailed
        }

        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            if let rateEvent = event as? MPChangePlaybackRateCommandEvent {
                self?.player?.setSpeed(Double(rateEvent.playbackRate))
                return .success
            }
            return .commandFailed
        }

        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
    }

    func updateSkipIntervals(forwardMs: Int, backwardMs: Int) {
        if forwardMs > 0 { self.forwardMs = forwardMs }
        if backwardMs > 0 { self.backwardMs = backwardMs }
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: self.forwardMs / 1000)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: self.backwardMs / 1000)]
    }
}
