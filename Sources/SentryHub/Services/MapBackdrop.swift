import AppKit
import CoreLocation
import Foundation
import MapKit

/// A rendered map tile image plus the region it covers.
///
/// The HUD's mini map is vector-drawn so it can be rasterised for export, but a
/// bare vector card looks empty for the common case — a TeslaCam clip whose only
/// telemetry is the single fix in `event.json`, which has no route to draw. So a
/// real map is snapshotted once per clip and used as the backdrop, with the
/// route and marker drawn over it.
struct MapBackdrop: Equatable {
    let image: CGImage
    let region: MKCoordinateRegion

    static func == (lhs: MapBackdrop, rhs: MapBackdrop) -> Bool {
        lhs.image === rhs.image
            && lhs.region.center.latitude == rhs.region.center.latitude
            && lhs.region.center.longitude == rhs.region.center.longitude
            && lhs.region.span.latitudeDelta == rhs.region.span.latitudeDelta
    }

    /// Projects a coordinate into a unit square (0…1, y down) of this region.
    func unitPoint(for coordinate: CLLocationCoordinate2D) -> CGPoint {
        let spanLat = max(region.span.latitudeDelta, 0.000001)
        let spanLon = max(region.span.longitudeDelta, 0.000001)
        let x = (coordinate.longitude - region.center.longitude) / spanLon + 0.5
        let y = 0.5 - (coordinate.latitude - region.center.latitude) / spanLat
        return CGPoint(x: x, y: y)
    }
}

@MainActor
enum MapBackdropRenderer {
    private static var cache: [String: MapBackdrop] = [:]

    /// The region to snapshot for a clip: the route's bounding box when there is
    /// one, otherwise a fixed span around the single fix.
    static func region(
        route: [CLLocationCoordinate2D],
        fallback: CLLocationCoordinate2D?,
        zoomLevel: Double
    ) -> MKCoordinateRegion? {
        if route.count > 1 {
            var minLat = route[0].latitude, maxLat = route[0].latitude
            var minLon = route[0].longitude, maxLon = route[0].longitude
            for point in route {
                minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
                minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
            }
            let center = CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2
            )
            // Pad so the route doesn't touch the card's edges.
            let span = MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.5, 0.0015),
                longitudeDelta: max((maxLon - minLon) * 1.5, 0.0015)
            )
            return MKCoordinateRegion(center: center, span: span)
        }

        guard let fallback = route.first ?? fallback else { return nil }
        // A single fix has no extent, so the zoom slider decides the span.
        let metres = 156_543.03392 * cos(fallback.latitude * .pi / 180) / pow(2, zoomLevel) * 320
        let degrees = max(metres, 120) / 111_320
        return MKCoordinateRegion(
            center: fallback,
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    /// Renders (and caches) the backdrop. Returns `nil` when MapKit can't
    /// produce one — the mini map then falls back to its vector-only look.
    static func backdrop(
        region: MKCoordinateRegion,
        theme: MapTheme,
        pixelSize: CGSize
    ) async -> MapBackdrop? {
        let key = String(
            format: "%.5f,%.5f,%.5f,%@,%.0fx%.0f",
            region.center.latitude, region.center.longitude,
            region.span.latitudeDelta, theme.rawValue,
            pixelSize.width, pixelSize.height
        )
        if let cached = cache[key] { return cached }

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = pixelSize
        options.showsBuildings = true
        switch theme {
        case .dark:
            options.mapType = .standard
            options.appearance = NSAppearance(named: .darkAqua)
        case .light:
            options.mapType = .standard
            options.appearance = NSAppearance(named: .aqua)
        case .satellite:
            options.mapType = .satellite
        }

        let snapshotter = MKMapSnapshotter(options: options)
        let image: NSImage? = await withCheckedContinuation { continuation in
            snapshotter.start(with: .global(qos: .userInitiated)) { snapshot, _ in
                continuation.resume(returning: snapshot?.image)
            }
        }
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let backdrop = MapBackdrop(image: cgImage, region: region)
        if cache.count > 40 { cache.removeAll(keepingCapacity: true) }
        cache[key] = backdrop
        return backdrop
    }
}
