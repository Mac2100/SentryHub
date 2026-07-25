import Combine
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
    case grid, list, map

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        case .map: return "Map"
        }
    }

    var symbolName: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .map: return "map"
        }
    }
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

    /// Poster width in a list row. Shared with the list's column captions so
    /// the headings stay lined up with what's underneath them.
    var listThumbnailWidth: CGFloat {
        switch self {
        case .compact: return 64
        case .regular: return 88
        case .large: return 116
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

/// One chip in the library's filter row.
///
/// The row is one-of-N: picking a chip replaces whatever was picked before
/// rather than stacking with it, so it lives as a single value instead of the
/// three independent flags it used to be — which had every call site clearing
/// the other two by hand.
enum LibraryChip: Hashable, Identifiable {
    case all
    case category(ClipCategory)
    /// Anything the car flagged, whatever the reason.
    case flagged
    case trigger(ClipTrigger)

    var id: String {
        switch self {
        case .all: return "all"
        case .category(let category): return "category-\(category.rawValue)"
        case .flagged: return "flagged"
        case .trigger(let trigger): return "trigger-\(trigger.rawValue)"
        }
    }

    var label: String {
        switch self {
        case .all: return "All"
        case .category(let category): return category.label
        case .flagged: return "Event"
        case .trigger(let trigger): return trigger.label
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .category(let category): return category.symbolName
        case .flagged: return "bolt.badge.clock"
        case .trigger(let trigger): return trigger.symbolName
        }
    }

    var help: String {
        switch self {
        case .all: return "Every clip in the library"
        case .category(let category): return "Clips in the \(category.folderName) folder"
        case .flagged: return "Every clip the car flagged, including reasons SentryHub can't name"
        case .trigger(let trigger): return "Clips the car put down to \(trigger.label.lowercased())"
        }
    }
}

/// Which half of the library the gallery is showing.
enum StorageFilter: String, CaseIterable, Identifiable {
    case any, onMac, driveOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Everywhere"
        case .onMac: return "On This Mac"
        case .driveOnly: return "Drive Only"
        }
    }

    var symbolName: String {
        switch self {
        case .any: return "circle.grid.2x2"
        case .onMac: return "internaldrive.fill"
        case .driveOnly: return "externaldrive"
        }
    }

    func accepts(_ clip: Clip) -> Bool {
        switch self {
        case .any: return true
        case .onMac: return clip.storage.isSavedLocally
        case .driveOnly: return clip.storage == .device
        }
    }
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

/// Owns the clip library plus the gallery's filter/sort/selection state.
///
/// Two sources feed it: the dashcam drive, and SentryHub's own local library.
/// They are merged into one list of cards so the library reads as a library
/// rather than as a view onto whatever happens to be plugged in.
@MainActor
final class LibraryStore: ObservableObject {
    /// The merged view — what every screen reads.
    @Published private(set) var clips: [Clip] = []
    /// What the drive scan found, kept separately because deleting from the
    /// drive and copying off it both need the drive's own paths, which the
    /// merge replaces with the local copy's whenever there is one.
    @Published private(set) var deviceClips: [Clip] = []
    @Published private(set) var rootURL: URL?
    @Published private(set) var resolvedRoot: URL?
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?

    // Filters
    @Published var categoryFilter: ClipCategory?
    @Published var triggerFilter: ClipTrigger?
    /// Set by the Event chip: any clip the car flagged, whatever the reason.
    @Published var flaggedOnly = false
    @Published var searchText: String = ""
    @Published var storageFilter: StorageFilter = .any
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

    // Multi-select
    @Published var isSelecting = false
    @Published var selection: Set<Clip.ID> = []

    private var durationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Renaming a clip changes what search matches on, and SwiftUI only
        // watches the object a view declared — so pass the label store's
        // notifications on as our own.
        ClipLabels.shared.objectWillChange.sink { [weak self] _ in
            // ClipLabels is @MainActor, so this always arrives on the main actor.
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
            }
        }
        .store(in: &cancellables)

        // The local library is the other half of the merge, and it changes
        // whenever clips are saved or removed.
        LocalLibrary.shared.clipsDidChange.sink { [weak self] latest in
            // LocalLibrary is @MainActor, so this always arrives on the main actor.
            MainActor.assumeIsolated {
                self?.rebuild(local: latest)
            }
        }
        .store(in: &cancellables)
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
        // Every route into a folder goes through here — the picker, the restore,
        // and a drive being plugged in — so this is where it gets remembered.
        FolderAccess.remember(root)
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
            deviceClips = []
            rebuild()
            isScanning = false
            return
        }

        guard let result else {
            isScanning = false
            return
        }

        deviceClips = result.clips
        resolvedRoot = result.resolvedRoot
        rebuild()
        isScanning = false

        if let warning = result.warnings.first {
            ToastCenter.shared.show("Scan finished with notes", detail: warning, style: .info)
        }
        if deviceClips.isEmpty && scanError == nil {
            scanError = "No TeslaCam clips found in \(root.lastPathComponent)."
        }

        resolveDurationsInBackground()
    }

    // MARK: - Merging the drive and the local library

    /// Rebuilds the merged list. One card per clip, wherever it lives.
    func rebuild(local: [Clip]? = nil) {
        clips = Self.merge(device: deviceClips, local: local ?? LocalLibrary.shared.clips)
    }

    static func merge(device: [Clip], local: [Clip]) -> [Clip] {
        var byID: [Clip.ID: Clip] = [:]
        byID.reserveCapacity(device.count + local.count)

        for clip in device {
            var copy = clip
            copy.storage = .device
            byID[clip.id] = copy
        }
        for clip in local {
            var copy = clip
            // The local copy takes over playback where both exist: it keeps
            // working once the drive is unplugged, and reads faster than USB.
            copy.storage = byID[clip.id] == nil ? .local : .both
            byID[clip.id] = copy
        }
        return byID.values.sorted { $0.startDate > $1.startDate }
    }

    /// The drive's own copy of a clip — the one holding the paths to read from
    /// when saving, and the ones to delete when clearing the drive.
    func driveCopy(of id: Clip.ID) -> Clip? {
        deviceClips.first { $0.id == id }
    }

    /// Replaces the assumed 60 s segment length with the real durations, then
    /// republishes so the gallery's badges settle on the correct values.
    private func resolveDurationsInBackground() {
        let snapshot = deviceClips
        durationTask = Task { [weak self] in
            var updated: [Clip] = []
            updated.reserveCapacity(snapshot.count)
            for clip in snapshot {
                if Task.isCancelled { return }
                updated.append(await LibraryScanner.resolveDurations(for: clip))
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.deviceClips.count == updated.count else { return }
                self.deviceClips = updated
                self.rebuild()
            }
        }
    }

    /// The drive was pulled out. Its clips go with it; the ones saved to this
    /// Mac stay, which is the entire point of having saved them.
    ///
    /// The folder bookmark is deliberately kept, so plugging the drive back in
    /// picks up where this left off.
    func driveWasRemoved() {
        rootURL = nil
        resolvedRoot = nil
        deviceClips = []
        scanError = nil
        durationTask?.cancel()
        rebuild()
        selection.formIntersection(Set(clips.map(\.id)))
    }

    func forgetFolder() {
        FolderAccess.forget()
        rootURL = nil
        resolvedRoot = nil
        deviceClips = []
        rebuild()
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
    ///
    /// Recent isn't offered: it's the car's rolling buffer rather than something
    /// kept on purpose, so it's not a category you'd filter down to. Those clips
    /// still appear under All.
    static let leadingCategories: [ClipCategory] = [.saved]

    func triggerCount(_ trigger: ClipTrigger) -> Int {
        clips.filter { $0.trigger == trigger }.count
    }

    var flaggedCount: Int {
        clips.filter(\.isFlagged).count
    }

    // MARK: - The filter row

    /// Chips before the divider: everything, then the folders you keep.
    var leadingChips: [LibraryChip] {
        [.all] + Self.leadingCategories.map { LibraryChip.category($0) }
    }

    /// Chips after it: Sentry, then what the car said happened. `Event` leads
    /// the group as the catch-all — it's the only way to reach clips whose
    /// `reason` string SentryHub doesn't recognise.
    var eventChips: [LibraryChip] {
        var chips: [LibraryChip] = [.category(.sentry)]
        if flaggedCount > 0 { chips.append(.flagged) }
        chips.append(contentsOf: availableTriggers.map { LibraryChip.trigger($0) })
        return chips
    }

    var selectedChip: LibraryChip {
        if let triggerFilter { return .trigger(triggerFilter) }
        if flaggedOnly { return .flagged }
        if let categoryFilter { return .category(categoryFilter) }
        return .all
    }

    func count(for chip: LibraryChip) -> Int {
        switch chip {
        case .all: return clips.count
        case .category(let category): return counts[category] ?? 0
        case .flagged: return flaggedCount
        case .trigger(let trigger): return triggerCount(trigger)
        }
    }

    /// Picking the chip that's already picked goes back to All.
    func select(_ chip: LibraryChip) {
        let target = selectedChip == chip ? LibraryChip.all : chip
        categoryFilter = nil
        triggerFilter = nil
        flaggedOnly = false
        switch target {
        case .all: break
        case .category(let category): categoryFilter = category
        case .flagged: flaggedOnly = true
        case .trigger(let trigger): triggerFilter = trigger
        }
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

        if flaggedOnly {
            result = result.filter(\.isFlagged)
        }

        if let interval = dateInterval {
            result = result.filter { interval.contains($0.startDate) }
        }

        if storageFilter != .any {
            result = result.filter { storageFilter.accepts($0) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { clip in
                if clip.name.lowercased().contains(query) { return true }
                if let label = ClipLabels.shared.label(for: clip)?.lowercased(),
                   label.contains(query) { return true }
                // "saved", "mac", "drive" are things people type when they mean
                // where the footage is, so let them work as search terms.
                if clip.storage.shortLabel.lowercased().contains(query) { return true }
                for incident in IncidentStore.shared.incidents(containing: clip.id) {
                    if incident.title.lowercased().contains(query) { return true }
                    if !incident.reference.isEmpty,
                       incident.reference.lowercased().contains(query) { return true }
                }
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
        flaggedOnly = false
        searchText = ""
        datePreset = .any
        storageFilter = .any
    }

    var hasActiveFilters: Bool {
        categoryFilter != nil || triggerFilter != nil || flaggedOnly || isDateFiltered
            || storageFilter != .any
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Storage

    var savedLocallyCount: Int {
        clips.filter { $0.storage.isSavedLocally }.count
    }

    var driveOnlyCount: Int {
        clips.filter { $0.storage == .device }.count
    }

    var locallySavedBytes: Int64 {
        clips.filter { $0.storage.isSavedLocally }.reduce(0) { $0 + $1.byteCount }
    }

    /// True when nothing is plugged in but the local library still has footage —
    /// the case the whole feature exists for.
    var isRunningWithoutDrive: Bool {
        deviceClips.isEmpty && !clips.isEmpty
    }

    // MARK: - Selection

    func toggleSelection(_ id: Clip.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func beginSelecting(with id: Clip.ID? = nil) {
        isSelecting = true
        if let id { selection.insert(id) }
    }

    func endSelecting() {
        isSelecting = false
        selection.removeAll()
    }

    func selectAllVisible() {
        selection.formUnion(filteredClips.map(\.id))
    }

    /// Everything selected, whether or not the current filters still show it —
    /// changing a filter shouldn't quietly drop clips out of a pending action.
    var selectedClips: [Clip] {
        clips.filter { selection.contains($0.id) }
    }

    /// Selected clips that aren't on this Mac yet, as their *drive* copies.
    var selectionToSave: [Clip] {
        selectedClips
            .filter { !$0.storage.isSavedLocally }
            .compactMap { driveCopy(of: $0.id) }
    }

    var selectionSavedLocally: [Clip] {
        selectedClips.filter { $0.storage.isSavedLocally }
    }

    var selectionOnDrive: [Clip] {
        selectedClips.compactMap { driveCopy(of: $0.id) }
    }

    // MARK: - Selection actions

    func saveSelectionLocally() async {
        let targets = selectionToSave
        guard !targets.isEmpty else {
            ToastCenter.shared.show("Already saved", detail: "Every selected clip is on this Mac.", style: .info)
            return
        }
        await LocalLibrary.shared.save(targets)
    }

    func removeSelectionFromMac() async {
        await LocalLibrary.shared.remove(selectionSavedLocally.map(\.id))
    }

    /// Deletes the drive's copies. Anything saved locally survives — that's the
    /// point of the pairing, and it's what makes clearing the drive safe.
    func deleteSelectionFromDrive() async {
        let targets = selectionOnDrive
        guard !targets.isEmpty else { return }

        let urls = targets.flatMap(\.storedItems)
        let failure = await Task.detached(priority: .utility) {
            ClipFiles.trash(urls)
        }.value

        let ids = Set(targets.map(\.id))
        deviceClips.removeAll { ids.contains($0.id) }
        rebuild()
        // Clips that had a local copy are still here; the rest are gone.
        selection.formIntersection(Set(clips.map(\.id)))

        if let failure {
            ToastCenter.shared.show(
                "Couldn't delete every clip", detail: failure, style: .error
            )
        } else {
            ToastCenter.shared.show(
                "Deleted \(targets.count) clip\(targets.count == 1 ? "" : "s") from the drive",
                detail: "Local copies are untouched.",
                style: .info
            )
        }
    }

    /// Names the selection. One clip takes the name as-is; several get numbered,
    /// in the order the gallery is showing them.
    func renameSelection(to base: String) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = filteredClips.filter { selection.contains($0.id) }
        let targets = ordered.isEmpty ? selectedClips : ordered
        guard !targets.isEmpty else { return }

        if trimmed.isEmpty {
            for clip in targets { ClipLabels.shared.set(nil, for: clip) }
            return
        }
        if targets.count == 1 {
            ClipLabels.shared.set(trimmed, for: targets[0])
            return
        }
        for (index, clip) in targets.enumerated() {
            ClipLabels.shared.set("\(trimmed) \(index + 1)", for: clip)
        }
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
