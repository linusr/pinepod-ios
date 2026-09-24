import Foundation

struct PinepodsEpisode: Identifiable, Hashable, Sendable, Codable {
    let podcastName: String
    let episodeTitle: String
    let episodePubDate: String
    let episodeDescription: String
    let episodeArtwork: String
    let episodeUrl: String
    let episodeDuration: Int
    let listenDuration: Int?
    let episodeId: Int
    let completed: Bool
    let saved: Bool
    let queued: Bool
    let downloaded: Bool
    let isYoutube: Bool
    let podcastId: Int?
    let listenDate: String?
    let saveDate: String?

    var id: Int { episodeId }

    var formattedDuration: String {
        Formatters.duration(seconds: episodeDuration)
    }

    var formattedListenDuration: String? {
        savedPosition.map { Formatters.duration(seconds: $0) }
    }

    /// Saved position, or nil when past the end: rows written through
    /// `record_podcast_history` hold position × 100.
    var savedPosition: Int? {
        guard let listenDuration, listenDuration > 0 else { return nil }
        if episodeDuration > 0 && listenDuration > episodeDuration + 1 { return nil }
        return listenDuration
    }

    var progressPercentage: Double {
        guard episodeDuration > 0, let savedPosition else { return 0 }
        return min(max(Double(savedPosition) / Double(episodeDuration) * 100, 0), 100)
    }

    var remainingSeconds: Int? {
        episodeDuration > 0 ? max(episodeDuration - (savedPosition ?? 0), 0) : nil
    }

    /// Completed, or under a minute left.
    var isNearlyFinished: Bool {
        completed || (remainingSeconds.map { $0 < 60 } ?? false)
    }

    var formattedPubDate: String {
        Formatters.relativeDate(episodePubDate)
    }

    func updated(
        listenDuration: Int? = nil,
        completed: Bool? = nil,
        saved: Bool? = nil,
        downloaded: Bool? = nil,
        queued: Bool? = nil
    ) -> PinepodsEpisode {
        PinepodsEpisode(
            podcastName: podcastName,
            episodeTitle: episodeTitle,
            episodePubDate: episodePubDate,
            episodeDescription: episodeDescription,
            episodeArtwork: episodeArtwork,
            episodeUrl: episodeUrl,
            episodeDuration: episodeDuration,
            listenDuration: listenDuration ?? self.listenDuration,
            episodeId: episodeId,
            completed: completed ?? self.completed,
            saved: saved ?? self.saved,
            queued: queued ?? self.queued,
            downloaded: downloaded ?? self.downloaded,
            isYoutube: isYoutube,
            podcastId: podcastId,
            listenDate: listenDate,
            saveDate: saveDate
        )
    }

    static func fromJSON(_ json: [String: Any]) -> PinepodsEpisode {
        PinepodsEpisode(
            podcastName: JSON.str(json, "podcastname", "Podcastname") ?? "",
            episodeTitle: JSON.str(json, "episodetitle", "Episodetitle") ?? "",
            episodePubDate: JSON.str(json, "episodepubdate", "Episodepubdate") ?? "",
            episodeDescription: JSON.str(json, "episodedescription", "Episodedescription") ?? "",
            episodeArtwork: JSON.str(json, "episodeartwork", "Episodeartwork") ?? "",
            episodeUrl: JSON.str(json, "episodeurl", "Episodeurl") ?? "",
            episodeDuration: JSON.int(json, "episodeduration", "Episodeduration"),
            listenDuration: JSON.intOrNull(json, "listenduration", "Listenduration"),
            episodeId: JSON.int(json, "episodeid", "Episodeid"),
            completed: JSON.bool(json, "completed", "Completed"),
            saved: JSON.bool(json, "saved", "Saved"),
            queued: JSON.bool(json, "queued", "Queued"),
            downloaded: JSON.bool(json, "downloaded", "Downloaded"),
            isYoutube: JSON.bool(json, "is_youtube", "Is_youtube"),
            podcastId: JSON.intOrNull(json, "podcastid", "Podcastid"),
            listenDate: JSON.str(json, "listendate"),
            saveDate: JSON.str(json, "savedate")
        )
    }
}

struct Podcast: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let description: String
    let imageUrl: String
    let feedUrl: String
    let websiteUrl: String
    let author: String
    let episodeCount: Int
    let isFavorite: Bool
    let isYoutube: Bool
    let categories: String?

    static func fromJSON(_ json: [String: Any]) -> Podcast {
        Podcast(
            id: JSON.int(json, "podcastid", "podcast_id"),
            title: JSON.str(json, "podcastname", "podcast_name") ?? "",
            description: JSON.str(json, "description") ?? "",
            imageUrl: JSON.str(json, "artworkurl", "artwork_url") ?? "",
            feedUrl: JSON.str(json, "feedurl", "feed_url") ?? "",
            websiteUrl: JSON.str(json, "websiteurl", "website_url") ?? "",
            author: JSON.str(json, "author") ?? "",
            episodeCount: JSON.int(json, "episodecount", "episode_count"),
            isFavorite: JSON.bool(json, "is_favorite"),
            isYoutube: JSON.bool(json, "is_youtube"),
            categories: JSON.categories(json["categories"])
        )
    }
}

struct HomeEpisode: Identifiable, Hashable, Sendable {
    let episodeId: Int
    let podcastId: Int
    let episodeTitle: String
    let episodeDescription: String
    let episodeUrl: String
    let episodeArtwork: String
    let episodePubDate: String
    let episodeDuration: Int
    let completed: Bool
    let podcastName: String
    let isYoutube: Bool
    let listenDuration: Int?
    let saved: Bool
    let queued: Bool
    let downloaded: Bool

    var id: Int { episodeId }

    var formattedDuration: String {
        episodeDuration <= 0 ? "--:--" : Formatters.duration(seconds: episodeDuration)
    }

    /// Saved position, or nil when past the end: rows written through
    /// `record_podcast_history` hold position × 100.
    var savedPosition: Int? {
        guard let listenDuration, listenDuration > 0 else { return nil }
        if episodeDuration > 0 && listenDuration > episodeDuration + 1 { return nil }
        return listenDuration
    }

    var progressPercentage: Double {
        guard episodeDuration > 0, let savedPosition else { return 0 }
        return min(max(Double(savedPosition) / Double(episodeDuration) * 100, 0), 100)
    }

    var asPinepodsEpisode: PinepodsEpisode {
        PinepodsEpisode(
            podcastName: podcastName,
            episodeTitle: episodeTitle,
            episodePubDate: episodePubDate,
            episodeDescription: episodeDescription,
            episodeArtwork: episodeArtwork,
            episodeUrl: episodeUrl,
            episodeDuration: episodeDuration,
            listenDuration: listenDuration,
            episodeId: episodeId,
            completed: completed,
            saved: saved,
            queued: queued,
            downloaded: downloaded,
            isYoutube: isYoutube,
            podcastId: podcastId,
            listenDate: nil,
            saveDate: nil
        )
    }

    static func fromJSON(_ json: [String: Any]) -> HomeEpisode {
        HomeEpisode(
            episodeId: JSON.int(json, "episodeid"),
            podcastId: JSON.int(json, "podcastid"),
            episodeTitle: JSON.str(json, "episodetitle") ?? "",
            episodeDescription: JSON.str(json, "episodedescription") ?? "",
            episodeUrl: JSON.str(json, "episodeurl") ?? "",
            episodeArtwork: JSON.str(json, "episodeartwork") ?? "",
            episodePubDate: JSON.str(json, "episodepubdate") ?? "",
            episodeDuration: JSON.int(json, "episodeduration"),
            completed: JSON.bool(json, "completed"),
            podcastName: JSON.str(json, "podcastname") ?? "",
            isYoutube: JSON.bool(json, "is_youtube"),
            listenDuration: JSON.intOrNull(json, "listenduration"),
            saved: JSON.bool(json, "saved"),
            queued: JSON.bool(json, "queued"),
            downloaded: JSON.bool(json, "downloaded")
        )
    }
}

struct HomePodcast: Identifiable, Hashable, Sendable {
    let podcastId: Int
    let podcastName: String
    let podcastIndexId: Int?
    let artworkUrl: String?
    let author: String?
    let categories: String?
    let description: String?
    let episodeCount: Int?
    let feedUrl: String?
    let websiteUrl: String?
    let isYoutube: Bool
    let playCount: Int
    let totalListenTime: Int?

    var id: Int { podcastId }

    static func fromJSON(_ json: [String: Any]) -> HomePodcast {
        HomePodcast(
            podcastId: JSON.int(json, "podcastid"),
            podcastName: JSON.str(json, "podcastname") ?? "",
            podcastIndexId: JSON.intOrNull(json, "podcastindexid"),
            artworkUrl: JSON.str(json, "artworkurl"),
            author: JSON.str(json, "author"),
            categories: JSON.categories(json["categories"]),
            description: JSON.str(json, "description"),
            episodeCount: JSON.intOrNull(json, "episodecount"),
            feedUrl: JSON.str(json, "feedurl"),
            websiteUrl: JSON.str(json, "websiteurl"),
            isYoutube: JSON.bool(json, "is_youtube"),
            playCount: JSON.int(json, "play_count"),
            totalListenTime: JSON.intOrNull(json, "total_listen_time")
        )
    }
}

struct WeeklyStats: Sendable {
    let secondsListened: Int
    let episodesCompleted: Int

    var hasActivity: Bool { secondsListened > 0 || episodesCompleted > 0 }

    var formattedListened: String {
        let hours = secondsListened / 3600
        let minutes = (secondsListened % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func fromJSON(_ json: [String: Any]?) -> WeeklyStats {
        guard let json else { return WeeklyStats(secondsListened: 0, episodesCompleted: 0) }
        return WeeklyStats(
            secondsListened: JSON.int(json, "seconds_listened"),
            episodesCompleted: JSON.int(json, "episodes_completed")
        )
    }
}

struct HomeOverview: Sendable {
    let recentEpisodes: [HomeEpisode]
    let inProgressEpisodes: [HomeEpisode]
    let queuePreview: [HomeEpisode]
    let topPodcasts: [HomePodcast]
    let savedCount: Int
    let downloadedCount: Int
    let queueCount: Int
    let weeklyStats: WeeklyStats

    static func fromJSON(_ json: [String: Any]) -> HomeOverview {
        HomeOverview(
            recentEpisodes: JSON.array(json, "recent_episodes").map(HomeEpisode.fromJSON),
            inProgressEpisodes: JSON.array(json, "in_progress_episodes").map(HomeEpisode.fromJSON),
            queuePreview: JSON.array(json, "queue_preview").map(HomeEpisode.fromJSON),
            topPodcasts: JSON.array(json, "top_podcasts").map(HomePodcast.fromJSON),
            savedCount: JSON.int(json, "saved_count"),
            downloadedCount: JSON.int(json, "downloaded_count"),
            queueCount: JSON.int(json, "queue_count"),
            weeklyStats: WeeklyStats.fromJSON(json["weekly_stats"] as? [String: Any])
        )
    }
}

struct DownloadTask: Identifiable, Hashable, Sendable {
    let id: String
    let taskType: String
    let status: String
    let progress: Double
    let message: String?
    let episodeTitle: String?
    let podcastName: String?
    let episodeId: Int?

    var isCompleted: Bool { status == "SUCCESS" }
    var isFailed: Bool { status == "FAILED" }
    var isActive: Bool { status == "PENDING" || status == "DOWNLOADING" }

    static func fromJSON(_ json: [String: Any]) -> DownloadTask {
        let result = json["result"] as? [String: Any]
        return DownloadTask(
            id: JSON.str(json, "id") ?? "",
            taskType: JSON.str(json, "task_type") ?? "",
            status: JSON.str(json, "status") ?? "",
            progress: JSON.double(json, "progress"),
            message: JSON.str(json, "message"),
            episodeTitle: JSON.str(json, "episode_title"),
            podcastName: JSON.str(json, "podcast_name"),
            episodeId: result.flatMap { JSON.intOrNull($0, "episode_id") }
        )
    }
}

struct PlayEpisodeDetails: Sendable {
    let playbackSpeed: Double
    let startSkip: Int
    let endSkip: Int

    static let `default` = PlayEpisodeDetails(playbackSpeed: 1.0, startSkip: 0, endSkip: 0)

    static func fromJSON(_ json: [String: Any]) -> PlayEpisodeDetails {
        PlayEpisodeDetails(
            playbackSpeed: JSON.double(json, "playback_speed", fallback: 1.0),
            startSkip: JSON.int(json, "start_skip"),
            endSkip: JSON.int(json, "end_skip")
        )
    }
}
