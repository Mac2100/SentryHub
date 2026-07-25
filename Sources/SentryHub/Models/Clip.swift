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


/// What made the car keep this clip, read from `event.json`'s `reason`.
///
/// Tesla only writes three *folders* (Sentry / Saved / Recent), but Sentry and
/// Saved events also record why they were captured — which is a far more useful
/// thing to filter on than the folder alone.
enum ClipTrigger: String, CaseIterable, Identifiable, Codable, Hashable {
    case motion
    case impact
    case honk
    case manualSave

    var id: String { rawValue }

    /// Deliberately not "Saved": that word belongs to Tesla's `SavedClips`
    /// folder, and a clip can be manually saved without landing in it — tap
    /// save during a Sentry event and it stays in `SentryClips`.
    var label: String {
        switch self {
        case .motion: return "Motion"
        case .impact: return "Impact"
        case .honk: return "Honk"
        case .manualSave: return "Manual Save"
        }
    }

    /// Short form for the badge drawn on a clip card.
    var badgeLabel: String {
        switch self {
        case .motion: return "MOTION"
        case .impact: return "IMPACT"
        case .honk: return "HONK"
        case .manualSave: return "MANUAL SAVE"
        }
    }

    var symbolName: String {
        switch self {
        case .motion: return "figure.walk.motion"
        case .impact: return "burst"
        case .honk: return "speaker.wave.2.fill"
        case .manualSave: return "hand.tap.fill"
        }
    }

    /// Which system decided to keep the clip, which is also which folder the
    /// reason comes out of.
    ///
    /// Tesla's `reason` strings come in two families, and the prefix is the
    /// useful part: `sentry_aware_*` is the car noticing something by itself
    /// while parked, `user_interaction_*` is the driver saying *keep this*.
    var origin: ClipCategory {
        switch self {
        case .motion, .impact: return .sentry
        case .honk, .manualSave: return .saved
        }
    }

    /// Parses the strings Tesla has shipped:
    ///
    /// - `sentry_aware_object_detection` — something moved near the parked car
    /// - `sentry_aware_accel_v2` / `sentry_aware_accel` — the car was jolted
    /// - `user_interaction_honk` — the horn, while the dashcam was recording
    /// - `user_interaction_dashcam_icon_tapped`,
    ///   `user_interaction_dashcam_panel_save` — the driver saved it by hand
    ///
    /// Tesla publishes none of this and has changed the strings across
    /// firmware, so anything unrecognised returns nil and the clip is offered
    /// under **Other** rather than guessed into the nearest bucket. A blanket
    /// "starts with sentry, call it Motion" would quietly mislabel whatever
    /// they ship next.
    init?(reason: String?) {
        guard let raw = reason?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("honk") {
            self = .honk
        } else if raw.contains("accel") || raw.contains("impact") || raw.contains("collision") {
            self = .impact
        } else if raw.contains("object") || raw.contains("detection") || raw.contains("motion") {
            self = .motion
        } else if raw.contains("tapped") || raw.contains("icon") || raw.contains("panel")
                    || raw.contains("voice") || raw.contains("save") {
            self = .manualSave
        } else {
            return nil
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
    /// The road the car was on. Newer firmware writes this alongside `city`.
    var street: String?
    var latitude: Double?
    var longitude: Double?
    var reason: String?
    /// Index of the camera that triggered the event, when the car recorded one.
    var triggerCamera: CameraAngle?

    private enum CodingKeys: String, CodingKey {
        case timestamp, city, street, reason, camera
        case estLat = "est_lat"
        case estLon = "est_lon"
    }

    init(
        timestamp: Date? = nil,
        city: String? = nil,
        street: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        reason: String? = nil,
        triggerCamera: CameraAngle? = nil
    ) {
        self.timestamp = timestamp
        self.city = city
        self.street = street
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
        street = try? container.decodeIfPresent(String.self, forKey: .street)
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
        try container.encodeIfPresent(street, forKey: .street)
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

/// Where a clip's files live.
///
/// The dashcam drive is a rolling buffer: the car overwrites it, and everything
/// on it disappears the moment it's unplugged. Knowing which side of that line a
/// clip sits on is the single most useful thing the library can tell you.
enum ClipStorage: String, CaseIterable, Identifiable, Codable, Hashable {
    /// Only on the drive — it goes away when the drive does.
    case device
    /// Only in SentryHub's local library; the drive no longer has it.
    case local
    /// Copied to this Mac and still on the drive.
    case both

    var id: String { rawValue }

    var isSavedLocally: Bool { self != .device }
    var isOnDrive: Bool { self != .local }

    var label: String {
        switch self {
        case .device: return "On the drive only"
        case .local: return "Saved on this Mac"
        case .both: return "Saved on this Mac and on the drive"
        }
    }

    /// Chip text on a clip card.
    ///
    /// Both local states read the same, and neither says "Saved": that word is
    /// already taken twice over by Tesla's `SavedClips` folder and by a manual
    /// save, and three meanings for one word on one card is two too many.
    var shortLabel: String {
        switch self {
        case .device: return "Drive only"
        case .local, .both: return "On this Mac"
        }
    }

    var symbolName: String {
        switch self {
        case .device: return "externaldrive"
        case .local: return "internaldrive.fill"
        case .both: return "internaldrive.fill"
        }
    }
}

/// A single reviewable event: a Sentry/Saved folder, or one Recent recording.
struct Clip: Identifiable, Hashable {
    let category: ClipCategory
    /// `2025-12-21_20-59-54` — the folder name, or the segment prefix for Recent clips.
    let name: String
    /// Folder that holds the clip's files (the parent folder for Recent clips).
    let directory: URL
    let startDate: Date
    var segments: [ClipSegment]
    var event: EventMetadata?
    var thumbnailURL: URL?
    /// Filled in by `LibraryStore` when the drive and the local library are merged.
    var storage: ClipStorage = .device

    /// Deliberately derived from the category and the car's own name rather than
    /// from the path. The same footage keeps one identity whether it's being
    /// read off the drive or out of the local library — which is what lets the
    /// two merge into a single card, and what renames and incidents key on.
    var id: String { "\(category.rawValue)/\(name)" }

    /// True when the clip owns the folder it sits in — a Sentry or Saved event.
    ///
    /// This distinction matters enormously for copying and deleting: a Recent
    /// clip is loose files sharing `RecentClips` with every other recording on
    /// the drive, so its "folder" is emphatically not its own.
    var ownsDirectory: Bool {
        directory.lastPathComponent == name
    }

    /// Everything on disk that belongs to this clip and to nothing else — what
    /// a copy takes and what a delete is allowed to touch.
    var storedItems: [URL] {
        ownsDirectory ? [directory] : allFiles
    }

    /// Sidecar files that travel alongside a loose clip, when they exist.
    var sidecarFileNames: [String] {
        [
            "\(name).telemetry.json", "\(name).json",
            "\(name).telemetry.csv", "\(name).csv"
        ]
    }

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

    /// Why the car saved this clip, when it said.
    var trigger: ClipTrigger? {
        ClipTrigger(reason: event?.reason)
    }

    /// True when the car flagged this clip for a reason of any kind.
    ///
    /// Wider than `trigger` on purpose: Tesla has shipped `reason` strings we
    /// don't classify, and those clips draw a badge on their card with no
    /// specific pill to reach them by.
    var isFlagged: Bool {
        trigger != nil || event?.reasonLabel != nil
    }

    /// The car gave a reason for keeping this clip that SentryHub can't name.
    /// These are the only clips no trigger chip can reach.
    var hasUnclassifiedEvent: Bool {
        trigger == nil && event?.reasonLabel != nil
    }

    /// Where the playable timeline actually begins.
    ///
    /// A Sentry folder is *named* for the moment of the event, but the footage
    /// inside starts earlier — so the folder date is the wrong zero point for
    /// the clock and for the event marker.
    var timelineStart: Date {
        segments.first?.timestamp ?? startDate
    }

    /// Offset of the triggering event along the timeline, when it falls inside
    /// the recorded footage. This is what the timeline marker points at.
    var eventOffset: TimeInterval? {
        let moment = event?.timestamp ?? (segments.isEmpty ? nil : startDate)
        guard let moment else { return nil }
        let offset = moment.timeIntervalSince(timelineStart)
        guard offset.isFinite, duration > 0 else { return nil }
        // The car names a Sentry folder for the moment of the event, but the
        // last segment is often cut short — so the stamp can sit a little past
        // the final frame. Clamp generously rather than dropping the marker,
        // which would take the jump button with it.
        guard offset >= -Self.eventStampTolerance,
              offset <= duration + Self.eventStampTolerance else { return nil }
        return min(max(offset, 0), duration)
    }

    /// How far outside the footage an `event.json` stamp may sit and still be
    /// treated as "this clip's event".
    private static let eventStampTolerance: TimeInterval = 30

    var coordinate: (latitude: Double, longitude: Double)? {
        guard let event, let lat = event.latitude, let lon = event.longitude,
              event.hasCoordinate else { return nil }
        return (lat, lon)
    }

    var city: String? {
        guard let city = event?.city, !city.isEmpty else { return nil }
        return city
    }

    var street: String? {
        guard let street = event?.street, !street.isEmpty else { return nil }
        return street
    }

    /// "River Rd, Fair Lawn" — the most specific place the car named.
    ///
    /// `street` arrived in newer firmware and the app never read it, so a clip
    /// that knew its road was only ever showing its town.
    var placeLabel: String? {
        switch (street, city) {
        case let (street?, city?): return "\(street), \(city)"
        case let (street?, nil): return street
        case let (nil, city?): return city
        default: return nil
        }
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
