import Foundation
import Observation

/// Aggregates all server-backed library state: subscribed podcasts, home
/// overview, the recent-episodes feed, server downloads, and download tasks.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var podcasts: [Podcast] = []
    private(set) var podcastsLoaded = false
    private(set) var homeOverview: HomeOverview?
    private(set) var feedEpisodes: [PinepodsEpisode] = []
    private(set) var feedTotal = 0
    private(set) var serverDownloads: [PinepodsEpisode] = []
    private(set) var savedEpisodes: [PinepodsEpisode] = []
    private(set) var queuedEpisodes: [PinepodsEpisode] = []
    private(set) var downloadTasks: [DownloadTask] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var podcastEpisodesCache: [Int: [PinepodsEpisode]] = [:]
    private var taskPolling: Task<Void, Never>?

    private static let queueFileName = "queue.json"

    /// The queue starts from the last saved copy so it works offline.
    private init() {
        queuedEpisodes = LocalFiles.load([PinepodsEpisode].self, from: Self.queueFileName) ?? []
    }

    private var client: APIClient? {
        let session = SessionStore.shared
        guard session.isLoggedIn else { return nil }
        return session.client
    }

    private var userId: Int { SessionStore.shared.userId }

    // MARK: - Loading

    func loadPodcasts() async {
        guard let client else { return }
        do {
            podcasts = try await client.userPodcasts(userId: userId)
            podcastsLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load podcasts: \(error.localizedDescription)"
        }
    }

    func loadHome() async {
        guard let client else { return }
        do {
            homeOverview = try await client.homeOverview(userId: userId)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load home: \(error.localizedDescription)"
        }
    }

    func loadFeed(reset: Bool = false) async {
        guard let client else { return }
        if reset {
            feedEpisodes = []
            feedTotal = 0
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.recentEpisodes(
                userId: userId, limit: 50, offset: feedEpisodes.count)
            feedEpisodes += page.episodes
            feedTotal = page.total
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
        }
    }

    func loadSaved() async {
        guard let client else { return }
        do {
            savedEpisodes = try await client.savedEpisodes(userId: userId)
        } catch {
            errorMessage = "Failed to load saved episodes: \(error.localizedDescription)"
        }
    }

    func loadQueue() async {
        guard let client else { return }
        do {
            queuedEpisodes = try await client.queuedEpisodes(userId: userId)
            queueDidChange()
        } catch {
            errorMessage = "Failed to load queue: \(error.localizedDescription)"
        }
    }

    func episodes(for podcastId: Int, force: Bool = false) async -> [PinepodsEpisode] {
        if !force, let cached = podcastEpisodesCache[podcastId] {
            return cached
        }
        guard let client else { return podcastEpisodesCache[podcastId] ?? [] }
        do {
            let episodes = try await client.podcastEpisodes(userId: userId, podcastId: podcastId)
            podcastEpisodesCache[podcastId] = episodes
            return episodes
        } catch {
            return podcastEpisodesCache[podcastId] ?? []
        }
    }

    func refreshDownloads() async {
        guard let client else { return }
        async let downloads = try? client.serverDownloads(userId: userId)
        async let tasks = try? client.downloadTasks(userId: userId)
        serverDownloads = await downloads ?? serverDownloads
        let fetchedTasks = await tasks ?? downloadTasks
        downloadTasks = fetchedTasks
        if fetchedTasks.contains(where: { $0.isActive }) {
            startTaskPolling()
        } else {
            stopTaskPolling()
        }
    }

    @discardableResult
    func startDownload(episode: PinepodsEpisode) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.downloadEpisode(
                episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube)
            updateEpisode(episode.updated(downloaded: true))
            await refreshDownloads()
            return true
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            return false
        }
    }

    func deleteDownload(episode: PinepodsEpisode) async {
        guard let client else { return }
        do {
            _ = try await client.deleteDownloadedEpisode(
                episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube)
            updateEpisode(episode.updated(downloaded: false))
            serverDownloads.removeAll { $0.episodeId == episode.episodeId }
            await refreshDownloads()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setSaved(_ episode: PinepodsEpisode, _ saved: Bool) async -> PinepodsEpisode? {
        guard let client else { return nil }
        do {
            if saved {
                _ = try await client.saveEpisode(
                    episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube)
            } else {
                _ = try await client.removeSavedEpisode(
                    episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube)
            }
            let updated = episode.updated(saved: saved)
            updateEpisode(updated)
            if saved {
                if !savedEpisodes.contains(where: { $0.episodeId == updated.episodeId }) {
                    savedEpisodes.insert(updated, at: 0)
                }
            } else {
                savedEpisodes.removeAll { $0.episodeId == updated.episodeId }
            }
            return updated
        } catch {
            errorMessage = "Could not update saved state: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func setCompleted(_ episode: PinepodsEpisode, _ completed: Bool) async -> PinepodsEpisode? {
        guard let client else { return nil }
        do {
            if completed {
                _ = try await client.markCompleted(
                    episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube)
            } else {
                _ = try await client.markUncompleted(
                    episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube)
            }
            let updated = episode.updated(
                listenDuration: completed ? episode.episodeDuration : 0, completed: completed)
            updateEpisode(updated)
            await loadHome()
            return updated
        } catch {
            errorMessage = "Could not update played state: \(error.localizedDescription)"
            return nil
        }
    }

    func cachedEpisodes(for podcastId: Int) -> [PinepodsEpisode]? {
        podcastEpisodesCache[podcastId]
    }

    /// Every episode currently held in memory, de-duplicated; backs local search.
    var knownEpisodes: [PinepodsEpisode] {
        var seen = Set<Int>()
        let all = feedEpisodes + serverDownloads + savedEpisodes + queuedEpisodes
            + podcastEpisodesCache.values.flatMap { $0 }
        return all.filter { seen.insert($0.episodeId).inserted }
    }

    /// Pushes a mutated episode into every cached collection (and the player)
    /// so rows reflect progress/save/download state without a refetch.
    func updateEpisode(_ episode: PinepodsEpisode) {
        AudioPlayerController.shared.updateCurrentEpisode(episode)
        DownloadManager.shared.updateSnapshot(episode)
        feedEpisodes = feedEpisodes.map { $0.episodeId == episode.episodeId ? episode : $0 }
        serverDownloads = serverDownloads.map { $0.episodeId == episode.episodeId ? episode : $0 }
        savedEpisodes = savedEpisodes.map { $0.episodeId == episode.episodeId ? episode : $0 }
        queuedEpisodes = queuedEpisodes.map { $0.episodeId == episode.episodeId ? episode : $0 }
        for (podcastId, episodes) in podcastEpisodesCache {
            podcastEpisodesCache[podcastId] = episodes.map { $0.episodeId == episode.episodeId ? episode : $0 }
        }
    }

    #if DEBUG
    func installDemo(
        podcasts: [Podcast], overview: HomeOverview, feed: [PinepodsEpisode],
        downloads: [PinepodsEpisode], saved: [PinepodsEpisode], queued: [PinepodsEpisode],
        tasks: [DownloadTask], episodesByPodcast: [Int: [PinepodsEpisode]]
    ) {
        savedEpisodes = saved
        queuedEpisodes = queued
        self.podcasts = podcasts
        podcastsLoaded = true
        homeOverview = overview
        feedEpisodes = feed
        feedTotal = feed.count
        serverDownloads = downloads
        downloadTasks = tasks
        podcastEpisodesCache = episodesByPodcast
    }
    #endif

    /// Reloads everything a bulk server-side change can affect.
    func refreshAfterBulkChange() async {
        podcastEpisodesCache = [:]
        await loadQueue()
        await refreshDownloads()
        await loadHome()
        if !feedEpisodes.isEmpty {
            await loadFeed(reset: true)
        }
    }

    // MARK: - Queue

    func isQueued(_ episodeId: Int) -> Bool {
        queuedEpisodes.contains { $0.episodeId == episodeId }
    }

    @discardableResult
    func addToQueue(_ episode: PinepodsEpisode) async -> Bool {
        guard !isQueued(episode.episodeId) else { return true }
        guard let client else { return false }
        do {
            guard try await client.queueEpisode(
                episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube) else {
                throw APIError.invalidResponse
            }
            let updated = episode.updated(queued: true)
            queuedEpisodes.append(updated)
            updateEpisode(updated)
            queueDidChange()
            return true
        } catch {
            errorMessage = "Could not add to queue: \(error.localizedDescription)"
            return false
        }
    }

    /// Queues the episode right after the one playing (or first).
    func playNext(_ episode: PinepodsEpisode) async {
        guard await addToQueue(episode) else { return }
        var order = queuedEpisodes.filter { $0.episodeId != episode.episodeId }
        let playingId = AudioPlayerController.shared.currentEpisode?.episodeId
        let insertAt = order.firstIndex { $0.episodeId == playingId }.map { $0 + 1 } ?? 0
        let queued = queuedEpisodes.first { $0.episodeId == episode.episodeId } ?? episode.updated(queued: true)
        order.insert(queued, at: insertAt)
        await setQueueOrder(order)
    }

    func removeFromQueue(_ episode: PinepodsEpisode) async {
        guard let client else { return }
        do {
            guard try await client.removeQueuedEpisode(
                episodeId: episode.episodeId, userId: userId, isYoutube: episode.isYoutube) else {
                throw APIError.invalidResponse
            }
            queuedEpisodes.removeAll { $0.episodeId == episode.episodeId }
            updateEpisode(episode.updated(queued: false))
            queueDidChange()
        } catch {
            errorMessage = "Could not remove from queue: \(error.localizedDescription)"
        }
    }

    func moveQueue(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var order = queuedEpisodes
        order.move(fromOffsets: source, toOffset: destination)
        await setQueueOrder(order)
    }

    func clearQueue() async {
        guard let client else { return }
        do {
            guard try await client.clearQueue(userId: userId) else { throw APIError.invalidResponse }
            let cleared = queuedEpisodes
            queuedEpisodes = []
            cleared.forEach { updateEpisode($0.updated(queued: false)) }
            queueDidChange()
        } catch {
            errorMessage = "Could not clear the queue: \(error.localizedDescription)"
        }
    }

    /// The server removes completed episodes from the queue; mirror that locally.
    func removeCompletedFromQueue(_ episodeId: Int) {
        guard isQueued(episodeId) else { return }
        queuedEpisodes.removeAll { $0.episodeId == episodeId }
        queueDidChange()
    }

    /// The unplayed queue entry after `episodeId`, wrapping to the front when
    /// `episodeId` isn't queued.
    func nextInQueue(after episodeId: Int?) -> PinepodsEpisode? {
        let candidates = queuedEpisodes.filter { !$0.completed && $0.episodeId != episodeId }
        guard let episodeId, let index = queuedEpisodes.firstIndex(where: { $0.episodeId == episodeId }) else {
            return candidates.first
        }
        return queuedEpisodes[(index + 1)...].first { !$0.completed } ?? candidates.first
    }

    /// Applied locally first so a drag feels instant; reverted if the server refuses.
    private func setQueueOrder(_ order: [PinepodsEpisode]) async {
        let previous = queuedEpisodes
        queuedEpisodes = order
        guard let client,
              (try? await client.reorderQueue(episodeIds: order.map(\.episodeId), userId: userId)) == true else {
            queuedEpisodes = previous
            errorMessage = "Could not reorder the queue."
            return
        }
        queueDidChange()
    }

    private func queueDidChange() {
        LocalFiles.save(queuedEpisodes, to: Self.queueFileName)
        WidgetPublisher.setNeedsUpdate()
        DownloadManager.shared.syncQueueDownloads(queuedEpisodes)
    }

    // MARK: - Task polling

    private func startTaskPolling() {
        guard taskPolling == nil else { return }
        taskPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                await self.refreshDownloads()
            }
        }
    }

    private func stopTaskPolling() {
        taskPolling?.cancel()
        taskPolling = nil
    }
}
