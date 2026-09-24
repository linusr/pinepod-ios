import Foundation
import Observation

struct LocalDownload: Codable, Identifiable, Sendable {
    var episode: PinepodsEpisode
    let fileName: String
    let bytes: Int64
    let downloadedAt: Date

    var id: Int { episode.episodeId }
}

/// Episode files stored on the phone for offline playback. Transfers run in
/// a background URLSession, so they continue while the app is suspended.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    nonisolated static let sessionIdentifier = "me.4vr.pinepods.downloads"
    nonisolated static let mediaDirectory: URL = {
        let url = LocalFiles.directory.appending(path: "Media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private struct Index: Codable {
        var downloads: [LocalDownload]
        var pending: [PinepodsEpisode]
    }

    private static let indexFileName = "downloads.json"

    private(set) var downloads: [Int: LocalDownload] = [:]
    /// In-flight transfers: episode id → fraction complete (0 until the size is known).
    private(set) var progress: [Int: Double] = [:]
    private(set) var lastError: String?

    /// Episodes whose transfer hasn't finished; kept so a relaunch can finish them.
    private var pendingEpisodes: [Int: PinepodsEpisode] = [:]
    /// Set by the app delegate when iOS relaunches the app for finished transfers.
    var backgroundEventsCompletion: (() -> Void)?

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: DownloadSessionDelegate(), delegateQueue: nil)

        let index = LocalFiles.load(Index.self, from: Self.indexFileName)
        let fileManager = FileManager.default
        downloads = Dictionary(
            (index?.downloads ?? [])
                .filter { fileManager.fileExists(atPath: Self.mediaDirectory.appending(path: $0.fileName).path) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest })
        pendingEpisodes = Dictionary(
            (index?.pending ?? []).map { ($0.episodeId, $0) },
            uniquingKeysWith: { _, latest in latest })

        // Reattach to transfers that survived a relaunch; forget pending ones that didn't.
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription.flatMap(Int.init) })
            Task { @MainActor in
                let manager = DownloadManager.shared
                for id in manager.pendingEpisodes.keys where !running.contains(id) {
                    manager.pendingEpisodes[id] = nil
                }
                for id in running where manager.progress[id] == nil {
                    manager.progress[id] = 0
                }
                manager.save()
            }
        }
    }

    // MARK: - Queries

    var usedBytes: Int64 {
        downloads.values.reduce(0) { $0 + $1.bytes }
    }

    var sortedDownloads: [LocalDownload] {
        downloads.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    /// Episodes with a transfer in flight.
    var activeEpisodes: [PinepodsEpisode] {
        progress.keys.compactMap { pendingEpisodes[$0] }.sorted { $0.episodeId < $1.episodeId }
    }

    func isDownloaded(_ episodeId: Int) -> Bool {
        downloads[episodeId] != nil
    }

    func isDownloading(_ episodeId: Int) -> Bool {
        progress[episodeId] != nil
    }

    func localURL(for episodeId: Int) -> URL? {
        guard let download = downloads[episodeId] else { return nil }
        let url = Self.mediaDirectory.appending(path: download.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Actions

    /// Automatic downloads respect the storage limit; manual ones don't.
    func download(_ episode: PinepodsEpisode, automatic: Bool = false) {
        let id = episode.episodeId
        guard !isDownloaded(id), !isDownloading(id) else { return }
        if automatic, let limit = SettingsStore.shared.downloadLimitBytes, usedBytes >= limit {
            NSLog("[PinePods] downloads: storage limit reached, skipping episode %ld", id)
            return
        }
        guard let url = sourceURL(for: episode) else {
            lastError = "No downloadable file for “\(episode.episodeTitle)”."
            return
        }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = SettingsStore.shared.downloadOverCellular
        request.setValue(
            "AppleCoreMedia/1.0.0.27B91 (iPhone; U; CPU OS 27_0 like Mac OS X; en_us)",
            forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        task.taskDescription = String(id)
        pendingEpisodes[id] = episode
        progress[id] = 0
        lastError = nil
        save()
        task.resume()
    }

    func cancel(_ episodeId: Int) {
        let description = String(episodeId)
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == description }.forEach { $0.cancel() }
        }
        progress[episodeId] = nil
        pendingEpisodes[episodeId] = nil
        save()
    }

    func delete(_ episodeId: Int) {
        if let url = localURL(for: episodeId) {
            try? FileManager.default.removeItem(at: url)
        }
        downloads[episodeId] = nil
        save()
    }

    func deleteAll() {
        for id in Array(progress.keys) { cancel(id) }
        for id in Array(downloads.keys) { delete(id) }
    }

    /// Keeps the first N unplayed queue entries on the phone (N from settings).
    func syncQueueDownloads(_ queue: [PinepodsEpisode]) {
        let keep = SettingsStore.shared.keepQueuedDownloaded
        guard keep > 0 else { return }
        for episode in queue.filter({ !$0.completed }).prefix(keep) {
            download(episode, automatic: true)
        }
    }

    func updateSnapshot(_ episode: PinepodsEpisode) {
        downloads[episode.episodeId]?.episode = episode
    }

    // MARK: - Session callbacks

    fileprivate func updateProgress(_ episodeId: Int, fraction: Double) {
        guard progress[episodeId] != nil else { return }
        progress[episodeId] = fraction
    }

    fileprivate func finish(_ episodeId: Int, fileName: String, bytes: Int64) {
        progress[episodeId] = nil
        guard let episode = pendingEpisodes.removeValue(forKey: episodeId) else {
            try? FileManager.default.removeItem(at: Self.mediaDirectory.appending(path: fileName))
            save()
            return
        }
        downloads[episodeId] = LocalDownload(
            episode: episode, fileName: fileName, bytes: bytes, downloadedAt: .now)
        save()
    }

    fileprivate func fail(_ episodeId: Int, message: String?) {
        progress[episodeId] = nil
        let episode = pendingEpisodes.removeValue(forKey: episodeId)
        if let message {
            lastError = "Download failed for “\(episode?.episodeTitle ?? "episode")”: \(message)"
        }
        save()
    }

    fileprivate func finishBackgroundEvents() {
        backgroundEventsCompletion?()
        backgroundEventsCompletion = nil
    }

    // MARK: - Private

    /// The podcast's own URL, else the server stream (YouTube, or feeds without one).
    private func sourceURL(for episode: PinepodsEpisode) -> URL? {
        if !episode.isYoutube, let url = URL(string: episode.episodeUrl),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        guard SessionStore.shared.isLoggedIn,
              let stream = SessionStore.shared.client.streamURL(
                  episodeId: episode.episodeId, userId: SessionStore.shared.userId,
                  isYoutube: episode.isYoutube, isLocal: episode.downloaded) else { return nil }
        return URL(string: stream)
    }

    private func save() {
        LocalFiles.save(
            Index(downloads: Array(downloads.values), pending: Array(pendingEpisodes.values)),
            to: Self.indexFileName)
    }
}

/// Session delegate: runs on URLSession's queue and forwards results to the
/// main-actor manager. Finished files must be moved before the callback returns.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription.flatMap(Int.init), totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in DownloadManager.shared.updateProgress(id, fraction: fraction) }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription.flatMap(Int.init) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        guard let status = response?.statusCode, (200..<300).contains(status) else {
            let code = response?.statusCode ?? 0
            Task { @MainActor in DownloadManager.shared.fail(id, message: "server returned \(code)") }
            return
        }

        let fileName = "\(id).\(Self.fileExtension(for: response, url: downloadTask.originalRequest?.url))"
        let destination = DownloadManager.mediaDirectory.appending(path: fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            Task { @MainActor in DownloadManager.shared.finish(id, fileName: fileName, bytes: bytes) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in DownloadManager.shared.fail(id, message: message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(Int.init) else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        let message = cancelled ? nil : error.localizedDescription
        Task { @MainActor in DownloadManager.shared.fail(id, message: message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadManager.shared.finishBackgroundEvents() }
    }

    /// AVPlayer picks the decoder from the file extension, so it must match the content.
    private static func fileExtension(for response: HTTPURLResponse?, url: URL?) -> String {
        switch response?.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac", "audio/aacp": return "aac"
        case "video/mp4": return "mp4"
        case "audio/wav", "audio/x-wav": return "wav"
        default: break
        }
        let known = ["mp3", "m4a", "aac", "mp4", "m4b", "wav", "caf"]
        for candidate in [response?.suggestedFilename, url?.lastPathComponent] {
            if let ext = candidate.map({ ($0 as NSString).pathExtension.lowercased() }), known.contains(ext) {
                return ext
            }
        }
        return "mp3"
    }
}
