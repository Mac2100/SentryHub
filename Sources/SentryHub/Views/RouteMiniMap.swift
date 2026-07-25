import CoreLocation
import SwiftUI

/// The small MAP card in the HUD.
///
/// Deliberately vector-drawn rather than tile-backed: it renders identically in
/// the live overlay and inside the export renderer, costs nothing to redraw as
/// the play head moves, and matches the stylised look of the reference design.
/// The full tile-backed map lives behind the transport bar's **Map** button.
struct RouteMiniMap: View {
    let route: [CLLocationCoordinate2D]
    let position: CLLocationCoordinate2D?
    let heading: Double?
    let progress: Double
    let config: HUDConfiguration
    /// Scales every stroke and radius with the HUD.
    var unit: CGFloat = 1

    private var palette: Palette {
        switch config.mapStyle {
        case .standard:
            return Palette(
                background: Color(red: 0.06, green: 0.09, blue: 0.15),
                grid: Color.white.opacity(0.06),
                route: Color(red: 0.35, green: 0.72, blue: 1.0),
                traveled: Color(red: 0.20, green: 0.55, blue: 1.0)
            )
        case .hybrid:
            return Palette(
                background: Color(red: 0.10, green: 0.12, blue: 0.09),
                grid: Color.white.opacity(0.05),
                route: Color(red: 0.62, green: 0.90, blue: 0.70),
                traveled: Color(red: 0.30, green: 0.78, blue: 0.52)
            )
        case .satellite:
            return Palette(
                background: Color(red: 0.09, green: 0.08, blue: 0.07),
                grid: Color.white.opacity(0.04),
                route: Color(red: 1.0, green: 0.83, blue: 0.42),
                traveled: Color(red: 1.0, green: 0.66, blue: 0.20)
            )
        }
    }

    private struct Palette {
        let background: Color
        let grid: Color
        let route: Color
        let traveled: Color
    }

    var body: some View {
        GeometryReader { geometry in
            let box = geometry.size
            let points = projected(into: box)
            let colors = palette

            ZStack {
                RoundedRectangle(cornerRadius: 9 * unit, style: .continuous)
                    .fill(colors.background)

                // Faint graticule so an empty card still reads as a map.
                Path { path in
                    let steps = 4
                    for index in 1..<steps {
                        let x = box.width * CGFloat(index) / CGFloat(steps)
                        let y = box.height * CGFloat(index) / CGFloat(steps)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: box.height))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: box.width, y: y))
                    }
                }
                .stroke(colors.grid, lineWidth: 0.75 * unit)

                if points.count > 1, config.mapTrackStyle != .hidden {
                    if config.mapTrackStyle == .full {
                        line(points)
                            .stroke(
                                colors.route.opacity(0.45),
                                style: StrokeStyle(lineWidth: 2.6 * unit, lineCap: .round,
                                                   lineJoin: .round)
                            )
                    }
                    let travelledCount = max(2, Int(Double(points.count) * min(max(progress, 0), 1)))
                    line(Array(points.prefix(travelledCount)))
                        .stroke(
                            colors.traveled,
                            style: StrokeStyle(lineWidth: 2.6 * unit, lineCap: .round,
                                               lineJoin: .round)
                        )
                }

                if config.mapShowEndpoints, points.count > 1 {
                    Circle()
                        .fill(Color(red: 0.30, green: 0.85, blue: 0.45))
                        .frame(width: 6 * unit, height: 6 * unit)
                        .position(points[points.count - 1])
                }

                if let marker = currentPoint(points) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.20, green: 0.55, blue: 1.0))
                            .frame(width: 15 * unit, height: 15 * unit)
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 8 * unit, weight: .bold))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(config.mapRotateWithHeading ? 0 : (heading ?? 0)))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 2 * unit)
                    .position(marker)
                }

                if points.isEmpty {
                    Text("NO GPS")
                        .font(.system(size: 8 * unit, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.4))
                }

                if config.mapShowLabel {
                    Text("MAP")
                        .font(.system(size: 8 * unit, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 5 * unit)
                        .padding(.vertical, 2 * unit)
                        .background(
                            RoundedRectangle(cornerRadius: 4 * unit, style: .continuous)
                                .fill(Color.black.opacity(0.45))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(5 * unit)
                }
            }
            .rotationEffect(
                config.mapRotateWithHeading ? .degrees(-(heading ?? 0)) : .zero
            )
            .clipShape(RoundedRectangle(cornerRadius: 9 * unit, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9 * unit, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1 * unit)
            )
        }
        .opacity(config.mapOpacity)
    }

    private func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func currentPoint(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let index = Int((Double(points.count - 1) * min(max(progress, 0), 1)).rounded())
        return points[min(max(index, 0), points.count - 1)]
    }

    /// Equirectangular projection of the route into the card, centred on the
    /// current position and scaled by the configured zoom.
    private func projected(into box: CGSize) -> [CGPoint] {
        guard !route.isEmpty else { return [] }

        let center = position ?? route[route.count / 2]
        let latitudeRadians = center.latitude * .pi / 180
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude * max(cos(latitudeRadians), 0.01)

        // Fit the route, but never zoom in past the configured span.
        var spanMeters = config.mapZoomMeters
        var maxDistance = 0.0
        for coordinate in route {
            let dx = (coordinate.longitude - center.longitude) * metersPerDegreeLongitude
            let dy = (coordinate.latitude - center.latitude) * metersPerDegreeLatitude
            maxDistance = max(maxDistance, max(abs(dx), abs(dy)))
        }
        if maxDistance > 0 {
            spanMeters = min(spanMeters, maxDistance * 2.4)
        }
        spanMeters = max(spanMeters, 60)

        let inset = 10 * unit
        let usable = min(box.width, box.height) - inset * 2
        guard usable > 0 else { return [] }
        let scale = usable / spanMeters

        return route.map { coordinate in
            let dx = (coordinate.longitude - center.longitude) * metersPerDegreeLongitude
            let dy = (coordinate.latitude - center.latitude) * metersPerDegreeLatitude
            return CGPoint(
                x: box.width / 2 + dx * scale,
                y: box.height / 2 - dy * scale
            )
        }
    }
}
