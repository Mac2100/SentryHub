import Foundation
import SwiftUI

// MARK: - Enumerations used by the HUD panel

enum HUDDateFormat: String, Codable, CaseIterable, Identifiable {
    case auto, us, eu, iso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "AUTO"
        case .us: return "US"
        case .eu: return "EU"
        case .iso: return "ISO"
        }
    }

    func string(from date: Date) -> String {
        switch self {
        case .auto:
            // The weekday is drawn separately, so the date itself omits it.
            return date.formatted(.dateTime.month(.defaultDigits).day().year())
        case .us:
            return Self.fixed("MM/dd/yyyy").string(from: date)
        case .eu:
            return Self.fixed("dd/MM/yyyy").string(from: date)
        case .iso:
            return Self.fixed("yyyy-MM-dd").string(from: date)
        }
    }

    /// Weekday prefix shown ahead of the date, matching the in-video stamp.
    func weekday(from date: Date) -> String {
        Self.fixed("EEE").string(from: date).uppercased()
    }

    private static var cache: [String: DateFormatter] = [:]

    private static func fixed(_ format: String) -> DateFormatter {
        if let existing = cache[format] { return existing }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        cache[format] = formatter
        return formatter
    }
}

enum HUDCorner: String, Codable, CaseIterable, Identifiable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeading: return "Top Left"
        case .topTrailing: return "Top Right"
        case .bottomLeading: return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        }
    }

    var symbolName: String {
        switch self {
        case .topLeading: return "arrow.up.left.square"
        case .topTrailing: return "arrow.up.right.square"
        case .bottomLeading: return "arrow.down.left.square"
        case .bottomTrailing: return "arrow.down.right.square"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

/// The map popover's **Theme** chip.
enum MapTheme: String, Codable, CaseIterable, Identifiable {
    case dark, light, satellite

    var id: String { rawValue }

    /// Shown inside the value chip, e.g. `DARK`.
    var chipLabel: String { rawValue.uppercased() }

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .satellite: return "Satellite"
        }
    }
}

/// The map popover's **Rotation** chip: follow the car's heading, or keep north up.
enum MapRotation: String, Codable, CaseIterable, Identifiable {
    case heading, northUp

    var id: String { rawValue }

    var chipLabel: String {
        switch self {
        case .heading: return "HEADING"
        case .northUp: return "NORTH UP"
        }
    }

    var followsHeading: Bool { self == .heading }
}

/// The map popover's **Size** segments.
enum MapSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var chipLabel: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    /// Multiplier applied to the mini map's base width.
    var scale: CGFloat {
        switch self {
        case .small: return 0.78
        case .medium: return 1.0
        case .large: return 1.32
        }
    }
}

enum MapTrackStyle: String, Codable, CaseIterable, Identifiable {
    case full, traveled, hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Whole Route"
        case .traveled: return "Traveled Only"
        case .hidden: return "Hidden"
        }
    }
}

// MARK: - Configuration

/// Every toggle in the HUD and Map popovers. Persisted as JSON in `UserDefaults`
/// so the export renderer and the live overlay always agree.
struct HUDConfiguration: Codable, Equatable {
    // Master switches
    var enabled: Bool = true

    // Elements
    var speedometer: Bool = true
    var pedals: Bool = true
    var steeringWheel: Bool = true
    var gearSelector: Bool = true
    var autopilot: Bool = true
    var gForceIndicator: Bool = true
    var date: Bool = true
    var time: Bool = true
    var location: Bool = false
    var turnSignals: Bool = true
    var compassCoords: Bool = false

    // Units
    var showKMH: Bool = true
    var showMPH: Bool = true
    var showMS: Bool = false
    var speedDecimals: Int = 0
    var dateFormat: HUDDateFormat = .auto

    // Presentation
    var opacity: Double = 0.9
    var scale: Double = 1.0
    var watermark: Bool = true

    // Map — the six rows of the Map popover…
    var mapEnabled: Bool = true
    var mapTheme: MapTheme = .dark
    var mapRotation: MapRotation = .heading
    /// Standard slippy-map zoom level; converted to a metric span for the
    /// vector mini map and to a region span for the interactive map.
    var mapZoomLevel: Double = 15
    var mapSize: MapSize = .small
    /// Frame the whole drive instead of staying centred on the car.
    var mapRouteOverview: Bool = false

    // …plus the extras, which live in Settings → HUD rather than the popover.
    var mapCorner: HUDCorner = .topTrailing
    var mapTrackStyle: MapTrackStyle = .full
    var mapShowEndpoints: Bool = true
    var mapOpacity: Double = 0.95
    var mapShowLabel: Bool = true
    var mapIncludeInExport: Bool = true

    /// Metres covered across `pixelWidth` points at the configured zoom level.
    func mapSpanMeters(atLatitude latitude: Double, pixelWidth: CGFloat) -> Double {
        // Web-Mercator ground resolution at 256 px tiles.
        let metersPerPixel = 156_543.03392
            * cos(latitude * .pi / 180)
            / pow(2, mapZoomLevel)
        return max(metersPerPixel * Double(pixelWidth), 40)
    }

    static let `default` = HUDConfiguration()

    /// The element rows drawn in the HUD popover, in the order they appear.
    static let elementOrder: [Element] = [
        .init(id: "speedometer", label: "Speedometer", symbol: "speedometer",
              keyPath: \.speedometer),
        .init(id: "pedals", label: "Pedals", symbol: "waveform.path.ecg",
              keyPath: \.pedals),
        .init(id: "steeringWheel", label: "Steering Wheel", symbol: "steeringwheel",
              keyPath: \.steeringWheel),
        .init(id: "gearSelector", label: "Gear Selector", symbol: "rectangle.split.3x1",
              keyPath: \.gearSelector),
        .init(id: "autopilot", label: "Autopilot/FSD", symbol: "bolt.fill",
              keyPath: \.autopilot),
        .init(id: "gForce", label: "G-Force Indicator", symbol: "waveform.path.ecg",
              keyPath: \.gForceIndicator),
        .init(id: "date", label: "Date", symbol: "textformat", keyPath: \.date),
        .init(id: "time", label: "Time", symbol: "textformat", keyPath: \.time),
        .init(id: "location", label: "Location", symbol: "mappin.and.ellipse",
              keyPath: \.location),
        .init(id: "turnSignals", label: "Turn Signals", symbol: "arrow.triangle.branch",
              keyPath: \.turnSignals),
        .init(id: "compass", label: "Compass & Coords", symbol: "location.circle",
              keyPath: \.compassCoords)
    ]

    static let unitOrder: [Element] = [
        .init(id: "kmh", label: "KM/H", symbol: "gauge.with.dots.needle.bottom.50percent",
              keyPath: \.showKMH),
        .init(id: "mph", label: "MPH", symbol: "gauge.with.dots.needle.bottom.50percent",
              keyPath: \.showMPH),
        .init(id: "ms", label: "M/S", symbol: "gauge.with.dots.needle.bottom.50percent",
              keyPath: \.showMS)
    ]

    struct Element: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let keyPath: WritableKeyPath<HUDConfiguration, Bool>
    }

    /// Turns on every element row (the "Show All" action in the popover header).
    mutating func showAllElements() {
        for element in Self.elementOrder {
            self[keyPath: element.keyPath] = true
        }
    }

    var allElementsShown: Bool {
        Self.elementOrder.allSatisfy { self[keyPath: $0.keyPath] }
    }

    /// At least one speed unit must stay on, otherwise the readout vanishes.
    var anySpeedUnit: Bool { showKMH || showMPH || showMS }
}

// MARK: - Persistence

@MainActor
final class HUDStore: ObservableObject {
    static let shared = HUDStore()

    private static let defaultsKey = "hudConfiguration"

    @Published var config: HUDConfiguration {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(HUDConfiguration.self, from: data) {
            config = decoded
        } else {
            config = .default
        }
    }

    func reset() {
        config = .default
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
