import BackgroundTasks
import Foundation
import Observation

struct AutomationRun: Codable, Identifiable, Sendable {
    enum Trigger: String, Codable, Sendable {
        case app, background, manual
    }

    struct Entry: Codable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case downloaded, queued, removedFromPhone, removedFromServer, markedPlayed
        }

        var kind: Kind
        var count: Int
        /// The first few episode titles, for the activity log.
        var titles: [String]

        var id: String { kind.rawValue }
    }

    var id = UUID()
    var date: Date
    var trigger: Trigger
    var entries: [Entry] = []
    var error: String?
}

/// Runs the automation rules: gathers library state, asks `AutomationPlanner`
/// for a plan and applies it. Runs when the app becomes active (if due), in
/// background app refresh, and on demand.
@MainActor
@Observable
final class AutomationEngine {
    static let shared = AutomationEngine()

    nonisolated static let backgroundTaskIdentifier = "me.4vr.pinepods.automation"

    private struct State: Codable {
        var lastRun: Date?
        var lastSweep: Date?
        var handledIds: [Int]
        var log: [AutomationRun]
    }

    private static let fileName = "automation.json"
    private static let sweepInterval: TimeInterval = 20 * 3600
    private static let logLimit = 30
    private static let handledLimit = 3000

    private(set) var isRunning = false
    private(set) var lastRun: Date?
    private(set) var log: [AutomationRun]
    private var lastSweep: Date?
    private var handledIds: [Int]

    private init() {
        let state = LocalFiles.load(State.self, from: Self.fileName)
        lastRun = state?.lastRun
        lastSweep = state?.lastSweep
        handledIds = state?.handledIds ?? []
        log = state?.log ?? []
    }

    /// Runs when rules are on and the configured interval has passed.
    func runIfDue() {
        let rules = SettingsStore.shared.automationRules
        guard rules.anyEnabled, !isRunning else { return }
        if let lastRun, Date().timeIntervalSince(lastRun) < Double(rules.intervalHours) * 3600 { return }
        Task { await run(trigger: .app) }
    }

    func run(trigger: AutomationRun.Trigger) async {
        let rules = SettingsStore.shared.automationRules
        guard rules.anyEnabled || trigger == .manual, !isRunning, SessionStore.shared.isLoggedIn else { return }
        isRunning = true
        defer {
            isRunning = false
            scheduleBackgroundRun()
        }

        let now = Date()
        var run = AutomationRun(date: now, trigger: trigger)
        do {
            let (input, sweepDue) = try await gather(rules: rules, now: now, forceSweep: trigger == .manual)
            let plan = AutomationPlanner.plan(rules: rules, input: input)
            try Task.checkCancellation()
            run.entries = await apply(plan)
            if sweepDue { lastSweep = now }
            handledIds = Array((handledIds + plan.handled).suffix(Self.handledLimit))
            lastRun = now
            NSLog("[PinePods] automation (%@): %@", trigger.rawValue,
                  run.entries.map { "\($0.kind.rawValue)=\($0.count)" }.joined(separator: " "))
        } catch is CancellationError {
            run.error = "Stopped before finishing."
        } catch {
            // Nothing was changed: gathering happens before any action.
            run.error = "Skipped — couldn't reach the server (\(error.localizedDescription))."
        }

        if !run.entries.isEmpty || trigger == .manual {
            log.insert(run, at: 0)
            log = Array(log.prefix(Self.logLimit))
        }
        save()
    }

    func clearLog() {
        log = []
        save()
    }

    // MARK: - Background refresh

    /// Must run before the app finishes launching.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            let backgroundTask = UncheckedBox(task)
            let work = Task { @MainActor in
                await AutomationEngine.shared.run(trigger: .background)
                backgroundTask.value.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func scheduleBackgroundRun() {
        let rules = SettingsStore.shared.automationRules
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        guard rules.anyEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Double(rules.intervalHours) * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[PinePods] automation: background refresh not scheduled: %@", error.localizedDescription)
        }
    }

    // MARK: - Gathering

    private func gather(
        rules: AutomationRules, now: Date, forceSweep: Bool
    ) async throws -> (AutomationInput, sweepDue: Bool) {
        let session = SessionStore.shared
        let client = session.client
        let userId = session.userId
        let library = LibraryStore.shared

        let coverDays = max(rules.regularWindowDays,
                            rules.removePlayedFromPhoneAfterDays,
                            rules.removePlayedFromServerAfterDays) + 1
        let history = try await fetchHistory(client: client, userId: userId, coverDays: coverDays, now: now)
        try Task.checkCancellation()

        let feed = rules.downloadRegular || rules.queueRegular
            ? try await client.recentEpisodes(userId: userId, limit: 300).episodes
            : []
        let serverDownloads = rules.removePlayedFromServerAfterDays != AutomationRules.never
            || rules.clearUnplayedAfterDays != AutomationRules.never
            ? try await client.serverDownloads(userId: userId)
            : []

        let sweepDue = rules.clearUnplayedAfterDays != AutomationRules.never
            && (forceSweep || lastSweep.map { now.timeIntervalSince($0) > Self.sweepInterval } ?? true)
        var showEpisodes: [PinepodsEpisode]?
        if sweepDue {
            if !library.podcastsLoaded { await library.loadPodcasts() }
            guard library.podcastsLoaded else { throw APIError.invalidResponse }
            var all: [PinepodsEpisode] = []
            for podcast in library.podcasts {
                try Task.checkCancellation()
                all += try await client.podcastEpisodes(userId: userId, podcastId: podcast.id)
            }
            showEpisodes = all
        }

        let queue = try await client.queuedEpisodes(userId: userId)
        let playing = AudioPlayerController.shared.currentEpisode?.episodeId
        let input = AutomationInput(
            now: now,
            history: history,
            historyCoversDays: coverDays,
            feed: feed,
            queue: queue,
            phoneDownloads: DownloadManager.shared.sortedDownloads.map(\.episode),
            serverDownloads: serverDownloads,
            showEpisodes: showEpisodes,
            handledIds: Set(handledIds),
            protectedIds: playing.map { [$0] } ?? [])
        return (input, sweepDue)
    }

    /// History is sorted newest first; stop paging once it reaches `coverDays` back.
    private func fetchHistory(client: APIClient, userId: Int, coverDays: Int, now: Date) async throws -> [PinepodsEpisode] {
        let pageSize = 100
        let start = now.addingTimeInterval(-Double(coverDays) * 86_400)
        var all: [PinepodsEpisode] = []
        for page in 0..<20 {
            let batch = try await client.userHistory(userId: userId, limit: pageSize, offset: page * pageSize)
            all += batch
            guard batch.count == pageSize else { break }
            if let oldest = batch.last?.listenDate.flatMap(Formatters.parseDate), oldest < start { break }
        }
        return all
    }

    // MARK: - Applying

    private func apply(_ plan: AutomationPlan) async -> [AutomationRun.Entry] {
        let session = SessionStore.shared
        let client = session.client
        let userId = session.userId
        let downloads = DownloadManager.shared
        let library = LibraryStore.shared
        var entries: [AutomationRun.Entry] = []

        func record(_ kind: AutomationRun.Entry.Kind, _ episodes: [PinepodsEpisode]) {
            guard !episodes.isEmpty else { return }
            entries.append(.init(kind: kind, count: episodes.count, titles: episodes.prefix(8).map(\.episodeTitle)))
        }

        let queued = await bulk(plan.queue) { try await client.bulkQueue(episodeIds: $0, userId: userId, isYoutube: $1) }
        record(.queued, queued)

        for episode in plan.download {
            downloads.download(episode, automatic: true)
        }
        record(.downloaded, plan.download.filter { downloads.isDownloading($0.episodeId) || downloads.isDownloaded($0.episodeId) })

        let marked = await bulk(plan.markPlayed) { try await client.bulkMarkCompleted(episodeIds: $0, userId: userId, isYoutube: $1) }
        record(.markedPlayed, marked)

        let removedFromServer = await bulk(plan.removeFromServer) {
            try await client.bulkDeleteServerDownloads(episodeIds: $0, userId: userId, isYoutube: $1)
        }
        record(.removedFromServer, removedFromServer)

        for episode in plan.removeFromPhone {
            downloads.delete(episode.episodeId)
        }
        record(.removedFromPhone, plan.removeFromPhone)

        if !entries.isEmpty {
            await library.refreshAfterBulkChange()
        }
        return entries
    }

    /// Sends bulk requests grouped by source (the API takes one `is_youtube` per
    /// call) in chunks, returning the episodes the server accepted.
    private func bulk(
        _ episodes: [PinepodsEpisode],
        _ send: ([Int], Bool) async throws -> Bool
    ) async -> [PinepodsEpisode] {
        var accepted: [PinepodsEpisode] = []
        for isYoutube in [false, true] {
            let group = episodes.filter { $0.isYoutube == isYoutube }
            for start in stride(from: 0, to: group.count, by: 100) {
                let chunk = Array(group[start..<min(start + 100, group.count)])
                if (try? await send(chunk.map(\.episodeId), isYoutube)) == true {
                    accepted += chunk
                }
            }
        }
        return accepted
    }

    private func save() {
        LocalFiles.save(
            State(lastRun: lastRun, lastSweep: lastSweep, handledIds: handledIds, log: log),
            to: Self.fileName)
    }
}

/// Carries a non-Sendable system object into a main-actor task. The
/// background task is only touched from that task after this point.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
