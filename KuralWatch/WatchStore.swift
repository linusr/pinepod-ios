import Observation
import SwiftUI
import UIKit
import WatchConnectivity
import WidgetKit

/// The watch side of the remote: holds the last playback state from the
/// iPhone (persisted, so it shows while out of range) and sends commands.
@MainActor
@Observable
final class WatchStore {
    static let shared = WatchStore()

    private(set) var snapshot: WidgetSnapshot
    private(set) var artwork: [String: UIImage] = [:]
    private(set) var isReachable = false
    private(set) var isSending = false
    private(set) var errorMessage: String?

    private let delegate = SessionDelegate()

    private init() {
        snapshot = SharedContainer.loadSnapshot()
        loadArtwork()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    func image(for file: String?) -> UIImage? {
        file.flatMap { artwork[$0] }
    }

    // MARK: - Commands

    func toggle() {
        // Optimistic: flip immediately; the phone's reply confirms.
        if var now = snapshot.nowPlaying {
            now = .init(episode: now.episode, isPlaying: !now.isPlaying, speed: now.speed, capturedAt: now.capturedAt)
            snapshot.nowPlaying = now
        }
        send(.toggle)
    }

    func skip(_ seconds: Int) {
        send(.skip, seconds: seconds)
    }

    func play(_ episode: WidgetSnapshot.Episode) {
        send(.play, episodeId: episode.id)
    }

    func remove(_ episode: WidgetSnapshot.Episode) {
        snapshot.upNext.removeAll { $0.id == episode.id }
        send(.remove, episodeId: episode.id)
    }

    func refresh() {
        send(.refresh)
    }

    private func send(_ command: WatchProtocol.Command, seconds: Int = 0, episodeId: Int = 0) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            errorMessage = "iPhone not reachable"
            return
        }
        errorMessage = nil
        isSending = true
        let message: [String: Any] = [
            WatchProtocol.commandKey: command.rawValue,
            WatchProtocol.secondsKey: seconds,
            WatchProtocol.episodeIdKey: episodeId,
        ]
        session.sendMessage(message, replyHandler: { reply in
            let update = Update(reply)
            Task { @MainActor in
                WatchStore.shared.isSending = false
                WatchStore.shared.apply(update)
            }
        }, errorHandler: { error in
            let description = error.localizedDescription
            Task { @MainActor in
                WatchStore.shared.isSending = false
                WatchStore.shared.errorMessage = description
            }
        })
    }

    // MARK: - Updates from the iPhone

    fileprivate func apply(_ update: Update) {
        guard let data = update.snapshot,
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return }
        self.snapshot = snapshot
        if let folder = SharedContainer.artworkFolder {
            for (file, data) in update.artwork {
                try? data.write(to: folder.appending(path: file), options: .atomic)
                artwork[file] = UIImage(data: data)
            }
        }
        SharedContainer.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    fileprivate func setReachable(_ reachable: Bool) {
        isReachable = reachable
        if reachable { errorMessage = nil }
    }

    private func loadArtwork() {
        guard let folder = SharedContainer.artworkFolder,
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for file in files {
            artwork[file] = UIImage(contentsOfFile: folder.appending(path: file).path)
        }
    }
}

/// A WatchConnectivity payload converted to Sendable values.
private struct Update: Sendable {
    let snapshot: Data?
    let artwork: [String: Data]

    init(_ payload: [String: Any]) {
        snapshot = payload[WatchProtocol.snapshotKey] as? Data
        artwork = payload[WatchProtocol.artworkKey] as? [String: Data] ?? [:]
    }
}

private final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = Update(session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            WatchStore.shared.apply(context)
            WatchStore.shared.setReachable(reachable)
            if reachable { WatchStore.shared.refresh() }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in WatchStore.shared.setReachable(reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let update = Update(applicationContext)
        Task { @MainActor in WatchStore.shared.apply(update) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let update = Update(message)
        Task { @MainActor in WatchStore.shared.apply(update) }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
