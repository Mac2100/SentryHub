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

    private init() {}

    func open(_ clip: Clip) {
        openClip = clip
    }

    func closePlayer() {
        openClip = nil
    }

    /// True once a folder has been picked — before that the welcome screen shows.
    var hasLibrary: Bool { library.rootURL != nil }
}
