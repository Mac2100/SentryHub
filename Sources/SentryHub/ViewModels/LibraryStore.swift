import Foundation
import SwiftUI

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case date, duration, size, name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return "Date"
        case .duration: return "Length"
        case .size: return "Size"
        case .name: return "Name"
        }
    }
}

enum LibraryPresentation: String, CaseIterable, Identifiable {
    case grid, map
    var id: String { rawValue }

    var label: String { self == .grid ? "Grid" : "Map" }
    var symbolName: String { self == .grid ? "square.grid.2x2" : "map" }
}

/// Card size for the gallery — the three-step density control in the toolbar.
enum GalleryDensity: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .compact: return "square.grid.3x3"
        case .regular: return "square.grid.2x2"
        case .large: return "square"
        }
    }

    var minimumCardWidth: CGFloat {
        switch self {
        case .compact: return 220
        case .regular: return 300
        case .large: return 420
        }
    }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Comfortable"
        case .large: return "Large"
        }
    }
}

/// Owns the scanned clip library plus the gallery's filter/sort state.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var rootURL: URL?
    @Published private(set) var resolvedRoot: URL?
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?
    @Published private(set) var isUsingSampleLibrary = false
    @Published private(set) var isBuildingSample = false
    /// 0…1 while the sample library is being generated.
    @Published private(set) var sampleProgress: Double = 0

    // Filters
    @Published var categoryFilter: ClipCategory?
    @Published var searchText: String = ""
    @Published var sortOrder: LibrarySortOrder = .date
    @Published var presentation: LibraryPresentation = .grid
    @Published var density: GalleryDensity = .regular

    private var durationTask: Task<Void, Never>?

    init() {
        if let stored = UserDefaults.standard.string(forKey: "galleryDensity"),
           let value = GalleryDensity(rawValue: stored) {
            density = value
        }
    }

    // MARK: - Loading

    func restoreLastFolder() async {
        guard let url = FolderAccess.restore() else { return }
        await load(root: url, isSample: url.path.hasPrefix(SampleLibrary.rootURL.path))
    }

    func chooseFolder() async {
        guard let url = FolderAccess.chooseFolder(startingAt: rootURL) else { return }
        await load(root: url, isSample: false)
    }

    func load(root: URL, isSample: Bool) async {
        rootURL = root
        isUsingSampleLibrary = isSample
        await rescan()
    }

    func rescan() async {
        guard let root = rootURL else { return }
        isScanning = true
        scanError = nil
        durationTask?.cancel()

        let result: LibraryScanner.Result?
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try LibraryScanner.scan(root: root)
            }.value
        } catch {
            scanError = error.localizedDescription
            clips = []
            isScanning = false
            return
        }

        guard let result else {
            isScanning = false
            return
        }

        clips = result.clips
        resolvedRoot = result.resolvedRoot
        isScanning = false

        if let warning = result.warnings.first {
            ToastCenter.shared.show("Scan finished with notes", detail: warning, style: .info)
        }
        if clips.isEmpty && scanError == nil {
            scanError = "No TeslaCam clips found in \(root.lastPathComponent)."
        }

        resolveDurationsInBackground()
    }

    /// Replaces the assumed 60 s segment length with the real durations, then
    /// republishes so the gallery's badges settle on the correct values.
    private func resolveDurationsInBackground() {
        let snapshot = clips
        durationTask = Task { [weak self] in
            var updated: [Clip] = []
            updated.reserveCapacity(snapshot.count)
            for clip in snapshot {
                if Task.isCancelled { return }
                updated.append(await LibraryScanner.resolveDurations(for: clip))
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.clips.count == updated.count else { return }
                self.clips = updated
            }
        }
    }

    // MARK: - Sample library

    func loadSampleLibrary(force: Bool = false) async {
        isBuildingSample = true
        sampleProgress = 0
        defer {
            isBuildingSample = false
            sampleProgress = 0
        }
        do {
            let root = try await SampleLibrary.build(force: force) { [weak self] fraction in
                self?.sampleProgress = fraction
            }
            FolderAccess.remember(root)
            await load(root: root, isSample: true)
            ToastCenter.shared.show(
                "Sample library loaded",
                detail: "\(clips.count) synthetic clips with demo telemetry"
            )
        } catch {
            scanError = error.localizedDescription
            ToastCenter.shared.show(
                "Couldn't build the sample library",
                detail: error.localizedDescription,
                style: .error
            )
        }
    }

    func forgetFolder() {
        FolderAccess.forget()
        rootURL = nil
        resolvedRoot = nil
        clips = []
        scanError = nil
        isUsingSampleLibrary = false
    }

    // MARK: - Derived state

    var counts: [ClipCategory: Int] {
        var result: [ClipCategory: Int] = [:]
        for clip in clips {
            result[clip.category, default: 0] += 1
        }
        return result
    }

    var gpsTaggedCount: Int {
        clips.filter { $0.coordinate != nil }.count
    }

    /// Distinct camera feeds present anywhere in the library.
    var cameraStreamCount: Int {
        clips.reduce(into: Set<CameraAngle>()) { $0.formUnion($1.cameras) }.count
    }

    var totalBytes: Int64 {
        clips.reduce(0) { $0 + $1.byteCount }
    }

    /// Newest clip date, shown in the header's Timeline card.
    var timelineDate: Date? {
        clips.map(\.startDate).max()
    }

    var filteredClips: [Clip] {
        var result = clips

        if let categoryFilter {
            result = result.filter { $0.category == categoryFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { clip in
                if clip.name.lowercased().contains(query) { return true }
                if let city = clip.city?.lowercased(), city.contains(query) { return true }
                if let reason = clip.event?.reasonLabel?.lowercased(), reason.contains(query) {
                    return true
                }
                let formatted = clip.startDate.formatted(date: .long, time: .shortened).lowercased()
                if formatted.contains(query) { return true }
                if let coordinate = clip.coordinate {
                    let text = Format.coordinate(
                        latitude: coordinate.latitude, longitude: coordinate.longitude
                    )
                    if text.contains(query) { return true }
                }
                return false
            }
        }

        switch sortOrder {
        case .date: result.sort { $0.startDate > $1.startDate }
        case .duration: result.sort { $0.duration > $1.duration }
        case .size: result.sort { $0.byteCount > $1.byteCount }
        case .name: result.sort { $0.name < $1.name }
        }
        return result
    }

    /// Clips that can be pinned on the library map.
    var mappableClips: [Clip] {
        filteredClips.filter { $0.coordinate != nil }
    }

    func persistDensity() {
        UserDefaults.standard.set(density.rawValue, forKey: "galleryDensity")
    }
}
