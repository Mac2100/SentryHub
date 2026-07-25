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
    /// Real map tiles under the route. Without one the card is vector-only,
    /// which reads as empty for a clip whose only fix is from `event.json`.
    var backdrop: MapBackdrop?
    /// Scales every stroke and radius with the HUD.
    var unit: CGFloat = 1

    /// Whether the car actually moved, as far as the recorded fixes know.
    private var hasRoute: Bool { route.describesRoute }

    private var palette: Palette {
        switch config.mapTheme {
        case .dark:
            return Palette(
                background: Color(red: 0.06, green: 0.09, blue: 0.15),
                grid: Color.white.opacity(0.06),
                route: Color(red: 0.35, green: 0.72, blue: 1.0),
                traveled: Color(red: 0.20, green: 0.55, blue: 1.0),
                ink: Color.white
            )
        case .light:
            return Palette(
                background: Color(red: 0.90, green: 0.92, blue: 0.95),
                grid: Color.black.opacity(0.07),
                route: Color(red: 0.30, green: 0.55, blue: 0.90),
                traveled: Color(red: 0.10, green: 0.38, blue: 0.85),
                ink: Color.black
            )
        case .satellite:
            return Palette(
                background: Color(red: 0.09, green: 0.08, blue: 0.07),
                grid: Color.white.opacity(0.04),
                route: Color(red: 1.0, green: 0.83, blue: 0.42),
                traveled: Color(red: 1.0, green: 0.66, blue: 0.20),
                ink: Color.white
            )
        }
    }

    private struct Palette {
        let background: Color
        let grid: Color
        let route: Color
        let traveled: Color
        /// Foreground colour for the label and the "no GPS" notice.
        let ink: Color
    }

    var body: some View {
        GeometryReader { geometry in
            let box = geometry.size
            let points = projected(into: box)
            let colors = palette

            ZStack {
                RoundedRectangle(cornerRadius: 9 * unit, style: .continuous)
                    .fill(colors.background)

                if let backdrop {
                    Image(decorative: backdrop.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: box.width, height: box.height)
                        .clipped()
                }

                // Faint graticule, only when there are no tiles to sit on.
                if backdrop == nil {
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
                }

                if hasRoute, points.count > 1, config.mapTrackStyle != .hidden {
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

                if config.mapShowEndpoints, hasRoute, points.count > 1 {
                    Circle()
                        .fill(Color(red: 0.30, green: 0.85, blue: 0.45))
                        .frame(width: 6 * unit, height: 6 * unit)
                        .position(points[points.count - 1])
                }

                if hasRoute, points.count > 1, let marker = currentPoint(points) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.20, green: 0.55, blue: 1.0))
                            .frame(width: 15 * unit, height: 15 * unit)
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 8 * unit, weight: .bold))
                            .foregroundStyle(.white)
                            .rotationEffect(
                                .degrees(config.mapRotation.followsHeading ? 0 : (heading ?? 0))
                            )
                    }
                    .shadow(color: .black.opacity(0.4), radius: 2 * unit)
                    .position(marker)
                }

                if points.isEmpty {
                    Text("NO GPS")
                        .font(.system(size: 8 * unit, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(colors.ink.opacity(0.45))
                } else if !hasRoute, let only = points.first {
                    // A single event.json fix, however many times it was repeated:
                    // a pin says more than a bare dot, and there is no car to
                    // move along a route that was never recorded.
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 16 * unit))
                        .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.30))
                        .shadow(color: .black.opacity(0.5), radius: 2 * unit)
                        .position(only)
                }

                if config.mapShowLabel {
                    Text("MAP")
                        .font(.system(size: 8 * unit, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(colors.ink.opacity(0.75))
                        .padding(.horizontal, 5 * unit)
                        .padding(.vertical, 2 * unit)
                        .background(
                            RoundedRectangle(cornerRadius: 4 * unit, style: .continuous)
                                .fill(colors.background.opacity(0.75))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(5 * unit)
                }
            }
            .rotationEffect(
                config.mapRotation.followsHeading ? .degrees(-(heading ?? 0)) : .zero
            )
            .clipShape(RoundedRectangle(cornerRadius: 9 * unit, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9 * unit, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1 * unit)
            )
        }
        .opacity(config.mapOpacity)
    }

    static func centroid(of route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !route.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let latitude = route.reduce(0) { $0 + $1.latitude } / Double(route.count)
        let longitude = route.reduce(0) { $0 + $1.longitude } / Double(route.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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

    /// Equirectangular projection of the route into the card.
    ///
    /// Normally the card stays centred on the car at the configured zoom level;
    /// with **Route Overview** on it centres on the route and zooms out far
    /// enough to frame the whole drive.
    private func projected(into box: CGSize) -> [CGPoint] {
        guard !route.isEmpty else { return [] }

        let inset = 10 * unit
        let usable = min(box.width, box.height) - inset * 2
        guard usable > 0 else { return [] }

        // With tiles underneath, the overlay must use the snapshot's own region
        // or the route would float away from the roads it's drawn on.
        if let backdrop {
            return route.map { coordinate in
                let unitPoint = backdrop.unitPoint(for: coordinate)
                return CGPoint(x: unitPoint.x * box.width, y: unitPoint.y * box.height)
            }
        }

        let center = config.mapRouteOverview
            ? RouteMiniMap.centroid(of: route)
            : (position ?? route[route.count / 2])
        let latitudeRadians = center.latitude * .pi / 180
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude * max(cos(latitudeRadians), 0.01)

        var maxDistance = 0.0
        for coordinate in route {
            let dx = (coordinate.longitude - center.longitude) * metersPerDegreeLongitude
            let dy = (coordinate.latitude - center.latitude) * metersPerDegreeLatitude
            maxDistance = max(maxDistance, max(abs(dx), abs(dy)))
        }

        var spanMeters: Double
        if config.mapRouteOverview {
            spanMeters = max(maxDistance * 2.3, 60)
        } else {
            spanMeters = config.mapSpanMeters(atLatitude: center.latitude, pixelWidth: usable)
            // Don't zoom out past the route itself — an empty card reads as broken.
            if maxDistance > 0 {
                spanMeters = min(spanMeters, maxDistance * 2.4)
            }
            spanMeters = max(spanMeters, 60)
        }

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
