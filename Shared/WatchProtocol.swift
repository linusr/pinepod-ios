import Foundation

/// Message keys shared by the iPhone app and the watch app over WatchConnectivity.
enum WatchProtocol {
    /// JSON-encoded `WidgetSnapshot`.
    static let snapshotKey = "snapshot"
    /// Artwork thumbnails, `[fileName: JPEG data]`.
    static let artworkKey = "artwork"
    static let commandKey = "command"
    static let secondsKey = "seconds"
    static let episodeIdKey = "episodeId"

    enum Command: String, Sendable {
        case toggle, skip, play, remove, refresh
    }
}
