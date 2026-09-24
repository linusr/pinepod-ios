import Foundation

/// User-configured automation rules. Day thresholds use `never` to switch a rule off.
struct AutomationRules: Codable, Equatable, Sendable {
    static let never = -1

    var downloadRegular = false
    var queueRegular = false
    /// A show is "regular" after this many episodes played within `regularWindowDays`.
    var regularMinEpisodes = 2
    var regularWindowDays = 30
    /// 0 removes on the next run after playing.
    var removePlayedFromPhoneAfterDays = never
    var removePlayedFromServerAfterDays = never
    /// Unplayed episodes published longer ago than this are marked played.
    var clearUnplayedAfterDays = never
    var keepSaved = true
    var intervalHours = 12

    var anyEnabled: Bool {
        downloadRegular || queueRegular
            || removePlayedFromPhoneAfterDays != Self.never
            || removePlayedFromServerAfterDays != Self.never
            || clearUnplayedAfterDays != Self.never
    }

    var enabledCount: Int {
        [downloadRegular || queueRegular,
         removePlayedFromPhoneAfterDays != Self.never || removePlayedFromServerAfterDays != Self.never,
         clearUnplayedAfterDays != Self.never].filter { $0 }.count
    }
}

/// Everything the planner looks at, gathered by the engine.
struct AutomationInput: Sendable {
    var now: Date
    /// Most recent first; complete back to `historyCoversDays`.
    var history: [PinepodsEpisode]
    var historyCoversDays: Int
    var feed: [PinepodsEpisode]
    var queue: [PinepodsEpisode]
    var phoneDownloads: [PinepodsEpisode]
    var serverDownloads: [PinepodsEpisode]
    /// Every episode of every subscribed show; nil when the daily sweep isn't due.
    var showEpisodes: [PinepodsEpisode]?
    /// New episodes already acted on, so a removed one isn't re-added.
    var handledIds: Set<Int>
    /// Never touched (the episode playing now).
    var protectedIds: Set<Int>
    var newEpisodeWindowDays = 7
}

struct AutomationPlan: Sendable {
    var regularShows: [String] = []
    var download: [PinepodsEpisode] = []
    var queue: [PinepodsEpisode] = []
    var removeFromPhone: [PinepodsEpisode] = []
    var removeFromServer: [PinepodsEpisode] = []
    var markPlayed: [PinepodsEpisode] = []
    /// New episodes considered this run, whether or not an action applied.
    var handled: [Int] = []

    var isEmpty: Bool {
        download.isEmpty && queue.isEmpty && removeFromPhone.isEmpty
            && removeFromServer.isEmpty && markPlayed.isEmpty
    }
}

enum AutomationPlanner {
    static func plan(rules: AutomationRules, input: AutomationInput) -> AutomationPlan {
        var plan = AutomationPlan()
        let day: TimeInterval = 86_400
        let now = input.now

        var listenDates: [Int: Date] = [:]
        var completedInHistory = Set<Int>()
        for entry in input.history {
            if listenDates[entry.episodeId] == nil, let date = entry.listenDate.flatMap(Formatters.parseDate) {
                listenDates[entry.episodeId] = date
            }
            if entry.completed { completedInHistory.insert(entry.episodeId) }
        }
        let historyStart = now.addingTimeInterval(-Double(input.historyCoversDays) * day)

        func isPlayed(_ episode: PinepodsEpisode) -> Bool {
            episode.completed || completedInHistory.contains(episode.episodeId)
        }
        /// A played episode missing from the fetched history was played before it began.
        func playedAt(_ episode: PinepodsEpisode) -> Date {
            listenDates[episode.episodeId] ?? historyStart.addingTimeInterval(-day)
        }
        func publishedAt(_ episode: PinepodsEpisode) -> Date? {
            Formatters.parseDate(episode.episodePubDate)
        }
        func eligible(_ episode: PinepodsEpisode) -> Bool {
            !input.protectedIds.contains(episode.episodeId)
        }

        // Regular shows: new episodes are downloaded and/or queued once.
        if rules.downloadRegular || rules.queueRegular {
            let windowStart = now.addingTimeInterval(-Double(rules.regularWindowDays) * day)
            var playedPerShow: [String: Set<Int>] = [:]
            for entry in input.history where !entry.podcastName.isEmpty {
                guard let date = listenDates[entry.episodeId], date >= windowStart else { continue }
                playedPerShow[entry.podcastName, default: []].insert(entry.episodeId)
            }
            let regular = Set(playedPerShow.filter { $0.value.count >= rules.regularMinEpisodes }.keys)
            plan.regularShows = regular.sorted()

            let newSince = now.addingTimeInterval(-Double(input.newEpisodeWindowDays) * day)
            let queued = Set(input.queue.map(\.episodeId))
            let candidates = input.feed
                .filter { regular.contains($0.podcastName) && !isPlayed($0) && eligible($0) }
                .filter { !input.handledIds.contains($0.episodeId) }
                .filter { (publishedAt($0) ?? .distantPast) >= newSince }
                .sorted { (publishedAt($0) ?? .distantPast) < (publishedAt($1) ?? .distantPast) }
            if rules.downloadRegular {
                plan.download = candidates
            }
            if rules.queueRegular {
                plan.queue = candidates.filter { !queued.contains($0.episodeId) }
            }
            plan.handled = candidates.map(\.episodeId)
        }

        // Played episodes: remove downloads some time after playing.
        if rules.removePlayedFromPhoneAfterDays != AutomationRules.never {
            let cutoff = now.addingTimeInterval(-Double(rules.removePlayedFromPhoneAfterDays) * day)
            plan.removeFromPhone = input.phoneDownloads.filter {
                isPlayed($0) && eligible($0) && playedAt($0) <= cutoff
            }
        }
        if rules.removePlayedFromServerAfterDays != AutomationRules.never {
            let cutoff = now.addingTimeInterval(-Double(rules.removePlayedFromServerAfterDays) * day)
            plan.removeFromServer = input.serverDownloads.filter {
                isPlayed($0) && eligible($0) && playedAt($0) <= cutoff
            }
        }

        // Old unplayed episodes: mark played and drop their downloads.
        if rules.clearUnplayedAfterDays != AutomationRules.never {
            let cutoff = now.addingTimeInterval(-Double(rules.clearUnplayedAfterDays) * day)
            var pool: [Int: PinepodsEpisode] = [:]
            for episode in (input.showEpisodes ?? []) + input.queue + input.phoneDownloads + input.serverDownloads {
                pool[episode.episodeId] = pool[episode.episodeId] ?? episode
            }
            let stale = pool.values.filter { episode in
                guard !isPlayed(episode), eligible(episode),
                      !(rules.keepSaved && episode.saved),
                      let published = publishedAt(episode) else { return false }
                return published < cutoff
            }
            let staleIds = Set(stale.map(\.episodeId))
            plan.markPlayed = stale.sorted { $0.episodeId < $1.episodeId }
            plan.removeFromPhone += input.phoneDownloads.filter { staleIds.contains($0.episodeId) }
            plan.removeFromServer += input.serverDownloads.filter { staleIds.contains($0.episodeId) }
        }

        plan.removeFromPhone = unique(plan.removeFromPhone)
        plan.removeFromServer = unique(plan.removeFromServer)
        return plan
    }

    private static func unique(_ episodes: [PinepodsEpisode]) -> [PinepodsEpisode] {
        var seen = Set<Int>()
        return episodes.filter { seen.insert($0.episodeId).inserted }
    }
}
