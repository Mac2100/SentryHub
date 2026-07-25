import Combine
import Foundation
import SwiftUI

/// Top-level navigation and the objects every screen needs.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let library = LibraryStore()
    let updates = UpdateChecker()

    /// The clip currently open in the player. `nil` shows the library.
    @Published var openClip: Clip?

    /// Set when the user asks for the start screen from the library. Keeps the
    /// chosen folder loaded so coming back is instant.
    @Published private(set) var isShowingStartScreen = false

    /// Which half of the library is on screen.
    @Published var libraryTab: LibraryTab = .clips

    enum LibraryTab: String, CaseIterable, Identifiable {
        case clips, incidents

        var id: String { rawValue }
        var label: String { self == .clips ? "Clips" : "Incidents" }
        var symbolName: String { self == .clips ? "square.grid.2x2" : "folder.badge.person.crop" }
    }

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // `library` and `updates` are nested ObservableObjects. SwiftUI only
        // observes the object a view actually declares, so without forwarding
        // their change events a view watching AppState — like ContentView's
        // welcome/library/player switch, which reads `library.rootURL` — never
        // re-renders when the library loads.
        forward(library.objectWillChange)
        forward(updates.objectWillChange)
        forward(LocalLibrary.shared.objectWillChange)
        forward(IncidentStore.shared.objectWillChange)
    }

    private func forward(_ publisher: ObservableObjectPublisher) {
        publisher
            .sink { [weak self] _ in
                // The nested stores are @MainActor, so their notifications
                // always arrive on the main actor.
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - The drive coming and going

    /// Starts watching for the dashcam drive, and picks up one that's already
    /// attached. Called once the app is on screen.
    func startWatchingDrives() {
        DriveWatcher.shared.driveMounted.sink { [weak self] url in
            MainActor.assumeIsolated { self?.driveAppeared(url) }
        }
        .store(in: &cancellables)

        DriveWatcher.shared.driveUnmounted.sink { [weak self] url in
            MainActor.assumeIsolated { self?.driveDisappeared(url) }
        }
        .store(in: &cancellables)

        DriveWatcher.shared.start()

        // Already plugged in at launch, and nothing restored from last time.
        if library.rootURL == nil, let drive = DriveWatcher.shared.detectedDrive {
            adopt(drive, announce: false)
        }
    }

    private func driveAppeared(_ url: URL) {
        guard library.rootURL == nil else {
            // Something is already loaded. Refresh if this is that same drive
            // coming back, otherwise say so and leave the library alone rather
            // than swapping it out from under someone mid-review.
            if isSameVolume(library.rootURL, url) {
                Task { await library.rescan() }
            } else {
                ToastCenter.shared.show(
                    "Dashcam drive connected",
                    detail: "\(url.lastPathComponent) — open it from Home or Change Folder.",
                    style: .info
                )
            }
            return
        }
        adopt(url)
    }

    private func adopt(_ url: URL, announce: Bool = true) {
        Task {
            await library.load(root: url)
            isShowingStartScreen = false
            guard announce, library.deviceClips.isEmpty == false else { return }
            ToastCenter.shared.show(
                "Dashcam drive connected",
                detail: "\(library.deviceClips.count) clips from \(url.lastPathComponent).",
                style: .success
            )
        }
    }

    private func driveDisappeared(_ url: URL) {
        guard isSameVolume(library.rootURL, url) else { return }

        // A clip playing off the drive has just lost its files. One saved to
        // this Mac is reading from the local copy and carries on.
        if openClip?.storage == .device { closePlayer() }

        let lost = library.deviceClips.count
        library.driveWasRemoved()

        ToastCenter.shared.show(
            "Dashcam drive removed",
            detail: library.clips.isEmpty
                ? "\(lost) clips went with it. Nothing was saved to this Mac."
                : "\(library.clips.count) saved clips are still here.",
            style: .info
        )
    }

    /// Whether a loaded folder lives on the given volume — the folder may be the
    /// volume itself, or `TeslaCam` inside it.
    private func isSameVolume(_ folder: URL?, _ volume: URL) -> Bool {
        guard let folder else { return false }
        return folder == volume
            || folder.path.hasPrefix(volume.path + "/")
            || volume.path.hasPrefix(folder.path + "/")
    }

    func open(_ clip: Clip) {
        isShowingStartScreen = false
        openClip = clip
    }

    func showStartScreen() {
        openClip = nil
        isShowingStartScreen = true
    }

    func showLibrary() {
        isShowingStartScreen = false
    }

    func closePlayer() {
        openClip = nil
    }

    /// True once there is something to show — a chosen drive folder, or clips
    /// saved to this Mac, which are there whether or not the drive is.
    var hasLibrary: Bool {
        library.rootURL != nil || !LocalLibrary.shared.clips.isEmpty
    }

    /// The library is shown when a folder is loaded and the user hasn't asked
    /// to go back to the start screen.
    var showsLibrary: Bool { hasLibrary && !isShowingStartScreen }
}
