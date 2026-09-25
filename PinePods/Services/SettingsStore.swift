import Foundation
import Observation

/// User preferences persisted in UserDefaults (mirrors the Flutter client's
/// SharedPreferences-backed settings service).
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private enum Keys {
        static let playbackSpeed = "playback_speed"
        static let skipForward = "skip_forward_seconds"
        static let skipBackward = "skip_backward_seconds"
        static let skipSilence = "skip_silence"
        static let continuePlayback = "continue_playback"
        static let keepQueuedDownloaded = "keep_queued_downloaded"
        static let downloadOverCellular = "download_over_cellular"
        static let downloadLimitGB = "download_limit_gb"
        static let automationRules = "automation_rules"
        static let accent = "accent_theme"
        static let iconFollowsAccent = "icon_follows_accent"
    }

    private let defaults = UserDefaults.standard

    var playbackSpeed: Double {
        didSet { defaults.set(playbackSpeed, forKey: Keys.playbackSpeed) }
    }
    var skipForwardSeconds: Int {
        didSet { defaults.set(skipForwardSeconds, forKey: Keys.skipForward) }
    }
    var skipBackwardSeconds: Int {
        didSet { defaults.set(skipBackwardSeconds, forKey: Keys.skipBackward) }
    }
    var skipSilence: Bool {
        didSet { defaults.set(skipSilence, forKey: Keys.skipSilence) }
    }
    /// Start the next queued episode when one finishes.
    var continuePlayback: Bool {
        didSet { defaults.set(continuePlayback, forKey: Keys.continuePlayback) }
    }
    /// How many upcoming queue episodes to keep on the phone; 0 turns it off.
    var keepQueuedDownloaded: Int {
        didSet { defaults.set(keepQueuedDownloaded, forKey: Keys.keepQueuedDownloaded) }
    }
    var downloadOverCellular: Bool {
        didSet { defaults.set(downloadOverCellular, forKey: Keys.downloadOverCellular) }
    }
    /// Storage limit for automatic downloads; 0 means no limit.
    var downloadLimitGB: Int {
        didSet { defaults.set(downloadLimitGB, forKey: Keys.downloadLimitGB) }
    }

    var accent: AccentTheme {
        didSet {
            defaults.set(accent.rawValue, forKey: Keys.accent)
            WidgetPublisher.setNeedsUpdate()
            if iconFollowsAccent { AppIcon.apply(accent) }
        }
    }
    /// Switch the Home Screen icon along with the accent.
    var iconFollowsAccent: Bool {
        didSet {
            defaults.set(iconFollowsAccent, forKey: Keys.iconFollowsAccent)
            if iconFollowsAccent { AppIcon.apply(accent) }
        }
    }

    var automationRules: AutomationRules {
        didSet {
            defaults.set(try? JSONEncoder().encode(automationRules), forKey: Keys.automationRules)
            AutomationEngine.shared.scheduleBackgroundRun()
        }
    }

    var downloadLimitBytes: Int64? {
        downloadLimitGB > 0 ? Int64(downloadLimitGB) * 1_000_000_000 : nil
    }

    private init() {
        let speed = defaults.double(forKey: Keys.playbackSpeed)
        playbackSpeed = speed > 0 ? speed : 1.0
        let forward = defaults.integer(forKey: Keys.skipForward)
        skipForwardSeconds = forward > 0 ? forward : 30
        let backward = defaults.integer(forKey: Keys.skipBackward)
        skipBackwardSeconds = backward > 0 ? backward : 10
        skipSilence = defaults.bool(forKey: Keys.skipSilence)
        continuePlayback = defaults.object(forKey: Keys.continuePlayback) as? Bool ?? true
        keepQueuedDownloaded = defaults.object(forKey: Keys.keepQueuedDownloaded) as? Int ?? 3
        downloadOverCellular = defaults.bool(forKey: Keys.downloadOverCellular)
        downloadLimitGB = defaults.object(forKey: Keys.downloadLimitGB) as? Int ?? 5
        accent = defaults.string(forKey: Keys.accent).flatMap(AccentTheme.init(rawValue:)) ?? .pine
        iconFollowsAccent = defaults.object(forKey: Keys.iconFollowsAccent) as? Bool ?? true
        automationRules = defaults.data(forKey: Keys.automationRules)
            .flatMap { try? JSONDecoder().decode(AutomationRules.self, from: $0) } ?? AutomationRules()
    }
}
