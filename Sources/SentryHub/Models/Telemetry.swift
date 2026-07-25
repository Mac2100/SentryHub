import CoreLocation
import Foundation

/// Drive-state fields the HUD can show. Everything is optional: TeslaCam files
/// carry very little telemetry on their own, so a field is drawn only when a
/// source actually supplied it (see `TelemetryLoader`).
struct TelemetrySample: Hashable {
    /// Seconds from the start of the clip.
    var time: TimeInterval

    var speedMetersPerSecond: Double?
    var latitude: Double?
    var longitude: Double?
    /// Degrees clockwise from true north.
    var heading: Double?
    var elevation: Double?

    var gear: Gear?
    var autopilotState: AutopilotState?

    /// Longitudinal (forward/back) acceleration in g.
    var accelerationLongitudinal: Double?
    /// Lateral (side to side) acceleration in g.
    var accelerationLateral: Double?

    /// Steering wheel angle in degrees; negative is left.
    var steeringAngle: Double?
    var turnSignalLeft: Bool?
    var turnSignalRight: Bool?

    /// 0…1 pedal travel.
    var brake: Double?
    var accelerator: Double?

    /// Wall-clock time this sample represents, when known.
    var wallClock: Date?

    init(time: TimeInterval) {
        self.time = time
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude, !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum Gear: String, Codable, Hashable, CaseIterable {
        case park = "P"
        case reverse = "R"
        case neutral = "N"
        case drive = "D"
    }

    enum AutopilotState: String, Codable, Hashable {
        case off
        case available
        case autosteer
        case fsd

        var label: String {
            switch self {
            case .off: return "OFF"
            case .available: return "READY"
            case .autosteer: return "AUTOSTEER"
            case .fsd: return "FSD"
            }
        }

        var isEngaged: Bool { self == .autosteer || self == .fsd }
    }
}

// MARK: - Track

/// Where a track's numbers came from, so the UI can be honest about it.
enum TelemetrySource: String, Hashable {
    /// Nothing beyond the clip's own file names.
    case unavailable
    /// A single fix from `event.json`.
    case eventMetadata
    /// A timed metadata track inside the MP4 (some firmware writes GPS there).
    case embeddedVideoMetadata
    /// A user-supplied `telemetry.json` / `.csv` sidecar.
    case sidecarFile

    var label: String {
        switch self {
        case .unavailable: return "No telemetry"
        case .eventMetadata: return "event.json"
        case .embeddedVideoMetadata: return "Embedded in video"
        case .sidecarFile: return "Sidecar file"
        }
    }

    var symbolName: String {
        switch self {
        case .unavailable: return "antenna.radiowaves.left.and.right.slash"
        case .eventMetadata: return "doc.text"
        case .embeddedVideoMetadata: return "film"
        case .sidecarFile: return "doc.badge.plus"
        }
    }
}

/// Time-ordered telemetry for one clip, with linear interpolation between samples.
struct TelemetryTrack: Hashable {
    var samples: [TelemetrySample]
    var source: TelemetrySource

    static let empty = TelemetryTrack(samples: [], source: .unavailable)

    var isEmpty: Bool { samples.isEmpty }

    /// True when the track has more than one fix, i.e. an actual route.
    var hasRoute: Bool { route.count > 1 }

    var route: [CLLocationCoordinate2D] {
        samples.compactMap(\.coordinate)
    }

    var topSpeedMetersPerSecond: Double? {
        samples.compactMap(\.speedMetersPerSecond).max()
    }

    var averageSpeedMetersPerSecond: Double? {
        let speeds = samples.compactMap(\.speedMetersPerSecond)
        guard !speeds.isEmpty else { return nil }
        return speeds.reduce(0, +) / Double(speeds.count)
    }

    /// Sample at `time`, interpolating numeric fields between the two nearest
    /// samples and holding discrete fields (gear, signals) from the earlier one.
    func sample(at time: TimeInterval) -> TelemetrySample? {
        guard !samples.isEmpty else { return nil }
        if samples.count == 1 { return samples[0] }
        if time <= samples[0].time { return samples[0] }
        if let last = samples.last, time >= last.time { return last }

        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid } else { high = mid }
        }

        let a = samples[low]
        let b = samples[high]
        let span = b.time - a.time
        guard span > 0 else { return a }
        let t = (time - a.time) / span

        var result = a
        result.time = time
        result.speedMetersPerSecond = Self.blend(a.speedMetersPerSecond, b.speedMetersPerSecond, t)
        result.latitude = Self.blend(a.latitude, b.latitude, t)
        result.longitude = Self.blend(a.longitude, b.longitude, t)
        result.heading = Self.blendAngle(a.heading, b.heading, t)
        result.elevation = Self.blend(a.elevation, b.elevation, t)
        result.accelerationLongitudinal = Self.blend(
            a.accelerationLongitudinal, b.accelerationLongitudinal, t
        )
        result.accelerationLateral = Self.blend(a.accelerationLateral, b.accelerationLateral, t)
        result.steeringAngle = Self.blend(a.steeringAngle, b.steeringAngle, t)
        result.brake = Self.blend(a.brake, b.brake, t)
        result.accelerator = Self.blend(a.accelerator, b.accelerator, t)
        if let start = a.wallClock {
            result.wallClock = start.addingTimeInterval(span * t)
        }
        return result
    }

    private static func blend(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a else { return b }
        guard let b else { return a }
        return a + (b - a) * t
    }

    /// Shortest-arc interpolation so a heading crossing 360° doesn't spin backwards.
    private static func blendAngle(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a else { return b }
        guard let b else { return a }
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var result = (a + delta * t).truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }
}

// MARK: - Sidecar decoding

/// Schema for a user-supplied `telemetry.json` sitting next to a clip.
/// Documented in the README so exports from TeslaMate/TeslaFi/dashcam loggers
/// can be dropped in without writing any code.
struct TelemetrySidecar: Decodable {
    var samples: [Row]

    struct Row: Decodable {
        var t: Double?
        var time: Double?
        var timestamp: String?

        var speed_mps: Double?
        var speed_kph: Double?
        var speed_mph: Double?

        var lat: Double?
        var lon: Double?
        var latitude: Double?
        var longitude: Double?
        var heading: Double?
        var elevation: Double?

        var gear: String?
        var autopilot: AutopilotValue?

        var accel_lon: Double?
        var accel_lat: Double?
        var steering: Double?
        var turn_left: Bool?
        var turn_right: Bool?
        var brake: Double?
        var accelerator: Double?
    }

    /// `autopilot` accepts `true`, `"fsd"`, `"autosteer"`, `"off"`, …
    enum AutopilotValue: Decodable {
        case flag(Bool)
        case named(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else {
                self = .named(try container.decode(String.self))
            }
        }

        var state: TelemetrySample.AutopilotState {
            switch self {
            case .flag(let on):
                return on ? .autosteer : .off
            case .named(let raw):
                switch raw.lowercased() {
                case "fsd", "full_self_driving", "navigate_on_autopilot": return .fsd
                case "autosteer", "on", "engaged", "true": return .autosteer
                case "available", "ready", "standby": return .available
                default: return .off
                }
            }
        }
    }
}

// MARK: - Availability

/// Which HUD readouts a clip can actually feed.
///
/// TeslaCam footage carries very little telemetry, so most elements have no
/// data most of the time. The HUD uses this to hide readouts that would only
/// ever show `—`, keeping the overlay to what's genuinely known.
struct TelemetryAvailability: Equatable {
    var speed = false
    var gear = false
    var autopilot = false
    var pedals = false
    var steering = false
    var turnSignals = false
    var gForce = false
    var location = false
    var heading = false
    /// The clip records a triggering event inside its footage.
    var event = false

    /// Date and time always work: they come from the clip's own start time plus
    /// the play head, not from telemetry.
    static let clockOnly = TelemetryAvailability()

    init() {}

    init(track: TelemetryTrack, hasCity: Bool = false, hasEvent: Bool = false) {
        location = hasCity
        event = hasEvent
        for sample in track.samples {
            if sample.speedMetersPerSecond != nil { speed = true }
            if sample.gear != nil { gear = true }
            if sample.autopilotState != nil { autopilot = true }
            if sample.brake != nil || sample.accelerator != nil { pedals = true }
            if sample.steeringAngle != nil { steering = true }
            if sample.turnSignalLeft != nil || sample.turnSignalRight != nil { turnSignals = true }
            if sample.accelerationLongitudinal != nil || sample.accelerationLateral != nil {
                gForce = true
            }
            if sample.coordinate != nil { location = true }
            if sample.heading != nil { heading = true }
        }
    }

    /// Answers for the element rows in the HUD popover, keyed by their id.
    func supports(elementID: String) -> Bool {
        switch elementID {
        case "speedometer": return speed
        case "pedals": return pedals
        case "steeringWheel": return steering
        case "gearSelector": return gear
        case "autopilot": return autopilot
        case "gForce": return gForce
        case "date", "time": return true
        case "location": return location
        case "turnSignals": return turnSignals
        case "compass": return heading || location
        case "eventFlash": return event
        default: return true
        }
    }

    /// True when nothing beyond the clock is known.
    var isClockOnly: Bool { self == .clockOnly }
}
