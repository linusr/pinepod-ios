import MediaPlayer
import UIKit

/// Manages the Now Playing Info Center for lock screen and control center
/// display. Ported from the Flutter client's native layer.
@MainActor
final class NowPlayingManager {
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkCache: [String: UIImage] = [:]
    private var defaultArtwork: MPMediaItemArtwork?

    /// MPMediaItemArtwork invokes its request handler on MediaPlayer's own
    /// (non-main) queue. The closure must therefore be created in a nonisolated
    /// context — a handler formed inside @MainActor code carries actor
    /// isolation and trips a libdispatch queue assert when MediaPlayer calls
    /// it off the main thread.
    nonisolated private static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    init() {
        createDefaultArtwork()
    }

    private func createDefaultArtwork() {
        if let appIcon = UIImage(named: "pinepods-logo") {
            defaultArtwork = Self.makeArtwork(from: appIcon)
            return
        }
        let size = CGSize(width: 300, height: 300)
        UIGraphicsBeginImageContextWithOptions(size, true, 0)
        UIColor(red: 0.33, green: 0.62, blue: 0.54, alpha: 1.0).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        if let placeholderImage = UIGraphicsGetImageFromCurrentImageContext() {
            defaultArtwork = Self.makeArtwork(from: placeholderImage)
        }
        UIGraphicsEndImageContext()
    }

    func updateNowPlaying(
        title: String,
        artist: String,
        artworkUrl: String?,
        duration: Double,
        playbackRate: Float,
        elapsedTime: Double
    ) {
        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = artist
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime

        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.podcast.rawValue

        if let artwork = currentArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if let defaultArt = defaultArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = defaultArt
        }

        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo

        if let urlString = artworkUrl, !urlString.isEmpty, let url = URL(string: urlString) {
            Task { await self.loadArtwork(from: url) }
        }
    }

    func updatePlaybackInfo(elapsedTime: Double, playbackRate: Float) {
        guard var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }

    func clearNowPlaying() {
        nowPlayingInfoCenter.nowPlayingInfo = nil
        currentArtwork = nil
    }

    private func loadArtwork(from url: URL) async {
        let cacheKey = url.absoluteString
        if let cachedImage = artworkCache[cacheKey] {
            applyArtwork(cachedImage)
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        artworkCache[cacheKey] = image
        if artworkCache.count > 10, let firstKey = artworkCache.keys.first {
            artworkCache.removeValue(forKey: firstKey)
        }
        applyArtwork(image)
    }

    private func applyArtwork(_ image: UIImage) {
        currentArtwork = Self.makeArtwork(from: image)
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = currentArtwork
        nowPlayingInfoCenter.nowPlayingInfo = info
    }
}
