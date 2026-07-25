import AVFoundation
import AppKit
import CoreLocation
import Foundation
import SwiftUI

/// Renders the current multi-camera layout — optionally with the HUD burned in
/// — to a single MP4 over the trimmed range.
///
/// This is a real reader → writer pipeline rather than a screen capture: an
/// `AVAssetReaderVideoCompositionOutput` composites the camera grid, the HUD is
/// drawn onto each decoded frame, and an `AVAssetWriter` encodes at the chosen
/// resolution, frame rate, and bitrate. That gives exact control over the output
/// (and means the export doesn't depend on playback keeping up).
///
/// The HUD comes from the *same* `HUDCanvas` the player draws, rasterised
/// through `ImageRenderer` at the export resolution, so exports are WYSIWYG.
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

    private var cancelFlag = CancelFlag()

    // MARK: - Options

    struct Options {
        var includeHUD: Bool = true
        var resolution: Resolution = .p1080
        var frameRate: FrameRate = .fps30
        var bitrate: Bitrate = .mbps8
        var codec: Codec = .h264
        /// How often the HUD is re-rasterised, in Hz.
        var hudFrameRate: Double = 5
        var layout: CameraLayout
        var focused: CameraAngle

        enum Resolution: String, CaseIterable, Identifiable {
            case p720, p1080

            var id: String { rawValue }
            var label: String { self == .p720 ? "720p" : "1080p" }
            /// Output height; width follows the grid's aspect ratio.
            var height: CGFloat { self == .p720 ? 720 : 1080 }
        }

        enum FrameRate: Int, CaseIterable, Identifiable {
            case fps30 = 30
            case fps60 = 60

            var id: Int { rawValue }
            var label: String { "\(rawValue) fps" }
        }

        enum Bitrate: Int, CaseIterable, Identifiable {
            case mbps4 = 4
            case mbps8 = 8

            var id: Int { rawValue }
            var label: String { "\(rawValue) Mbps" }
            var bitsPerSecond: Int { rawValue * 1_000_000 }
        }

        enum Codec: String, CaseIterable, Identifiable {
            case h264, hevc

            var id: String { rawValue }
            var label: String { self == .h264 ? "H.264" : "HEVC" }
            var fileExtension: String { "mp4" }

            var videoCodec: AVVideoCodecType {
                self == .h264 ? .h264 : .hevc
            }
        }
    }

    /// Ceiling on pre-rasterised HUD frames so a long export can't balloon.
    private static let maximumOverlayFrames = 2000

    /// Shared cancellation flag — the encode loop runs off the main actor.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock(); value = true; lock.unlock()
        }

        func reset() {
            lock.lock(); value = false; lock.unlock()
        }
    }

    // MARK: - Entry point

    func export(
        clip: Clip,
        telemetry: TelemetryTrack,
        config: HUDConfiguration,
        availability: TelemetryAvailability,
        options: Options,
        range: ClosedRange<TimeInterval>,
        to destination: URL
    ) async {
        phase = .preparing
        cancelFlag.reset()

        do {
            let available = Set(clip.cameras)
            let renderSize = Self.renderSize(for: options, available: available)
            let tiles = TileLayoutEngine.tiles(
                layout: options.layout,
                focused: options.focused,
                available: available,
                in: renderSize,
                spacing: 0
            )

            let build = try await Self.buildComposition(
                clip: clip, tiles: tiles, renderSize: renderSize, frameRate: options.frameRate
            )

            let start = max(0, range.lowerBound)
            let end = min(build.duration, max(range.upperBound, start + 0.2))
            let outputDuration = end - start

            var overlay: OverlayFrames?
            if options.includeHUD && config.enabled {
                overlay = try await renderOverlayFrames(
                    clip: clip,
                    telemetry: telemetry,
                    config: config,
                    availability: availability,
                    renderSize: renderSize,
                    start: start,
                    duration: outputDuration,
                    frameRate: options.hudFrameRate
                )
            }

            try? FileManager.default.removeItem(at: destination)
            phase = .exporting(0)

            let flag = cancelFlag
            let encoder = Encoder(
                composition: build.composition,
                videoComposition: build.videoComposition,
                renderSize: renderSize,
                options: options,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: outputDuration, preferredTimescale: 600)
                ),
                overlay: overlay,
                cancelFlag: flag
            )

            try await encoder.run(to: destination) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .exporting = self.phase else { return }
                    self.phase = .exporting(fraction)
                }
            }

            if cancelFlag.isSet {
                try? FileManager.default.removeItem(at: destination)
                phase = .cancelled
                return
            }

            phase = .finished(destination)
            ToastCenter.shared.show("Export finished", detail: destination.lastPathComponent)
        } catch {
            if cancelFlag.isSet {
                try? FileManager.default.removeItem(at: destination)
                phase = .cancelled
                return
            }
            phase = .failed(error.localizedDescription)
            ToastCenter.shared.show(
                "Export failed", detail: error.localizedDescription, style: .error
            )
        }
    }

    func cancel() {
        cancelFlag.set()
        phase = .cancelled
    }

    func reset() {
        phase = .idle
    }

    // MARK: - Sizing

    /// Output size: the requested height, widened to the grid's aspect ratio and
    /// rounded to even numbers because H.264 requires it.
    static func renderSize(for options: Options, available: Set<CameraAngle>) -> CGSize {
        // A 4:3 tile is what Tesla records; the grid multiplies that out.
        let base = TileLayoutEngine.renderSize(
            layout: options.layout,
            focused: options.focused,
            available: available,
            tileSize: CGSize(width: 640, height: 480)
        )
        guard base.height > 0 else { return CGSize(width: 1920, height: 1080) }
        let aspect = base.width / base.height
        let height = options.resolution.height
        let width = (height * aspect / 2).rounded() * 2
        return CGSize(width: width, height: (height / 2).rounded() * 2)
    }

    // MARK: - Composition

    private struct Build {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let duration: TimeInterval
    }

    private nonisolated static func buildComposition(
        clip: Clip,
        tiles: [TileLayoutEngine.Tile],
        renderSize: CGSize,
        frameRate: Options.FrameRate
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
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        videoComposition.renderScale = 1

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(timelineLength, 0.1), preferredTimescale: 600)
        )
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

    /// Pre-rasterised HUD frames plus the spacing between them.
    struct OverlayFrames: @unchecked Sendable {
        let images: [CGImage]
        /// Seconds of output covered by each frame.
        let step: Double

        func image(atOutputTime time: Double) -> CGImage? {
            guard !images.isEmpty, step > 0 else { return images.first }
            let index = min(max(Int(time / step), 0), images.count - 1)
            return images[index]
        }
    }

    /// Rasterises the HUD at `frameRate` and keeps each frame as a PNG-backed
    /// `CGImage`, which stays compressed in memory until it's drawn — a
    /// full-resolution uncompressed cache would be gigabytes.
    private func renderOverlayFrames(
        clip: Clip,
        telemetry: TelemetryTrack,
        config: HUDConfiguration,
        availability: TelemetryAvailability,
        renderSize: CGSize,
        start: TimeInterval,
        duration: TimeInterval,
        frameRate: Double
    ) async throws -> OverlayFrames {
        var exportConfig = config
        if !config.mapIncludeInExport {
            exportConfig.mapEnabled = false
        }

        let rate = max(1, min(frameRate, 30))
        var count = Int((duration * rate).rounded()) + 1
        count = max(2, min(count, Self.maximumOverlayFrames))
        let step = duration / Double(max(1, count - 1))

        let route = telemetry.route
        var images: [CGImage] = []
        images.reserveCapacity(count)

        for index in 0..<count {
            if cancelFlag.isSet { throw ExportError("Export cancelled.") }
            let clipTime = start + Double(index) * step

            let canvas = HUDCanvas(
                size: renderSize,
                config: exportConfig,
                sample: telemetry.sample(at: clipTime),
                wallClock: clip.timelineStart.addingTimeInterval(clipTime),
                city: clip.city,
                route: route,
                progress: clip.duration > 0 ? clipTime / clip.duration : 0,
                availability: availability,
                context: .export
            )

            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 1
            renderer.isOpaque = false
            guard let cgImage = renderer.cgImage,
                  let compressed = Self.compress(cgImage) else { continue }
            images.append(compressed)

            phase = .renderingOverlay(Double(index + 1) / Double(count))
            if index % 8 == 0 {
                await Task.yield()
            }
        }
        return OverlayFrames(images: images, step: step)
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

    // MARK: - Encoder

    /// Reader → (draw HUD) → writer. Runs entirely off the main actor.
    private struct Encoder: @unchecked Sendable {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let renderSize: CGSize
        let options: Options
        let timeRange: CMTimeRange
        let overlay: OverlayFrames?
        let cancelFlag: CancelFlag

        func run(
            to destination: URL,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            let reader = try AVAssetReader(asset: composition)
            reader.timeRange = timeRange

            let videoTracks = composition.tracks(withMediaType: .video)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
            )
            output.videoComposition = videoComposition
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else {
                throw ExportError("Could not read the composed video.")
            }
            reader.add(output)

            let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: options.bitrate.bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: options.frameRate.rawValue,
                AVVideoMaxKeyFrameIntervalKey: options.frameRate.rawValue * 2
            ]
            if options.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: options.codec.videoCodec,
                    AVVideoWidthKey: Int(renderSize.width),
                    AVVideoHeightKey: Int(renderSize.height),
                    AVVideoCompressionPropertiesKey: compression
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ExportError("Could not configure the video encoder.")
            }
            writer.add(input)

            guard reader.startReading() else {
                throw ExportError(
                    reader.error?.localizedDescription ?? "Could not start reading the composition."
                )
            }
            guard writer.startWriting() else {
                throw ExportError(
                    writer.error?.localizedDescription ?? "Could not start writing the export."
                )
            }
            writer.startSession(atSourceTime: timeRange.start)

            let queue = DispatchQueue(label: "com.mac2100.SentryHub.export")
            let totalSeconds = CMTimeGetSeconds(timeRange.duration)
            let startSeconds = CMTimeGetSeconds(timeRange.start)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if cancelFlag.isSet {
                            reader.cancelReading()
                            input.markAsFinished()
                            writer.cancelWriting()
                            continuation.resume()
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            writer.finishWriting {
                                if writer.status == .failed {
                                    continuation.resume(throwing: ExportError(
                                        writer.error?.localizedDescription ?? "The export failed."
                                    ))
                                } else if reader.status == .failed {
                                    continuation.resume(throwing: ExportError(
                                        reader.error?.localizedDescription
                                            ?? "Reading the composition failed."
                                    ))
                                } else {
                                    continuation.resume()
                                }
                            }
                            return
                        }

                        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                        if let overlay,
                           let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                            let outputTime = CMTimeGetSeconds(presentation) - startSeconds
                            if let hud = overlay.image(atOutputTime: max(0, outputTime)) {
                                Encoder.draw(hud, into: pixelBuffer)
                            }
                        }

                        if !input.append(sample) {
                            reader.cancelReading()
                            input.markAsFinished()
                            let message = writer.error?.localizedDescription
                                ?? "The encoder rejected a frame."
                            writer.cancelWriting()
                            continuation.resume(throwing: ExportError(message))
                            return
                        }

                        if totalSeconds > 0 {
                            let done = (CMTimeGetSeconds(presentation) - startSeconds) / totalSeconds
                            progress(min(max(done, 0), 1))
                        }
                    }
                }
            }
        }

        /// Composites one HUD frame onto a decoded video frame.
        ///
        /// A `CGContext` over a `CVPixelBuffer` treats row 0 as the *bottom* of
        /// its coordinate space while the buffer stores it as the top row, so
        /// the context is flipped before drawing.
        private static func draw(_ hud: CGImage, into pixelBuffer: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else { return }

            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                hud,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
        }
    }

    // MARK: - Still frames

    /// Writes the frame at `time` (with the HUD composited on top) as a PNG.
    static func exportStill(
        clip: Clip,
        telemetry: TelemetryTrack,
        config: HUDConfiguration,
        availability: TelemetryAvailability,
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

        var exportConfig = config
        if !config.mapIncludeInExport { exportConfig.mapEnabled = false }

        if config.enabled {
            let canvas = HUDCanvas(
                size: renderSize,
                config: exportConfig,
                sample: telemetry.sample(at: time),
                wallClock: clip.timelineStart.addingTimeInterval(time),
                city: clip.city,
                route: telemetry.route,
                progress: clip.duration > 0 ? time / clip.duration : 0,
                availability: availability,
                context: .export
            )
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 1
            renderer.isOpaque = false
            if let overlay = renderer.cgImage {
                context.saveGState()
                context.translateBy(x: 0, y: renderSize.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(overlay, in: CGRect(origin: .zero, size: renderSize))
                context.restoreGState()
            }
        }

        guard let composed = context.makeImage() else {
            throw ExportError("Could not render the still frame.")
        }
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
