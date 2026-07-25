import AVFoundation
import AppKit
import CoreLocation
import Foundation
import SwiftUI

/// Renders the current multi-camera layout — optionally with the HUD burned in
/// — to a single MP4 over the trimmed range.
///
/// The HUD is drawn by the *same* `HUDCanvas` the player uses, rasterised
/// through `ImageRenderer` and attached as a Core Animation overlay, so the
/// exported file matches what was on screen.
@MainActor
final class ExportService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case renderingOverlay(Double)
        case exporting(Double)
        case finished(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .preparing, .renderingOverlay, .exporting: return true
        default: return false
        }
    }

    private var session: AVAssetExportSession?
    private var progressTimer: Timer?

    struct Options {
        var includeHUD: Bool = true
        var quality: Quality = .high
        var hudFrameRate: Double = 5
        var layout: CameraLayout
        var focused: CameraAngle

        enum Quality: String, CaseIterable, Identifiable {
            case standard, high, maximum

            var id: String { rawValue }

            var label: String {
                switch self {
                case .standard: return "Standard"
                case .high: return "High"
                case .maximum: return "Maximum"
                }
            }

            /// Per-tile pixel size; the grid multiplies it out.
            var tileSize: CGSize {
                switch self {
                case .standard: return CGSize(width: 480, height: 360)
                case .high: return CGSize(width: 640, height: 480)
                case .maximum: return CGSize(width: 960, height: 720)
                }
            }
        }
    }

    /// Hard ceiling on pre-rendered HUD frames so a long export can't balloon.
    private static let maximumOverlayFrames = 1500

    // MARK: - Entry point

    func export(
        clip: Clip,
        telemetry: TelemetryTrack,
        config: HUDConfiguration,
        options: Options,
        range: ClosedRange<TimeInterval>,
        to destination: URL
    ) async {
        phase = .preparing
        do {
            let available = Set(clip.cameras)
            let renderSize = TileLayoutEngine.renderSize(
                layout: options.layout,
                focused: options.focused,
                available: available,
                tileSize: options.quality.tileSize
            )
            let tiles = TileLayoutEngine.tiles(
                layout: options.layout,
                focused: options.focused,
                available: available,
                in: renderSize,
                spacing: 0
            )

            let build = try await Self.buildComposition(clip: clip, tiles: tiles, renderSize: renderSize)
            let videoComposition = build.videoComposition

            let start = max(0, range.lowerBound)
            let end = min(build.duration, max(range.upperBound, start + 0.2))
            let outputDuration = end - start

            if options.includeHUD && config.enabled {
                let frames = try await renderOverlayFrames(
                    clip: clip,
                    telemetry: telemetry,
                    config: config,
                    renderSize: renderSize,
                    start: start,
                    duration: outputDuration,
                    frameRate: options.hudFrameRate
                )
                if !frames.isEmpty {
                    videoComposition.animationTool = Self.makeAnimationTool(
                        frames: frames, renderSize: renderSize, duration: outputDuration
                    )
                }
            }

            try? FileManager.default.removeItem(at: destination)

            guard let session = AVAssetExportSession(
                asset: build.composition, presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw ExportError("Could not create an export session.")
            }
            session.outputURL = destination
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            session.videoComposition = videoComposition
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: outputDuration, preferredTimescale: 600)
            )
            self.session = session

            phase = .exporting(0)
            startProgressPolling(session)

            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            stopProgressPolling()

            switch session.status {
            case .completed:
                phase = .finished(destination)
                ToastCenter.shared.show(
                    "Export finished", detail: destination.lastPathComponent
                )
            case .cancelled:
                phase = .cancelled
            default:
                let message = session.error?.localizedDescription ?? "The export failed."
                phase = .failed(message)
                ToastCenter.shared.show("Export failed", detail: message, style: .error)
            }
            self.session = nil
        } catch {
            stopProgressPolling()
            phase = .failed(error.localizedDescription)
            ToastCenter.shared.show(
                "Export failed", detail: error.localizedDescription, style: .error
            )
        }
    }

    func cancel() {
        session?.cancelExport()
        stopProgressPolling()
        phase = .cancelled
    }

    func reset() {
        phase = .idle
    }

    // MARK: - Composition

    private struct Build {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let duration: TimeInterval
    }

    private nonisolated static func buildComposition(
        clip: Clip, tiles: [TileLayoutEngine.Tile], renderSize: CGSize
    ) async throws -> Build {
        let composition = AVMutableComposition()
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        var timelineLength: TimeInterval = 0

        for tile in tiles {
            guard let camera = tile.camera, clip.cameras.contains(camera) else { continue }
            guard let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            var cursor = CMTime.zero
            var naturalSize = CGSize(width: 1280, height: 960)
            var didInsert = false

            for segment in clip.segments {
                let slot = CMTime(seconds: segment.duration, preferredTimescale: 600)
                guard let url = segment.files[camera] else {
                    cursor = cursor + slot
                    continue
                }
                let asset = AVURLAsset(url: url)
                guard let source = try? await asset.loadTracks(withMediaType: .video).first else {
                    cursor = cursor + slot
                    continue
                }
                if let size = try? await source.load(.naturalSize) {
                    naturalSize = size
                }
                let assetDuration = (try? await asset.load(.duration)) ?? slot
                let usable = CMTimeMinimum(assetDuration, slot)
                try? track.insertTimeRange(
                    CMTimeRange(start: .zero, duration: usable), of: source, at: cursor
                )
                didInsert = true
                cursor = cursor + slot
            }

            timelineLength = max(timelineLength, CMTimeGetSeconds(cursor))
            guard didInsert else { continue }

            let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            instruction.setTransform(
                Self.transform(from: naturalSize, into: tile.rect), at: .zero
            )
            layerInstructions.append(instruction)
        }

        guard !layerInstructions.isEmpty else {
            throw ExportError("None of the selected cameras have video to export.")
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderScale = 1

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(timelineLength, 0.1), preferredTimescale: 600)
        )
        // Later layers draw on top; the tiles never overlap, so order is free.
        instruction.layerInstructions = layerInstructions
        instruction.backgroundColor = NSColor.black.cgColor
        videoComposition.instructions = [instruction]

        return Build(
            composition: composition,
            videoComposition: videoComposition,
            duration: timelineLength
        )
    }

    /// Aspect-fits a source frame into its tile.
    ///
    /// The video composition render space has its origin at the top-left, which
    /// is the same convention `TileLayoutEngine` uses, so the rect goes in as-is.
    private nonisolated static func transform(
        from naturalSize: CGSize, into rect: CGRect
    ) -> CGAffineTransform {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return .identity }
        let scale = min(rect.width / naturalSize.width, rect.height / naturalSize.height)
        let scaledWidth = naturalSize.width * scale
        let scaledHeight = naturalSize.height * scale
        let x = rect.origin.x + (rect.width - scaledWidth) / 2
        let y = rect.origin.y + (rect.height - scaledHeight) / 2
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }

    // MARK: - HUD overlay

    /// Rasterises the HUD at `frameRate` and keeps each frame as PNG-backed
    /// `CGImage`s, which stay compressed in memory until Core Animation needs
    /// them — a full-resolution uncompressed cache would be gigabytes.
    private func renderOverlayFrames(
        clip: Clip,
        telemetry: TelemetryTrack,
        config: HUDConfiguration,
        renderSize: CGSize,
        start: TimeInterval,
        duration: TimeInterval,
        frameRate: Double
    ) async throws -> [CGImage] {
        var exportConfig = config
        if !config.mapIncludeInExport {
            exportConfig.mapEnabled = false
        }

        let rate = max(1, min(frameRate, 15))
        var count = Int((duration * rate).rounded()) + 1
        count = max(2, min(count, Self.maximumOverlayFrames))
        let step = duration / Double(max(1, count - 1))

        let route = telemetry.route
        var images: [CGImage] = []
        images.reserveCapacity(count)

        for index in 0..<count {
            if Task.isCancelled { throw ExportError("Export cancelled.") }
            let clipTime = start + Double(index) * step

            let canvas = HUDCanvas(
                size: renderSize,
                config: exportConfig,
                sample: telemetry.sample(at: clipTime),
                wallClock: clip.startDate.addingTimeInterval(clipTime),
                city: clip.city,
                route: route,
                progress: clip.duration > 0 ? clipTime / clip.duration : 0,
                context: .export
            )

            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 1
            renderer.isOpaque = false
            guard let cgImage = renderer.cgImage,
                  let compressed = Self.compress(cgImage) else { continue }
            images.append(compressed)

            phase = .renderingOverlay(Double(index + 1) / Double(count))
            // Let the run loop breathe so the progress bar actually moves.
            if index % 8 == 0 {
                await Task.yield()
            }
        }
        return images
    }

    /// Round-trips through PNG so the frame stays compressed until drawn.
    private nonisolated static func compress(_ image: CGImage) -> CGImage? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]),
              let provider = CGDataProvider(data: data as CFData) else { return image }
        return CGImage(
            pngDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) ?? image
    }

    private nonisolated static func makeAnimationTool(
        frames: [CGImage], renderSize: CGSize, duration: TimeInterval
    ) -> AVVideoCompositionCoreAnimationTool {
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)

        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: renderSize)
        overlayLayer.contentsGravity = .resizeAspect
        overlayLayer.masksToBounds = true
        overlayLayer.contents = frames.first

        if frames.count > 1 {
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames
            animation.keyTimes = (0..<frames.count).map {
                NSNumber(value: Double($0) / Double(frames.count - 1))
            }
            animation.calculationMode = .discrete
            animation.duration = max(duration, 0.1)
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            overlayLayer.add(animation, forKey: "contents")
        }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )
    }

    // MARK: - Progress

    private func startProgressPolling(_ session: AVAssetExportSession) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .exporting = self.phase {
                    self.phase = .exporting(Double(session.progress))
                }
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Still frames

    /// Writes the frame at `time` (with the HUD composited on top) as a PNG.
    static func exportStill(
        clip: Clip,
        telemetry: TelemetryTrack,
        config: HUDConfiguration,
        layout: CameraLayout,
        focused: CameraAngle,
        time: TimeInterval,
        to destination: URL
    ) async throws {
        let available = Set(clip.cameras)
        let renderSize = TileLayoutEngine.renderSize(
            layout: layout, focused: focused, available: available,
            tileSize: CGSize(width: 640, height: 480)
        )
        let tiles = TileLayoutEngine.tiles(
            layout: layout, focused: focused, available: available,
            in: renderSize, spacing: 0
        )

        guard let context = CGContext(
            data: nil,
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ExportError("Could not create the still-frame canvas.")
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))

        for tile in tiles {
            guard let camera = tile.camera else { continue }
            guard let frame = await frameImage(clip: clip, camera: camera, time: time) else {
                continue
            }
            let scale = min(
                tile.rect.width / CGFloat(frame.width),
                tile.rect.height / CGFloat(frame.height)
            )
            let width = CGFloat(frame.width) * scale
            let height = CGFloat(frame.height) * scale
            // Core Graphics origin is bottom-left; tile rects are top-left.
            let drawRect = CGRect(
                x: tile.rect.origin.x + (tile.rect.width - width) / 2,
                y: renderSize.height - tile.rect.origin.y - tile.rect.height
                    + (tile.rect.height - height) / 2,
                width: width,
                height: height
            )
            context.draw(frame, in: drawRect)
        }

        guard let base = context.makeImage() else {
            throw ExportError("Could not render the still frame.")
        }

        var exportConfig = config
        if !config.mapIncludeInExport { exportConfig.mapEnabled = false }

        let overlay: CGImage? = await MainActor.run {
            let canvas = HUDCanvas(
                size: renderSize,
                config: exportConfig,
                sample: telemetry.sample(at: time),
                wallClock: clip.startDate.addingTimeInterval(time),
                city: clip.city,
                route: telemetry.route,
                progress: clip.duration > 0 ? time / clip.duration : 0,
                context: .export
            )
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 1
            renderer.isOpaque = false
            return renderer.cgImage
        }

        if config.enabled, let overlay {
            context.draw(overlay, in: CGRect(origin: .zero, size: renderSize))
        }
        let composed = context.makeImage() ?? base

        let rep = NSBitmapImageRep(cgImage: composed)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ExportError("Could not encode the still frame.")
        }
        try data.write(to: destination)
    }

    /// Pulls one decoded frame for a camera at a clip-relative time, walking the
    /// segment list to find which file that time lands in.
    private static func frameImage(
        clip: Clip, camera: CameraAngle, time: TimeInterval
    ) async -> CGImage? {
        var elapsed: TimeInterval = 0
        for segment in clip.segments {
            let end = elapsed + segment.duration
            if time < end || segment.id == clip.segments.last?.id {
                guard let url = segment.files[camera] else { return nil }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
                let local = CMTime(seconds: max(0, time - elapsed), preferredTimescale: 600)
                guard let result = try? await generator.image(at: local) else { return nil }
                return result.image
            }
            elapsed = end
        }
        return nil
    }
}

struct ExportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
