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

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // `library` and `updates` are nested ObservableObjects. SwiftUI only
        // observes the object a view actually declares, so without forwarding
        // their change events a view watching AppState — like ContentView's
        // welcome/library/player switch, which reads `library.rootURL` — never
        // re-renders when the library loads.
        forward(library.objectWillChange)
        forward(updates.objectWillChange)
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

    /// True once a folder has been picked — before that the welcome screen shows.
    var hasLibrary: Bool { library.rootURL != nil }

    /// The library is shown when a folder is loaded and the user hasn't asked
    /// to go back to the start screen.
    var showsLibrary: Bool { hasLibrary && !isShowingStartScreen }
}
