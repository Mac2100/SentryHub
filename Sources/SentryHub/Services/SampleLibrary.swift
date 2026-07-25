import AVFoundation
import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds a synthetic TeslaCam library in Application Support so the app can be
/// explored — sync, HUD, map, trimming, export — without a dashcam drive.
/// Everything it writes lives under
/// `~/Library/Application Support/SentryHub/SampleLibrary`.
///
/// The footage is deliberately generated rather than bundled: it keeps the repo
/// small and avoids shipping anyone's real dashcam recordings. The scene is
/// driven by the *same* telemetry the HUD reads, so the lane dashes scroll at
/// the speed on the speedometer and the horizon rolls with the steering angle —
/// which makes it obvious at a glance whether playback is really in sync.
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

    /// Two segments, so the Sentry event exercises the segment-stitching path
    /// and the timeline shows a boundary marker.
    private static let segmentSeconds = 25
    private static let segmentCount = 2

    /// All six angles, so the full 3×2 grid is populated.
    private static let sentryCameras: [CameraAngle] = CameraAngle.sixUpOrder

    // MARK: - Build

    /// Generates the sample library if it isn't there yet and returns its root.
    /// `progress` is reported 0…1 on the main actor.
    static func build(
        force: Bool = false,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        let root = rootURL
        if force, fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        if isBuilt, !force { return root }

        let start = Calendar.current.date(
            from: DateComponents(year: 2025, month: 12, day: 21, hour: 20, minute: 59, second: 54)
        ) ?? Date()

        let drive = DriveModel(totalSeconds: Double(segmentSeconds * segmentCount))

        let sentryRoot = root.appendingPathComponent("TeslaCam/SentryClips", isDirectory: true)
        let eventName = TeslaTimestamp.fileFormatter.string(from: start)
        let sentryFolder = sentryRoot.appendingPathComponent(eventName, isDirectory: true)
        try fm.createDirectory(at: sentryFolder, withIntermediateDirectories: true)

        // One job per (segment, camera) plus the two RecentClips files.
        var jobs: [RenderJob] = []
        for segment in 0..<segmentCount {
            let offset = Double(segment * segmentSeconds)
            let segmentStart = start.addingTimeInterval(offset)
            let prefix = TeslaTimestamp.fileFormatter.string(from: segmentStart)
            for camera in sentryCameras {
                jobs.append(
                    RenderJob(
                        url: sentryFolder.appendingPathComponent(
                            "\(prefix)-\(camera.fileSuffixes[0]).mp4"
                        ),
                        camera: camera,
                        startDate: segmentStart,
                        clipOffset: offset,
                        seconds: segmentSeconds,
                        drive: drive
                    )
                )
            }
        }

        // A short RecentClips recording too, so the category filters and the
        // "no event.json" path both have something to show.
        let recentStart = start.addingTimeInterval(-3600)
        let recentName = TeslaTimestamp.fileFormatter.string(from: recentStart)
        let recentFolder = root.appendingPathComponent("TeslaCam/RecentClips", isDirectory: true)
        try fm.createDirectory(at: recentFolder, withIntermediateDirectories: true)
        for camera in [CameraAngle.front, .back, .leftRepeater, .rightRepeater] {
            jobs.append(
                RenderJob(
                    url: recentFolder.appendingPathComponent(
                        "\(recentName)-\(camera.fileSuffixes[0]).mp4"
                    ),
                    camera: camera,
                    startDate: recentStart,
                    clipOffset: 0,
                    seconds: 8,
                    drive: DriveModel(totalSeconds: 8)
                )
            )
        }

        // Encode concurrently — a dozen clips serially is a long wait on a click.
        let total = jobs.count
        var finished = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            let maxConcurrent = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            var iterator = jobs.makeIterator()
            var inFlight = 0

            while inFlight < maxConcurrent, let job = iterator.next() {
                group.addTask { try await render(job) }
                inFlight += 1
            }
            while inFlight > 0 {
                try await group.next()
                inFlight -= 1
                finished += 1
                let fraction = Double(finished) / Double(total)
                if let progress {
                    await MainActor.run { progress(fraction) }
                }
                if let job = iterator.next() {
                    group.addTask { try await render(job) }
                    inFlight += 1
                }
            }
        }

        try writeEvent(in: sentryFolder, start: start, drive: drive)
        try writeTelemetry(in: sentryFolder, drive: drive)
        try writeThumbnail(in: sentryFolder, drive: drive)

        return root
    }

    private struct RenderJob {
        let url: URL
        let camera: CameraAngle
        let startDate: Date
        /// Seconds from the start of the whole event, so telemetry lines up.
        let clipOffset: Double
        let seconds: Int
        let drive: DriveModel
    }

    // MARK: - The drive being simulated

    /// A short highway stretch: cruise, a signalled lane change, a braking event
    /// for something ahead, then back up to speed with Autopilot re-engaged.
    /// Both the video and the telemetry sidecar read from this, so the picture
    /// and the HUD always agree.
    struct DriveModel: Sendable {
        let totalSeconds: Double
        /// Cumulative distance sampled every `distanceStep` seconds. Precomputed
        /// because every rendered frame asks for it.
        private let distanceTable: [Double]
        private static let distanceStep = 0.05

        init(totalSeconds: Double) {
            self.totalSeconds = totalSeconds
            var table: [Double] = [0]
            var travelled = 0.0
            var cursor = 0.0
            let step = Self.distanceStep
            while cursor < totalSeconds + step {
                travelled += DriveModel.instantaneousSpeed(
                    at: cursor, totalSeconds: totalSeconds
                ) * step
                table.append(travelled)
                cursor += step
            }
            self.distanceTable = table
        }

        /// Metres per second at `t`.
        func speed(at t: Double) -> Double {
            DriveModel.instantaneousSpeed(at: t, totalSeconds: totalSeconds)
        }

        private static func instantaneousSpeed(at t: Double, totalSeconds: Double) -> Double {
            let cruise = 27.5                       // ~99 km/h
            let brakePhase = ramp(t, totalSeconds, from: 0.52, to: 0.68)
            let recoverPhase = ramp(t, totalSeconds, from: 0.68, to: 0.86)
            var value = cruise
            value -= 11 * brakePhase                // down to ~60 km/h
            value += 11 * recoverPhase
            value += sin(t / max(totalSeconds, 1) * .pi * 2) * 0.6
            return max(value, 3)
        }

        /// Smooth 0->1 ramp across a fraction-of-total window.
        private static func ramp(
            _ t: Double, _ totalSeconds: Double, from: Double, to: Double
        ) -> Double {
            let fraction = t / max(totalSeconds, 1)
            guard to > from else { return 0 }
            let x = min(max((fraction - from) / (to - from), 0), 1)
            return x * x * (3 - 2 * x)
        }

        /// Distance travelled by `t`, used to scroll the road consistently.
        func distance(at t: Double) -> Double {
            guard t > 0, !distanceTable.isEmpty else { return 0 }
            let position = t / Self.distanceStep
            let low = Int(position)
            guard low + 1 < distanceTable.count else { return distanceTable[distanceTable.count - 1] }
            let blend = position - Double(low)
            return distanceTable[low] + (distanceTable[low + 1] - distanceTable[low]) * blend
        }

        func brake(at t: Double) -> Double {
            phase(t, from: 0.52, to: 0.60) * (1 - phase(t, from: 0.60, to: 0.68)) * 0.75
        }

        func accelerator(at t: Double) -> Double {
            let base = 0.26
            let lift = phase(t, from: 0.50, to: 0.56)
            let push = phase(t, from: 0.68, to: 0.80)
            return max(0, base - base * lift + 0.35 * push)
        }

        /// Degrees; negative is left. One lane change, plus a lazy highway curve.
        func steering(at t: Double) -> Double {
            let fraction = t / max(totalSeconds, 1)
            let curve = sin(fraction * .pi * 1.4) * 4
            let laneChange = pulse(t, centre: 0.30, width: 0.10) * 11
            return curve + laneChange
        }

        func turnSignalRight(at t: Double) -> Bool {
            let fraction = t / max(totalSeconds, 1)
            return fraction > 0.24 && fraction < 0.36
        }

        func heading(at t: Double) -> Double {
            let fraction = t / max(totalSeconds, 1)
            return 182 + sin(fraction * .pi * 1.4) * 9
        }

        func autopilot(at t: Double) -> TelemetrySample.AutopilotState {
            let fraction = t / max(totalSeconds, 1)
            // Disengages when the driver brakes, re-engages once back up to speed.
            if fraction < 0.18 { return .available }
            if fraction >= 0.50 && fraction < 0.84 { return .off }
            return .autosteer
        }

        func coordinate(at t: Double) -> (latitude: Double, longitude: Double) {
            // Walk the ground track using the simulated heading and distance so
            // the map route matches the speed trace.
            let metresNorth = distance(at: t) * cos((heading(at: t) - 180) * .pi / 180)
            let metresEast = distance(at: t) * sin((heading(at: t) - 180) * .pi / 180)
            let latitude = 48.0610 - metresNorth / 111_320
            let longitude = 3.2910 + metresEast / (111_320 * cos(48.0610 * .pi / 180))
            return (latitude, longitude)
        }

        func longitudinalG(at t: Double) -> Double {
            let delta = speed(at: t + 0.25) - speed(at: max(0, t - 0.25))
            return delta / 0.5 / 9.81
        }

        func lateralG(at t: Double) -> Double {
            steering(at: t) / 90 * (speed(at: t) / 30)
        }

        private func phase(_ t: Double, from: Double, to: Double) -> Double {
            Self.ramp(t, totalSeconds, from: from, to: to)
        }

        private func pulse(_ t: Double, centre: Double, width: Double) -> Double {
            let fraction = t / max(totalSeconds, 1)
            let x = (fraction - centre) / width
            return exp(-x * x * 4) * (x < 0 ? 1 : -1)
        }
    }

    // MARK: - event.json / telemetry.json

    private static func writeEvent(in folder: URL, start: Date, drive: DriveModel) throws {
        let fix = drive.coordinate(at: 0)
        let json: [String: Any] = [
            "timestamp": TeslaTimestamp.string(from: start),
            "city": "Sample Drive",
            "est_lat": String(format: "%.6f", fix.latitude),
            "est_lon": String(format: "%.6f", fix.longitude),
            "reason": "sentry_aware_object_detection",
            "camera": "0"
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: folder.appendingPathComponent("event.json"))
    }

    private static func writeTelemetry(in folder: URL, drive: DriveModel) throws {
        var rows: [[String: Any]] = []
        let hz = 10.0
        let samples = Int(drive.totalSeconds * hz)
        for index in 0...samples {
            let t = Double(index) / hz
            let fix = drive.coordinate(at: t)
            rows.append([
                "t": t,
                "speed_mps": drive.speed(at: t),
                "lat": fix.latitude,
                "lon": fix.longitude,
                "heading": drive.heading(at: t),
                "elevation": 214 + sin(t / max(drive.totalSeconds, 1) * .pi) * 11,
                "gear": "D",
                "autopilot": drive.autopilot(at: t).rawValue,
                "accel_lon": drive.longitudinalG(at: t),
                "accel_lat": drive.lateralG(at: t),
                "steering": drive.steering(at: t),
                "turn_left": false,
                "turn_right": drive.turnSignalRight(at: t),
                "brake": drive.brake(at: t),
                "accelerator": drive.accelerator(at: t)
            ])
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["samples": rows], options: [.prettyPrinted]
        )
        try data.write(to: folder.appendingPathComponent("telemetry.json"))
    }

    private static func writeThumbnail(in folder: URL, drive: DriveModel) throws {
        guard let context = makeContext() else { return }
        drawFrame(in: context, camera: .front, time: 3, drive: drive, stamp: "SAMPLE")
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: folder.appendingPathComponent("thumb.png"))
    }

    // MARK: - Video rendering

    private static func render(_ job: RenderJob) async throws {
        try? FileManager.default.removeItem(at: job.url)

        let writer = try AVAssetWriter(outputURL: job.url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_400_000
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

        let frameCount = Int(fps) * job.seconds
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

            let localTime = Double(frame) / Double(fps)
            let clipTime = job.clipOffset + localTime
            let stamp = stampFormatter.string(from: job.startDate.addingTimeInterval(localTime))
            draw(into: pixelBuffer, camera: job.camera, time: clipTime, drive: job.drive, stamp: stamp)

            _ = adaptor.append(pixelBuffer, withPresentationTime: CMTime(
                value: CMTimeValue(frame), timescale: fps
            ))
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
        into pixelBuffer: CVPixelBuffer,
        camera: CameraAngle,
        time: Double,
        drive: DriveModel,
        stamp: String
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

        drawFrame(in: context, camera: camera, time: time, drive: drive, stamp: stamp)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - The scene

    /// A night highway rendered per camera. `time` is seconds into the whole
    /// event, so every angle drawn at the same `time` shows the same moment.
    private static func drawFrame(
        in context: CGContext,
        camera: CameraAngle,
        time: Double,
        drive: DriveModel,
        stamp: String
    ) {
        let w = CGFloat(context.width)
        let h = CGFloat(context.height)
        let travelled = drive.distance(at: time)
        let steering = drive.steering(at: time)

        // Roll the horizon slightly with the steering input.
        let tilt = CGFloat(steering) * 0.35
        let horizon = h * 0.56 - tilt

        context.setFillColor(gray(0.035))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        switch camera {
        case .front:
            drawForwardScene(context, w: w, h: h, horizon: horizon, travelled: travelled,
                             steering: steering, time: time, drive: drive, reversed: false)
        case .back:
            drawForwardScene(context, w: w, h: h, horizon: horizon, travelled: travelled,
                             steering: -steering, time: time, drive: drive, reversed: true)
        case .leftRepeater, .rightRepeater:
            drawSideScene(context, w: w, h: h, horizon: horizon, travelled: travelled,
                          mirrored: camera == .rightRepeater, wide: true)
        case .leftPillar, .rightPillar:
            drawSideScene(context, w: w, h: h, horizon: horizon, travelled: travelled,
                          mirrored: camera == .rightPillar, wide: false)
        }

        drawCaption(context, w: w, h: h, camera: camera, stamp: stamp)
    }

    /// Front and rear: perspective road, lane dashes scrolling at the driven
    /// distance, plus traffic that closes in during the braking phase.
    private static func drawForwardScene(
        _ context: CGContext,
        w: CGFloat, h: CGFloat, horizon: CGFloat,
        travelled: Double, steering: Double,
        time: Double, drive: DriveModel, reversed: Bool
    ) {
        // Sky and a faint town glow on the horizon.
        context.setFillColor(CGColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: horizon, width: w, height: h - horizon))
        context.setFillColor(CGColor(red: 0.16, green: 0.15, blue: 0.20, alpha: 0.7))
        context.fillEllipse(in: CGRect(x: w * 0.15, y: horizon - h * 0.06,
                                       width: w * 0.7, height: h * 0.14))

        // Road surface, skewed by the steering angle.
        let skew = CGFloat(steering) * 2.2
        context.setFillColor(gray(0.105))
        context.beginPath()
        context.move(to: CGPoint(x: -w * 0.55, y: 0))
        context.addLine(to: CGPoint(x: w * 0.44 + skew, y: horizon))
        context.addLine(to: CGPoint(x: w * 0.56 + skew, y: horizon))
        context.addLine(to: CGPoint(x: w * 1.55, y: 0))
        context.closePath()
        context.fillPath()

        // Painted edge lines.
        for side in [-1.0, 1.0] {
            context.setFillColor(gray(0.62, alpha: 0.55))
            context.beginPath()
            context.move(to: CGPoint(x: w * (0.5 + side * 0.55), y: 0))
            context.addLine(to: CGPoint(x: w * (0.5 + side * 0.062) + skew, y: horizon))
            context.addLine(to: CGPoint(x: w * (0.5 + side * 0.052) + skew, y: horizon))
            context.addLine(to: CGPoint(x: w * (0.5 + side * 0.48), y: 0))
            context.closePath()
            context.fillPath()
        }

        // Centre dashes, positioned by distance travelled — this is what makes
        // the feeds visibly share a clock.
        let dashSpacing = 12.0
        let phase = (travelled / dashSpacing).truncatingRemainder(dividingBy: 1)
        context.setFillColor(gray(0.88, alpha: 0.9))
        for index in 0..<12 {
            var t = (Double(index) + (reversed ? phase : 1 - phase)) / 12.0
            t = min(max(t, 0.001), 1)
            let depth = pow(t, 2.4)
            let y = horizon * depth
            let dashWidth = 2 + (1 - t) * 20
            let dashHeight = 2 + (1 - t) * 16
            let x = w / 2 + skew * CGFloat(1 - depth)
            context.fill(CGRect(x: x - dashWidth / 2, y: y, width: dashWidth, height: dashHeight))
        }

        // The vehicle ahead that triggers the braking event.
        let closeness = min(max((time / max(drive.totalSeconds, 1) - 0.28) / 0.30, 0), 1)
        if closeness > 0 {
            let scale = 0.02 + closeness * 0.26
            let carWidth = w * CGFloat(scale)
            let carHeight = carWidth * 0.42
            let y = horizon - carHeight * 0.35 - CGFloat(closeness) * h * 0.10
            let x = w / 2 + skew * 0.4 - carWidth / 2
            context.setFillColor(gray(0.06))
            context.fill(CGRect(x: x, y: y, width: carWidth, height: carHeight))
            // Tail lights brighten as it brakes.
            let lampWidth = carWidth * 0.20
            let lampHeight = carHeight * 0.26
            let intensity = 0.55 + drive.brake(at: time) * 0.45
            context.setFillColor(CGColor(red: 1.0, green: 0.18, blue: 0.14, alpha: intensity))
            context.fill(CGRect(x: x + carWidth * 0.07, y: y + carHeight * 0.45,
                                width: lampWidth, height: lampHeight))
            context.fill(CGRect(x: x + carWidth * 0.73, y: y + carHeight * 0.45,
                                width: lampWidth, height: lampHeight))
        }

        // Headlight wash on the tarmac.
        context.setFillColor(CGColor(red: 0.95, green: 0.92, blue: 0.80, alpha: 0.055))
        context.beginPath()
        context.move(to: CGPoint(x: w * 0.30, y: 0))
        context.addLine(to: CGPoint(x: w * 0.47 + skew, y: horizon * 0.72))
        context.addLine(to: CGPoint(x: w * 0.53 + skew, y: horizon * 0.72))
        context.addLine(to: CGPoint(x: w * 0.70, y: 0))
        context.closePath()
        context.fillPath()
    }

    /// Repeaters and pillars: a side-on view with guardrail posts and lane
    /// markings streaming past at the driven speed.
    private static func drawSideScene(
        _ context: CGContext,
        w: CGFloat, h: CGFloat, horizon: CGFloat,
        travelled: Double, mirrored: Bool, wide: Bool
    ) {
        context.saveGState()
        if mirrored {
            context.translateBy(x: w, y: 0)
            context.scaleBy(x: -1, y: 1)
        }

        context.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: horizon, width: w, height: h - horizon))
        context.setFillColor(gray(0.09))
        context.fill(CGRect(x: 0, y: 0, width: w, height: horizon))

        // Guardrail posts, spaced in metres so they scroll with real speed.
        let postSpacing = 8.0
        let phase = (travelled / postSpacing).truncatingRemainder(dividingBy: 1)
        let postCount = wide ? 9 : 6
        for index in 0..<postCount {
            let t = (Double(index) + phase) / Double(postCount)
            let depth = pow(1 - t, wide ? 1.8 : 2.2)
            let x = w * CGFloat(t)
            let postHeight = horizon * CGFloat(0.18 + depth * 0.5)
            let postWidth = 2 + CGFloat(depth) * 7
            context.setFillColor(gray(0.30, alpha: 0.75))
            context.fill(CGRect(x: x, y: horizon - postHeight * 0.2,
                                width: postWidth, height: postHeight))
        }
        // The rail itself.
        context.setFillColor(gray(0.38, alpha: 0.6))
        context.fill(CGRect(x: 0, y: horizon + h * 0.02, width: w, height: max(2, h * 0.012)))

        // Lane line sweeping through the lower half.
        let lanePhase = (travelled / 12.0).truncatingRemainder(dividingBy: 1)
        context.setFillColor(gray(0.85, alpha: 0.8))
        for index in 0..<5 {
            let t = (Double(index) + lanePhase) / 5.0
            let x = w * CGFloat(t) - w * 0.1
            context.saveGState()
            context.translateBy(x: x, y: horizon * 0.42)
            context.rotate(by: wide ? -0.28 : -0.44)
            context.fill(CGRect(x: 0, y: 0, width: w * 0.16, height: max(2, h * 0.014)))
            context.restoreGState()
        }

        // A sliver of the car's own bodywork, as the real repeaters see.
        context.setFillColor(gray(0.13))
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: w * (wide ? 0.16 : 0.10), y: 0))
        context.addLine(to: CGPoint(x: 0, y: horizon * 0.55))
        context.closePath()
        context.fillPath()

        context.restoreGState()
    }

    private static func drawCaption(
        _ context: CGContext, w: CGFloat, h: CGFloat, camera: CameraAngle, stamp: String
    ) {
        context.setFillColor(gray(0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: h - 30, width: w, height: 30))
        drawText(camera.shortLabel, in: context, at: CGPoint(x: 12, y: h - 22), size: 13)
        drawText(stamp, in: context, at: CGPoint(x: w - 92, y: h - 22), size: 13)
        drawText("SENTRYHUB SAMPLE", in: context, at: CGPoint(x: 12, y: 10), size: 10)
    }

    private static func gray(_ level: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(red: level, green: level, blue: level, alpha: alpha)
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
