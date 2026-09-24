import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UIKit

/// Artwork loader: disk-backed URL cache, downsampled decode off the main
/// thread, in-memory image cache, request coalescing, and an average-color
/// tint per artwork for tinted backgrounds.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let images = NSCache<NSString, UIImage>()
    private var tints: [String: Color] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16_000_000, diskCapacity: 256_000_000)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private init() {
        images.countLimit = 400
    }

    func cachedImage(for urlString: String?) -> UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return images.object(forKey: urlString as NSString)
    }

    func cachedTint(for urlString: String?) -> Color? {
        guard let urlString else { return nil }
        return tints[urlString]
    }

    func image(for urlString: String?) async -> UIImage? {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        if let cached = images.object(forKey: urlString as NSString) { return cached }
        if let pending = inFlight[urlString] { return await pending.value }

        let session = self.session
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                Self.downsample(data, maxPixel: 1000)
            }.value
        }
        inFlight[urlString] = task
        let image = await task.value
        inFlight[urlString] = nil
        if let image {
            images.setObject(image, forKey: urlString as NSString)
        }
        return image
    }

    func tint(for urlString: String?) async -> Color? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let tint = tints[urlString] { return tint }
        guard let image = await image(for: urlString) else { return nil }
        let tint = await Task.detached(priority: .utility) {
            Self.averageColor(of: image)
        }.value
        if let tint {
            tints[urlString] = tint
        }
        return tint
    }

    nonisolated private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    /// Mean artwork color, clamped into a mid-dark band so white text stays
    /// legible on top of it.
    nonisolated private static func averageColor(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)

        let average = UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(
            hue: hue,
            saturation: min(saturation * 1.25, 0.75),
            brightness: min(max(brightness, 0.3), 0.52))
    }
}
