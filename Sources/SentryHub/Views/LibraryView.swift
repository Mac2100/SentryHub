import AppKit
import SwiftUI

/// The app's home screen: header stats, filters, and the clip gallery.
struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var library: LibraryStore
    @ObservedObject private var incidents = IncidentStore.shared
    @Environment(\.appTheme) private var theme

    @State private var pendingDelete: DeleteRequest?
    @State private var showRenameSheet = false
    @State private var showIncidentSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if appState.libraryTab == .incidents {
                    IncidentsView(library: library)
                } else {
                    controls
                    if library.isSelecting {
                        selectionBar
                    }
                    gallery
                }
            }
            .padding(24)
        }
        .background(backdrop)
        .overlay(alignment: .bottom) { TransferBanner() }
        .sheet(isPresented: $showRenameSheet) {
            BulkRenameSheet(count: library.selection.count) { name in
                library.renameSelection(to: name)
            }
        }
        .sheet(isPresented: $showIncidentSheet) {
            AddToIncidentSheet(clipIDs: Array(library.selection))
        }
        .alert(
            pendingDelete?.title ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { request in
            Button(request.confirmLabel, role: .destructive) {
                Task { await request.perform() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }

    /// A pending destructive action, held so the alert can describe exactly what
    /// is about to happen before it happens.
    struct DeleteRequest: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let perform: () async -> Void
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [
                theme.primary.opacity(0.10),
                Color.clear,
                theme.secondary.opacity(0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                theme.glyph(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your clip library")
                        .font(.system(size: 30, weight: .bold))
                    Text(headerSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)

                CapsuleSegments(
                    options: AppState.LibraryTab.allCases.map { ($0, $0.label, $0.symbolName) },
                    selection: $appState.libraryTab
                )

                Button {
                    appState.showStartScreen()
                } label: {
                    Label("Home", systemImage: "house")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Back to the start screen")

                Button {
                    Task { await library.rescan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(library.isScanning)

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(alignment: .top, spacing: 14) {
                statCard(
                    caption: "CLIPS IN LIBRARY",
                    value: "\(library.clips.count)",
                    detail: library.driveOnlyCount > 0
                        ? "\(library.driveOnlyCount) only on the drive"
                        : (library.clips.isEmpty ? nil : "all saved to this Mac"),
                    symbol: "video.fill",
                    tint: Color(red: 0.16, green: 0.55, blue: 0.98)
                )
                statCard(
                    caption: "ON THIS MAC",
                    value: "\(library.savedLocallyCount)",
                    detail: library.savedLocallyCount > 0
                        ? Format.bytes(library.locallySavedBytes)
                        : "nothing saved yet",
                    symbol: "internaldrive.fill",
                    tint: Color(red: 0.13, green: 0.68, blue: 0.42)
                )
                statCard(
                    caption: "INCIDENTS",
                    value: "\(incidents.incidents.count)",
                    detail: incidents.openCount > 0 ? "\(incidents.openCount) open" : nil,
                    symbol: "folder.badge.person.crop",
                    tint: Color(red: 0.50, green: 0.34, blue: 0.86)
                )
                statCard(
                    caption: "TOTAL SIZE",
                    value: Format.bytes(library.totalBytes),
                    detail: "\(library.gpsTaggedCount) GPS tagged",
                    symbol: "externaldrive.fill",
                    tint: Color(red: 0.80, green: 0.60, blue: 0.16)
                )
                timelineCard
            }
        }
    }

    private var headerSubtitle: String {
        if library.isRunningWithoutDrive {
            return "No drive connected — showing the \(library.clips.count) clip"
                + "\(library.clips.count == 1 ? "" : "s") saved on this Mac."
        }
        return "Browse, filter and launch any drive session from a workspace built for fast review."
    }

    private func statCard(
        caption: String, value: String, detail: String? = nil, symbol: String, tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(.system(size: 27, weight: .bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.16))
                )
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var timelineCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.gradient)
                )

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Timeline")
                        .font(.system(size: 14, weight: .semibold))
                    Text(timelineSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button {
                    Task { await library.chooseFolder() }
                } label: {
                    Label("Change Folder", systemImage: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        // Without this the label is the first thing the HStack
                        // squeezes, and it renders as "Change Fol…".
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 260, minHeight: 108)
        // Keeps the card from being the one that gives up space when the four
        // stat cards compete for width.
        .layoutPriority(1)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var timelineSubtitle: String {
        if library.isScanning { return "Scanning…" }
        if let date = library.timelineDate {
            return date.formatted(date: .long, time: .omitted)
        }
        if let root = library.rootURL { return root.lastPathComponent }
        return library.clips.isEmpty ? "No folder selected" : "Local library only"
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                CountChip(
                    label: "All", symbol: "square.grid.2x2",
                    count: library.clips.count,
                    isSelected: library.categoryFilter == nil && library.triggerFilter == nil,
                    tint: theme.primary
                ) {
                    library.categoryFilter = nil
                    library.triggerFilter = nil
                }

                // Folders you or the car chose to keep.
                ForEach(LibraryStore.leadingCategories) { category in
                    CountChip(
                        label: category.label,
                        symbol: category.symbolName,
                        count: library.counts[category] ?? 0,
                        isSelected: library.categoryFilter == category,
                        tint: theme.primary
                    ) {
                        library.categoryFilter = category
                        library.triggerFilter = nil
                    }
                }

                Divider().frame(height: 22)

                // Sentry sits on this side of the divider with the reasons it
                // fired, because that's the folder those clips come from.
                CountChip(
                    label: ClipCategory.sentry.label,
                    symbol: ClipCategory.sentry.symbolName,
                    count: library.counts[.sentry] ?? 0,
                    isSelected: library.categoryFilter == .sentry,
                    tint: theme.primary
                ) {
                    library.categoryFilter = .sentry
                    library.triggerFilter = nil
                }

                // Why the car kept the clip, from event.json. Only kinds that
                // actually appear in this library are offered.
                ForEach(library.availableTriggers) { trigger in
                    CountChip(
                        label: trigger.label,
                        symbol: trigger.symbolName,
                        count: library.triggerCount(trigger),
                        isSelected: library.triggerFilter == trigger,
                        tint: theme.primary
                    ) {
                        library.triggerFilter =
                            library.triggerFilter == trigger ? nil : trigger
                        library.categoryFilter = nil
                    }
                }
                Spacer()
            }

            HStack(spacing: 12) {
                SearchField(text: $library.searchText, prompt: "Search by city, street or event")
                    .frame(maxWidth: .infinity)

                DateFilterControl(library: library, tint: theme.primary)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $library.sortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 112)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

                CapsuleSegments(
                    options: GalleryDensity.allCases.map { ($0, $0.label, $0.symbolName) },
                    selection: $library.density,
                    showLabels: false
                )
                .onChange(of: library.density) { _, _ in library.persistDensity() }

                CapsuleSegments(
                    options: LibraryPresentation.allCases.map { ($0, $0.label, $0.symbolName) },
                    selection: $library.presentation
                )
            }

            HStack(spacing: 12) {
                // Where the footage lives is a filter in its own right: it's the
                // difference between a clip you have and one you're about to
                // lose to the car's rolling buffer.
                HStack(spacing: 8) {
                    Text("Storage")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    CapsuleSegments(
                        options: StorageFilter.allCases.map { ($0, $0.label, $0.symbolName) },
                        selection: $library.storageFilter
                    )
                }

                if library.driveOnlyCount > 0 {
                    Text("\(library.driveOnlyCount) clip\(library.driveOnlyCount == 1 ? "" : "s") "
                         + "will disappear with the drive")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    if library.isSelecting {
                        library.endSelecting()
                    } else {
                        library.beginSelecting()
                    }
                } label: {
                    Label(
                        library.isSelecting ? "Done" : "Select",
                        systemImage: library.isSelecting
                            ? "xmark.circle" : "checkmark.circle"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .tint(library.isSelecting ? theme.primary : nil)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Selection

    private var selectionBar: some View {
        let selected = library.selectedClips
        let toSave = library.selectionToSave
        let savedLocally = library.selectionSavedLocally
        let onDrive = library.selectionOnDrive
        let selectedSize = Format.bytes(selected.reduce(Int64(0)) { $0 + $1.byteCount })
        let saveSize = Format.bytes(toSave.reduce(Int64(0)) { $0 + $1.byteCount })
        let saveLabel = toSave.isEmpty ? "Save to Mac" : "Save \(toSave.count) to Mac"
        let saveHelp = toSave.isEmpty
            ? "Every selected clip is already on this Mac"
            : "Copy \(saveSize) into the local library"
        let isBusy = LocalLibrary.shared.transfer != nil

        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.primary)
            Text("\(selected.count) selected")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            if !selected.isEmpty {
                Text(selectedSize)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button("Select All") { library.selectAllVisible() }
                .buttonStyle(.link)
                .font(.system(size: 12))
            if !selected.isEmpty {
                Button("Clear") { library.selection.removeAll() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }

            Spacer(minLength: 12)

            Button {
                Task { await library.saveSelectionLocally() }
            } label: {
                Label(saveLabel, systemImage: "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .disabled(toSave.isEmpty || isBusy)
            .help(saveHelp)

            Button {
                showIncidentSheet = true
            } label: {
                Label("Add to Incident", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(selected.isEmpty)

            Button {
                showRenameSheet = true
            } label: {
                Label("Rename", systemImage: "pencil")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(selected.isEmpty)

            Menu {
                Button("Remove \(savedLocally.count) from This Mac", role: .destructive) {
                    pendingDelete = removeFromMacRequest(savedLocally)
                }
                .disabled(savedLocally.isEmpty)

                Button("Delete \(onDrive.count) from the Drive", role: .destructive) {
                    pendingDelete = deleteFromDriveRequest(onDrive)
                }
                .disabled(onDrive.isEmpty)
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(selected.isEmpty || isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primary.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primary.opacity(0.35), lineWidth: 1)
        )
    }

    private func removeFromMacRequest(_ clips: [Clip]) -> DeleteRequest {
        let orphaned = clips.filter { $0.storage == .local }
        var message = "The local copies of \(clips.count) clip"
            + "\(clips.count == 1 ? "" : "s") will be moved to the Trash."
        if orphaned.isEmpty {
            message += " They're still on the drive, so you can save them again later."
        } else {
            message += " \(orphaned.count) of them "
                + "\(orphaned.count == 1 ? "is" : "are") no longer on the drive, so this is the "
                + "only copy."
        }
        return DeleteRequest(
            title: "Remove from this Mac?",
            message: message,
            confirmLabel: "Remove"
        ) {
            await library.removeSelectionFromMac()
        }
    }

    private func deleteFromDriveRequest(_ clips: [Clip]) -> DeleteRequest {
        let unsaved = clips.filter { LocalLibrary.shared.contains($0.id) == false }
        var message = "\(clips.count) clip\(clips.count == 1 ? "" : "s") will be deleted from the "
            + "dashcam drive. Dashcam drives usually have no Trash, so treat this as permanent."
        if unsaved.isEmpty {
            message += " Every one of them is saved on this Mac and will stay in your library."
        } else {
            message += " \(unsaved.count) of them "
                + "\(unsaved.count == 1 ? "is" : "are") not saved on this Mac — "
                + "that footage will be gone."
        }
        return DeleteRequest(
            title: "Delete from the drive?",
            message: message,
            confirmLabel: "Delete"
        ) {
            await library.deleteSelectionFromDrive()
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCaption(text: "CLIP GALLERY")

            HStack(spacing: 8) {
                Text("Showing \(library.filteredClips.count) clip\(library.filteredClips.count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .medium))
                if library.effectiveGrouping != .none, library.groups.count > 1 {
                    Text("in \(library.groups.count) groups")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if library.isScanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if library.hasActiveFilters {
                    Button {
                        library.clearFilters()
                    } label: {
                        Label("Clear filters", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if library.clips.isEmpty, let error = library.scanError {
                emptyState(message: error)
            } else if library.filteredClips.isEmpty && !library.isScanning {
                emptyState(
                    message: library.storageFilter == .onMac && library.savedLocallyCount == 0
                        ? "Nothing is saved to this Mac yet. Select clips and choose Save to Mac to keep them once the drive is unplugged."
                        : "No clips match the current filters."
                )
            } else if library.presentation == .map {
                LibraryMapView(clips: library.mappableClips) { clip in
                    appState.open(clip)
                }
                .frame(minHeight: 480)
            } else {
                if library.presentation == .list {
                    ClipListHeader(
                        isSelecting: library.isSelecting,
                        thumbnailWidth: library.density.listThumbnailWidth
                    )
                }

                LazyVStack(
                    alignment: .leading,
                    spacing: library.presentation == .list ? 16 : 26,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(library.groups) { group in
                        Section {
                            // Both presentations share the sections, the sticky
                            // headers, and the selection wiring; only the shape
                            // of a clip changes.
                            if library.presentation == .list {
                                VStack(spacing: 4) {
                                    ForEach(group.clips) { clip in
                                        ClipRow(
                                            clip: clip,
                                            density: library.density,
                                            isSelecting: library.isSelecting,
                                            isSelected: library.selection.contains(clip.id),
                                            onToggleSelection: { toggle(clip) }
                                        ) {
                                            appState.open(clip)
                                        }
                                    }
                                }
                            } else {
                                LazyVGrid(
                                    columns: [
                                        GridItem(
                                            .adaptive(minimum: library.density.minimumCardWidth),
                                            spacing: 16
                                        )
                                    ],
                                    spacing: 16
                                ) {
                                    ForEach(group.clips) { clip in
                                        ClipCard(
                                            clip: clip,
                                            density: library.density,
                                            isSelecting: library.isSelecting,
                                            isSelected: library.selection.contains(clip.id),
                                            onToggleSelection: { toggle(clip) }
                                        ) {
                                            appState.open(clip)
                                        }
                                    }
                                }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ clip: Clip) {
        library.beginSelecting()
        library.toggleSelection(clip.id)
    }

    /// Sticky section header — the gallery runs to hundreds of cards on a real
    /// drive, so the heading needs to stay visible while scrolling through one.
    private func groupHeader(_ group: ClipGroup) -> some View {
        HStack(spacing: 9) {
            Image(systemName: group.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.primary.opacity(0.14))
                )
            Text(group.title)
                .font(.system(size: 15, weight: .semibold))
            if let subtitle = group.subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Choose Folder…") {
                    Task { await library.chooseFolder() }
                }
                if library.hasActiveFilters {
                    Button("Clear Filters") { library.clearFilters() }
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}


/// Date filter: presets plus a real two-ended date picker, so a range can be
/// chosen rather than typed into the search box.
struct DateFilterControl: View {
    @ObservedObject var library: LibraryStore
    let tint: Color

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                Text(library.dateFilterLabel)
                    .font(.system(size: 12, weight: library.isDateFiltered ? .semibold : .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    library.isDateFiltered ? tint.opacity(0.16) : Color.primary.opacity(0.04)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    library.isDateFiltered ? tint.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(library.isDateFiltered ? Color.primary : Color.secondary)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(DateRangePreset.allCases) { preset in
                    Button {
                        library.datePreset = preset
                        if preset != .custom { isPresented = false }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: preset.symbolName)
                                .font(.system(size: 11))
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            Text(preset.label)
                                .font(.system(size: 13))
                            Spacer()
                            if library.datePreset == preset {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(tint)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if library.datePreset == .custom {
                    Divider().padding(.vertical, 6)
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker(
                            "From",
                            selection: $library.customStart,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        DatePicker(
                            "To",
                            selection: $library.customEnd,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    }
                    .datePickerStyle(.compact)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }

                Divider().padding(.vertical, 6)
                Button("Any date") {
                    library.datePreset = .any
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .padding(.top, 8)
            .frame(width: 250)
        }
    }
}
