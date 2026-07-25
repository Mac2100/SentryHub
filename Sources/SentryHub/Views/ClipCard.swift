import AppKit
import SwiftUI

/// One clip in the gallery: poster frame, category badge, and the metadata rows.
struct ClipCard: View {
    let clip: Clip
    let density: GalleryDensity
    let onOpen: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var poster: NSImage?
    @State private var previewCamera: CameraAngle?
    @State private var isHovering = false

    private var cameras: [CameraAngle] { clip.orderedCameras }

    private var thumbnailHeight: CGFloat {
        switch density {
        case .compact: return 132
        case .regular: return 186
        case .large: return 252
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            details
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHovering ? theme.primary.opacity(0.45) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .task(id: previewCamera) { await loadPoster() }
        .contextMenu {
            Button("Open in Player", action: onOpen)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([clip.directory])
            }
            if let coordinate = clip.coordinate {
                Button("Open Location in Maps") {
                    let url = URL(
                        string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(clip.name)"
                    )
                    if let url { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    // MARK: - Thumbnail

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color.black)

            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
            }

            VStack {
                HStack(spacing: 6) {
                    categoryBadge
                    durationChip
                    Spacer()
                }
                Spacer()
                if cameras.count > 1 {
                    HStack {
                        Spacer()
                        Button {
                            advancePreview()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        .buttonStyle(.plain)
                        .help("Preview the next camera")
                    }
                }
            }
            .padding(8)

            if let previewCamera {
                Text(previewCamera.shortLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)
            }
        }
        .frame(height: thumbnailHeight)
        .frame(maxWidth: .infinity)
        .clipShape(
            .rect(topLeadingRadius: 13, bottomLeadingRadius: 0,
                  bottomTrailingRadius: 0, topTrailingRadius: 13)
        )
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private var categoryBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: clip.category.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(clip.category.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(badgeColor.opacity(0.85)))
    }

    private var badgeColor: Color {
        switch clip.category {
        case .sentry: return Color(red: 0.72, green: 0.14, blue: 0.25)
        case .saved: return Color(red: 0.14, green: 0.45, blue: 0.72)
        case .recent: return Color(red: 0.30, green: 0.32, blue: 0.38)
        }
    }

    private var durationChip: some View {
        Text(Format.duration(clip.duration))
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.5)))
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(clip.name)
                    .font(.system(size: density == .compact ? 14 : 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .fixedSize()
            }

            Text(clip.startDate.formatted(date: .long, time: .omitted))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            metaRow(
                symbol: "calendar",
                text: "\(clip.startDate.formatted(.dateTime.month(.abbreviated).day())) · \(clip.startDate.formatted(date: .omitted, time: .shortened))"
            )

            if let coordinate = clip.coordinate {
                metaRow(
                    symbol: "mappin.and.ellipse",
                    text: Format.coordinate(
                        latitude: coordinate.latitude, longitude: coordinate.longitude
                    )
                )
            } else if let city = clip.city {
                metaRow(symbol: "building.2", text: city)
            }

            if let reason = clip.event?.reasonLabel {
                metaRow(symbol: "exclamationmark.bubble", text: reason)
            }

            HStack(spacing: 6) {
                infoChip(Format.bytes(clip.byteCount))
                infoChip(clip.name)
                    .lineLimit(1)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private func metaRow(symbol: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 13)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func infoChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }

    // MARK: - Behaviour

    private func advancePreview() {
        guard !cameras.isEmpty else { return }
        let current = previewCamera ?? cameras.first
        let index = current.flatMap { cameras.firstIndex(of: $0) } ?? 0
        previewCamera = cameras[(index + 1) % cameras.count]
    }

    private func loadPoster() async {
        let image = await ThumbnailService.shared.image(for: clip, camera: previewCamera)
        await MainActor.run { poster = image }
    }
}
