import AppKit
import SwiftUI

/// One clip in the gallery: poster frame, category badge, and the metadata rows.
struct ClipCard: View {
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
    @State private var previewCamera: CameraAngle?
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var cameras: [CameraAngle] { clip.orderedCameras }

    private var thumbnailHeight: CGFloat {
        switch density {
        case .compact: return 132
        case .regular: return 186
        case .large: return 252
        }
    }

    private var borderColor: Color {
        if isSelected { return theme.primary }
        return isHovering ? theme.primary.opacity(0.45) : Color.primary.opacity(0.08)
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
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if isRenaming {
                commitRename()
            } else if isSelecting {
                onToggleSelection()
            } else {
                onOpen()
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .task(id: previewCamera) { await loadPoster() }
        .contextMenu {
            Button("Open in Player", action: onOpen)
            Button(isSelected ? "Deselect" : "Select", action: onToggleSelection)
            Button("Rename…", action: beginRename)
            if labels.label(for: clip) != nil {
                Button("Restore Original Name") {
                    labels.set(nil, for: clip)
                }
            }
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
                // The picture must not drive the layout. A `.fill` image reports
                // a size larger than the space it was offered, and a ZStack sizes
                // itself to its biggest child — so the badges and the camera
                // button were being positioned against those overflowing bounds
                // and then cut in half by the clip. Handing the image to an
                // overlay keeps the stack the size of the tile.
                Color.clear
                    .overlay {
                        Image(decorative: poster, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
            }

            VStack {
                // The badge answers one question: what happened. A Recent clip
                // is just the car recording as it drives — nothing happened, so
                // it gets no badge rather than one naming the folder it sits in.
                HStack(spacing: 6) {
                    if let trigger = clip.trigger {
                        triggerBadge(trigger)
                    } else if let reason = clip.event?.reasonLabel {
                        // Tesla has shipped reason strings we don't classify. Show
                        // them anyway rather than dropping the badge silently.
                        genericEventBadge(reason)
                    }
                    durationChip
                    Spacer()
                    // Always there: it's how selection starts, so hiding it
                    // behind a mode you can only enter elsewhere defeats it.
                    selectionToggle
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

    /// Hidden until the pointer is over the card, so a quiet gallery stays
    /// quiet. Once anything is selected it shows on every card at once —
    /// otherwise adding the second clip to a selection would mean hunting for
    /// an invisible target.
    private var showsSelectionToggle: Bool {
        isSelected || isSelecting || isHovering
    }

    private var selectionToggle: some View {
        Button(action: onToggleSelection) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.primary : Color.black.opacity(0.35))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : Color.white.opacity(0.75),
                        lineWidth: 1.5
                    )
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(showsSelectionToggle ? 1 : 0)
        .allowsHitTesting(showsSelectionToggle)
        .help(isSelected ? "Deselect this clip" : "Select this clip")
    }

    /// Why the car kept it — the same pill the library filters by.
    private func triggerBadge(_ trigger: ClipTrigger) -> some View {
        HStack(spacing: 4) {
            Image(systemName: trigger.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(trigger.badgeLabel)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(triggerColor(trigger).opacity(0.85)))
    }

    private func genericEventBadge(_ reason: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(reason.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(red: 0.34, green: 0.36, blue: 0.42).opacity(0.9)))
        .help(reason)
    }

    private func triggerColor(_ trigger: ClipTrigger) -> Color {
        switch trigger {
        case .motion: return Color(red: 0.62, green: 0.42, blue: 0.10)
        case .impact: return Color(red: 0.78, green: 0.22, blue: 0.14)
        case .honk: return Color(red: 0.46, green: 0.30, blue: 0.72)
        case .manualSave: return Color(red: 0.16, green: 0.46, blue: 0.44)
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
                title
                Spacer(minLength: 8)
                Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .fixedSize()
            }

            metaRow(
                symbol: "calendar",
                text: "\(clip.startDate.formatted(.dateTime.month(.abbreviated).day().year())) · \(clip.startDate.formatted(date: .omitted, time: .shortened))"
            )

            // Where it happened, in words where the car gave words. Tesla only
            // names a town in event.json, which it doesn't write beside Recent
            // clips — so rather than leaving those cards with a silent gap,
            // fall back to the fix and then to saying there isn't one.
            if let city = clip.city {
                metaRow(symbol: "building.2", text: city)
                    .help(coordinateText ?? city)
            } else if let coordinateText {
                metaRow(symbol: "mappin.and.ellipse", text: coordinateText)
            } else {
                metaRow(symbol: "mappin.slash", text: "No location recorded")
                    .help("The car saved no position with this clip.")
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                infoChip(Format.bytes(clip.byteCount))
                storagePill
            }
            .padding(.top, 2)

            if let incident = incidents.incidents(containing: clip.id).first {
                metaRow(symbol: "folder.badge.person.crop", text: incident.title)
                    .help("Part of the “\(incident.title)” incident")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    /// Click to rename. The label is ours alone — see `ClipLabels`.
    private var title: some View {
        Group {
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: density == .compact ? 14 : 17, weight: .semibold))
                    .focused($nameFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: nameFieldFocused) { _, focused in
                        // Clicking away keeps what was typed rather than
                        // silently throwing it out.
                        if !focused, isRenaming { commitRename() }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.primary.opacity(0.6), lineWidth: 1)
                    )
            } else {
                Button(action: beginRename) {
                    HStack(spacing: 5) {
                        Text(labels.title(for: clip))
                            .font(.system(size: density == .compact ? 14 : 17, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isHovering {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Click to rename — the files on the drive keep their own name")
            }
        }
    }

    /// Whether this footage survives the drive being unplugged — the one thing
    /// about a clip that changes what you'd do next.
    private var storagePill: some View {
        HStack(spacing: 4) {
            Image(systemName: clip.storage.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(clip.storage.shortLabel)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(storageTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(storageTint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(storageTint.opacity(0.35), lineWidth: 1)
        )
        .help(clip.storage.label)
    }

    private var storageTint: Color {
        switch clip.storage {
        case .device: return Color(red: 0.62, green: 0.45, blue: 0.10)
        case .local, .both: return Color(red: 0.13, green: 0.55, blue: 0.40)
        }
    }

    private var coordinateText: String? {
        guard let coordinate = clip.coordinate else { return nil }
        return Format.coordinate(
            latitude: coordinate.latitude, longitude: coordinate.longitude
        )
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

    private func beginRename() {
        draftName = labels.title(for: clip)
        isRenaming = true
        nameFieldFocused = true
    }

    private func commitRename() {
        labels.set(draftName, for: clip)
        isRenaming = false
    }

    private func advancePreview() {
        guard !cameras.isEmpty else { return }
        let current = previewCamera ?? cameras.first
        let index = current.flatMap { cameras.firstIndex(of: $0) } ?? 0
        previewCamera = cameras[(index + 1) % cameras.count]
    }

    private func loadPoster() async {
        let image = await ThumbnailService.shared.image(for: clip, camera: previewCamera)
        poster = image
    }
}
