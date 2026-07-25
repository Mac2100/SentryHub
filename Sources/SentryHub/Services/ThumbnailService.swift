import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Produces (and caches) poster frames for the clip gallery.
///
/// Sentry and Saved folders ship a `thumb.png` from the car; everything else
/// gets a frame pulled a couple of seconds into the clip. `CGImage` rather than
/// `NSImage` so results cross the actor boundary cleanly.
actor ThumbnailService {
    static let shared = ThumbnailService()

    private var cache: [String: CGImage] = [:]
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let maximumCacheSize = 300

    /// Poster image for a clip, from a specific camera when asked.
    func image(for clip: Clip, camera: CameraAngle? = nil) async -> CGImage? {
        let key = "\(clip.id)#\(camera?.rawValue ?? "auto")"
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<CGImage?, Never> { [clip, camera] in
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

    private static func render(clip: Clip, camera: CameraAngle?) async -> CGImage? {
        // The car's own thumbnail is the fastest path, but only represents the
        // triggering camera, so it's used only when no specific camera is asked for.
        if camera == nil, let url = clip.thumbnailURL,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
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
        if let result = try? await generator.image(at: time) {
            return result.image
        }
        // Very short clips may not reach 2 s; fall back to the first frame.
        guard let first = try? await generator.image(at: .zero) else { return nil }
        return first.image
    }
}
