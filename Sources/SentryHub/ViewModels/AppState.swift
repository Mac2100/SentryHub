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
