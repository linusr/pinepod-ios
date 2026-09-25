import UIKit
import WatchConnectivity

/// The iPhone side of the watch remote: sends playback state to the watch and
/// runs the watch's commands. Sending a message from the watch wakes the app
/// in the background if it isn't running.
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchBridge()

    private static let thumbnailSize: CGFloat = 80
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private let lock = NSLock()
    private var thumbnails: [String: Data] = [:]

    /// Must run early in launch so commands that woke the app are received.
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func publish(_ snapshot: WidgetSnapshot) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let payload = payload(for: snapshot) else { return }
        do {
            try session.updateApplicationContext(payload)
        } catch {
            NSLog("[PinePods] watch: context update failed: %@", error.localizedDescription)
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        }
    }

    private func payload(for snapshot: WidgetSnapshot) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        let files = ([snapshot.nowPlaying?.episode] + snapshot.upNext).compactMap { $0?.artworkFile }
        var artwork: [String: Data] = [:]
        for file in Set(files) {
            if let thumbnail = thumbnail(for: file) { artwork[file] = thumbnail }
        }
        return [WatchProtocol.snapshotKey: data, WatchProtocol.artworkKey: artwork]
    }

    /// Watch payloads are size-limited, so artwork is shrunk well below the widget's.
    private func thumbnail(for file: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = thumbnails[file] { return cached }
        guard let folder = SharedContainer.artworkFolder,
              let image = UIImage(contentsOfFile: folder.appending(path: file).path) else { return nil }
        let size = CGSize(width: Self.thumbnailSize, height: Self.thumbnailSize)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.7) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        thumbnails[file] = data
        return data
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            NSLog("[PinePods] watch: activation failed: %@", error.localizedDescription)
        }
        Task { @MainActor in WidgetPublisher.setNeedsUpdate() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Called when the user switches watches; the new one needs a fresh session.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let command = (message[WatchProtocol.commandKey] as? String).flatMap(WatchProtocol.Command.init(rawValue:))
        let seconds = message[WatchProtocol.secondsKey] as? Int ?? 0
        let episodeId = message[WatchProtocol.episodeIdKey] as? Int ?? 0
        let reply = ReplyBox(replyHandler)
        NSLog("[PinePods] watch command: %@ (seconds %ld, episode %ld)", command?.rawValue ?? "unknown", seconds, episodeId)
        Task { @MainActor in
            switch command {
            case .toggle: await PlaybackBridge.togglePlayback()
            case .skip: await PlaybackBridge.skip(seconds: seconds)
            case .play: await PlaybackBridge.play(episodeId: episodeId)
            case .remove: await PlaybackBridge.removeFromQueue(episodeId: episodeId)
            case .refresh, nil: break
            }
            let snapshot = await WidgetPublisher.makeSnapshot()
            reply.send(WatchBridge.shared.payload(for: snapshot) ?? [:])
            WidgetPublisher.setNeedsUpdate()
        }
    }
}

/// WatchConnectivity reply handlers aren't Sendable; each is called exactly once.
private struct ReplyBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ payload: [String: Any]) { handler(payload) }
}
