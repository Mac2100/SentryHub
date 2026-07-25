import AVFoundation
import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds a small synthetic TeslaCam library in Application Support so the app
/// can be explored (and the HUD, sync, map, and export tried out) without a
/// dashcam drive plugged in. Everything it writes lives under
/// `~/Library/Application Support/SentryHub/SampleLibrary`.
enum SampleLibrary {
    struct GenerationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var rootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("SentryHub", isDirectory: true)
            .appendingPathComponent("SampleLibrary", isDirectory: true)
    }

    static var isBuilt: Bool {
        FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("TeslaCam/SentryClips").path
        )
    }

    private static let width = 640
    private static let height = 480
    private static let fps: Int32 = 24
    private static let seconds = 12

    /// Cameras included in the sample — the four a pre-pillar car records, so
    /// the "no video" tiles are exercised too.
    private static let cameras: [CameraAngle] = [.front, .back, .leftRepeater, .rightRepeater]

    /// Generates the sample library if it isn't there yet and returns its root.
    static func build(force: Bool = false) async throws -> URL {
        let fm = FileManager.default
        let root = rootURL
        if force, fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        if isBuilt, !force { return root }

        let start = Calendar.current.date(
            from: DateComponents(year: 2025, month: 12, day: 21, hour: 20, minute: 59, second: 54)
        ) ?? Date()
        let name = TeslaTimestamp.fileFormatter.string(from: start)

        let sentryFolder = root
            .appendingPathComponent("TeslaCam/SentryClips", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: sentryFolder, withIntermediateDirectories: true)

        for camera in cameras {
            let url = sentryFolder.appendingPathComponent("\(name)-\(camera.fileSuffixes[0]).mp4")
            try await renderClip(to: url, camera: camera, startDate: start)
        }

        try writeEvent(in: sentryFolder, start: start)
        try writeTelemetry(in: sentryFolder)
        try writeThumbnail(in: sentryFolder)

        // A second, shorter recording in RecentClips so the category filters and
        // the "no event.json" path both have something to show.
        let recentStart = start.addingTimeInterval(-3600)
        let recentName = TeslaTimestamp.fileFormatter.string(from: recentStart)
        let recentFolder = root.appendingPathComponent("TeslaCam/RecentClips", isDirectory: true)
        try fm.createDirectory(at: recentFolder, withIntermediateDirectories: true)
        for camera in [CameraAngle.front, .back] {
            let url = recentFolder.appendingPathComponent("\(recentName)-\(camera.fileSuffixes[0]).mp4")
            try await renderClip(to: url, camera: camera, startDate: recentStart, seconds: 6)
        }

        return root
    }

    // MARK: - event.json / telemetry.json

    private static func writeEvent(in folder: URL, start: Date) throws {
        let json: [String: Any] = [
            "timestamp": TeslaTimestamp.string(from: start),
            "city": "Sample Drive",
            "est_lat": "48.0610",
            "est_lon": "3.2910",
            "reason": "sentry_aware_object_detection",
            "camera": "0"
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: folder.appendingPathComponent("event.json"))
    }

    /// A believable-looking drive: gentle curve, slight speed changes, one
    /// indicator pulse. Clearly labelled as sample data everywhere it surfaces.
    private static func writeTelemetry(in folder: URL) throws {
        var rows: [[String: Any]] = []
        let sampleCount = seconds * 4
        for index in 0...sampleCount {
            let t = Double(index) / 4.0
            let progress = t / Double(seconds)
            let speedKPH = 96 + sin(progress * .pi * 2) * 6
            let heading = 182 + progress * 14
            let latitude = 48.0610 + progress * 0.0042
            let longitude = 3.2910 + progress * 0.0016 + sin(progress * .pi * 3) * 0.00035
            rows.append([
                "t": t,
                "speed_kph": speedKPH,
                "lat": latitude,
                "lon": longitude,
                "heading": heading,
                "elevation": 214 + sin(progress * .pi) * 9,
                "gear": "D",
                "autopilot": progress > 0.35 ? "autosteer" : "off",
                "accel_lon": cos(progress * .pi * 4) * 0.06,
                "accel_lat": sin(progress * .pi * 3) * 0.15,
                "steering": sin(progress * .pi * 2) * 9,
                "turn_left": false,
                "turn_right": progress > 0.62 && progress < 0.78,
                "brake": 0.0,
                "accelerator": 0.28 + sin(progress * .pi * 2) * 0.08
            ])
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["samples": rows], options: [.prettyPrinted]
        )
        try data.write(to: folder.appendingPathComponent("telemetry.json"))
    }

    private static func writeThumbnail(in folder: URL) throws {
        guard let context = makeContext() else { return }
        drawFrame(in: context, camera: .front, progress: 0.12, label: "SAMPLE")
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: folder.appendingPathComponent("thumb.png"))
    }

    // MARK: - Video rendering

    private static func renderClip(
        to url: URL, camera: CameraAngle, startDate: Date, seconds: Int = SampleLibrary.seconds
    ) async throws {
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_600_000
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw GenerationError(message: "Could not configure the sample video writer.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw GenerationError(
                message: writer.error?.localizedDescription ?? "Sample video writing failed to start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(fps) * seconds
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw GenerationError(message: "Sample video pixel buffer pool unavailable.")
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let pixelBuffer = buffer else {
                throw GenerationError(message: "Could not allocate a sample video frame.")
            }

            let progress = Double(frame) / Double(frameCount)
            let stamp = startDate.addingTimeInterval(Double(frame) / Double(fps))
            draw(into: pixelBuffer, camera: camera, progress: progress, date: stamp)

            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw GenerationError(
                message: writer.error?.localizedDescription ?? "Sample video export failed."
            )
        }
    }

    private static func makeContext() -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private static func draw(
        into pixelBuffer: CVPixelBuffer, camera: CameraAngle, progress: Double, date: Date
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }

        let stamp = Self.stampFormatter.string(from: date)
        drawFrame(in: context, camera: camera, progress: progress, label: stamp)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// A stylised night road: horizon, lane dashes that scroll with `progress`,
    /// and the camera name. Enough motion to see that the feeds stay in sync.
    private static func drawFrame(
        in context: CGContext, camera: CameraAngle, progress: Double, label: String
    ) {
        let w = CGFloat(context.width)
        let h = CGFloat(context.height)
        let tint = tintComponents(for: camera)

        context.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Sky glow.
        let horizon = h * 0.58
        context.setFillColor(CGColor(red: tint.0 * 0.22, green: tint.1 * 0.24,
                                     blue: tint.2 * 0.34, alpha: 1))
        context.fill(CGRect(x: 0, y: horizon, width: w, height: h - horizon))

        // Road surface.
        context.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1))
        context.beginPath()
        context.move(to: CGPoint(x: -w * 0.4, y: 0))
        context.addLine(to: CGPoint(x: w * 0.42, y: horizon))
        context.addLine(to: CGPoint(x: w * 0.58, y: horizon))
        context.addLine(to: CGPoint(x: w * 1.4, y: 0))
        context.closePath()
        context.fillPath()

        // Scrolling centre dashes.
        context.setFillColor(CGColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 0.85))
        let scroll = progress * 6
        for step in 0..<9 {
            var t = (Double(step) / 9.0 + scroll).truncatingRemainder(dividingBy: 1.0)
            t = 1 - t
            let y = horizon * pow(t, 2.2)
            let width = 3 + (1 - t) * 22
            let height = 3 + (1 - t) * 20
            context.fill(CGRect(x: w / 2 - width / 2, y: y, width: width, height: height))
        }

        // Distant headlights that grow as the clip plays.
        let glow = 4 + progress * 16
        context.setFillColor(CGColor(red: 1, green: 0.72, blue: 0.35, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: w * 0.60, y: horizon + 6, width: glow, height: glow))
        context.fillEllipse(in: CGRect(x: w * 0.66, y: horizon + 4, width: glow, height: glow))

        // Camera name + timestamp, drawn as a plain caption bar.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        context.fill(CGRect(x: 0, y: h - 34, width: w, height: 34))
        drawText(camera.shortLabel, in: context, at: CGPoint(x: 14, y: h - 26), size: 15)
        drawText(label, in: context, at: CGPoint(x: w - 110, y: h - 26), size: 15)
        drawText("SENTRYHUB SAMPLE", in: context, at: CGPoint(x: 14, y: 12), size: 11)
    }

    private static func tintComponents(for camera: CameraAngle) -> (CGFloat, CGFloat, CGFloat) {
        switch camera {
        case .front: return (0.30, 0.42, 0.72)
        case .back: return (0.42, 0.32, 0.60)
        case .leftRepeater: return (0.24, 0.46, 0.58)
        case .rightRepeater: return (0.34, 0.46, 0.50)
        case .leftPillar: return (0.36, 0.36, 0.62)
        case .rightPillar: return (0.30, 0.40, 0.64)
        }
    }

    private static func drawText(
        _ string: String, in context: CGContext, at point: CGPoint, size: CGFloat
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes)
        )
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
