import AppKit
import SwiftUI

/// One clip as a row. The grid is for recognising footage by sight; the list is
/// for scanning a few hundred clips by their facts — when, what, how big, and
/// whether you actually have it.
struct ClipRow: View {
    let clip: Clip
    let density: GalleryDensity
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}
    let onOpen: () -> Void

    @Environment(\.appTheme) private var theme
    @ObservedObject private var labels = ClipLabels.shared
    @ObservedObject private var incidents = IncidentStore.shared
    @State private var poster: CGImage?
    @State private var isHovering = false

    private var thumbnailWidth: CGFloat { density.listThumbnailWidth }
    private var thumbnailHeight: CGFloat { thumbnailWidth * 9 / 16 }

    private var showsSelectionToggle: Bool {
        isSelected || isSelecting || isHovering
    }

    var body: some View {
        HStack(spacing: 12) {
            // Always laid out so the columns never shift, but only drawn under
            // the pointer — or on every row at once, once anything is selected.
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? theme.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .opacity(showsSelectionToggle ? 1 : 0)
            .allowsHitTesting(showsSelectionToggle)
            .frame(width: 20)

            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(labels.title(for: clip))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(clip.startDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    Text("·")
                    Text(clip.startDate.formatted(date: .omitted, time: .shortened))
                    if let city = clip.city {
                        Text("·")
                        Text(city).lineLimit(1)
                    }
                    if let incident = incidents.incidents(containing: clip.id).first {
                        Text("·")
                        Label(incident.title, systemImage: "folder.badge.person.crop")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            eventCell.frame(width: 108, alignment: .leading)
            storageCell.frame(width: 96, alignment: .leading)

            Label("\(clip.orderedCameras.count)", systemImage: "video")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)

            Text(Format.duration(clip.duration))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            Text(Format.bytes(clip.byteCount))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? theme.primary.opacity(0.6) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { onToggleSelection() } else { onOpen() }
        }
        .onHover { isHovering = $0 }
        .task { await loadPoster() }
        .contextMenu {
            Button("Open in Player", action: onOpen)
            Button(isSelected ? "Deselect" : "Select", action: onToggleSelection)
            Divider()
            if clip.storage.isSavedLocally {
                Button("Remove from This Mac") {
                    Task { await LocalLibrary.shared.remove([clip.id]) }
                }
            } else {
                Button("Save to This Mac") {
                    Task {
                        guard let drive = AppState.shared.library.driveCopy(of: clip.id) else { return }
                        await LocalLibrary.shared.save([drive])
                    }
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([clip.directory])
            }
        }
    }

    private var rowFill: Color {
        if isSelected { return theme.primary.opacity(0.14) }
        return Color.primary.opacity(isHovering ? 0.07 : 0.035)
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let poster {
                // Same reason as the card: a `.fill` image would otherwise size
                // the stack and push the row's height around.
                Color.clear
                    .overlay {
                        Image(decorative: poster, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var eventCell: some View {
        Group {
            if let trigger = clip.trigger {
                tag(trigger.label, symbol: trigger.symbolName, tint: triggerTint(trigger))
            } else if let reason = clip.event?.reasonLabel {
                tag(reason, symbol: "diamond.fill", tint: .secondary)
            } else {
                // Nothing happened — this is the car recording as it drives. The
                // folder it came from is not an answer to "what event?".
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private var storageCell: some View {
        tag(
            clip.storage.shortLabel,
            symbol: clip.storage.symbolName,
            tint: clip.storage.isSavedLocally
                ? Color(red: 0.13, green: 0.55, blue: 0.40)
                : Color(red: 0.62, green: 0.45, blue: 0.10)
        )
        .help(clip.storage.label)
    }

    private func tag(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(0.13))
        )
    }

    private func triggerTint(_ trigger: ClipTrigger) -> Color {
        switch trigger {
        case .motion: return Color(red: 0.62, green: 0.42, blue: 0.10)
        case .impact: return Color(red: 0.78, green: 0.22, blue: 0.14)
        case .honk: return Color(red: 0.46, green: 0.30, blue: 0.72)
        case .manualSave: return Color(red: 0.16, green: 0.46, blue: 0.44)
        }
    }

    private func loadPoster() async {
        guard poster == nil else { return }
        poster = await ThumbnailService.shared.image(for: clip, camera: nil)
    }
}

/// Column captions for the list, so the right-hand figures are readable as
/// columns rather than as a row of unlabelled numbers.
struct ClipListHeader: View {
    let isSelecting: Bool
    let thumbnailWidth: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 20)
            Color.clear.frame(width: thumbnailWidth, height: 1)
            caption("CLIP")
            Spacer(minLength: 8)
            caption("EVENT").frame(width: 108, alignment: .leading)
            caption("STORAGE").frame(width: 96, alignment: .leading)
            caption("CAMS").frame(width: 46, alignment: .leading)
            caption("LENGTH").frame(width: 56, alignment: .trailing)
            caption("SIZE").frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1)
            .foregroundStyle(.tertiary)
    }
}
