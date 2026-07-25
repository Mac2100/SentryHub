import CoreGraphics
import Foundation

/// Single source of truth for where each camera tile sits.
///
/// The live grid and the exporter both lay out from this, so what you see in
/// the player is what lands in the exported file.
enum TileLayoutEngine {
    struct Tile: Identifiable {
        let id: Int
        let camera: CameraAngle?
        /// Top-left origin, in the coordinate space of the passed-in size.
        let rect: CGRect
    }

    private struct Row {
        let weight: CGFloat
        let cameras: [CameraAngle?]
    }

    private static func rows(
        layout: CameraLayout, focused: CameraAngle, available: Set<CameraAngle>
    ) -> [Row] {
        switch layout {
        case .single:
            return [Row(weight: 1, cameras: [focused])]
        case .dual:
            let partner = CameraAngle.preferredFocusOrder.first {
                $0 != focused && available.contains($0)
            }
            return [Row(weight: 1, cameras: [focused, partner])]
        case .cinema:
            let others = CameraAngle.sixUpOrder.filter { $0 != focused && available.contains($0) }
            let strip: [CameraAngle?] = others.prefix(3).map { $0 }
            if strip.isEmpty {
                return [Row(weight: 1, cameras: [focused])]
            }
            return [
                Row(weight: 0.68, cameras: [focused]),
                Row(weight: 0.32, cameras: strip)
            ]
        case .quad:
            var order = CameraAngle.quadOrder
            if !order.contains(focused) { order[0] = focused }
            return [
                Row(weight: 0.5, cameras: [order[0], order[1]]),
                Row(weight: 0.5, cameras: [order[2], order[3]])
            ]
        case .six:
            // The full 3×2 grid, arranged like the cameras on the car. Angles the
            // vehicle didn't record stay as labelled placeholders.
            let all = CameraAngle.sixUpOrder
            return [
                Row(weight: 0.5, cameras: [all[0], all[1], all[2]]),
                Row(weight: 0.5, cameras: [all[3], all[4], all[5]])
            ]
        }
    }

    static func tiles(
        layout: CameraLayout,
        focused: CameraAngle,
        available: Set<CameraAngle>,
        in size: CGSize,
        spacing: CGFloat = 1
    ) -> [Tile] {
        let rowList = rows(layout: layout, focused: focused, available: available)
        guard !rowList.isEmpty, size.width > 0, size.height > 0 else { return [] }

        let totalWeight = rowList.reduce(0) { $0 + $1.weight }
        let verticalGaps = spacing * CGFloat(max(0, rowList.count - 1))
        let usableHeight = max(0, size.height - verticalGaps)

        var tiles: [Tile] = []
        var y: CGFloat = 0
        var index = 0

        for row in rowList {
            let rowHeight = usableHeight * (row.weight / totalWeight)
            let columns = max(1, row.cameras.count)
            let horizontalGaps = spacing * CGFloat(columns - 1)
            let columnWidth = max(0, size.width - horizontalGaps) / CGFloat(columns)

            for (column, camera) in row.cameras.enumerated() {
                let x = (columnWidth + spacing) * CGFloat(column)
                tiles.append(
                    Tile(
                        id: index,
                        camera: camera,
                        rect: CGRect(x: x, y: y, width: columnWidth, height: rowHeight)
                    )
                )
                index += 1
            }
            y += rowHeight + spacing
        }
        return tiles
    }

    /// Render size for an export: the tile grid at the requested tile height,
    /// rounded to even numbers because H.264 requires it.
    static func renderSize(
        layout: CameraLayout,
        focused: CameraAngle,
        available: Set<CameraAngle>,
        tileSize: CGSize
    ) -> CGSize {
        let rowList = rows(layout: layout, focused: focused, available: available)
        guard !rowList.isEmpty else { return tileSize }

        let columns = rowList.map(\.cameras.count).max() ?? 1
        let width = tileSize.width * CGFloat(columns)

        // Height follows the row weights so a 0.68/0.32 split keeps the big
        // tile at the requested size.
        let maxWeight = rowList.map(\.weight).max() ?? 1
        let height = tileSize.height * (rowList.reduce(0) { $0 + $1.weight } / maxWeight)

        return CGSize(
            width: (width / 2).rounded() * 2,
            height: (height / 2).rounded() * 2
        )
    }
}
