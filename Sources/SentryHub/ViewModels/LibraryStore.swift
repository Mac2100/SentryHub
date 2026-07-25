import Foundation
import SwiftUI

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case date, category, duration, size, name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return "Date"
        case .category: return "Category"
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

/// How the gallery is broken into sections.
enum ClipGrouping: String, CaseIterable, Identifiable {
    case day, event, category, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Day"
        case .event: return "Event"
        case .category: return "Folder"
        case .none: return "None"
        }
    }

    var symbolName: String {
        switch self {
        case .day: return "calendar"
        case .event: return "bolt.badge.clock"
        case .category: return "folder"
        case .none: return "square.grid.2x2"
        }
    }
}

/// One section of the gallery.
struct ClipGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbolName: String
    let clips: [Clip]
}

/// Presets for the library's date filter.
enum DateRangePreset: String, CaseIterable, Identifiable {
    case any, today, week, month, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Any date"
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .custom: return "Custom range"
        }
    }

    var symbolName: String {
        switch self {
        case .any: return "calendar"
        case .today: return "calendar.badge.clock"
        case .week: return "calendar.day.timeline.left"
        case .month: return "calendar.badge.plus"
        case .custom: return "calendar.badge.exclamationmark"
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

    // Filters
    @Published var categoryFilter: ClipCategory?
    @Published var triggerFilter: ClipTrigger?
    @Published var searchText: String = ""
    @Published var sortOrder: LibrarySortOrder = .date
    @Published var presentation: LibraryPresentation = .grid
    @Published var density: GalleryDensity = .regular
    @Published var grouping: ClipGrouping = .day

    // Date filter
    @Published var datePreset: DateRangePreset = .any
    @Published var customStart: Date = Calendar.current.date(
        byAdding: .day, value: -7, to: Date()
    ) ?? Date()
    @Published var customEnd: Date = Date()

    private var durationTask: Task<Void, Never>?

    init() {
        if let stored = UserDefaults.standard.string(forKey: "galleryDensity"),
           let value = GalleryDensity(rawValue: stored) {
            density = value
        }
        if let stored = UserDefaults.standard.string(forKey: "galleryGrouping"),
           let value = ClipGrouping(rawValue: stored) {
            grouping = value
        }
    }

    // MARK: - Loading

    func restoreLastFolder() async {
        guard let url = FolderAccess.restore() else { return }
        await load(root: url)
    }

    func chooseFolder() async {
        guard let url = FolderAccess.chooseFolder(startingAt: rootURL) else { return }
        await load(root: url)
    }

    func load(root: URL) async {
        rootURL = root
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

    func forgetFolder() {
        FolderAccess.forget()
        rootURL = nil
        resolvedRoot = nil
        clips = []
        scanError = nil
    }

    // MARK: - Derived state

    var counts: [ClipCategory: Int] {
        var result: [ClipCategory: Int] = [:]
        for clip in clips {
            result[clip.category, default: 0] += 1
        }
        return result
    }

    /// Trigger kinds actually present, so no empty pills are offered. Ordered
    /// most-common-first rather than by declaration order.
    var availableTriggers: [ClipTrigger] {
        let present = Set(clips.compactMap(\.trigger))
        return Self.triggerDisplayOrder.filter { present.contains($0) }
    }

    private static let triggerDisplayOrder: [ClipTrigger] = [
        .motion, .honk, .impact, .manualSave
    ]

    /// Folder chips shown ahead of the divider. Sentry sits with the event
    /// kinds on the other side, because that's where its clips come from.
    static let leadingCategories: [ClipCategory] = [.recent, .saved]

    func triggerCount(_ trigger: ClipTrigger) -> Int {
        clips.filter { $0.trigger == trigger }.count
    }

    /// The window the date filter currently allows, or `nil` for "any date".
    var dateInterval: DateInterval? {
        let calendar = Calendar.current
        let now = Date()
        switch datePreset {
        case .any:
            return nil
        case .today:
            let start = calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .week:
            let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))
            return DateInterval(start: start ?? now, end: now)
        case .month:
            let start = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))
            return DateInterval(start: start ?? now, end: now)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let end = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customStart, customEnd))
            ) ?? max(customStart, customEnd)
            return DateInterval(start: start, end: end)
        }
    }

    /// Label for the date-filter button.
    var dateFilterLabel: String {
        guard datePreset == .custom else { return datePreset.label }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let a = min(customStart, customEnd)
        let b = max(customStart, customEnd)
        return "\(formatter.string(from: a)) – \(formatter.string(from: b))"
    }

    var isDateFiltered: Bool { datePreset != .any }

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

        if let triggerFilter {
            result = result.filter { $0.trigger == triggerFilter }
        }

        if let interval = dateInterval {
            result = result.filter { interval.contains($0.startDate) }
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
        case .date:
            result.sort { $0.startDate > $1.startDate }
        case .category:
            // Sentry, then Saved, then Recent — newest first inside each.
            result.sort { a, b in
                let left = Self.categoryRank(a)
                let right = Self.categoryRank(b)
                if left != right { return left < right }
                return a.startDate > b.startDate
            }
        case .duration:
            result.sort { $0.duration > $1.duration }
        case .size:
            result.sort { $0.byteCount > $1.byteCount }
        case .name:
            result.sort { $0.name < $1.name }
        }
        return result
    }

    private static func categoryRank(_ clip: Clip) -> Int {
        ClipCategory.allCases.firstIndex(of: clip.category) ?? ClipCategory.allCases.count
    }

    /// Clips that can be pinned on the library map.
    var mappableClips: [Clip] {
        filteredClips.filter { $0.coordinate != nil }
    }

    func clearFilters() {
        categoryFilter = nil
        triggerFilter = nil
        searchText = ""
        datePreset = .any
    }

    var hasActiveFilters: Bool {
        categoryFilter != nil || triggerFilter != nil || isDateFiltered
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func persistDensity() {
        UserDefaults.standard.set(density.rawValue, forKey: "galleryDensity")
    }

    func persistGrouping() {
        UserDefaults.standard.set(grouping.rawValue, forKey: "galleryGrouping")
    }

    // MARK: - Grouping

    /// Day sections only make sense while the list is in date order — sorting
    /// by size or length inside per-day buckets looks like the sort did
    /// nothing. Any other sort collapses the gallery to one section so the
    /// ordering is global and visible.
    var effectiveGrouping: ClipGrouping {
        sortOrder == .date ? grouping : .none
    }

    /// The filtered clips broken into sections. A drive's worth of Sentry
    /// events is hundreds of cards; sections make that scannable.
    var groups: [ClipGroup] {
        let clips = filteredClips
        guard !clips.isEmpty else { return [] }

        switch effectiveGrouping {
        case .none:
            return [ClipGroup(
                id: "all",
                title: sortOrder == .date ? "All Clips" : "Sorted by \(sortOrder.label)",
                subtitle: Self.groupSubtitle(clips),
                symbolName: sortOrder == .date ? "square.grid.2x2" : "arrow.up.arrow.down",
                clips: clips
            )]

        case .day:
            let calendar = Calendar.current
            let buckets = Dictionary(grouping: clips) {
                calendar.startOfDay(for: $0.startDate)
            }
            return buckets.keys.sorted(by: >).map { day in
                let items = buckets[day] ?? []
                return ClipGroup(
                    id: "day-\(day.timeIntervalSince1970)",
                    title: Self.dayTitle(day, calendar: calendar),
                    subtitle: Self.groupSubtitle(items),
                    symbolName: "calendar",
                    clips: items
                )
            }

        case .event:
            let buckets = Dictionary(grouping: clips) { $0.trigger }
            let order: [ClipTrigger?] = ClipTrigger.allCases.map { $0 } + [nil]
            return order.compactMap { trigger in
                guard let items = buckets[trigger], !items.isEmpty else { return nil }
                return ClipGroup(
                    id: "event-\(trigger?.rawValue ?? "other")",
                    title: trigger?.label ?? "No Event Recorded",
                    subtitle: Self.groupSubtitle(items),
                    symbolName: trigger?.symbolName ?? "questionmark.circle",
                    clips: items
                )
            }

        case .category:
            let buckets = Dictionary(grouping: clips) { $0.category }
            return ClipCategory.allCases.compactMap { category in
                guard let items = buckets[category], !items.isEmpty else { return nil }
                return ClipGroup(
                    id: "category-\(category.rawValue)",
                    title: category.label,
                    subtitle: Self.groupSubtitle(items),
                    symbolName: category.symbolName,
                    clips: items
                )
            }
        }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -7, to: Date()), day > week {
            return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    private static func groupSubtitle(_ clips: [Clip]) -> String {
        let count = clips.count
        let bytes = clips.reduce(Int64(0)) { $0 + $1.byteCount }
        return "\(count) clip\(count == 1 ? "" : "s") · \(Format.bytes(bytes))"
    }
}
