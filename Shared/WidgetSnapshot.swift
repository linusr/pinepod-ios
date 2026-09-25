import Foundation

/// What the widgets show, written by the app into the shared App Group
/// container. Widgets can't reach the app's data or the network directly.
struct WidgetSnapshot: Codable, Sendable {
    struct Episode: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        let title: String
        let podcast: String
        /// File name of a thumbnail in the shared artwork folder.
        let artworkFile: String?
        let duration: Double
        let position: Double
    }

    struct NowPlaying: Codable, Sendable {
        let episode: Episode
        let isPlaying: Bool
        let speed: Double
        /// When `episode.position` was captured, for extrapolating progress.
        let capturedAt: Date
    }

    var nowPlaying: NowPlaying?
    var upNext: [Episode]
    var accentHex: UInt32
    var skipBackSeconds: Int
    var skipForwardSeconds: Int

    static let empty = WidgetSnapshot(
        nowPlaying: nil, upNext: [], accentHex: 0x549E8A, skipBackSeconds: 10, skipForwardSeconds: 30)
}

enum SharedContainer {
    static let appGroup = "group.me.4vr.kural"
    static let widgetKind = "KuralNowPlaying"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var artworkFolder: URL? {
        guard let url else { return nil }
        let folder = url.appending(path: "Artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var snapshotURL: URL? {
        url?.appending(path: "widget-snapshot.json")
    }

    static func loadSnapshot() -> WidgetSnapshot {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
