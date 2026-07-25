import AppKit
import SwiftUI

/// The app's home screen: header stats, filters, and the clip gallery.
struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var library: LibraryStore
    @Environment(\.appTheme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                controls
                gallery
            }
            .padding(24)
        }
        .background(backdrop)
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
                    Text("Browse, filter and launch any drive session from a workspace built for fast review.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)

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

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(alignment: .top, spacing: 14) {
                statCard(
                    caption: "CLIPS LOADED",
                    value: "\(library.clips.count)",
                    symbol: "video.fill",
                    tint: Color(red: 0.16, green: 0.55, blue: 0.98)
                )
                statCard(
                    caption: "GPS TAGGED",
                    value: "\(library.gpsTaggedCount)",
                    symbol: "mappin.circle.fill",
                    tint: Color(red: 0.13, green: 0.68, blue: 0.42)
                )
                statCard(
                    caption: "CAMERA STREAMS",
                    value: "\(library.cameraStreamCount)",
                    symbol: "camera.fill",
                    tint: Color(red: 0.50, green: 0.34, blue: 0.86)
                )
                statCard(
                    caption: "STORAGE",
                    value: Format.bytes(library.totalBytes),
                    symbol: "internaldrive.fill",
                    tint: Color(red: 0.80, green: 0.60, blue: 0.16)
                )
                timelineCard
            }
        }
    }

    private func statCard(caption: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .font(.system(size: 27, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
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
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await library.chooseFolder() }
                    } label: {
                        Label("Change Folder", systemImage: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)

                    Button {
                        Task { await library.loadSampleLibrary() }
                    } label: {
                        Label("Load Sample", systemImage: "video.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.isBuildingSample)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 330, minHeight: 108)
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
        if library.isBuildingSample { return "Building the sample library…" }
        if library.isScanning { return "Scanning…" }
        if let date = library.timelineDate {
            return date.formatted(date: .long, time: .omitted)
        }
        return library.rootURL?.lastPathComponent ?? "No folder selected"
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                CountChip(
                    label: "All", symbol: "square.grid.2x2",
                    count: library.clips.count,
                    isSelected: library.categoryFilter == nil,
                    tint: theme.primary
                ) { library.categoryFilter = nil }

                ForEach(ClipCategory.allCases) { category in
                    CountChip(
                        label: category.label,
                        symbol: category.symbolName,
                        count: library.counts[category] ?? 0,
                        isSelected: library.categoryFilter == category,
                        tint: theme.primary
                    ) { library.categoryFilter = category }
                }
                Spacer()
            }

            HStack(spacing: 12) {
                SearchField(text: $library.searchText, prompt: "Search by date, city or street")
                    .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Sort")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $library.sortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 96)
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

    // MARK: - Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCaption(text: "CLIP GALLERY")

            HStack(spacing: 8) {
                Text("Showing \(library.filteredClips.count) clip\(library.filteredClips.count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .medium))
                if library.isScanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if library.isUsingSampleLibrary {
                    Label("Sample library", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = library.scanError, library.clips.isEmpty {
                emptyState(message: error)
            } else if library.filteredClips.isEmpty && !library.isScanning {
                emptyState(message: "No clips match the current filters.")
            } else if library.presentation == .map {
                LibraryMapView(clips: library.mappableClips) { clip in
                    appState.open(clip)
                }
                .frame(minHeight: 480)
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
                    ForEach(library.filteredClips) { clip in
                        ClipCard(clip: clip, density: library.density) {
                            appState.open(clip)
                        }
                    }
                }
            }
        }
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
                Button("Load Sample") {
                    Task { await library.loadSampleLibrary() }
                }
                .disabled(library.isBuildingSample)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
