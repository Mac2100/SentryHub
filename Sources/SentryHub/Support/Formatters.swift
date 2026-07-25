import Foundation

enum Format {
    /// `0:30`, `1:04:12`
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// `00:06` — fixed-width form used by the transport bar.
    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: count)
    }

    /// `48.061°, 3.291°`
    static func coordinate(latitude: Double, longitude: Double, decimals: Int = 3) -> String {
        String(format: "%.\(decimals)f°, %.\(decimals)f°", latitude, longitude)
    }

    /// `48.0610° N, 3.2910° E`
    static func coordinateWithHemisphere(latitude: Double, longitude: Double) -> String {
        let ns = latitude >= 0 ? "N" : "S"
        let ew = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), ns, abs(longitude), ew)
    }

    /// Sixteen-point compass abbreviation for a heading in degrees.
    static func compassPoint(_ heading: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        var normalized = heading.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let index = Int((normalized / 22.5).rounded()) % points.count
        return points[index]
    }

    static func speed(_ metersPerSecond: Double, unit: SpeedUnit, decimals: Int) -> String {
        let value = unit.convert(metersPerSecond)
        return String(format: "%.\(max(0, min(2, decimals)))f", value)
    }

    static func gForce(_ value: Double) -> String {
        String(format: "%.2fG", value)
    }
}

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kmh, mph, ms

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kmh: return "KM/H"
        case .mph: return "MPH"
        case .ms: return "M/S"
        }
    }

    func convert(_ metersPerSecond: Double) -> Double {
        switch self {
        case .kmh: return metersPerSecond * 3.6
        case .mph: return metersPerSecond * 2.2369362920544
        case .ms: return metersPerSecond
        }
    }
}
