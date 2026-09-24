import Foundation
import Network
import Observation

/// Durable queue of playback updates for the server. Updates made offline are
/// kept on disk and sent in order once the network returns.
@MainActor
@Observable
final class SyncOutbox {
    static let shared = SyncOutbox()

    enum Action: Codable, Equatable {
        case position(episodeId: Int, userId: Int, seconds: Double, isYoutube: Bool)
        case completed(episodeId: Int, userId: Int, durationSeconds: Double, isYoutube: Bool)

        var episodeId: Int {
            switch self {
            case .position(let episodeId, _, _, _), .completed(let episodeId, _, _, _): episodeId
            }
        }
    }

    private static let fileName = "outbox.json"
    private static let positionsFileName = "positions.json"

    private(set) var pending: [Action]
    /// Last position played on this device per episode, including ones not yet sent.
    private var lastPositions: [Int: Double]
    private var isFlushing = false
    private let monitor = NWPathMonitor()

    private init() {
        pending = LocalFiles.load([Action].self, from: Self.fileName) ?? []
        lastPositions = LocalFiles.load([Int: Double].self, from: Self.positionsFileName) ?? [:]
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in SyncOutbox.shared.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "me.4vr.kural.outbox"))
    }

    func lastPosition(for episodeId: Int) -> Double? {
        lastPositions[episodeId]
    }

    /// Only the latest position per episode is kept.
    func recordPosition(episodeId: Int, userId: Int, seconds: Double, isYoutube: Bool) {
        lastPositions[episodeId] = seconds
        LocalFiles.save(lastPositions, to: Self.positionsFileName)
        pending.removeAll {
            if case .position = $0 { return $0.episodeId == episodeId }
            return false
        }
        enqueue(.position(episodeId: episodeId, userId: userId, seconds: seconds, isYoutube: isYoutube))
    }

    /// Supersedes any queued positions for the episode.
    func recordCompleted(episodeId: Int, userId: Int, durationSeconds: Double, isYoutube: Bool) {
        lastPositions[episodeId] = nil
        LocalFiles.save(lastPositions, to: Self.positionsFileName)
        pending.removeAll { $0.episodeId == episodeId }
        enqueue(.completed(episodeId: episodeId, userId: userId, durationSeconds: durationSeconds, isYoutube: isYoutube))
    }

    func flush() {
        guard !isFlushing, !pending.isEmpty, SessionStore.shared.isLoggedIn else { return }
        isFlushing = true
        let client = SessionStore.shared.client
        Task {
            defer { isFlushing = false }
            while let action = pending.first {
                do {
                    // A rejected action (e.g. the episode was deleted) is dropped;
                    // a transport error keeps it for the next flush.
                    if try await !send(action, client: client) {
                        NSLog("[PinePods] outbox: server rejected %@", String(describing: action))
                    }
                } catch {
                    return
                }
                pending.removeAll { $0 == action }
                save()
            }
        }
    }

    private func enqueue(_ action: Action) {
        pending.append(action)
        save()
        flush()
    }

    private func save() {
        LocalFiles.save(pending, to: Self.fileName)
    }

    private func send(_ action: Action, client: APIClient) async throws -> Bool {
        switch action {
        case .position(let episodeId, let userId, let seconds, let isYoutube):
            return try await client.recordListenDuration(
                episodeId: episodeId, userId: userId, durationSeconds: seconds, isYoutube: isYoutube)
        case .completed(let episodeId, let userId, let durationSeconds, let isYoutube):
            let marked = try await client.markCompleted(episodeId: episodeId, userId: userId, isYoutube: isYoutube)
            let recorded = try await client.recordListenDuration(
                episodeId: episodeId, userId: userId, durationSeconds: durationSeconds, isYoutube: isYoutube)
            return marked && recorded
        }
    }
}
