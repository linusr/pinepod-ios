import Foundation
@testable import PinePods

/// Builds episodes the way the server sends them, with dates relative to `now`.
enum Fixtures {
    static let now = Date()

    static func ago(_ days: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: now.addingTimeInterval(-days * 86_400))
    }

    static func episode(
        _ id: Int, show: String = "Show", published: Double = 1, duration: Int = 3000,
        listened: Int? = nil, completed: Bool = false, listenedDaysAgo: Double? = nil,
        saved: Bool = false, downloaded: Bool = false, youtube: Bool = false
    ) -> PinepodsEpisode {
        var json: [String: Any] = [
            "episodeid": id, "podcastname": show, "episodetitle": "Episode \(id)",
            "episodepubdate": ago(published), "episodeduration": duration,
            "completed": completed, "saved": saved, "downloaded": downloaded, "is_youtube": youtube,
        ]
        if let listened { json["listenduration"] = listened }
        if let listenedDaysAgo { json["listendate"] = ago(listenedDaysAgo) }
        return PinepodsEpisode.fromJSON(json)
    }
}

extension Array where Element == PinepodsEpisode {
    var ids: [Int] { map(\.episodeId).sorted() }
}
