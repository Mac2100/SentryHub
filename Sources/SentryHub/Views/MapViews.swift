import CoreLocation
import MapKit
import SwiftUI

extension MapTheme {
    var mapStyle: MapStyle {
        switch self {
        case .dark, .light: return .standard(elevation: .realistic)
        case .satellite: return .imagery
        }
    }

    /// MapKit renders the standard style light or dark from the environment's
    /// colour scheme, so the theme drives that rather than the style itself.
    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }
}

/// Library map mode: every GPS-tagged clip as a pin, click to open it.
struct LibraryMapView: View {
    let clips: [Clip]
    let onOpen: (Clip) -> Void

    @State private var position: MapCameraPosition = .automatic
    @State private var selected: Clip.ID?
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $position, selection: $selected) {
                ForEach(clips) { clip in
                    if let coordinate = clip.coordinate {
                        Marker(
                            clip.city ?? clip.name,
                            systemImage: clip.category.symbolName,
                            coordinate: CLLocationCoordinate2D(
                                latitude: coordinate.latitude, longitude: coordinate.longitude
                            )
                        )
                        .tint(markerTint(clip.category))
                        .tag(clip.id as Clip.ID?)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapZoomStepper()
            }

            if clips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("None of these clips carry GPS data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }

            if let selected, let clip = clips.first(where: { $0.id == selected }) {
                selectionCard(clip)
                    .padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func markerTint(_ category: ClipCategory) -> Color {
        switch category {
        case .sentry: return Color(red: 0.80, green: 0.18, blue: 0.28)
        case .saved: return Color(red: 0.14, green: 0.48, blue: 0.86)
        case .recent: return Color(red: 0.42, green: 0.44, blue: 0.50)
        }
    }

    private func selectionCard(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(clip.name)
                .font(.system(size: 13, weight: .semibold))
            Text(clip.startDate.briefFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let city = clip.city {
                Label(city, systemImage: "building.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open in Player") { onOpen(clip) }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .controlSize(.small)
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// The player's interactive route map, opened from the transport bar's
/// **Map** button. Unlike the HUD's vector mini map this one is tile-backed and
/// pannable, and its marker tracks the play head.
struct RouteMapView: View {
    let route: [CLLocationCoordinate2D]
    let current: CLLocationCoordinate2D?
    let heading: Double?
    let config: HUDConfiguration

    @State private var position: MapCameraPosition = .automatic

    /// Route Overview frames the whole drive; otherwise the camera follows the
    /// play head at the configured zoom level.
    private var followsCar: Bool { !config.mapRouteOverview }

    private var regionSpanMeters: Double {
        config.mapSpanMeters(
            atLatitude: current?.latitude ?? route.first?.latitude ?? 0,
            pixelWidth: 460
        )
    }

    var body: some View {
        Map(position: $position) {
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(
                        Color(red: 0.25, green: 0.62, blue: 1.0),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
            }
            if config.mapShowEndpoints, let first = route.first {
                Marker("Start", systemImage: "flag.fill", coordinate: first)
                    .tint(.green)
            }
            if config.mapShowEndpoints, route.count > 1, let last = route.last {
                Marker("End", systemImage: "flag.checkered", coordinate: last)
                    .tint(.orange)
            }
            if let current {
                Annotation("", coordinate: current) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.20, green: 0.55, blue: 1.0))
                            .frame(width: 22, height: 22)
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(heading ?? 0))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 3)
                }
            }
        }
        .mapStyle(config.mapTheme.mapStyle)
        .environment(\.colorScheme, config.mapTheme.colorScheme)
        .mapControls {
            MapCompass()
            MapZoomStepper()
        }
        .overlay(alignment: .topLeading) {
            Label(
                config.mapRouteOverview ? "Route Overview" : "Following",
                systemImage: config.mapRouteOverview ? "point.topleft.down.curvedto.point.bottomright.up" : "location.fill"
            )
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
        .onChange(of: currentKey) { _, _ in recentre() }
        .onChange(of: config.mapRouteOverview) { _, _ in recentre() }
        .onChange(of: config.mapZoomLevel) { _, _ in recentre() }
        .onAppear { recentre() }
        .overlay {
            if route.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("This clip has no GPS data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Drop a telemetry.json next to the clip to add a route.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
    }

    private func recentre() {
        guard followsCar, let current else {
            // .automatic frames all the map's content, i.e. the whole route.
            withAnimation(.easeInOut(duration: 0.3)) { position = .automatic }
            return
        }
        let span = regionSpanMeters
        withAnimation(.easeInOut(duration: 0.3)) {
            position = .region(
                MKCoordinateRegion(
                    center: current,
                    latitudinalMeters: span,
                    longitudinalMeters: span
                )
            )
        }
    }

    /// Cheap change key so the camera only re-centres when the pin really moves.
    private var currentKey: String {
        guard let current else { return "none" }
        return String(format: "%.5f,%.5f", current.latitude, current.longitude)
    }
}
