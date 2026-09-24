#if DEBUG
import Foundation

/// Offline sample library for UI work without a server. Launch with
/// `-PinePodsDemo`; optionally `-PinePodsDemoScreen <home|feed|library|downloads|search|player|settings>`.
/// `-PinePodsDemoMedia <url>` points every episode at a real audio file and
/// signs in with a stand-in session so playback and downloads run; API calls
/// then fail harmlessly against that host. `-PinePodsDemoArtwork <base-url>`
/// loads show artwork from `<base-url>/<seed>.png` instead of picsum.photos.
enum DemoMode {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-PinePodsDemo")
    }

    private static var screen: String? {
        UserDefaults.standard.string(forKey: "PinePodsDemoScreen")
    }

    private static var artworkBase: String? {
        UserDefaults.standard.string(forKey: "PinePodsDemoArtwork")
    }

    private static var mediaURL: URL? {
        UserDefaults.standard.string(forKey: "PinePodsDemoMedia").flatMap(URL.init(string:))
    }

    @MainActor
    static func installIfRequested() {
        guard isActive else { return }
        let media = mediaURL
        if let media, let host = media.host() {
            let session = SessionStore.shared
            session.server = "\(media.scheme ?? "http")://\(host):\(media.port ?? 80)"
            session.apiKey = "demo"
            session.userId = 1
            session.username = "demo"
        }

        let podcastsJSON: [[String: Any]] = [
            podcast(1, "The Daily Signal", "Northwind Media", 812, favorite: true, seed: "signal"),
            podcast(2, "Hard Fork Café", "Byte & Brew", 214, seed: "fork"),
            podcast(3, "Deep Forest Radio", "Pine Collective", 96, favorite: true, seed: "forest"),
            podcast(4, "Syntax Errors", "Two Devs", 530, seed: "syntax"),
            podcast(5, "Slow History", "Archive Audio", 158, seed: "history"),
            podcast(6, "Night Shift Science", "Lab Notes", 322, seed: "science"),
        ]
        let podcasts = podcastsJSON.map(Podcast.fromJSON)

        var episodesByPodcast: [Int: [PinepodsEpisode]] = [:]
        var allEpisodes: [PinepodsEpisode] = []
        var nextId = 100
        for (index, podcast) in podcastsJSON.enumerated() {
            let podcastId = index + 1
            let name = podcast["podcastname"] as! String
            let art = podcast["artworkurl"] as! String
            var list: [PinepodsEpisode] = []
            for n in 0..<8 {
                nextId += 1
                let duration = media == nil ? [2700, 3900, 1800, 5400, 2400][(n + index) % 5] : 50
                let listened: Int? = media != nil ? nil : (n == 1 ? duration / 3 : (n == 4 ? duration : nil))
                list.append(PinepodsEpisode.fromJSON([
                    "episodeid": nextId, "podcastid": podcastId, "podcastname": name,
                    "episodetitle": titles[(n + index * 3) % titles.count],
                    "episodedescription": "<p>In this episode we dig into the story behind the headlines, with guests from across the field.</p><ul><li>Chapter one</li><li>Chapter two</li></ul><p>Thanks for listening &amp; subscribing!</p>",
                    "episodeartwork": art, "episodeurl": media?.absoluteString ?? "https://example.com/\(nextId).mp3",
                    "episodepubdate": pubDate(daysAgo: n * 3 + index),
                    "episodeduration": duration, "listenduration": listened as Any,
                    "completed": media == nil && n == 4, "saved": n == 2, "downloaded": n == 3,
                ]))
            }
            episodesByPodcast[podcastId] = list
            allEpisodes += list
        }
        let feed = allEpisodes.sorted {
            (Formatters.parseDate($0.episodePubDate) ?? .distantPast) > (Formatters.parseDate($1.episodePubDate) ?? .distantPast)
        }

        func homeJSON(_ e: PinepodsEpisode) -> [String: Any] {
            [
                "episodeid": e.episodeId, "podcastid": e.podcastId ?? 0, "episodetitle": e.episodeTitle,
                "episodedescription": e.episodeDescription, "episodeurl": e.episodeUrl,
                "episodeartwork": e.episodeArtwork, "episodepubdate": e.episodePubDate,
                "episodeduration": e.episodeDuration, "completed": e.completed,
                "podcastname": e.podcastName, "listenduration": e.listenDuration as Any,
                "saved": e.saved, "downloaded": e.downloaded,
            ]
        }
        let inProgress = allEpisodes.filter { $0.progressPercentage > 1 && !$0.completed }
        // Queue preview exercises the Up Next filter: one with 20 s left (hidden)
        // and one carrying a ×100 corrupted position (shown as unstarted).
        var nearlyDone = homeJSON(feed[5])
        nearlyDone["listenduration"] = feed[5].episodeDuration - 20
        var corrupted = homeJSON(feed[6])
        corrupted["listenduration"] = feed[6].episodeDuration * 100
        let overview = HomeOverview.fromJSON([
            "recent_episodes": feed.prefix(12).map(homeJSON),
            "in_progress_episodes": inProgress.map(homeJSON),
            "queue_preview": [nearlyDone, corrupted, homeJSON(feed[7])],
            "top_podcasts": podcastsJSON.prefix(5).enumerated().map { i, p in
                p.merging(["play_count": 40 - i * 7]) { a, _ in a }
            },
            "saved_count": 14, "downloaded_count": 6, "queue_count": 3,
            "weekly_stats": ["seconds_listened": 5 * 3600 + 42 * 60, "episodes_completed": 7],
        ])
        let tasks = [DownloadTask.fromJSON([
            "id": "demo-task", "task_type": "download", "status": "DOWNLOADING", "progress": 62,
            "episode_title": feed[1].episodeTitle, "podcast_name": feed[1].podcastName,
        ])]

        LibraryStore.shared.installDemo(
            podcasts: podcasts, overview: overview, feed: feed,
            downloads: allEpisodes.filter(\.downloaded), saved: allEpisodes.filter(\.saved),
            queued: Array(feed.dropFirst(5).prefix(3)), tasks: tasks,
            episodesByPodcast: episodesByPodcast)

        if media == nil {
            let nowPlaying = inProgress.first ?? feed[0]
            AudioPlayerController.shared.installDemo(
                episode: nowPlaying, position: Double(nowPlaying.listenDuration ?? 0),
                duration: Double(nowPlaying.episodeDuration))
        }

        let router = AppRouter.shared
        switch screen {
        case "feed": router.selectedTab = .feed
        case "library": router.selectedTab = .library
        case "downloads": router.selectedTab = .downloads
        case "search": router.selectedTab = .search
        case "player": router.presentPlayer()
        case "settings": router.isSettingsPresented = true
        default: break
        }
    }

    private static let titles = [
        "The Quiet Revolution in Battery Chemistry",
        "Why Every City Is Rethinking Its Streets",
        "Inside the Race to Map the Ocean Floor",
        "A Conversation About Craft, Time, and Patience",
        "What the Old Maps Got Right",
        "The Economics of Small Things",
        "Debugging the Weird Bug That Took a Week",
        "Letters From a Lighthouse Keeper",
        "How Forests Talk to Each Other",
        "The Last Analog Studio in Town",
        "Night Skies and the People Who Chase Them",
    ]

    private static func podcast(
        _ id: Int, _ name: String, _ author: String, _ count: Int, favorite: Bool = false, seed: String
    ) -> [String: Any] {
        [
            "podcastid": id, "podcastname": name, "author": author, "episodecount": count,
            "is_favorite": favorite,
            "artworkurl": artworkBase.map { "\($0)/\(seed).png" } ?? "https://picsum.photos/seed/pinepods-\(seed)/600",
            "description": "\(name) is a weekly show from \(author) about the ideas, people, and places shaping the world — told slowly and carefully.",
            "categories": "Society, Technology",
        ]
    }

    private static func pubDate(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}
#endif
