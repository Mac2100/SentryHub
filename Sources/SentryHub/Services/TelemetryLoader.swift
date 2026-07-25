import AVFoundation
import Foundation

/// Builds a `TelemetryTrack` for a clip from whatever the drive actually offers.
///
/// TeslaCam footage is, by itself, almost telemetry-free: the car writes video
/// plus a small `event.json` with one approximate fix. So the loader tries the
/// richest source first and falls back:
///
/// 1. **Sidecar file** — `telemetry.json` / `telemetry.csv` next to the clip
///    (or `<clip-name>.telemetry.json`). Documented in the README so exports
///    from TeslaMate, TeslaFi, or a dashcam logger can be dropped in.
/// 2. **Embedded video metadata** — some firmware writes a timed metadata track
///    or an ISO-6709 location atom into the MP4; both are read when present.
/// 3. **`event.json`** — a single static fix, enough for the map pin.
///
/// Fields no source provided stay `nil`, and the HUD draws `—` rather than
/// inventing a number.
enum TelemetryLoader {

    static func load(for clip: Clip) async -> TelemetryTrack {
        if let track = loadSidecar(for: clip), !track.isEmpty {
            return track
        }
        if let track = await loadEmbedded(for: clip), !track.isEmpty {
            return track
        }
        if let track = loadFromEvent(clip) {
            return track
        }
        return .empty
    }

    // MARK: - Sidecar files

    private static func sidecarCandidates(for clip: Clip) -> [URL] {
        let directory = clip.directory
        return [
            directory.appendingPathComponent("telemetry.json"),
            directory.appendingPathComponent("\(clip.name).telemetry.json"),
            directory.appendingPathComponent("\(clip.name).json"),
            directory.appendingPathComponent("telemetry.csv"),
            directory.appendingPathComponent("\(clip.name).telemetry.csv"),
            directory.appendingPathComponent("\(clip.name).csv")
        ]
    }

    private static func loadSidecar(for clip: Clip) -> TelemetryTrack? {
        let fm = FileManager.default
        for url in sidecarCandidates(for: clip) where fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let samples: [TelemetrySample]?
            if url.pathExtension.lowercased() == "csv" {
                samples = parseCSV(data, clipStart: clip.startDate)
            } else {
                samples = parseJSON(data, clipStart: clip.startDate)
            }
            if let samples, !samples.isEmpty {
                return TelemetryTrack(samples: samples.sorted { $0.time < $1.time },
                                      source: .sidecarFile)
            }
        }
        return nil
    }

    private static func parseJSON(_ data: Data, clipStart: Date) -> [TelemetrySample]? {
        let decoder = JSONDecoder()
        // Accept both `{"samples": [...]}` and a bare array.
        let rows: [TelemetrySidecar.Row]
        if let wrapper = try? decoder.decode(TelemetrySidecar.self, from: data) {
            rows = wrapper.samples
        } else if let bare = try? decoder.decode([TelemetrySidecar.Row].self, from: data) {
            rows = bare
        } else {
            return nil
        }
        return rows.compactMap { convert($0, clipStart: clipStart) }
    }

    private static func convert(_ row: TelemetrySidecar.Row, clipStart: Date) -> TelemetrySample? {
        var offset: TimeInterval?
        if let t = row.t {
            offset = t
        } else if let t = row.time {
            offset = t
        } else if let raw = row.timestamp, let date = TeslaTimestamp.parse(raw) {
            offset = date.timeIntervalSince(clipStart)
        }
        guard let offset else { return nil }

        var sample = TelemetrySample(time: offset)
        if let value = row.speed_mps {
            sample.speedMetersPerSecond = value
        } else if let value = row.speed_kph {
            sample.speedMetersPerSecond = value / 3.6
        } else if let value = row.speed_mph {
            sample.speedMetersPerSecond = value / 2.2369362920544
        }
        sample.latitude = row.lat ?? row.latitude
        sample.longitude = row.lon ?? row.longitude
        sample.heading = row.heading
        sample.elevation = row.elevation
        sample.gear = row.gear.flatMap { TelemetrySample.Gear(rawValue: $0.uppercased()) }
        sample.autopilotState = row.autopilot?.state
        sample.accelerationLongitudinal = row.accel_lon
        sample.accelerationLateral = row.accel_lat
        sample.steeringAngle = row.steering
        sample.turnSignalLeft = row.turn_left
        sample.turnSignalRight = row.turn_right
        sample.brake = row.brake
        sample.accelerator = row.accelerator
        sample.wallClock = clipStart.addingTimeInterval(offset)
        return sample
    }

    /// Header-driven CSV using the same column names as the JSON schema.
    private static func parseCSV(_ data: Data, clipStart: Date) -> [TelemetrySample]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { return nil }
        lines.removeFirst()

        let columns = header
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        func index(_ names: [String]) -> Int? {
            for name in names {
                if let position = columns.firstIndex(of: name) { return position }
            }
            return nil
        }

        let iT = index(["t", "time", "seconds", "offset"])
        let iTimestamp = index(["timestamp", "date"])
        let iSpeedMS = index(["speed_mps", "speed_ms"])
        let iSpeedKPH = index(["speed_kph", "speed_kmh", "kph"])
        let iSpeedMPH = index(["speed_mph", "mph"])
        let iLat = index(["lat", "latitude"])
        let iLon = index(["lon", "lng", "longitude"])
        let iHeading = index(["heading", "bearing", "course"])
        let iElevation = index(["elevation", "altitude"])
        let iGear = index(["gear", "shift"])
        let iAutopilot = index(["autopilot", "ap", "fsd"])
        let iAccelLon = index(["accel_lon", "accel_longitudinal"])
        let iAccelLat = index(["accel_lat", "accel_lateral"])
        let iSteering = index(["steering", "steering_angle"])
        let iTurnLeft = index(["turn_left", "left_signal"])
        let iTurnRight = index(["turn_right", "right_signal"])
        let iBrake = index(["brake"])
        let iAccelerator = index(["accelerator", "throttle"])

        var samples: [TelemetrySample] = []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = line
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }

            func value(_ position: Int?) -> String? {
                guard let position, position < fields.count else { return nil }
                let raw = fields[position]
                return raw.isEmpty ? nil : raw
            }
            func number(_ position: Int?) -> Double? {
                value(position).flatMap(Double.init)
            }
            func flag(_ position: Int?) -> Bool? {
                guard let raw = value(position)?.lowercased() else { return nil }
                return ["1", "true", "yes", "on"].contains(raw)
            }

            var offset: TimeInterval?
            if let t = number(iT) {
                offset = t
            } else if let raw = value(iTimestamp), let date = TeslaTimestamp.parse(raw) {
                offset = date.timeIntervalSince(clipStart)
            }
            guard let offset else { continue }

            var sample = TelemetrySample(time: offset)
            if let value = number(iSpeedMS) {
                sample.speedMetersPerSecond = value
            } else if let value = number(iSpeedKPH) {
                sample.speedMetersPerSecond = value / 3.6
            } else if let value = number(iSpeedMPH) {
                sample.speedMetersPerSecond = value / 2.2369362920544
            }
            sample.latitude = number(iLat)
            sample.longitude = number(iLon)
            sample.heading = number(iHeading)
            sample.elevation = number(iElevation)
            sample.gear = value(iGear).flatMap { TelemetrySample.Gear(rawValue: $0.uppercased()) }
            if let raw = value(iAutopilot) {
                sample.autopilotState = TelemetrySidecar.AutopilotValue.named(raw).state
            }
            sample.accelerationLongitudinal = number(iAccelLon)
            sample.accelerationLateral = number(iAccelLat)
            sample.steeringAngle = number(iSteering)
            sample.turnSignalLeft = flag(iTurnLeft)
            sample.turnSignalRight = flag(iTurnRight)
            sample.brake = number(iBrake)
            sample.accelerator = number(iAccelerator)
            sample.wallClock = clipStart.addingTimeInterval(offset)
            samples.append(sample)
        }
        return samples
    }

    // MARK: - Embedded video metadata

    /// Reads whatever the container carries: a timed metadata track (sampled
    /// GPS) or a single ISO-6709 location atom.
    private static func loadEmbedded(for clip: Clip) async -> TelemetryTrack? {
        var samples: [TelemetrySample] = []
        var elapsed: TimeInterval = 0

        // Prefer the front camera; every camera in a segment shares the same
        // metadata, and reading one track per segment is enough.
        for segment in clip.segments {
            let camera = CameraAngle.preferredFocusOrder.first { segment.files[$0] != nil }
            guard let camera, let url = segment.files[camera] else {
                elapsed += segment.duration
                continue
            }
            let asset = AVURLAsset(url: url)
            samples.append(contentsOf: await timedSamples(from: asset, offset: elapsed))

            if samples.isEmpty, let fix = await staticLocation(from: asset) {
                var sample = TelemetrySample(time: elapsed)
                sample.latitude = fix.latitude
                sample.longitude = fix.longitude
                sample.elevation = fix.elevation
                sample.wallClock = clip.startDate.addingTimeInterval(elapsed)
                samples.append(sample)
            }
            elapsed += segment.duration
        }

        guard !samples.isEmpty else { return nil }
        return TelemetryTrack(
            samples: samples.sorted { $0.time < $1.time },
            source: .embeddedVideoMetadata
        )
    }

    private static func timedSamples(
        from asset: AVURLAsset, offset: TimeInterval
    ) async -> [TelemetrySample] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata),
              let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var samples: [TelemetrySample] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let group = AVTimedMetadataGroup(sampleBuffer: buffer) else { continue }
            let time = CMTimeGetSeconds(group.timeRange.start)
            guard time.isFinite else { continue }

            var sample = TelemetrySample(time: offset + time)
            var populated = false
            for item in group.items {
                guard let identifier = item.identifier?.rawValue else { continue }
                let key = identifier.lowercased()
                // `load` returns an optional value, so a failed await nests two
                // levels of optionality — flatten before using either.
                let string: String? = (try? await item.load(.stringValue)) ?? nil
                let number: NSNumber? = (try? await item.load(.numberValue)) ?? nil

                if key.contains("location.iso6709") || key.contains("location") {
                    if let string, let fix = parseISO6709(string) {
                        sample.latitude = fix.latitude
                        sample.longitude = fix.longitude
                        sample.elevation = fix.elevation
                        populated = true
                    }
                } else if key.contains("speed") {
                    if let value = number?.doubleValue ?? string.flatMap(Double.init) {
                        sample.speedMetersPerSecond = value
                        populated = true
                    }
                } else if key.contains("direction") || key.contains("heading")
                            || key.contains("bearing") {
                    if let value = number?.doubleValue ?? string.flatMap(Double.init) {
                        sample.heading = value
                        populated = true
                    }
                }
            }
            if populated { samples.append(sample) }
        }
        reader.cancelReading()
        return samples
    }

    private static func staticLocation(
        from asset: AVURLAsset
    ) async -> (latitude: Double, longitude: Double, elevation: Double?)? {
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            guard let identifier = item.identifier?.rawValue.lowercased(),
                  identifier.contains("location") else { continue }
            let string: String? = (try? await item.load(.stringValue)) ?? nil
            if let string, let fix = parseISO6709(string) { return fix }
        }
        return nil
    }

    /// `+48.0610+003.2910+000.000/` → (48.0610, 3.2910, 0.0)
    static func parseISO6709(
        _ raw: String
    ) -> (latitude: Double, longitude: Double, elevation: Double?)? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        var numbers: [Double] = []
        var current = ""
        for character in trimmed {
            if character == "+" || character == "-" {
                if let value = Double(current) { numbers.append(value) }
                current = String(character)
            } else if character.isNumber || character == "." {
                current.append(character)
            } else {
                break
            }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1], numbers.count >= 3 ? numbers[2] : nil)
    }

    // MARK: - event.json fallback

    private static func loadFromEvent(_ clip: Clip) -> TelemetryTrack? {
        guard let event = clip.event, event.hasCoordinate,
              let latitude = event.latitude, let longitude = event.longitude else { return nil }

        // One fix, held for the whole clip: enough to place the map pin without
        // pretending the car's position was tracked.
        var start = TelemetrySample(time: 0)
        start.latitude = latitude
        start.longitude = longitude
        start.wallClock = event.timestamp ?? clip.startDate

        var end = start
        end.time = max(clip.duration, 1)
        end.wallClock = (event.timestamp ?? clip.startDate).addingTimeInterval(end.time)

        return TelemetryTrack(samples: [start, end], source: .eventMetadata)
    }
}
