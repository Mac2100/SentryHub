import Foundation

// MARK: - Categories

/// The three folders Tesla writes on the dashcam drive.
enum ClipCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case sentry
    case saved
    case recent

    var id: String { rawValue }

    /// Directory name inside `TeslaCam/`.
    var folderName: String {
        switch self {
        case .sentry: return "SentryClips"
        case .saved: return "SavedClips"
        case .recent: return "RecentClips"
        }
    }

    var label: String {
        switch self {
        case .sentry: return "Sentry"
        case .saved: return "Saved"
        case .recent: return "Recent"
        }
    }

    var symbolName: String {
        switch self {
        case .sentry: return "shield.lefthalf.filled"
        case .saved: return "bookmark.fill"
        case .recent: return "clock"
        }
    }
}

// MARK: - Cameras

/// The six camera feeds a Tesla can write. Older vehicles only produce four
/// (the B-pillar cameras arrived with later firmware/hardware).
enum CameraAngle: String, CaseIterable, Identifiable, Codable, Hashable {
    case leftPillar
    case front
    case rightPillar
    case leftRepeater
    case back
    case rightRepeater

    var id: String { rawValue }

    /// The suffix Tesla appends to the file name, e.g. `…-left_repeater.mp4`.
    var fileSuffixes: [String] {
        switch self {
        case .front: return ["front"]
        case .back: return ["back", "rear"]
        case .leftRepeater: return ["left_repeater"]
        case .rightRepeater: return ["right_repeater"]
        case .leftPillar: return ["left_pillar"]
        case .rightPillar: return ["right_pillar"]
        }
    }

    /// Label drawn under each tile, matching the on-screen badges.
    var shortLabel: String {
        switch self {
        case .front: return "FRONT"
        case .back: return "REAR"
        case .leftRepeater: return "L-REPEATER"
        case .rightRepeater: return "R-REPEATER"
        case .leftPillar: return "L-PILLAR"
        case .rightPillar: return "R-PILLAR"
        }
    }

    var displayName: String {
        switch self {
        case .front: return "Front"
        case .back: return "Rear"
        case .leftRepeater: return "Left Repeater"
        case .rightRepeater: return "Right Repeater"
        case .leftPillar: return "Left Pillar"
        case .rightPillar: return "Right Pillar"
        }
    }

    /// Directional glyph used by the camera-picker row in the transport bar —
    /// the buttons are laid out to mirror where each camera sits on the car.
    var directionSymbol: String {
        switch self {
        case .leftPillar: return "arrow.up.left"
        case .front: return "arrow.up"
        case .rightPillar: return "arrow.up.right"
        case .leftRepeater: return "arrow.down.left"
        case .back: return "arrow.down"
        case .rightRepeater: return "arrow.down.right"
        }
    }

    /// Row/column of this camera in the six-up layout (3 columns × 2 rows),
    /// arranged the way the cameras are arranged on the car.
    static let sixUpOrder: [CameraAngle] = [
        .leftPillar, .front, .rightPillar,
        .leftRepeater, .back, .rightRepeater
    ]

    static let quadOrder: [CameraAngle] = [.front, .back, .leftRepeater, .rightRepeater]

    /// Camera preferred when nothing has been picked yet.
    static let preferredFocusOrder: [CameraAngle] = [
        .front, .back, .leftRepeater, .rightRepeater, .leftPillar, .rightPillar
    ]

    init?(fileSuffix: String) {
        let normalized = fileSuffix.lowercased()
        for angle in CameraAngle.allCases where angle.fileSuffixes.contains(normalized) {
            self = angle
            return
        }
        return nil
    }
}

// MARK: - Event metadata (event.json)

/// `event.json`, written by the car alongside Sentry and Saved clips.
/// Tesla has shipped both string and numeric encodings of the coordinates over
/// the years, so the decoder accepts either.
struct EventMetadata: Codable, Hashable {
    var timestamp: Date?
    var city: String?
    var latitude: Double?
    var longitude: Double?
    var reason: String?
    /// Index of the camera that triggered the event, when the car recorded one.
    var triggerCamera: CameraAngle?

    private enum CodingKeys: String, CodingKey {
        case timestamp, city, reason, camera
        case estLat = "est_lat"
        case estLon = "est_lon"
    }

    init(
        timestamp: Date? = nil,
        city: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        reason: String? = nil,
        triggerCamera: CameraAngle? = nil
    ) {
        self.timestamp = timestamp
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.reason = reason
        self.triggerCamera = triggerCamera
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? container.decodeIfPresent(String.self, forKey: .timestamp) {
            timestamp = TeslaTimestamp.parse(raw)
        }
        city = try? container.decodeIfPresent(String.self, forKey: .city)
        latitude = EventMetadata.decodeNumber(container, .estLat)
        longitude = EventMetadata.decodeNumber(container, .estLon)
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)

        // `camera` is the index into Tesla's own camera ordering.
        var cameraIndex: Int?
        if let value = try? container.decodeIfPresent(Int.self, forKey: .camera) {
            cameraIndex = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .camera) {
            cameraIndex = Int(text)
        }
        if let index = cameraIndex {
            triggerCamera = EventMetadata.camera(forTeslaIndex: index)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(timestamp.map(TeslaTimestamp.string(from:)), forKey: .timestamp)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(latitude.map { String($0) }, forKey: .estLat)
        try container.encodeIfPresent(longitude.map { String($0) }, forKey: .estLon)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    private static func decodeNumber(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Tesla's `camera` field is an index, not a name.
    private static func camera(forTeslaIndex index: Int) -> CameraAngle? {
        switch index {
        case 0: return .front
        case 1: return .rightRepeater
        case 2: return .leftRepeater
        case 3: return .rightPillar
        case 4: return .leftPillar
        case 5, 6: return .back
        default: return nil
        }
    }

    var hasCoordinate: Bool {
        guard let latitude, let longitude else { return false }
        return !(latitude == 0 && longitude == 0)
    }

    /// Human-readable form of the `reason` string ("sentry_aware_object_detection").
    var reasonLabel: String? {
        guard let reason, !reason.isEmpty else { return nil }
        let cleaned = reason
            .replacingOccurrences(of: "sentry_aware_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}

// MARK: - Segments and clips

/// One ~60 second recording window. A single Sentry event is usually made of
/// several of these, one set of files per minute.
struct ClipSegment: Identifiable, Hashable {
    /// The shared `YYYY-MM-DD_HH-MM-SS` prefix of every file in the segment.
    let id: String
    let timestamp: Date
    var files: [CameraAngle: URL]
    var byteCount: Int64
    /// Filled in lazily once AVFoundation has been asked for the real duration.
    var duration: TimeInterval

    var cameras: Set<CameraAngle> { Set(files.keys) }
}

/// A single reviewable event: a Sentry/Saved folder, or one Recent recording.
struct Clip: Identifiable, Hashable {
    let id: String
    let category: ClipCategory
    /// `2025-12-21_20-59-54` — the folder name, or the segment prefix for Recent clips.
    let name: String
    /// Folder that holds the clip's files (the parent folder for Recent clips).
    let directory: URL
    let startDate: Date
    var segments: [ClipSegment]
    var event: EventMetadata?
    var thumbnailURL: URL?

    var byteCount: Int64 { segments.reduce(0) { $0 + $1.byteCount } }
    var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    var cameras: Set<CameraAngle> {
        segments.reduce(into: Set<CameraAngle>()) { $0.formUnion($1.cameras) }
    }

    /// Cameras in canonical display order.
    var orderedCameras: [CameraAngle] {
        let available = cameras
        return CameraAngle.sixUpOrder.filter { available.contains($0) }
    }

    var coordinate: (latitude: Double, longitude: Double)? {
        guard let event, let lat = event.latitude, let lon = event.longitude,
              event.hasCoordinate else { return nil }
        return (lat, lon)
    }

    var city: String? {
        guard let city = event?.city, !city.isEmpty else { return nil }
        return city
    }

    /// Every file in the clip, ordered by segment then camera.
    var allFiles: [URL] {
        segments.flatMap { segment in
            CameraAngle.sixUpOrder.compactMap { segment.files[$0] }
        }
    }

    func url(for camera: CameraAngle) -> URL? {
        segments.first { $0.files[camera] != nil }?.files[camera]
    }

    /// Ordered list of files for one camera across the whole event.
    func timeline(for camera: CameraAngle) -> [(url: URL, duration: TimeInterval)] {
        segments.compactMap { segment in
            guard let url = segment.files[camera] else { return nil }
            return (url, segment.duration)
        }
    }
}

// MARK: - Timestamp parsing

enum TeslaTimestamp {
    /// `2025-12-21_20-59-54`, used for file and folder names.
    static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// `2025-12-21T20:59:54`, used inside `event.json`.
    private static let eventFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = eventFormatter.date(from: trimmed) { return date }
        if let date = fileFormatter.date(from: trimmed) { return date }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    static func string(from date: Date) -> String {
        eventFormatter.string(from: date)
    }

    /// Extracts the `2025-12-21_20-59-54` prefix and camera suffix from a file name.
    static func components(ofFileNamed fileName: String) -> (prefix: String, camera: CameraAngle)? {
        let base = (fileName as NSString).deletingPathExtension
        // Names are `<prefix>-<camera>`; the camera suffix itself contains a `_`
        // but never a `-`, so splitting on the last dash is enough — except for
        // two-word suffixes like `left_repeater`, which keep their underscore.
        guard let dashIndex = base.lastIndex(of: "-") else { return nil }
        let suffix = String(base[base.index(after: dashIndex)...])
        guard let camera = CameraAngle(fileSuffix: suffix) else { return nil }
        return (String(base[base.startIndex..<dashIndex]), camera)
    }
}
