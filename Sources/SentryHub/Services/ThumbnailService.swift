import AVFoundation
import AppKit
import Foundation

/// Produces (and caches) poster frames for the clip gallery.
///
/// Sentry and Saved folders ship a `thumb.png` from the car; everything else
/// gets a frame pulled a couple of seconds into the clip.
actor ThumbnailService {
    static let shared = ThumbnailService()

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let maximumCacheSize = 300

    /// Poster image for a clip, from a specific camera when asked.
    func image(for clip: Clip, camera: CameraAngle? = nil) async -> NSImage? {
        let key = "\(clip.id)#\(camera?.rawValue ?? "auto")"
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<NSImage?, Never> { [clip, camera] in
            await Self.render(clip: clip, camera: camera)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            if cache.count >= maximumCacheSize { cache.removeAll(keepingCapacity: true) }
            cache[key] = image
        }
        return image
    }

    func clear() {
        cache.removeAll()
    }

    private static func render(clip: Clip, camera: CameraAngle?) async -> NSImage? {
        // The car's own thumbnail is the fastest path, but only represents the
        // triggering camera, so it's used only when no specific camera is asked for.
        if camera == nil, let url = clip.thumbnailURL,
           let image = NSImage(contentsOf: url) {
            return image
        }

        let target = camera
            ?? clip.event?.triggerCamera
            ?? CameraAngle.preferredFocusOrder.first { clip.cameras.contains($0) }
        guard let target, let url = clip.url(for: target) else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let time = CMTime(seconds: 2, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else {
            // Very short clips may not reach 2 s; fall back to the first frame.
            guard let first = try? await generator.image(at: .zero) else { return nil }
            return NSImage(cgImage: first.image, size: .zero)
        }
        return NSImage(cgImage: result.image, size: .zero)
    }
}
